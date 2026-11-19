import Foundation

/// 资料库中的一项:磁盘上的真实文件或文件夹。
public struct LibraryEntry: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case directory, audio, document }

    public let url: URL
    public let name: String
    public let kind: Kind
    /// 录音文件夹:直属内容至少包含一个支持的音频文件,不依赖本地恢复用的 session.json。
    public let isRecordingBundle: Bool

    public var id: URL { url.standardizedFileURL }

    public init(url: URL, name: String, kind: Kind, isRecordingBundle: Bool) {
        self.url = url
        self.name = name
        self.kind = kind
        self.isRecordingBundle = isRecordingBundle
    }
}

public enum LibraryError: Error, LocalizedError, Equatable {
    case outsideLibrary(String)
    case rootNotMutable
    case invalidName(String)
    case nameConflict(String)
    case notFound(String)
    case notWritable(String)
    case protectedItem(String)
    case operationFailed(String)
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .outsideLibrary(let p): return "不能在资料库外操作:\(p)"
        case .rootNotMutable: return "资料库根目录不能改名或移动"
        case .invalidName(let m): return m
        case .nameConflict(let n): return "已存在同名项目或文件:\(n)"
        case .notFound(let p): return "文件或文件夹不存在:\(p)"
        case .notWritable(let p): return "没有写入权限:\(p)"
        case .protectedItem(let p): return "正在使用中,不能改名或移动:\(p)"
        case .operationFailed(let m): return m
        case .rollbackFailed(let m): return m
        }
    }
}

