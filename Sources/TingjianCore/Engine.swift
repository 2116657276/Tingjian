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

public enum ModelState: Sendable { case ready, needsDownload, unsupported }

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
    private var firstFed = false

    public init() {}

    static func makeTranscriber(progressive: Bool = true) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: progressive ? [.volatileResults] : [],
                          attributeOptions: [.audioTimeRange])
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
        return (try? await AssetInventory.assetInstallationRequest(supporting: [t])) == nil
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
        let t = Self.makeTranscriber()
        guard await Self.modelReady() else { throw EngineError.modelMissing }
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else { throw EngineError.noFormat }
        let a = SpeechAnalyzer(modules: [t])
        try await a.prepareToAnalyze(in: fmt)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        lock.lock()
        analyzer = a; continuation = cont; format = fmt; self.callbacks = callbacks
        lock.unlock()
        resultsTask = Task { [weak self] in
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
                if let self, !self.isEnding { self.markFailed(); await callbacks.failure(error) }
            }
        }
        try await a.start(inputSequence: stream)
    }

    private var isEnding: Bool { lock.lock(); defer { lock.unlock() }; return finishing || cancelled }
    private func markFailed() { lock.lock(); failed = true; lock.unlock() }

    public func feed(_ buffer: AVAudioPCMBuffer, start: Double) {
        convQueue.async { [self] in
            lock.lock(); let cont = continuation; let fmt = format; let cb = callbacks; let dead = failed; lock.unlock()
            guard let cont, let fmt, !dead else { return }
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: fmt)
            }
            guard let converter else { return }
            let ratio = fmt.sampleRate / buffer.format.sampleRate
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return }
            var supplied = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, st in
                if supplied { st.pointee = .noDataNow; return nil }
                supplied = true; st.pointee = .haveData; return buffer
            }
            if let err {
                markFailed()
                if let cb { Task { await cb.failure(EngineError.conversion(err.localizedDescription)) } }
                return
            }
            guard out.frameLength > 0 else { return }
            if !firstFed {
                firstFed = true
                cont.yield(AnalyzerInput(buffer: out, bufferStartTime: CMTime(seconds: start, preferredTimescale: 1_000_000)))
            } else {
                cont.yield(AnalyzerInput(buffer: out))
            }
        }
    }

    public func finish() async -> Bool {
        lock.lock(); finishing = true; let a = analyzer; lock.unlock()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            convQueue.async { [self] in
                // 冲刷重采样器尾部
                if let converter, let fmt = format, let cont = continuation,
                   let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096) {
                    var err: NSError?
                    converter.convert(to: out, error: &err) { _, st in st.pointee = .endOfStream; return nil }
                    if err == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
                }
                continuation?.finish()
                c.resume()
            }
        }
        guard let a else { return false }
        do { try await a.finalizeAndFinishThroughEndOfInput() } catch { return false }
        await resultsTask?.value
        lock.lock(); let ok = !failed; lock.unlock()
        return ok
    }

    public func cancel() async {
        lock.lock(); cancelled = true; let a = analyzer; let c = continuation; lock.unlock()
        c?.finish()
        resultsTask?.cancel()
        await a?.cancelAndFinishNow()
    }
}
