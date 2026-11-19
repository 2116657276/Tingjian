import Foundation

public struct SessionInfo: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case recording, finalizing, pendingSave, saved, failed }
    public var baseName: String
    public var course: String
    public var startedAt: Date
    public var state: State
    public var sampleRate: Double = 0
    public var savedSamples: Int64 = 0
    public var destination: String?
    /// 录音所属草稿及开始时固定的目标。旧会话可能没有这些字段。
    public var draftID: UUID?
    public var sessionDestination: URL?
    public var recordingPlacement: RecordingPlacement?
    var deliveryID: UUID?
    var deliveryRoot: URL?
    var deliveryAudioName: String?
    public var status: TranscriptStatus?
    public var notes: [String] = []
    public var durationSeconds: Double { sampleRate > 0 ? Double(savedSamples) / sampleRate : 0 }

    public init(baseName: String, course: String, startedAt: Date, state: State) {
        self.baseName = baseName; self.course = course; self.startedAt = startedAt; self.state = state
    }
}

public enum SessionFiles {
    public static let info = "session.json"
    public static let audio = "audio.caf"
    public static let events = "transcript.jsonl"
}

public struct EventLoadResult: Sendable {
    public var events: [TranscriptEvent]
    public var issues: [String]
}

public enum SessionStoreError: Error, LocalizedError {
    case journalNeedsRepair
    public var errorDescription: String? { "文本日志需完整重建，当前没有继续追加" }
}

/// 本地会话目录，所有写入错误均交给调度层处理。
public final class SessionStore {
    public let dir: URL
    public var info: SessionInfo
    private var eventHandle: FileHandle?
    public private(set) var journalNeedsRepair = false

    public init(dir: URL, info: SessionInfo) { self.dir = dir; self.info = info }
    public var audioURL: URL { dir.appendingPathComponent(SessionFiles.audio) }

    public func save() throws {
        try Self.encoder.encode(info).write(to: dir.appendingPathComponent(SessionFiles.info), options: .atomic)
    }

    public func prepare() throws {
        try rewriteEvents([])
        try save()
    }

    public func append(_ e: TranscriptEvent) throws {
        guard !journalNeedsRepair else { throw SessionStoreError.journalNeedsRepair }
        do {
            if eventHandle == nil {
                eventHandle = try FileHandle(forWritingTo: dir.appendingPathComponent(SessionFiles.events))
                try eventHandle!.seekToEnd()
            }
            var line = try JSONEncoder().encode(e)
            line.append(0x0A)
            try eventHandle!.write(contentsOf: line)
        } catch {
            journalNeedsRepair = true
            throw error
        }
    }

    public func closeEvents() throws {
        let handle = eventHandle
        eventHandle = nil
        do { try handle?.close() }
        catch { journalNeedsRepair = true; throw error }
    }

    public func rewriteEvents(_ events: [TranscriptEvent]) throws {
        journalNeedsRepair = true
        try closeEvents()
        var data = Data()
        for e in events {
            data.append(try JSONEncoder().encode(e))
            data.append(0x0A)
        }
        try data.write(to: dir.appendingPathComponent(SessionFiles.events), options: .atomic)
        journalNeedsRepair = false
    }

    public static func readInfo(dir: URL) -> SessionInfo? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(SessionFiles.info)) else { return nil }
        return try? decoder.decode(SessionInfo.self, from: data)
    }

    public static func loadEvents(dir: URL) -> EventLoadResult {
        let url = dir.appendingPathComponent(SessionFiles.events)
        guard FileManager.default.fileExists(atPath: url.path) else { return EventLoadResult(events: [], issues: []) }
        do {
            let data = try Data(contentsOf: url)
            var events: [TranscriptEvent] = []
            var issues: [String] = []
            for (index, line) in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() where !line.isEmpty {
                do { events.append(try JSONDecoder().decode(TranscriptEvent.self, from: Data(line))) }
                catch { issues.append("文本日志第 \(index + 1) 行损坏或截断，已保留其他完整记录。") }
            }
            return EventLoadResult(events: events, issues: issues)
        } catch {
            return EventLoadResult(events: [], issues: ["无法读取文本日志:\(error.localizedDescription)"])
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted]; return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