/// 直接对应磁盘文件夹的资料库:不做数据库,不迁移旧数据。
public actor ProjectLibrary {
    public nonisolated let root: URL
    private var protectedURLs: [URL] = []

    public static let audioExtensions: Set<String> = ["m4a", "caf", "wav", "aiff", "aif", "mp3"]
    public static let documentExtensions: Set<String> = ["md"]

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .isPackageKey, .nameKey,
    ]

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static func isAudio(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isDocument(_ url: URL) -> Bool {
        documentExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isRecordingBundle(_ directory: URL) -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles]) else { return false }
        for url in contents where audioExtensions.contains(url.pathExtension.lowercased()) {
            let regular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? true
            if regular { return true }
        }
        return false
    }

    /// 正在录音、待保存或正在纠正的路径;这些路径本身及其祖先都不允许改名或移动。
    public func setProtected(_ urls: [URL]) {
        protectedURLs = urls.map { $0.standardizedFileURL }
    }

    public func children(of directory: URL) throws -> [LibraryEntry] {
        let dir = directory.standardizedFileURL
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else {
            throw LibraryError.notFound(dir.path)
        }
        guard isDir.boolValue else { throw LibraryError.operationFailed("\(dir.path) 不是文件夹") }
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Self.keys, options: [])
        } catch {
            throw LibraryError.operationFailed("无法读取 \(dir.path):\(error.localizedDescription)")
        }
        var entries: [LibraryEntry] = []
        for url in contents {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(Self.keys))
            } catch {
                throw LibraryError.operationFailed("无法读取 \(url.path):\(error.localizedDescription)")
            }
            if values.isHidden == true || values.isSymbolicLink == true || values.isPackage == true { continue }
            if values.isDirectory == true {
                entries.append(LibraryEntry(url: url, name: url.lastPathComponent, kind: .directory,
                                            isRecordingBundle: Self.isRecordingBundle(url)))
            } else if Self.isAudio(url) {
                entries.append(LibraryEntry(url: url, name: url.lastPathComponent, kind: .audio, isRecordingBundle: false))
            } else if Self.isDocument(url) {
                entries.append(LibraryEntry(url: url, name: url.lastPathComponent, kind: .document, isRecordingBundle: false))
            }
        }
        entries.sort { a, b in
            if (a.kind == .directory) != (b.kind == .directory) { return a.kind == .directory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return entries
    }

    public func createProject(named name: String, in parent: URL) throws -> URL {
        let parent = parent.standardizedFileURL
        try requireInside(parent)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
            throw LibraryError.notFound(parent.path)
        }
        let name = try validatedName(name, fileExtension: nil)
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) { throw LibraryError.nameConflict(name) }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        } catch {
            throw LibraryError.operationFailed("无法创建项目 \(name):\(error.localizedDescription)")
        }
        return destination
    }

    public func rename(_ item: URL, to name: String) throws -> URL {
        let src = item.standardizedFileURL
        try requireInside(src)
        guard src != root else { throw LibraryError.rootNotMutable }
        try requireNotSymlink(src)
        try requireNotProtected(src)
        let kind = try kindOf(src)
        let fileExtension = kind == .directory ? nil : src.pathExtension
        let newName = try validatedName(name, fileExtension: fileExtension)
        let destination = src.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: kind == .directory)
        guard destination.standardizedFileURL != src else { return src }
        if FileManager.default.fileExists(atPath: destination.path) {
            throw LibraryError.nameConflict(newName)
        }

        // 预读需要改写链接的文稿,并确认可写;失败时不改动任何文件。
        var edits: [(url: URL, original: Data, updated: Data)] = []
        if kind != .directory {
            let oldName = src.lastPathComponent
            let directory = src.deletingLastPathComponent()
            let candidates: [URL]
            do {
                candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                    .filter { ProjectLibrary.isDocument($0) }
            } catch {
                throw LibraryError.operationFailed("无法读取 \(directory.path):\(error.localizedDescription)")
            }
            for md in candidates {
                let original: Data
                do { original = try Data(contentsOf: md) }
                catch { throw LibraryError.operationFailed("无法读取 \(md.path):\(error.localizedDescription)") }
                guard let text = String(data: original, encoding: .utf8) else {
                    throw LibraryError.operationFailed("\(md.path) 不是 UTF-8 文稿,未改动任何文件")
                }
                let oldLink = "[[\(oldName)]]"
                guard text.contains(oldLink) else { continue }
                guard FileManager.default.isWritableFile(atPath: md.path) else {
                    throw LibraryError.notWritable(md.path)
                }
                let updated = text.replacingOccurrences(of: oldLink, with: "[[\(newName)]]")
                edits.append((md, original, Data(updated.utf8)))
            }
        }

        do {
            try FileManager.default.moveItem(at: src, to: destination)
        } catch {
            throw LibraryError.operationFailed("无法改名 \(src.lastPathComponent):\(error.localizedDescription)")
        }

        var written: [URL] = []
        do {
            for edit in edits {
                try edit.updated.write(to: edit.url, options: [.atomic])
                written.append(edit.url)
            }
        } catch {
            var problems: [String] = []
            for edit in edits where written.contains(edit.url) {
                do { try edit.original.write(to: edit.url, options: [.atomic]) }
                catch { problems.append("\(edit.url.path):\(error.localizedDescription)") }
            }
            do { try FileManager.default.moveItem(at: destination, to: src) }
            catch { problems.append("\(destination.path) → \(src.path):\(error.localizedDescription)") }
            if problems.isEmpty {
                throw LibraryError.operationFailed("改名失败,已恢复原状:\(error.localizedDescription)")
            }
            throw LibraryError.rollbackFailed("改名失败且未能完全恢复,请检查这些路径:\n" + problems.joined(separator: "\n"))
        }
        return destination
    }

    public func move(_ item: URL, into directory: URL) throws -> URL {
        let src = item.standardizedFileURL
        let dir = directory.standardizedFileURL
        try requireInside(src)
        try requireInside(dir)
        guard src != root else { throw LibraryError.rootNotMutable }
        try requireNotSymlink(src)
        try requireNotProtected(src)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw LibraryError.notFound(dir.path)
        }
        guard !Self.contains(src, dir) else {
            throw LibraryError.operationFailed("不能移动到自身或子文件夹:\(dir.path)")
        }
        if src.deletingLastPathComponent().standardizedFileURL == dir { return src }
        let kind = try kindOf(src)
        let destination = dir.appendingPathComponent(src.lastPathComponent, isDirectory: kind == .directory)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw LibraryError.nameConflict(destination.lastPathComponent)
        }
        do {
            try FileManager.default.moveItem(at: src, to: destination)
        } catch {
            throw LibraryError.operationFailed("无法移动 \(src.lastPathComponent):\(error.localizedDescription)")
        }
        return destination
    }

    /// 将资料库内的单个文件或目录移入系统废纸篓，不执行永久删除。
    @discardableResult
    public func trash(_ item: URL) throws -> URL? {
        let target = item.standardizedFileURL
        try requireInside(target)
        guard target != root else { throw LibraryError.rootNotMutable }
        try requireNotSymlink(target)
        try requireNotProtected(target)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw LibraryError.notFound(target.path)
        }
        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: target, resultingItemURL: &trashedURL)
            return trashedURL as URL?
        } catch {
            throw LibraryError.operationFailed("无法移入废纸篓 \(target.lastPathComponent):\(error.localizedDescription)")
        }
    }

    // MARK: 内部校验

    func kindOf(_ url: URL) throws -> LibraryEntry.Kind {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw LibraryError.notFound(url.path)
        }
        if isDir.boolValue { return .directory }
        if Self.isAudio(url) { return .audio }
        if Self.isDocument(url) { return .document }
        throw LibraryError.operationFailed("不支持的文件类型:\(url.lastPathComponent)")
    }

    private func requireInside(_ url: URL) throws {
        guard Self.contains(root, url) else { throw LibraryError.outsideLibrary(url.path) }
    }

    private func requireNotProtected(_ url: URL) throws {
        for protected in protectedURLs {
            if Self.contains(protected, url) || Self.contains(url, protected) {
                throw LibraryError.protectedItem(url.path)
            }
        }
    }

    private func requireNotSymlink(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            throw LibraryError.operationFailed("符号链接不能改名或移动:\(url.path)")
        }
    }

    /// 路径包含判断:按路径分段比较,不把 /a/bc 当成 /a/b 的子项。
    public static func contains(_ parent: URL, _ child: URL) -> Bool {
        let p = parent.standardizedFileURL.pathComponents
        let c = child.standardizedFileURL.pathComponents
        guard c.count >= p.count else { return false }
        return Array(c.prefix(p.count)) == p
    }

    /// 名称规则与 Paths.sanitize 的非法字符集一致,但这里拒绝而不是替换。
    private func validatedName(_ raw: String, fileExtension: String?) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.invalidName("名称不能为空") }
        guard trimmed != "." && trimmed != ".." else { throw LibraryError.invalidName("名称不能是 . 或 ..") }
        guard !trimmed.hasPrefix(".") else { throw LibraryError.invalidName("名称不能以点开头,否则会被当作隐藏文件") }
        guard trimmed.count <= 120 else { throw LibraryError.invalidName("名称不能超过 120 个字符") }
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        guard trimmed.rangeOfCharacter(from: bad) == nil else {
            throw LibraryError.invalidName("名称不能包含 / \\ : * ? \" < > | 或控制字符")
        }
        guard let fileExtension, !fileExtension.isEmpty else { return trimmed }
        let typedExtension = (trimmed as NSString).pathExtension
        if typedExtension.isEmpty {
            guard !trimmed.hasSuffix(".") else { throw LibraryError.invalidName("名称不能以点结尾") }
            return trimmed + "." + fileExtension
        }
        guard typedExtension.caseInsensitiveCompare(fileExtension) == .orderedSame else {
            throw LibraryError.invalidName("文件扩展名不能修改,应保留 .\(fileExtension)")
        }
        let stem = (trimmed as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty else { throw LibraryError.invalidName("名称不能只有扩展名") }
        return stem + "." + fileExtension
    }
}
