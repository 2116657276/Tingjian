import AVFoundation
import Foundation

public enum ExportError: Error, LocalizedError {
    case durationMismatch(Double, Double)
    case copyVerify(String)
    public var errorDescription: String? {
        switch self {
        case .durationMismatch(let a, let b): return "M4A 时长(\(Int(a))s)与已保存录音(\(Int(b))s)不符"
        case .copyVerify(let n): return "复制后校验失败:\(n)"
        }
    }
}

public enum AudioExporter {
    /// CAF → AAC M4A(单声道约 64kbps),完成后读回时长校验。
    public static func exportM4A(from caf: URL, to m4a: URL) async throws -> Double {
        let input = try AVAudioFile(forReading: caf)
        let expected = Double(input.length) / input.processingFormat.sampleRate
        if FileManager.default.fileExists(atPath: m4a.path) { try FileManager.default.trashItem(at: m4a, resultingItemURL: nil) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: input.processingFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        do {
            var output: AVAudioFile? = try AVAudioFile(forWriting: m4a, settings: settings,
                                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let cap: AVAudioFrameCount = 16384
            guard let buf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: cap) else {
                throw AudioError.noInput
            }
            while input.framePosition < input.length {
                try input.read(into: buf, frameCount: cap)
                if buf.frameLength == 0 { break }
                try output?.write(from: buf)
            }
            output = nil // 释放以写入文件尾
        }
        let dur = try await AVURLAsset(url: m4a).load(.duration).seconds
        if abs(dur - expected) > 1.0 { throw ExportError.durationMismatch(dur, expected) }
        return dur
    }
}

public struct MarkdownDoc {
    public var title: String
    public var date: Date
    public var duration: Double
    public var audioName: String?
    public var engine: String
    public var language: String
    public var status: TranscriptStatus
    public var notes: [String]
    public var segments: [Segment]

    public init(title: String, date: Date, duration: Double, audioName: String?, engine: String,
                language: String, status: TranscriptStatus, notes: [String], segments: [Segment]) {
        self.title = title; self.date = date; self.duration = duration; self.audioName = audioName
        self.engine = engine; self.language = language; self.status = status; self.notes = notes
        self.segments = segments
    }

    public func render() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var s = "# \(title)\n\n"
        s += "- 录制日期:\(f.string(from: date))\n"
        s += "- 音频时长:\(Timecode.string(duration))\n"
        if let a = audioName { s += "- 音频:![[\(a)]]\n" }
        s += "- 转写引擎:\(engine)(\(language))\n"
        s += "- 转写状态:\(status.label)\n"
        if !notes.isEmpty {
            s += "\n## 说明\n\n"
            for n in notes { s += "- \(n)\n" }
        }
        s += "\n## 转写\n\n"
        for seg in segments {
            if seg.incomplete {
                s += "> ⚠ [\(Timecode.string(seg.start))]–[\(Timecode.string(seg.end))] 此区间转写不完整\n\n"
            } else {
                s += "[\(Timecode.string(seg.start))] \(seg.text)\n\n"
            }
        }
        return s
    }

    /// 解析 Markdown 中的 "[HH:MM:SS] 文本" 行(忽略引用块里的不完整标记)。
    public static func parseSegments(_ md: String) -> [(time: String, text: String)] {
        md.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let l = String(line)
            guard l.hasPrefix("["), l.count > 11 else { return nil }
            let chars = Array(l)
            guard chars[9] == "]", chars[3] == ":", chars[6] == ":" else { return nil }
            let time = String(chars[1..<9])
            guard time.allSatisfy({ $0.isNumber || $0 == ":" }) else { return nil }
            return (time, String(chars[10...]).trimmingCharacters(in: .whitespaces))
        }
    }
}

public struct DeliveryResult: Sendable {
    public var directory: URL
    public var audio: URL?
    public var markdown: URL
}

public enum Deliverer {
    /// 复制到目标目录:临时名写入 → 校验大小 → 重命名。目录同名自动追加序号,绝不覆盖。
    public static func deliver(base: String, audio: URL?, markdown: URL, to root: URL) throws -> DeliveryResult {
        let dir = try Paths.makeUniqueDirectory(in: root, base: base)
        var audioOut: URL?
        if let audio {
            audioOut = try copyVerified(audio, to: dir.appendingPathComponent(audio.lastPathComponent))
        }
        let mdOut = try copyVerified(markdown, to: dir.appendingPathComponent(markdown.lastPathComponent))
        return DeliveryResult(directory: dir, audio: audioOut, markdown: mdOut)
    }

    static func copyVerified(_ src: URL, to dst: URL) throws -> URL {
        let fm = FileManager.default
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).partial")
        if fm.fileExists(atPath: tmp.path) { try fm.trashItem(at: tmp, resultingItemURL: nil) }
        try fm.copyItem(at: src, to: tmp)
        let a = (try fm.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.int64Value ?? -1
        let b = (try fm.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value ?? -2
        guard a == b else { try? fm.trashItem(at: tmp, resultingItemURL: nil); throw ExportError.copyVerify(dst.lastPathComponent) }
        try fm.moveItem(at: tmp, to: dst)
        return dst
    }
}
