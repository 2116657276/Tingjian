import AVFoundation
import CoreAudio
import Foundation
import IOKit

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

    /// 通过 CoreAudio 查询指定 UID 对应物理设备是否为内置麦克风；查不到时返回 nil（不误判）。
    public static func isBuiltInDevice(uid: String) -> Bool? {
        guard let deviceID = coreAudioDeviceID(forUID: uid) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        guard status == noErr else { return nil }
        return transport == kAudioDeviceTransportTypeBuiltIn
    }

    private static func coreAudioDeviceID(forUID targetUID: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids) == noErr else {
            return nil
        }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for deviceID in ids {
            var unmanagedUID: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &unmanagedUID) { ptr in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
            }
            guard status == noErr, let cfUID = unmanagedUID?.takeRetainedValue() else { continue }
            if (cfUID as String) == targetUID { return deviceID }
        }
        return nil
    }
}

/// 硬件录音前置环境抽象：用于识别“Mac 合盖 + 内置麦克风硬件断开”并在测试中注入可控状态。
public protocol HardwareInputEnvironment: Sendable {
    /// Mac 是否合盖；无法判定（如台式机或系统属性缺失）返回 nil，降级放行。
    func isClamshellClosed() -> Bool?
    /// 当前系统默认音频输入设备 UID。
    func defaultInputUID() -> String?
    /// 指定 UID 是否为内置麦克风；无法判定返回 nil。
    func isBuiltInInput(uid: String) -> Bool?
}

public struct SystemHardwareInputEnvironment: HardwareInputEnvironment {
    public init() {}

    public func isClamshellClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else {
            return nil
        }
        return property as? Bool
    }

    public func defaultInputUID() -> String? {
        AudioInputCatalog.defaultUID
    }

    public func isBuiltInInput(uid: String) -> Bool? {
        AudioInputCatalog.isBuiltInDevice(uid: uid)
    }
}

public enum HardwareInputGuard {
    public static let clamshellBuiltInMessage =
        "Mac 已合盖，内置麦克风已由硬件断开无法收音。请打开屏幕，或在底栏选择耳机或其他外接麦克风。"

    /// 检查给定请求设备（nil 表示系统默认）在当前硬件环境下是否应拦截。
    /// 仅当明确确认「已合盖」且最终指向「内置麦克风」时返回拦截说明；无法确定时降级返回 nil。
    public static func blockReason(for requestedUID: String?, environment: HardwareInputEnvironment) -> String? {
        guard environment.isClamshellClosed() == true else { return nil }
        guard let effectiveUID = requestedUID ?? environment.defaultInputUID() else { return nil }
        guard environment.isBuiltInInput(uid: effectiveUID) == true else { return nil }
        return clamshellBuiltInMessage
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
    /// 是否为真实硬件麦克风音源（需要执行合盖+内置麦前置守卫）。文件/合成源默认 false。
    var requiresHardwareInputGuard: Bool { get }
    func requestAccess() async -> Bool
    /// 准备输入并返回缓冲区格式,此时尚未开始采集。
    func prepare() async throws -> AVAudioFormat
    func start() async throws
    /// 设备变化后重建输入并继续采集(时间轴由写盘端累加)。
    func restart() async throws
    func pause() async
    func stop() async
}

public extension AudioSource {
    var requiresHardwareInputGuard: Bool { false }
}

public enum AudioError: Error, LocalizedError {
    case noInput
    case deviceUnavailable(String)
    case captureFailed(String)
    case clamshellBuiltInUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .noInput: return "没有可用的音频输入设备"
        case .deviceUnavailable(let name): return "输入设备不可用:\(name)"
        case .captureFailed(let message): return "麦克风采集失败:\(message)"
        case .clamshellBuiltInUnavailable(let message): return message
        }
    }
}

