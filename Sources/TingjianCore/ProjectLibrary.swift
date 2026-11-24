import Darwin
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

public struct LibraryMovePlan: Equatable, Sendable {
    public let item: URL
    public let sources: [URL]
    public let recordings: [String]
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

    public func children(of directory: URL, classifyDirectories: Bool = true) throws -> [LibraryEntry] {
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
                                            isRecordingBundle: classifyDirectories && Self.isRecordingBundle(url)))
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

    public func createRecordingPlacement(named title: String, in parent: URL) throws -> RecordingPlacement {
        let parent = parent.standardizedFileURL
        try requirePlacementParent(parent)
        let fm = FileManager.default
        if parent == root, !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let safe = Paths.sanitize(title).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let base = safe.isEmpty ? "未命名录音" : String(safe.prefix(60))
        var index = 1
        while true {
            let name = index == 1 ? base : "\(base)_\(index)"
            let folder = parent.appendingPathComponent(name, isDirectory: true)
            if mkdir(folder.path, 0o755) == 0 {
                do { return try RecordingPlacement(directory: folder) }
                catch {
                    if (try? fm.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                        try? fm.trashItem(at: folder, resultingItemURL: nil)
                    }
                    throw error
                }
            }
            let code = errno
            guard code == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            index += 1
        }
    }

    public func moveRecordingPlacement(_ placement: RecordingPlacement, into parent: URL) throws -> RecordingPlacement {
        try requirePlacementParent(parent)
        try requirePlacementParent(placement.directory)
        try placement.validateEmpty()
        var moved = placement
        moved.directory = try move(placement.directory, into: parent)
        return moved
    }

    private func requirePlacementParent(_ parent: URL) throws {
        try requireInside(parent)
        guard Self.contains(root.resolvingSymlinksInPath(), parent.resolvingSymlinksInPath()) else {
            throw LibraryError.outsideLibrary(parent.path)
        }
        try requireNotSymlink(parent)
        try requireNotProtected(parent)
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

    public func rename(_ item: URL, to name: String, syncFilePrefixes: Bool = false) throws -> URL {
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

        let parent = src.deletingLastPathComponent()
        let scan = kind == .directory ? src : parent
        if kind == .directory && !syncFilePrefixes {
            try FileManager.default.moveItem(at: src, to: destination)
            return destination
        }
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(at: scan, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        var names: [String: String] = [:]
        if kind == .directory {
            for child in children {
                let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                let old = child.lastPathComponent
                guard values.isRegularFile == true, values.isSymbolicLink != true, old.hasPrefix(src.lastPathComponent) else { continue }
                let renamed = newName + old.dropFirst(src.lastPathComponent.count)
                guard !fm.fileExists(atPath: scan.appendingPathComponent(renamed).path) else {
                    throw LibraryError.nameConflict(renamed)
                }
                names[old] = renamed
            }
        } else {
            names[src.lastPathComponent] = newName
        }

        let links = Dictionary(uniqueKeysWithValues: names.map { ("[[" + $0.key + "]]", "[[" + $0.value + "]]") })
        let escapedLinks = links.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
        let linkPattern = try NSRegularExpression(pattern: escapedLinks.isEmpty ? "(?!)" : escapedLinks.joined(separator: "|"))
        let writeRoot = kind == .directory ? destination : parent
        var edits: [(target: URL, original: Data, updated: Data)] = []
        for child in children where Self.isDocument(child) && !child.lastPathComponent.hasPrefix(".") {
            let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let original = try Data(contentsOf: child)
            guard let text = String(data: original, encoding: .utf8) else {
                throw LibraryError.operationFailed("文稿编码无法读取，改名已取消：" + child.lastPathComponent)
            }
            var updated = text
            for match in linkPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range, in: text), let replacement = links[String(text[range])] else { continue }
                // Resolve against the current string. Matches are replaced from the end.
                if let currentRange = Range(match.range, in: updated) { updated.replaceSubrange(currentRange, with: replacement) }
            }
            guard updated != text else { continue }
            try requireNotProtected(child)
            guard fm.isWritableFile(atPath: child.path) else { throw LibraryError.notWritable(child.path) }
            edits.append((writeRoot.appendingPathComponent(names[child.lastPathComponent] ?? child.lastPathComponent),
                          original, Data(updated.utf8)))
        }

        var moved: [(from: URL, to: URL)] = []
        var written = 0
        do {
            try fm.moveItem(at: src, to: destination)
            moved.append((src, destination))
            if kind == .directory {
                for (before, after) in names.sorted(by: { $0.key < $1.key }) {
                    let from = destination.appendingPathComponent(before)
                    let to = destination.appendingPathComponent(after)
                    try fm.moveItem(at: from, to: to)
                    moved.append((from, to))
                }
            }
            for edit in edits {
                try replaceContents(at: edit.target, expected: edit.original, with: edit.updated)
                written += 1
            }
        } catch {
            var failures: [String] = []
            for edit in edits.prefix(written).reversed() {
                do { try replaceContents(at: edit.target, expected: edit.updated, with: edit.original) }
                catch { failures.append(edit.target.path + " " + error.localizedDescription) }
            }
            for step in moved.reversed() {
                do { try fm.moveItem(at: step.to, to: step.from) }
                catch { failures.append(step.to.path + " " + error.localizedDescription) }
            }
            if !failures.isEmpty { throw LibraryError.rollbackFailed(failures.joined(separator: "\n")) }
            throw error
        }
        return destination
    }

    private func replaceContents(at url: URL, expected: Data, with updated: Data) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            do {
                guard try Data(contentsOf: coordinated) == expected else {
                    throw LibraryError.operationFailed("文稿已被外部修改，请刷新后重试：" + coordinated.lastPathComponent)
                }
                try updated.write(to: coordinated, options: .atomic)
            } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    public func movePlan(for item: URL) throws -> LibraryMovePlan {
        let url = item.standardizedFileURL
        try requireInside(url)
        try requireNotSymlink(url)
        let single = LibraryMovePlan(item: url, sources: [url], recordings: [])
        let kind = try kindOf(url)
        guard kind != .directory else { return single }

        let parent = url.deletingLastPathComponent()
        let entries = try children(of: parent, classifyDirectories: false)
        let audioNames = Set(entries.filter { $0.kind == .audio }.map(\.name))
        guard !audioNames.isEmpty else { return single }

        var documentsByAudio: [URL: [URL]] = [:]
        for entry in entries where entry.kind == .document {
            let text: String
            if entry.url.standardizedFileURL == url {
                text = try String(contentsOf: entry.url, encoding: .utf8)
            } else {
                guard let content = try? String(contentsOf: entry.url, encoding: .utf8) else { continue }
                text = content
            }
            guard let audio = Self.linkedAudio(in: text, beside: entry.url, available: audioNames) else { continue }
            documentsByAudio[audio.standardizedFileURL, default: []].append(entry.url.standardizedFileURL)
        }
        let match = documentsByAudio.first { audio, documents in audio == url || documents.contains(url) }
        guard let (audio, documents) = match else { return single }

        let files = [audio] + documents
        let names = files.map(\.lastPathComponent)
        let visible = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil,
                                                                  options: .skipsHiddenFiles)
        // 独立录音文件夹可整体移走。混放的项目中只移动实际配对的文件。
        let dedicated = parent.resolvingSymlinksInPath() != root.resolvingSymlinksInPath()
            && Set(visible.map(\.lastPathComponent)) == Set(names)
        return LibraryMovePlan(item: url, sources: dedicated ? [parent] : files, recordings: names)
    }

    public nonisolated static func linkedAudio(in text: String, beside document: URL, available: Set<String>? = nil) -> URL? {
        guard text.contains("![[") else { return nil }
        let parent = document.deletingLastPathComponent()
        let names = available ?? Set((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
        var first: (name: String, index: String.Index)?
        for name in names {
            let url = parent.appendingPathComponent(name)
            guard isAudio(url), let match = text.range(of: "![[" + name + "]]", options: .literal) else { continue }
            if available == nil {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            }
            if let first, match.lowerBound > first.index ||
                (match.lowerBound == first.index && name.count <= first.name.count) { continue }
            first = (name, match.lowerBound)
        }
        if let first { return parent.appendingPathComponent(first.name) }

        // 兼容旧文稿中链接两端的空格。
        let expression = #/!\[\[([^\]\n]+)\]\]/#
        for match in text.matches(of: expression) {
            let name = match.output.1.trimmingCharacters(in: .whitespaces)
            let url = parent.appendingPathComponent(name)
            guard names.contains(name), isAudio(url) else { continue }
            if available != nil { return url }
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
               values.isRegularFile == true, values.isSymbolicLink != true { return url }
        }
        return nil
    }

    public func move(_ plan: LibraryMovePlan, into directory: URL) throws -> [URL] {
        guard try movePlan(for: plan.item) == plan else {
            throw LibraryError.operationFailed("录音关联已改变，请重新确认要移动的文件。")
        }
        let destinations = try plan.sources.map { try moveDestination(for: $0, into: directory) }
        var moved: [(URL, URL)] = []
        do {
            for (source, target) in zip(plan.sources, destinations) where source != target {
                try FileManager.default.moveItem(at: source, to: target)
                moved.append((source, target))
            }
        } catch {
            var failures: [String] = []
            for (source, target) in moved.reversed() {
                do { try FileManager.default.moveItem(at: target, to: source) }
                catch { failures.append(target.path + " " + error.localizedDescription) }
            }
            if !failures.isEmpty { throw LibraryError.rollbackFailed(failures.joined(separator: "\n")) }
            throw LibraryError.operationFailed("移动失败：\(error.localizedDescription)")
        }
        return destinations
    }

    public func move(_ item: URL, into directory: URL) throws -> URL {
        let src = item.standardizedFileURL
        let destination = try moveDestination(for: src, into: directory)
        guard destination != src else { return src }
        do {
            try FileManager.default.moveItem(at: src, to: destination)
        } catch {
            throw LibraryError.operationFailed("无法移动 \(src.lastPathComponent):\(error.localizedDescription)")
        }
        return destination
    }

    private func moveDestination(for item: URL, into directory: URL) throws -> URL {
        let src = item.standardizedFileURL
        let dir = directory.standardizedFileURL
        try requireInside(src)
        try requireInside(dir)
        try requireNotSymlink(dir)
        let resolvedRoot = root.resolvingSymlinksInPath()
        for path in [src, dir] where !Self.contains(resolvedRoot, path.resolvingSymlinksInPath()) {
            throw LibraryError.outsideLibrary(path.path)
        }
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
        if src.deletingLastPathComponent().resolvingSymlinksInPath() == dir.resolvingSymlinksInPath() { return src }
        let kind = try kindOf(src)
        let destination = dir.appendingPathComponent(src.lastPathComponent, isDirectory: kind == .directory)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw LibraryError.nameConflict(destination.lastPathComponent)
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
        guard trimmed.rangeOfCharacter(from: Paths.invalidFileNameCharacters) == nil else {
            throw LibraryError.invalidName("名称不能包含 / \\ : * ? \" < > | [ ] 或控制字符")
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
