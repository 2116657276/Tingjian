import Foundation

/// 只恢复一次的 continuation,用于"工作 vs 超时"竞速,超时后工作任务可继续悬挂而不阻塞调用方。
final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?
    private var tasks: [Task<Void, Never>] = []
    init(_ c: CheckedContinuation<T, Never>) { cont = c }
    func install(_ tasks: [Task<Void, Never>]) {
        lock.lock(); let finished = cont == nil
        if !finished { self.tasks = tasks }
        lock.unlock()
        if finished { tasks.forEach { $0.cancel() } }
    }
    func resume(_ v: T) {
        lock.lock(); let c = cont; cont = nil; let pending = tasks; tasks = []; lock.unlock()
        pending.forEach { $0.cancel() }
        c?.resume(returning: v)
    }
}

func race<T: Sendable>(timeout: TimeInterval, onTimeout: T, _ work: @escaping @Sendable () async -> T) async -> T {
    await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
        let once = OnceResume(c)
        let worker = Task { once.resume(await work()) }
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            once.resume(onTimeout)
        }
        once.install([worker, timer])
    }
}

public enum Paths {
    public static var defaultSaveRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mobile Documents/iCloud~md~obsidian/Documents/听笺", isDirectory: true)
    }

    public static var defaultLocalRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("听笺/Sessions", isDirectory: true)
    }

    static let invalidFileNameCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|[]").union(.newlines).union(.controlCharacters)

    public static func sanitize(_ course: String) -> String {
        let cleaned = course.components(separatedBy: invalidFileNameCharacters).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return String(cleaned.prefix(40))
    }

    public static func baseName(date: Date, course: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let c = sanitize(course)
        return c.isEmpty ? f.string(from: date) : f.string(from: date) + "_" + c
    }

    /// 解析带 `yyyy-MM-dd_HH-mm-ss` 或 `yyyy-MM-dd_HH-mm-ss_<课程名>` 前缀的录音名称。
    public static func parseRecordingName(_ raw: String) -> RecordingNameParts? {
        if let match = raw.wholeMatch(of: #/(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})(?:_(.+))?/#) {
            let y = String(match.output.1)
            let mo = String(match.output.2)
            let d = String(match.output.3)
            let h = String(match.output.4)
            let mi = String(match.output.5)
            let s = String(match.output.6)
            let course = match.output.7.map { String($0) } ?? ""
            return RecordingNameParts(
                prefix: "\(y)-\(mo)-\(d)_\(h)-\(mi)-\(s)",
                course: course,
                fullDate: "\(y)-\(mo)-\(d) \(h):\(mi)",
                compactDate: "\(mo)-\(d) \(h):\(mi)"
            )
        }
        return nil
    }

    /// 统计本机恢复目录中已成功交付的备份目录数量与总磁盘占用（字节），适合在后台线程调用。
    public static func savedLocalBackupSummary(in localRoot: URL) -> LocalBackupSummary {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: localRoot, includingPropertiesForKeys: nil)) ?? []
        var savedDirs: [URL] = []
        var totalBytes: Int64 = 0
        for dir in dirs where SessionStore.readInfo(dir: dir)?.state == .saved {
            savedDirs.append(dir)
            totalBytes += directoryAllocatedSize(dir, fileManager: fm)
        }
        return LocalBackupSummary(directories: savedDirs, totalBytes: totalBytes)
    }

    private static func directoryAllocatedSize(_ directory: URL, fileManager fm: FileManager) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    /// 先写完整临时文件，重名时另存；不替换用户已有的派生文档。
    public static func writeUniqueMarkdown(_ text: String, base: String, in directory: URL) throws -> URL {
        let fm = FileManager.default
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        do {
            try text.write(to: temporary, atomically: true, encoding: .utf8)
            var index = 1
            while true {
                try Task.checkCancellation()
                let name = index == 1 ? base : "\(base)_\(index)"
                let destination = directory.appendingPathComponent(name + ".md")
                if fm.fileExists(atPath: destination.path) { index += 1; continue }
                do { try fm.moveItem(at: temporary, to: destination); return destination }
                catch CocoaError.fileWriteFileExists { index += 1 }
            }
        } catch {
            if fm.fileExists(atPath: temporary.path) { try? fm.trashItem(at: temporary, resultingItemURL: nil) }
            throw error
        }
    }

    /// 创建不与现有目录重名的新目录(同名追加 _2、_3 ...)。
    public static func makeUniqueDirectory(in parent: URL, base: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var n = 1
        while true {
            let url = parent.appendingPathComponent(n == 1 ? base : "\(base)_\(n)", isDirectory: true)
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch CocoaError.fileWriteFileExists {
                n += 1
            }
        }
    }
}

public struct RecordingNameParts: Equatable, Sendable {
    public let prefix: String
    public let course: String
    public let fullDate: String
    public let compactDate: String

    public var displayTitle: String {
        course.isEmpty ? "课堂录音" : course
    }

    public func rebuiltName(course newCourse: String) -> String {
        let trimmed = newCourse.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? prefix : "\(prefix)_\(trimmed)"
    }
}

public struct LocalBackupSummary: Equatable, Sendable {
    public let directories: [URL]
    public let totalBytes: Int64

    public var count: Int { directories.count }
}