/// 按 uniqueID 固定输入的设备麦克风。只有 start() 被调用后才采集。
/// 并发安全约束：会话配置/启停串行于 `controlQueue`，音频样本与转换器串行于 `sampleQueue`，`gate` 由 `lock` 保护。
public final class MicrophoneSource: NSObject, AudioSource, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    public var onInterruption: (@Sendable (String) -> Void)?
    public var onEnd: (@Sendable () -> Void)?

    public private(set) var activeDeviceUID: String?
    public private(set) var activeDeviceName: String?
    public var requiresHardwareInputGuard: Bool { true }

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
                // 暂停也是输入设备切换的边界，先投递旧设备的尾帧。
                self.sampleQueue.sync { _ = self.flushConverter() }
                cont.resume()
            }
        }
    }

    public func stop() async {
        setGate(false)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            controlQueue.async {
                if self.session.isRunning { self.session.stopRunning() }
                self.sampleQueue.sync { _ = self.flushConverter() }
                self.teardownLocked()
                cont.resume()
            }
        }
    }

    // MARK: 配置

    private func configureLocked() throws -> AVAudioFormat {
        setGate(false)
        if session.isRunning { session.stopRunning() }
        sampleQueue.sync { _ = flushConverter() }
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
            session.removeInput(input)
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
        if configured || !session.inputs.isEmpty || !session.outputs.isEmpty {
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
            session.commitConfiguration()
        }
        configured = false
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
        controlQueue.async { if self.session.isRunning { self.session.stopRunning() } }
        onInterruption?(message)
    }

    // MARK: 采集

    private func setGate(_ open: Bool) {
        lock.lock(); gate = open; lock.unlock()
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock(); let open = gate; lock.unlock()
        guard open else { return }
        guard let buffer = Self.makeBuffer(sampleBuffer), buffer.frameLength > 0 else { return }
        if converterInput != buffer.format, !flushConverter() { return }
        if buffer.format.sampleRate == targetFormat.sampleRate,
           buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32 {
            onBuffer?(buffer)
        } else {
            convert(buffer)
        }
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
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0, sampleCount <= Int(pcm.frameCapacity) else { return nil }
        pcm.frameLength = AVAudioFrameCount(sampleCount)
        return pcm
    }

    @discardableResult
    private func flushConverter() -> Bool {
        guard let converter else { return true }
        defer { self.converter = nil; converterInput = nil }
        do {
            try drainPCM(converter) { onBuffer?($0) }
            return true
        } catch {
            interrupt("音频转换收尾失败:\(error.localizedDescription)")
            return false
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        if converter == nil {
            let next = AVAudioConverter(from: buffer.format, to: targetFormat)
            next?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = next
            converterInput = buffer.format
        }
        guard let converter else {
            interrupt("音频格式不支持:\(buffer.format)")
            return
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = max(AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1024, 1024)
        var supplied = false
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                interrupt("无法分配采集重采样缓冲")
                return
            }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            if error != nil || status == .error {
                interrupt("音频转换失败:\(error?.localizedDescription ?? "重采样返回错误状态")")
                return
            }
            if out.frameLength > 0 { onBuffer?(out) }
            if status != .haveData || out.frameLength < capacity { return }
        }
    }
}

/// 从音频文件读取并按时间节奏送出,仅用于自动验证(合成音频)。
public final class FileSource: AudioSource, @unchecked Sendable {
    public var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    public var onInterruption: (@Sendable (String) -> Void)?
    public var onEnd: (@Sendable () -> Void)?
    public var activeDeviceUID: String? { nil }
    public var activeDeviceName: String? { nil }
    @_spi(Testing) public var observeBuffer: (@Sendable (Int, Double) -> Void)?

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
        guard f.length > 0 else { throw AudioError.captureFailed("合成音频无采样") }
        let sampleRate = f.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AudioError.captureFailed("合成音频采样率无效")
        }
        lock.withLock { file = f }
        return f.processingFormat
    }

    public func start() async throws {
        try lock.withLock {
            guard let file, !stopped else { throw AudioError.noInput }
            running = true
            guard task == nil else { return }
            let totalFrames = file.length
            task = Task.detached { [weak self] in
                var deadline = ContinuousClock.now
                while let self, !Task.isCancelled {
                    do {
                        switch try self.readNext(from: file, totalFrames: totalFrames) {
                        case .paused:
                            try await Task.sleep(for: .milliseconds(20))
                            deadline = .now
                        case .end:
                            self.finishReading()
                            self.onEnd?()
                            return
                        case .delivered(let duration):
                            if self.speed > 0 {
                                deadline = deadline.advanced(by: .seconds(duration / self.speed))
                                try await Task.sleep(until: deadline, clock: .continuous)
                            } else {
                                await Task.yield()
                            }
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        self.finishReading()
                        self.onInterruption?(error.localizedDescription)
                        return
                    }
                }
            }
        }
    }

    private enum ReadResult { case paused, end, delivered(Double) }

    private enum NextChunk {
        case paused
        case end
        case buffer(
            AVAudioPCMBuffer,
            rate: Double,
            observe: (@Sendable (Int, Double) -> Void)?,
            deliver: (@Sendable (AVAudioPCMBuffer) -> Void)?
        )
    }

    private func finishReading() {
        lock.withLock { task = nil; running = false }
    }

    private func readNext(from file: AVAudioFile, totalFrames: AVAudioFramePosition) throws -> ReadResult {
        let next: NextChunk = try lock.withLock {
            if stopped { throw CancellationError() }
            if !running { return .paused }
            let remaining = totalFrames - file.framePosition
            if remaining <= 0 { return .end }
            let chunk = AVAudioFrameCount(min(4096, remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
                throw AudioError.captureFailed("无法分配合成音频缓冲")
            }
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { return .end }
            let rate = buffer.format.sampleRate
            guard rate.isFinite, rate > 0 else {
                throw AudioError.captureFailed("合成音频采样率无效")
            }
            return .buffer(buffer, rate: rate, observe: observeBuffer, deliver: onBuffer)
        }
        switch next {
        case .paused:
            return .paused
        case .end:
            return .end
        case .buffer(let buffer, let rate, let observe, let deliver):
            observe?(Int(buffer.frameLength), rate)
            deliver?(buffer)
            return .delivered(Double(buffer.frameLength) / rate)
        }
    }

    public func restart() async throws { try await start() }

    public func pause() async {
        lock.withLock { running = false }
    }

    public func stop() async {
        let pending = lock.withLock {
            stopped = true; running = false
            let pending = task
            task = nil
            return pending
        }
        pending?.cancel()
        await pending?.value
    }
}
