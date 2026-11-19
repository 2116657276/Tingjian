import Foundation

public enum Timecode {
    public static func string(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

public enum TranscriptStatus: String, Codable, Sendable {
    case completed, partial, failed
    public var label: String {
        switch self {
        case .completed: return "完成"
        case .partial: return "部分完成"
        case .failed: return "失败"
        }
    }
}

/// 落盘的原始识别事件:最终文字或无法补回的区间。
public struct TranscriptEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, gap }
    public var kind: Kind
    public var start: Double
    public var end: Double
    public var text: String
    public init(kind: Kind, start: Double, end: Double, text: String = "") {
        self.kind = kind; self.start = start; self.end = end; self.text = text
    }
}

public struct Segment: Equatable, Identifiable, Sendable {
    public let id: Int
    public var start: Double
    public var end: Double
    public var text: String
    public var incomplete: Bool
}

/// 把识别结果拼装成段落:临时结果只更新进行中的文字,最终结果追加并合并。
public struct TranscriptAssembler {
    public static let maxGap = 2.0
    public static let maxChars = 120

    public private(set) var events: [TranscriptEvent] = []
    public private(set) var segments: [Segment] = []
    public private(set) var volatileText = ""
    private var volatileStart = 0.0

    public var lastEnd: Double { events.last?.end ?? 0 }

    public init(events: [TranscriptEvent] = []) {
        for e in events { apply(e); self.events.append(e) }
    }

    public mutating func setVolatile(_ text: String, start: Double) {
        volatileText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        volatileStart = start
    }

    @discardableResult
    public mutating func commit(start: Double, end: Double, text: String) -> TranscriptEvent? {
        if volatileStart <= end + 0.05 { volatileText = "" }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let last = events.last, last.kind == .text, last.start == start, last.text == t { return nil }
        let e = TranscriptEvent(kind: .text, start: start, end: end, text: t)
        events.append(e); apply(e)
        return e
    }

    @discardableResult
    public mutating func markGap(start: Double, end: Double) -> TranscriptEvent? {
        guard end > start else { return nil }
        let e = TranscriptEvent(kind: .gap, start: start, end: end)
        events.append(e); apply(e)
        return e
    }

    private mutating func apply(_ e: TranscriptEvent) {
        switch e.kind {
        case .gap:
            if let last = segments.last, last.incomplete, e.start <= last.end + 0.5 {
                segments[segments.count - 1].end = max(last.end, e.end)
            } else {
                segments.append(Segment(id: segments.count, start: e.start, end: e.end, text: "", incomplete: true))
            }
        case .text:
            if let last = segments.last, !last.incomplete,
               e.start - last.end <= Self.maxGap,
               last.text.count + e.text.count <= Self.maxChars {
                segments[segments.count - 1].text = Self.join(last.text, e.text)
                segments[segments.count - 1].end = e.end
            } else {
                segments.append(Segment(id: segments.count, start: e.start, end: e.end, text: e.text, incomplete: false))
            }
        }
    }

    static func join(_ a: String, _ b: String) -> String {
        guard let l = a.last, let f = b.first else { return a + b }
        func word(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        return word(l) && word(f) ? a + " " + b : a + b
    }
}
