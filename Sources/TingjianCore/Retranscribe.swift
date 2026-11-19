import AVFoundation
import Foundation
import Speech

/// 从已保存的录音文件重新转写(失败会话的补救),结果另存,不覆盖任何原文件。
public enum Retranscriber {
    public static func run(audio: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> TranscriptAssembler {
        let t = SpeechEngine.makeTranscriber(progressive: false)
        guard await SpeechEngine.modelReady() else { throw EngineError.modelMissing }
        let file = try AVAudioFile(forReading: audio)
        let total = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [t])
        let collector = Task { () -> TranscriptAssembler in
            var asm = TranscriptAssembler()
            for try await r in t.results where r.isFinal {
                let s = r.range.start.seconds, e = r.range.end.seconds
                asm.commit(start: s.isFinite ? s : asm.lastEnd, end: e.isFinite ? e : asm.lastEnd, text: String(r.text.characters))
                if total > 0 { progress(min(1, e / total)) }
            }
            return asm
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    /// 写出 `<原名>_重转写.md` 到音频所在目录。
    public static func writeMarkdown(audio: URL, assembler: TranscriptAssembler, duration: Double) throws -> URL {
        let base = audio.deletingPathExtension().lastPathComponent
        let doc = MarkdownDoc(title: "重新转写:\(base)", date: Date(), duration: duration,
                              audioName: audio.lastPathComponent, engine: SpeechEngine().name, language: "zh-CN",
                              status: .completed, notes: ["本文件由已保存录音重新转写生成,不覆盖原始转写。"],
                              segments: assembler.segments)
        return try Paths.writeUniqueMarkdown(doc.render(), base: base + "_重转写", in: audio.deletingLastPathComponent())
    }
}
