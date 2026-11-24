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

    public mutating func clearVolatile() {
        volatileText = ""
        volatileStart = 0
    }

    internal mutating func clearVolatileIfNotAfter(_ cutoff: Double) {
        if volatileStart <= cutoff {
            clearVolatile()
        }
    }

    internal func canUpdateVolatile(at time: Double) -> Bool {
        volatileText.isEmpty || volatileStart <= time
    }

    @discardableResult
    public mutating func commit(start: Double, end: Double, text: String) -> TranscriptEvent? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let last = events.last, last.kind == .text, last.start == start, last.text == t { return nil }
        reconcileVolatile(committed: t, end: end)
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

    private mutating func reconcileVolatile(committed: String, end: Double) {
        guard !volatileText.isEmpty, volatileStart <= end + 0.05 else { return }
        if let remainder = Self.stripCommittedPrefix(from: volatileText, committed: committed) {
            if remainder.isEmpty {
                clearVolatile()
            } else {
                volatileText = remainder
                volatileStart = max(volatileStart, end)
            }
        } else {
            clearVolatile()
        }
    }

    internal enum PrefixMatch: Equatable {
        /// 归一化后完全一致（忽略空白、标点与大小写）
        case exactMatch
        /// 以已提交文本为前缀并向后延伸；携带剥离前缀与切分点多余分隔标点后的新增后缀
        case extended(String)
        /// 全部实质字符落入已提交文本的前缀之内（严格短于已提交文本）
        case properPrefix
        /// 起始不匹配
        case noMatch
    }

    internal static let leadingSeparators: Set<Character> = [
        "，", "。", "！", "？", "；", "：", "、",
        ",", ".", "!", "?", ";", ":"
    ]

    internal static func isSubstantive(_ c: Character) -> Bool {
        !c.isWhitespace && !c.isPunctuation
    }

    internal static func normalizeForMatch(_ text: String) -> String {
        var normalized = ""
        for index in text.indices {
            if let token = matchToken(in: text, at: index) { normalized += token }
        }
        return normalized
    }

    private static func matchToken(in text: String, at index: String.Index) -> String? {
        let character = text[index]
        if isSubstantive(character) { return String(character).lowercased() }
        let next = text.index(after: index)
        guard next < text.endIndex, text[next].isNumber else { return nil }
        if character == "-" || character == "－" { return "-" }
        let previousIsNumber = index > text.startIndex && text[text.index(before: index)].isNumber
        guard previousIsNumber else { return nil }
        switch character {
        case ".", "．": return "."
        case ",", "，": return ","
        case ":", "：": return ":"
        case "/", "／": return "/"
        default: return nil
        }
    }

    /// 将 text 与已提交文本 committed 做归一化前缀比对（忽略空白、标点与大小写）。
    /// 剥离前缀时跳过切分点多余分隔标点，保留开引号/括号等成对符号。
    internal static func matchCommittedPrefix(of text: String, against committed: String) -> PrefixMatch {
        let target = normalizeForMatch(committed)
        guard !target.isEmpty else {
            return text.contains(where: isSubstantive) ? .noMatch : .exactMatch
        }
        var tIdx = target.startIndex
        var vIdx = text.startIndex
        var matchedAny = false
        while vIdx < text.endIndex && tIdx < target.endIndex {
            guard let lower = matchToken(in: text, at: vIdx) else {
                vIdx = text.index(after: vIdx)
                continue
            }
            guard let range = target.range(of: lower, options: [.anchored], range: tIdx..<target.endIndex) else {
                return .noMatch
            }
            matchedAny = true
            tIdx = range.upperBound
            vIdx = text.index(after: vIdx)
        }
        guard tIdx == target.endIndex else {
            return matchedAny ? .properPrefix : .exactMatch
        }
        while vIdx < text.endIndex {
            let vc = text[vIdx]
            if vc.isWhitespace || (leadingSeparators.contains(vc) && matchToken(in: text, at: vIdx) == nil) {
                vIdx = text.index(after: vIdx)
            } else {
                break
            }
        }
        let remainder = String(text[vIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.contains(where: isSubstantive) ? .extended(remainder) : .exactMatch
    }

    /// 若 volatile 以已提交文本为前缀(忽略空白、标点与大小写),返回尚未提交的后半句;
    /// 若已被完全覆盖返回空串;若不匹配(例如整句改写)返回 nil。
    private static func stripCommittedPrefix(from volatile: String, committed: String) -> String? {
        guard committed.contains(where: isSubstantive) else {
            return volatile.contains(where: isSubstantive) ? volatile : ""
        }
        switch matchCommittedPrefix(of: volatile, against: committed) {
        case .exactMatch, .properPrefix:
            return ""
        case .extended(let remainder):
            return remainder
        case .noMatch:
            return nil
        }
    }

    /// 返回末尾连续 `.text` 事件（遇到 `.gap` 即止）：始终包含最后一个 `.text` 事件，
    /// 并向前纳入与 `overlapStart` 相邻/重叠或同段连续（间隔 ≤ maxGap）的近期 `.text` 事件，
    /// 以覆盖单句被拆成多段后的跨段回退或末尾局部回退。
    internal func recentTrailingTextEvents(overlapping overlapStart: Double, maxEvents: Int = 6, maxChars: Int = 300) -> [TranscriptEvent] {
        guard let last = events.last, last.kind == .text else { return [] }
        var collected = [last]
        var charCount = last.text.count
        var nextStart = last.start
        var idx = events.count - 2
        while idx >= 0 && collected.count < maxEvents && charCount < maxChars {
            let e = events[idx]
            guard e.kind == .text,
                  e.end + 0.5 >= overlapStart || nextStart - e.end <= Self.maxGap else { break }
            collected.append(e)
            charCount += e.text.count
            nextStart = e.start
            idx -= 1
        }
        collected.reverse()
        return collected
    }

    /// 解析时间轴回退重叠（start < boundary && end > boundary）的最终回调文本：
    /// - 归一化后与已提交末尾完全一致，或为近期已提交文本的子串/前缀且新增时长不大 → 返回 nil（忽略重复）；
    /// - 以已提交末尾（含连续近期事件后缀）为前缀并向后延伸 → 返回剥离前缀后的新增后缀；
    /// - 不含重复前缀的新一句 → 原样返回。
    internal func resolveOverlappingFinal(text: String, start: Double, end: Double, boundary: Double) -> String? {
        let recent = recentTrailingTextEvents(overlapping: start)
        guard !recent.isEmpty else { return text }
        let normNew = Self.normalizeForMatch(text)
        guard !normNew.isEmpty else { return nil }

        for i in 0..<recent.count {
            let candidate = recent[i...].map(\.text).joined()
            switch Self.matchCommittedPrefix(of: text, against: candidate) {
            case .exactMatch:
                return nil
            case .extended(let remainder):
                return remainder
            case .properPrefix, .noMatch:
                continue
            }
        }

        let overlap = boundary - start
        let extra = end - boundary
        if extra <= max(0.25, overlap * 0.5) {
            let normCombined = Self.normalizeForMatch(recent.map(\.text).joined())
            if normCombined.contains(normNew) {
                return nil
            }
        }
        return text
    }

    /// 解析轻微回退（start < boundary 且在容忍窗内）的临时文本：
    /// 若以末尾已提交句为前缀则剥离前缀；若已被完全覆盖返回 nil（不显示旧词）；否则原样返回。
    internal func resolveOverlappingVolatile(text: String, start: Double) -> String? {
        let recent = recentTrailingTextEvents(overlapping: start)
        guard !recent.isEmpty else { return text }
        let normNew = Self.normalizeForMatch(text)
        guard !normNew.isEmpty else { return nil }

        var coveredByPrefix = false
        for i in 0..<recent.count {
            let candidate = recent[i...].map(\.text).joined()
            switch Self.matchCommittedPrefix(of: text, against: candidate) {
            case .exactMatch:
                return nil
            case .extended(let remainder):
                return remainder
            case .properPrefix:
                coveredByPrefix = true
            case .noMatch:
                continue
            }
        }
        if coveredByPrefix { return nil }
        let normCombined = Self.normalizeForMatch(recent.map(\.text).joined())
        if normCombined.hasSuffix(normNew) {
            return nil
        }
        return text
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
                segments[segments.count - 1].end = max(last.end, e.end)
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
