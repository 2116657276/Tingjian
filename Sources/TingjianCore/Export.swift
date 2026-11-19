import Darwin
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
            guard l.hasPrefix("["), l.count >= 10 else { return nil }
            let chars = Array(l)
            guard chars[9] == "]", chars[3] == ":", chars[6] == ":",
                  chars.count == 10 || chars[10].isWhitespace else { return nil }
            let time = String(chars[1..<9])
            guard time.allSatisfy({ $0.isNumber || $0 == ":" }) else { return nil }
            let text = chars.count == 10 ? "" : String(chars[10...]).trimmingCharacters(in: .whitespaces)
            return (time, text)
        }
    }
}

public struct DeliveryResult: Sendable {
    public var directory: URL
    public var audio: URL?
    public var markdown: URL
}

public enum Deliverer {
    public static func deliver(base: String, audio: URL?, markdown: URL, to root: URL,
                               id: UUID = UUID()) throws -> DeliveryResult {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = ".tingjian-delivery-" + id.uuidString
        let stage = root.appendingPathComponent(marker, isDirectory: true)
        if let existing = try published(base: base, audioName: audio?.lastPathComponent,
                                        markdownName: markdown.lastPathComponent, in: root, id: id) {
            if fm.fileExists(atPath: stage.path) { try fm.trashItem(at: stage, resultingItemURL: nil) }
            return existing
        }
        if fm.fileExists(atPath: stage.path) { try fm.trashItem(at: stage, resultingItemURL: nil) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        do {
            if let audio { try copyVerified(audio, to: stage.appendingPathComponent(audio.lastPathComponent)) }
            try copyVerified(markdown, to: stage.appendingPathComponent(markdown.lastPathComponent))
            try Data().write(to: stage.appendingPathComponent(marker), options: .withoutOverwriting)
            var suffix = 1
            while true {
                let name = suffix == 1 ? base : "\(base)_\(suffix)"
                let target = root.appendingPathComponent(name, isDirectory: true)
                // A same-volume exclusive rename publishes the complete directory at once.
                if renamex_np(stage.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                    return DeliveryResult(directory: target,
                                          audio: audio.map { target.appendingPathComponent($0.lastPathComponent) },
                                          markdown: target.appendingPathComponent(markdown.lastPathComponent))
                }
                let failure = errno
                guard failure == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
                suffix += 1
            }
        } catch {
            try? fm.trashItem(at: stage, resultingItemURL: nil)
            throw error
        }
    }

    static func published(base: String, audioName: String?, markdownName: String,
                          in root: URL, id: UUID) throws -> DeliveryResult? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return nil }
        let marker = ".tingjian-delivery-" + id.uuidString
        let directories = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                       options: .skipsHiddenFiles)
        for directory in directories where directory.lastPathComponent == base || directory.lastPathComponent.hasPrefix(base + "_") {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  fm.fileExists(atPath: directory.appendingPathComponent(marker).path) else { continue }
            let markdown = directory.appendingPathComponent(markdownName)
            let audio = audioName.map { directory.appendingPathComponent($0) }
            guard fm.fileExists(atPath: markdown.path), audio.map({ fm.fileExists(atPath: $0.path) }) ?? true else {
                throw ExportError.copyVerify(directory.lastPathComponent)
            }
            return DeliveryResult(directory: directory, audio: audio, markdown: markdown)
        }
        return nil
    }

    static func copyVerified(_ source: URL, to target: URL) throws {
        let fm = FileManager.default
        try fm.copyItem(at: source, to: target)
        let a = (try fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? -1
        let b = (try fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? -2
        guard a == b else { throw ExportError.copyVerify(target.lastPathComponent) }
    }
}
