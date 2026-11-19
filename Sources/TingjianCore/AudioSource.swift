import AVFoundation
import Foundation

/// 一个可选的音频输入设备。id 为系统 uniqueID,应用用它固定输入,不修改系统默认设备。
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

public enum AudioInputCatalog {
    public static var defaultUID: String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    /// 按名称排序;系统默认设备排在最前。
    public static func devices() -> [AudioInputDevice] {
        let defaultUID = Self.defaultUID
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
        return session.devices
            .filter { $0.isConnected }
            .map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultUID) }
            .sorted { a, b in
                if a.isDefault != b.isDefault { return a.isDefault }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    public static func device(forUID uid: String) -> AudioInputDevice? {
        devices().first { $0.id == uid }
    }
}

/// 音频输入抽象:麦克风用于真实录音,文件源只用于用合成音频验证管线。
public protocol AudioSource: AnyObject {
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }
    var onInterruption: (@Sendable (String) -> Void)? { get set }
    var onEnd: (@Sendable () -> Void)? { get set }
    /// 实际使用的输入设备;文件、合成源为 nil。
    var activeDeviceUID: String? { get }
    var activeDeviceName: String? { get }
    func requestAccess() async -> Bool
    /// 准备输入并返回缓冲区格式,此时尚未开始采集。
    func prepare() async throws -> AVAudioFormat
    func start() async throws
    /// 设备变化后重建输入并继续采集(时间轴由写盘端累加)。
    func restart() async throws
    func pause() async
    func stop() async
}

public enum AudioError: Error, LocalizedError {
    case noInput
    case deviceUnavailable(String)
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noInput: return "没有可用的音频输入设备"
        case .deviceUnavailable(let name): return "输入设备不可用:\(name)"
        case .captureFailed(let message): return "麦克风采集失败:\(message)"
        }
    }
}

/// 按 uniqueID 固定输入的设备麦克风。只有 start() 被调用后才采集。
public final class MicrophoneSource: NSObject, AudioSource, AVCaptureAudioDataOutputSampleBufferDelegate {
    public var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    public var onInterruption: (@Sendable (String) -> Void)?
    public var onEnd: (@Sendable () -> Void)?

    public private(set) var activeDeviceUID: String?
    public private(set) var activeDeviceName: String?

