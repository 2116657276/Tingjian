import AVFoundation
import Foundation
import Speech

/// 从已保存的录音文件重新转写(失败会话的补救),结果另存,不覆盖任何原文件。
public enum Retranscriber {
    public static func run(audio: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> TranscriptAssembler {
        let t = SpeechEngine.makeTranscriber(progressive: false)
        guard await SpeechEngine.modelReady() else { throw EngineError.modelMissing }
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
            throw EngineError.noFormat
        }
        let file = try AVAudioFile(forReading: audio)
        let sampleRate = file.processingFormat.sampleRate
        let total = sampleRate.isFinite && sampleRate > 0 ? Double(file.length) / sampleRate : 0
        let analyzer = SpeechAnalyzer(modules: [t])
        try await analyzer.prepareToAnalyze(in: targetFormat)

        let collector = Task { () -> TranscriptAssembler in
            var asm = TranscriptAssembler()
            for try await r in t.results where r.isFinal {
                let s = r.range.start.seconds, e = r.range.end.seconds
                let safeStart = s.isFinite ? s : asm.lastEnd
                let safeEnd = e.isFinite ? e : safeStart
                asm.commit(start: safeStart, end: safeEnd, text: String(r.text.characters))
                if total.isFinite, total > 0 {
                    let ratio = safeEnd / total
                    if ratio.isFinite {
                        progress(min(1.0, max(0.0, ratio)))
                    }
                }
            }
            return asm
        }
        do {
            let inputSequence = try EnhancedAudioSequence(audio: audio, targetFormat: targetFormat)
            if let last = try await analyzer.analyzeSequence(inputSequence) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await collector.value
    }

    /// 写出 `<原名>_重转写.md` 到音频所在目录。
    public static func writeMarkdown(audio: URL, assembler: TranscriptAssembler, duration: Double) throws -> URL {
        let base = audio.deletingPathExtension().lastPathComponent
        let hasText = assembler.segments.contains {
            !$0.incomplete && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let status: TranscriptStatus = hasText ? .completed : .partial
        var notes = ["本文件由已保存录音重新转写生成，不覆盖原始转写。"]
        if !hasText {
            notes.append("本次重新转写未识别出文字（可能为静音、设备无有效输入或音频过弱）。")
        }
        let doc = MarkdownDoc(title: "重新转写：\(base)", date: Date(), duration: duration,
                              audioName: audio.lastPathComponent, engine: SpeechEngine().name, language: "zh-CN",
                              status: status, notes: notes,
                              segments: assembler.segments)
        return try Paths.writeUniqueMarkdown(doc.render(), base: base + "_重转写", in: audio.deletingLastPathComponent())
    }
}

/// 按块惰性读取原音频并在内存中执行与实时链路一致的 SpeechEnhancer 预处理，不修改磁盘文件。
/// 每次迭代均独立打开文件并新建转换器与读取缓冲，保证可重入安全。
private struct EnhancedAudioSequence: AsyncSequence, @unchecked Sendable {
    typealias Element = AnalyzerInput

    private let audioURL: URL
    private let targetFormat: AVAudioFormat
    private let chunkFrames: AVAudioFrameCount

    init(audio: URL, targetFormat: AVAudioFormat, chunkFrames: AVAudioFrameCount = 8192) throws {
        self.audioURL = audio
        self.targetFormat = targetFormat
        self.chunkFrames = chunkFrames
        // 预先校验文件与转换格式可用性，提前抛出明确错误
        let probeFile = try AVAudioFile(forReading: audio)
        let rate = probeFile.processingFormat.sampleRate
        guard rate.isFinite, rate > 0,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: rate,
                  channels: 1,
                  interleaved: false
              ),
              AVAudioConverter(from: monoFormat, to: targetFormat) != nil,
              AVAudioPCMBuffer(pcmFormat: probeFile.processingFormat, frameCapacity: chunkFrames) != nil else {
            throw EngineError.noFormat
        }
    }

    func makeAsyncIterator() -> Iterator {
        do {
            let file = try AVAudioFile(forReading: audioURL)
            let rate = file.processingFormat.sampleRate
            guard rate.isFinite, rate > 0,
                  let monoFormat = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32,
                      sampleRate: rate,
                      channels: 1,
                      interleaved: false
                  ),
                  let converter = AVAudioConverter(from: monoFormat, to: targetFormat),
                  let readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
                return Iterator(initError: EngineError.noFormat)
            }
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            return Iterator(
                file: file,
                targetFormat: targetFormat,
                converter: converter,
                enhancer: SpeechEnhancer(sampleRate: rate),
                readBuffer: readBuffer,
                chunkFrames: chunkFrames
            )
        } catch {
            return Iterator(initError: error)
        }
    }

    struct Iterator: AsyncIteratorProtocol {
        private enum Phase { case reading, draining, done }

        private let file: AVAudioFile?
        private let targetFormat: AVAudioFormat?
        private let converter: AVAudioConverter?
        private let enhancer: SpeechEnhancer?
        private let readBuffer: AVAudioPCMBuffer?
        private let chunkFrames: AVAudioFrameCount
        private let initError: Error?
        private var phase: Phase
        private var pendingOutputs: [AVAudioPCMBuffer] = []
        private var firstYielded = false

        init(
            file: AVAudioFile,
            targetFormat: AVAudioFormat,
            converter: AVAudioConverter,
            enhancer: SpeechEnhancer,
            readBuffer: AVAudioPCMBuffer,
            chunkFrames: AVAudioFrameCount
        ) {
            self.file = file
            self.targetFormat = targetFormat
            self.converter = converter
            self.enhancer = enhancer
            self.readBuffer = readBuffer
            self.chunkFrames = chunkFrames
            self.initError = nil
            self.phase = .reading
        }

        init(initError: Error) {
            self.file = nil
            self.targetFormat = nil
            self.converter = nil
            self.enhancer = nil
            self.readBuffer = nil
            self.chunkFrames = 0
            self.initError = initError
            self.phase = .done
        }

        mutating func next() async throws -> AnalyzerInput? {
            if let initError {
                phase = .done
                throw initError
            }
            if !pendingOutputs.isEmpty {
                return makeInput(pendingOutputs.removeFirst())
            }
            guard let file, let targetFormat, let converter, let enhancer, let readBuffer else {
                phase = .done
                return nil
            }

            while phase != .done {
                try Task.checkCancellation()
                switch phase {
                case .reading:
                    let remaining = file.length - file.framePosition
                    if remaining <= 0 {
                        phase = .draining
                        continue
                    }
                    let toRead = AVAudioFrameCount(Swift.min(Int64(chunkFrames), remaining))
                    readBuffer.frameLength = 0
                    try file.read(into: readBuffer, frameCount: toRead)
                    if readBuffer.frameLength == 0 {
                        phase = .draining
                        continue
                    }
                    guard let mono = AudioPipeline.monoCopy(readBuffer) else { continue }
                    let enhanced = enhancer.process(mono)
                    try convertChunk(enhanced, converter: converter, targetFormat: targetFormat)
                    if !pendingOutputs.isEmpty {
                        return makeInput(pendingOutputs.removeFirst())
                    }

                case .draining:
                    try flushConverter(converter: converter)
                    phase = .done
                    if !pendingOutputs.isEmpty {
                        return makeInput(pendingOutputs.removeFirst())
                    }
                    return nil

                case .done:
                    return nil
                }
            }
            return nil
        }

        private mutating func convertChunk(
            _ enhanced: AVAudioPCMBuffer,
            converter: AVAudioConverter,
            targetFormat: AVAudioFormat
        ) throws {
            let ratio = targetFormat.sampleRate / Swift.max(enhanced.format.sampleRate, 1)
            let cap = Swift.max(AVAudioFrameCount(ceil(Double(enhanced.frameLength) * ratio)) + 1024, 1024)
            var supplied = false

            for _ in 0..<64 {
                guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else {
                    throw EngineError.conversion("无法分配重采样缓冲")
                }
                var err: NSError?
                let status = converter.convert(to: out, error: &err) { _, st in
                    if supplied { st.pointee = .noDataNow; return nil }
                    supplied = true; st.pointee = .haveData; return enhanced
                }
                if let err {
                    throw EngineError.conversion(err.localizedDescription)
                }
                switch status {
                case .error:
                    throw EngineError.conversion("音频重采样返回错误状态")
                case .haveData:
                    if out.frameLength > 0 {
                        pendingOutputs.append(out)
                    }
                    if out.frameLength < cap { return }
                case .inputRanDry:
                    if out.frameLength > 0 {
                        pendingOutputs.append(out)
                    }
                    return
                case .endOfStream:
                    if out.frameLength > 0 {
                        pendingOutputs.append(out)
                    }
                    phase = .done
                    return
                @unknown default:
                    if out.frameLength > 0 {
                        pendingOutputs.append(out)
                    }
                    return
                }
            }
        }

        private mutating func flushConverter(converter: AVAudioConverter) throws {
            try drainPCM(converter) { out in
                pendingOutputs.append(out)
            }
        }

        private mutating func makeInput(_ buffer: AVAudioPCMBuffer) -> AnalyzerInput {
            if !firstYielded {
                firstYielded = true
                return AnalyzerInput(buffer: buffer, bufferStartTime: .zero)
            }
            return AnalyzerInput(buffer: buffer)
        }
    }
}
