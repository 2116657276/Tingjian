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

    public static func sanitize(_ course: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        let cleaned = course.components(separatedBy: bad).joined(separator: "-")
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