    private let requestedUID: String?
    private var resolvedUID: String?
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let controlQueue = DispatchQueue(label: "tingjian.mic.control", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "tingjian.mic.samples", qos: .userInitiated)
    private let lock = NSLock()
    private var gate = false
    private var configured = false
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                             channels: 1, interleaved: false)!
    private var observers: [NSObjectProtocol] = []

    /// deviceUID 为 nil 时只在首次 prepare 解析系统默认设备,之后固定不变。
    public init(deviceUID: String? = nil) {
        self.requestedUID = deviceUID
        super.init()
    }

    public func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func prepare() async throws -> AVAudioFormat {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AVAudioFormat, Error>) in
            controlQueue.async {
                do { cont.resume(returning: try self.configureLocked()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            controlQueue.async {
                guard self.configured else {
                    cont.resume(throwing: AudioError.captureFailed("输入尚未准备"))
                    return
                }
                self.setGate(true)
                if !self.session.isRunning { self.session.startRunning() }
                cont.resume()
            }
        }
    }

    public func restart() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            controlQueue.async {
                do {
                    _ = try self.configureLocked()
                    self.setGate(true)
                    if !self.session.isRunning { self.session.startRunning() }
                    cont.resume()
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    public func pause() async {
        setGate(false)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            controlQueue.async {
                if self.session.isRunning { self.session.stopRunning() }
                // 排空已进入的 sample 回调,返回后不会再投递缓冲区。
                self.sampleQueue.sync {}
                cont.resume()
            }
        }
    }

    public func stop() async {
        setGate(false)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            controlQueue.async {
                if self.session.isRunning { self.session.stopRunning() }
                self.sampleQueue.sync {}
                self.teardownLocked()
                cont.resume()
            }
        }
    }

    // MARK: 配置

    private func configureLocked() throws -> AVAudioFormat {
        setGate(false)
        if session.isRunning { session.stopRunning() }
        teardownLocked()

        let uid: String
        if let resolvedUID {
            uid = resolvedUID
        } else if let requestedUID {
            uid = requestedUID
            resolvedUID = requestedUID
        } else if let fallback = AudioInputCatalog.defaultUID {
            uid = fallback
            resolvedUID = fallback
        } else {
            throw AudioError.noInput
        }
        guard let device = AVCaptureDevice(uniqueID: uid), device.isConnected else {
            throw AudioError.deviceUnavailable(uid)
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) }
        catch { throw AudioError.captureFailed(error.localizedDescription) }

        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        else {
            session.commitConfiguration()
            throw AudioError.captureFailed("无法使用输入设备 \(device.localizedName)")
        }
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        else {
            session.commitConfiguration()
            throw AudioError.captureFailed("无法添加音频输出")
        }
        session.commitConfiguration()

        activeDeviceUID = device.uniqueID
        activeDeviceName = device.localizedName
        configured = true
        observeNotifications(device: device)
        return targetFormat
    }

    private func teardownLocked() {
        if configured {
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
            session.commitConfiguration()
        }
        configured = false
        converter = nil
        converterInput = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func observeNotifications(device: AVCaptureDevice) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.interrupt("麦克风运行时错误:\(error?.localizedDescription ?? "未知原因")")
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
            self?.interrupt("输入设备已断开:\(device.localizedName)")
        })
    }

    private func interrupt(_ message: String) {
        setGate(false)
        if configured { controlQueue.async { if self.session.isRunning { self.session.stopRunning() } } }
        onInterruption?(message)
    }

    // MARK: 采集

    private func setGate(_ open: Bool) {
        lock.lock(); gate = open; lock.unlock()
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock(); let open = gate; lock.unlock()
        guard open else { return }
        guard let buffer = Self.makeBuffer(sampleBuffer) else { return }
        let ready: AVAudioPCMBuffer
        if buffer.format.sampleRate == targetFormat.sampleRate,
           buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32 {
            ready = buffer
        } else if let converted = convert(buffer) {
            ready = converted
        } else {
            return
        }
        guard ready.frameLength > 0 else { return }
        onBuffer?(ready)
    }

    /// 在 sampleBuffer 有效期内以无拷贝包装交出样本,由 AudioPipeline 同步拷贝。
    private static func makeBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        var needed = 0
        let probe = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: nil)
        guard probe == noErr, needed > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr else {
            raw.deallocate()
            return nil
        }
        let held = block
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: { _ in
            // held 由闭包持有,保证样本在缓冲区生命周期内有效;闭包释放时随之释放。
            withExtendedLifetime(held) {}
            raw.deallocate()
        }) else {
            withExtendedLifetime(held) {}
            raw.deallocate()
            return nil
        }
        pcm.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        return pcm
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterInput = buffer.format
        }
        guard let converter else {
            interrupt("音频格式不支持:\(buffer.format)")
            return nil
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        if let error {
            interrupt("音频转换失败:\(error.localizedDescription)")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }
}

/// 从音频文件读取并按时间节奏送出,仅用于自动验证(合成音频)。
public final class FileSource: AudioSource, @unchecked Sendable {
    public var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    public var onInterruption: (@Sendable (String) -> Void)?
    public var onEnd: (@Sendable () -> Void)?
    public var activeDeviceUID: String? { nil }
    public var activeDeviceName: String? { nil }

    private let url: URL
    private let speed: Double
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var running = false
    private var stopped = false
    private var task: Task<Void, Never>?

    /// speed 为实时倍率;0 表示不限速。
    public init(url: URL, speed: Double = 1) { self.url = url; self.speed = speed }

    public func requestAccess() async -> Bool { true }

    public func prepare() async throws -> AVAudioFormat {
        let f = try AVAudioFile(forReading: url)
        lock.lock(); file = f; lock.unlock()
        return f.processingFormat
    }

    public func start() async throws {
        lock.lock()
        guard let file = self.file else { lock.unlock(); throw AudioError.noInput }
        running = true
        let alreadyRunning = task != nil
        lock.unlock()
        if alreadyRunning { return }
        let chunk: AVAudioFrameCount = 4096
        let rate = file.processingFormat.sampleRate
        task = Task.detached { [weak self] in
            while let self, !Task.isCancelled {
                self.lock.lock(); let run = self.running; let stop = self.stopped; self.lock.unlock()
                if stop { return }
                if !run { try? await Task.sleep(for: .milliseconds(20)); continue }
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return }
                do { try file.read(into: buf, frameCount: chunk) } catch { self.onEnd?(); return }
                if buf.frameLength == 0 { self.onEnd?(); return }
                self.onBuffer?(buf)
                if self.speed > 0 {
                    try? await Task.sleep(for: .seconds(Double(buf.frameLength) / rate / self.speed))
                } else {
                    await Task.yield()
                }
            }
        }
    }

    public func restart() async throws { try await start() }

    public func pause() async {
        lock.lock(); running = false; lock.unlock()
    }

    public func stop() async {
        lock.lock(); stopped = true; running = false; lock.unlock()
        task?.cancel(); task = nil
    }
}
