import AVFoundation
import Foundation
import Speech

public struct EngineCallbacks: Sendable {
    public var volatile: @MainActor @Sendable (_ text: String, _ start: Double) -> Void
    public var final: @MainActor @Sendable (_ start: Double, _ end: Double, _ text: String) -> Void
    public var failure: @MainActor @Sendable (_ error: Error) -> Void
    public init(volatile: @escaping @MainActor @Sendable (String, Double) -> Void,
                final: @escaping @MainActor @Sendable (Double, Double, String) -> Void,
                failure: @escaping @MainActor @Sendable (Error) -> Void) {
        self.volatile = volatile; self.final = final; self.failure = failure
    }
}

public enum ModelState: Equatable, Sendable { case ready, needsDownload, unsupported }

/// 转写引擎抽象:每个实例只服务一次分析会话,恢复时重新创建。
public protocol TranscriptionEngine: AnyObject, Sendable {
    var name: String { get }
    var languageTag: String { get }
    func modelState() async -> ModelState
    func installModel(progress: @escaping @Sendable (Double) -> Void) async throws
    func start(callbacks: EngineCallbacks) async throws
    /// 非阻塞;第一块音频携带起始时间,之后按连续音频处理。
    func feed(_ buffer: AVAudioPCMBuffer, start: Double)
    /// 提交尾部音频并等待最终结果送达。返回 false 表示出错。
    func finish() async -> Bool
    func cancel() async
}

public enum EngineError: Error, LocalizedError {
    case modelMissing, noFormat, resultsEnded, conversion(String)
    public var errorDescription: String? {
        switch self {
        case .modelMissing: return "中文识别模型未安装"
        case .noFormat: return "没有可用的识别音频格式"
        case .resultsEnded: return "识别结果流意外结束"
        case .conversion(let m): return "音频转换失败:\(m)"
        }
    }
}

/// Apple SpeechAnalyzer + SpeechTranscriber(简体中文)。
public final class SpeechEngine: TranscriptionEngine, @unchecked Sendable {
    public static let locale = Locale(identifier: "zh_CN")
    public let name = "Apple SpeechAnalyzer / SpeechTranscriber"
    public let languageTag = "zh-CN"

    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private var callbacks: EngineCallbacks?
    private var finishing = false
    private var cancelled = false
    private var failed = false
    private let convQueue = DispatchQueue(label: "tingjian.speech.convert", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var firstFed = false
    private var firstStartTime: Double?
    private var pendingBuffer: AVAudioPCMBuffer?
    private var streamEnded = false
    private let fastResults: Bool
    private let observeInput: (@Sendable (_ frames: Int, _ sampleRate: Double) -> Void)?

    /// 首包尽快送出（约 40ms）保证首字响应；稳态聚合到约 80ms，减少过碎分片导致的 SpeechAnalyzer 调度开销。
    private static let firstPacketSeconds = 0.04
    private static let coalesceSeconds = 0.08

    public init() {
        fastResults = true
        observeInput = nil
    }

    @_spi(Testing) public init(fastResults: Bool, observeInput: (@Sendable (Int, Double) -> Void)? = nil) {
        self.fastResults = fastResults
        self.observeInput = observeInput
    }

    static func makeTranscriber(progressive: Bool = true, fastResults: Bool = true) -> SpeechTranscriber {
        let reporting: Set<SpeechTranscriber.ReportingOption> = progressive
            ? (fastResults ? [.volatileResults, .fastResults] : [.volatileResults]) : []
        return SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                 reportingOptions: reporting, attributeOptions: [.audioTimeRange])
    }

    public func modelState() async -> ModelState {
        guard SpeechTranscriber.isAvailable,
              await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale) != nil else { return .unsupported }
        return await Self.modelReady() ? .ready : .needsDownload
    }

    /// status 在首次分析前可能仍是 supported;以"安装请求为 nil"(无需下载)为准。
    static func modelReady() async -> Bool {
        let t = makeTranscriber()
        if await AssetInventory.status(forModules: [t]) == .installed { return true }
        do { return try await AssetInventory.assetInstallationRequest(supporting: [t]) == nil }
        catch { return false }
    }

    public func installModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        let t = Self.makeTranscriber()
        guard let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) else { return }
        let poll = Task {
            while !Task.isCancelled {
                progress(req.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { poll.cancel() }
        try await req.downloadAndInstall()
    }

    public func start(callbacks: EngineCallbacks) async throws {
        let t = Self.makeTranscriber(fastResults: fastResults)
        guard await Self.modelReady() else { throw EngineError.modelMissing }
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else { throw EngineError.noFormat }
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        let a = SpeechAnalyzer(modules: [t], options: options)
        try await a.prepareToAnalyze(in: fmt)
        try Task.checkCancellation()
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let task = Task { [weak self] in
            var lastStart = 0.0
            do {
                for try await r in t.results {
                    let text = String(r.text.characters)
                    let s = r.range.start.seconds.isFinite ? r.range.start.seconds : lastStart
                    let e = r.range.end.seconds.isFinite ? r.range.end.seconds : s
                    lastStart = s
                    if r.isFinal { await callbacks.final(s, e, text) } else { await callbacks.volatile(text, s) }
                }
                if let self, !self.isEnding { self.markFailed(); await callbacks.failure(EngineError.resultsEnded) }
            } catch {
                if let self, self.recordResultError() { await callbacks.failure(error) }
            }
        }
        let alreadyCancelled = lock.withLock { () -> Bool in
            if cancelled { return true }
            analyzer = a
            continuation = cont
            format = fmt
            self.callbacks = callbacks
            resultsTask = task
            return false
        }
        if alreadyCancelled {
            cont.finish()
            task.cancel()
            throw CancellationError()
        }
        do {
            try await a.start(inputSequence: stream)
        } catch {
            lock.withLock {
                cancelled = true
                analyzer = nil
                continuation = nil
                format = nil
                self.callbacks = nil
                resultsTask = nil
            }
            cont.finish()
            task.cancel()
            convQueue.async { [self] in
                streamEnded = true
                converter = nil
                converterInputFormat = nil
                pendingBuffer = nil
            }
            throw error
        }
    }

    private var isEnding: Bool { lock.lock(); defer { lock.unlock() }; return finishing || cancelled }
    private func recordResultError() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        failed = true
        return !finishing
    }

    private func markFailed() { lock.lock(); failed = true; lock.unlock() }

    public func feed(_ buffer: AVAudioPCMBuffer, start: Double) {
        guard buffer.frameLength > 0 else { return }
        convQueue.async { [self] in
            let (cont, fmt, dead) = lock.withLock { (continuation, format, failed || cancelled) }
            guard let cont, let fmt, !dead, !streamEnded else { return }
            if firstStartTime == nil { firstStartTime = start }

            if buffer.format == fmt {
                if let existing = converter {
                    guard flushConverter(existing, format: fmt, continuation: cont) else { return }
                    converter = nil
                    converterInputFormat = nil
                }
                enqueueOutput(buffer, format: fmt, continuation: cont, ownsBuffer: false)
                return
            }

            if converter == nil || converterInputFormat != buffer.format {
                if let existing = converter {
                    guard flushConverter(existing, format: fmt, continuation: cont) else { return }
                }
                let next = AVAudioConverter(from: buffer.format, to: fmt)
                next?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
                converter = next
                converterInputFormat = buffer.format
            }
            guard let converter else {
                reportConversionFailure(EngineError.conversion("不支持的输入格式:\(buffer.format)"))
                return
            }

            let ratio = fmt.sampleRate / buffer.format.sampleRate
            let cap = max(AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1024, 1024)
            var supplied = false
            while true {
                guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else {
                    reportConversionFailure(EngineError.conversion("无法分配识别重采样缓冲"))
                    return
                }
                var err: NSError?
                let status = converter.convert(to: out, error: &err) { _, st in
                    if supplied { st.pointee = .noDataNow; return nil }
                    supplied = true; st.pointee = .haveData; return buffer
                }
                if let err {
                    reportConversionFailure(EngineError.conversion(err.localizedDescription))
                    return
                }
                if status == .error {
                    reportConversionFailure(EngineError.conversion("音频重采样返回错误状态"))
                    return
                }
                if out.frameLength > 0 {
                    enqueueOutput(out, format: fmt, continuation: cont, ownsBuffer: true)
                }
                if status != .haveData || out.frameLength < cap { break }
            }
        }
    }

    public func finish() async -> Bool {
        let a = lock.withLock { finishing = true; return analyzer }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            convQueue.async { [self] in
                lock.lock(); let dead = failed || cancelled; let fmt = format; let cont = continuation; lock.unlock()
                if !dead, !streamEnded, let fmt, let cont {
                    // 先冲刷重采样器内部滤波器残留样本，再完整冲刷聚合缓冲中的尾部样本
                    if let converter {
                        _ = flushConverter(converter, format: fmt, continuation: cont)
                    }
                    flushPending(continuation: cont)
                }
                streamEnded = true
                converter = nil
                converterInputFormat = nil
                pendingBuffer = nil
                cont?.finish()
                c.resume()
            }
        }
        guard let a else { return false }
        do { try await a.finalizeAndFinishThroughEndOfInput() } catch { return false }
        await resultsTask?.value
        return lock.withLock { !failed && !cancelled }
    }

    public func cancel() async {
        let (a, c) = lock.withLock { cancelled = true; return (analyzer, continuation) }
        c?.finish()
        convQueue.async { [self] in
            streamEnded = true
            converter = nil
            converterInputFormat = nil
            pendingBuffer = nil
        }
        resultsTask?.cancel()
        await a?.cancelAndFinishNow()
    }

    // MARK: 流式重采样冲刷与帧聚合（仅在 convQueue 上调用）

    private func flushConverter(_ converter: AVAudioConverter, format fmt: AVAudioFormat,
                                continuation cont: AsyncStream<AnalyzerInput>.Continuation) -> Bool {
        do {
            try drainPCM(converter) { out in
                enqueueOutput(out, format: fmt, continuation: cont, ownsBuffer: true)
            }
            return true
        } catch {
            let failure = error is EngineError ? error : EngineError.conversion(error.localizedDescription)
            reportConversionFailure(failure)
            return false
        }
    }

    private func reportConversionFailure(_ error: Error) {
        let callback = lock.withLock { () -> EngineCallbacks? in
            guard !failed, !cancelled else { return nil }
            failed = true
            return finishing ? nil : callbacks
        }
        if let callback { Task { await callback.failure(error) } }
    }

    private func enqueueOutput(_ chunk: AVAudioPCMBuffer, format fmt: AVAudioFormat,
                               continuation cont: AsyncStream<AnalyzerInput>.Continuation, ownsBuffer: Bool) {
        guard chunk.frameLength > 0 else { return }
        let targetSeconds = firstFed ? Self.coalesceSeconds : Self.firstPacketSeconds
        let threshold = AVAudioFrameCount(max(1, Int((fmt.sampleRate * targetSeconds).rounded())))

        if pendingBuffer == nil {
            if ownsBuffer, chunk.frameLength >= threshold {
                yieldBuffer(chunk, continuation: cont)
                return
            }
            let cap = max(threshold * 2, chunk.frameLength + threshold, 4096)
            guard let acc = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return }
            if Self.appendFrames(from: chunk, to: acc) {
                pendingBuffer = acc
                if acc.frameLength >= threshold {
                    flushPending(continuation: cont)
                }
            }
            return
        }

        guard let acc = pendingBuffer else { return }
        let totalFrames = acc.frameLength + chunk.frameLength
        if totalFrames <= acc.frameCapacity {
            _ = Self.appendFrames(from: chunk, to: acc)
        } else {
            let cap = max(totalFrames, threshold * 2, 4096)
            guard let grown = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return }
            _ = Self.appendFrames(from: acc, to: grown)
            _ = Self.appendFrames(from: chunk, to: grown)
            pendingBuffer = grown
        }
        if let current = pendingBuffer, current.frameLength >= threshold {
            flushPending(continuation: cont)
        }
    }

    private func flushPending(continuation cont: AsyncStream<AnalyzerInput>.Continuation) {
        guard let buf = pendingBuffer, buf.frameLength > 0 else {
            pendingBuffer = nil
            return
        }
        pendingBuffer = nil
        yieldBuffer(buf, continuation: cont)
    }

    private func yieldBuffer(_ buffer: AVAudioPCMBuffer, continuation cont: AsyncStream<AnalyzerInput>.Continuation) {
        guard buffer.frameLength > 0 else { return }
        observeInput?(Int(buffer.frameLength), buffer.format.sampleRate)
        if !firstFed {
            firstFed = true
            let start = firstStartTime ?? 0
            cont.yield(AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(seconds: start, preferredTimescale: 1_000_000)))
        } else {
            cont.yield(AnalyzerInput(buffer: buffer))
        }
    }

    /// 格式无关的线性 PCM 帧追加（兼容 Int16/Int32/Float32 及交错/非交错布局）。
    private static func appendFrames(from src: AVAudioPCMBuffer, to dst: AVAudioPCMBuffer) -> Bool {
        let count = src.frameLength
        guard count > 0 else { return true }
        let offset = dst.frameLength
        guard offset + count <= dst.frameCapacity else { return false }
        let bytesPerFrame = Int(src.format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, bytesPerFrame == Int(dst.format.streamDescription.pointee.mBytesPerFrame) else { return false }

        dst.frameLength = offset + count
        let srcList = UnsafeMutableAudioBufferListPointer(src.mutableAudioBufferList)
        let dstList = UnsafeMutableAudioBufferListPointer(dst.mutableAudioBufferList)
        guard srcList.count == dstList.count else {
            dst.frameLength = offset
            return false
        }
        let byteCount = Int(count) * bytesPerFrame
        let byteOffset = Int(offset) * bytesPerFrame
        for i in 0..<srcList.count {
            guard let srcData = srcList[i].mData, let dstData = dstList[i].mData else {
                dst.frameLength = offset
                return false
            }
            memcpy(dstData.advanced(by: byteOffset), srcData, byteCount)
        }
        return true
    }
}
