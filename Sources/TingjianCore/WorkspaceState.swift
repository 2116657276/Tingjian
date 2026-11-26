import Darwin
import Foundation

/// 工作区路径重映射器（无 UI 依赖，用于目录/文件移动或重命名后的状态迁移）。
public struct WorkspacePathMapper: Sendable {
    private let root: URL
    private let resolvedRoot: URL
    private let resolvedOld: URL
    private let targetRoot: URL

    public init(saveRoot: URL, from old: URL, to new: URL) {
        let root = saveRoot.standardizedFileURL
        var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedRoot: URL
        if realpath(root.path, &resolvedPath) != nil {
            resolvedRoot = URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: true)
        } else {
            resolvedRoot = root
        }
        self.root = root
        self.resolvedRoot = resolvedRoot
        self.targetRoot = new.standardizedFileURL
        self.resolvedOld = Self.canonical(old, root: root, resolvedRoot: resolvedRoot)
    }

    /// 若 `url` 位于旧路径（或其子路径）下，则映射至对应的新路径；否则原样返回。
    public func map(_ url: URL) -> URL {
        let resolvedURL = Self.canonical(url, root: root, resolvedRoot: resolvedRoot)
        guard ProjectLibrary.contains(resolvedOld, resolvedURL) else { return url }
        let suffix = resolvedURL.pathComponents.dropFirst(resolvedOld.pathComponents.count)
        return suffix.reduce(targetRoot) { $0.appendingPathComponent($1) }.standardizedFileURL
    }

    /// 重映射以 URL 为键的字典；从旧路径移入的条目优先覆盖目标路径上的旧滞留条目。
    public func remapDictionary<Value>(_ values: [URL: Value]) -> [URL: Value] {
        var result = values.filter { map($0.key) == $0.key }
        for (url, value) in values {
            let target = map(url)
            if target != url {
                result[target] = value
            }
        }
        return result
    }

    /// 重映射已打开标签页列表：从已有标签移入目标优先于旧滞留标签，且按原顺序去重。
    public func remapTabs(_ tabs: [URL]) -> [URL] {
        let movedTabs = Set(tabs.compactMap { url -> URL? in
            let mapped = map(url)
            return mapped == url ? nil : mapped
        })
        var seen: Set<URL> = []
        return tabs.compactMap { url in
            let mapped = map(url)
            guard mapped != url || !movedTabs.contains(url), seen.insert(mapped).inserted else { return nil }
            return mapped
        }
    }

    private static func canonical(_ value: URL, root: URL, resolvedRoot: URL) -> URL {
        let path = value.standardizedFileURL
        guard ProjectLibrary.contains(root, path) else { return path }
        var result = resolvedRoot
        for component in path.pathComponents.dropFirst(root.pathComponents.count) {
            result.appendPathComponent(component)
        }
        return result
    }
}

/// 文稿播放高亮块解析器（无 UI 依赖）。
public enum DocumentHighlightResolver {
    /// 根据当前播放位置解析应高亮的块 ID。
    /// 当 `showEmptyCorrectedSegments` 为 `false` 时跳过空校正锚点，穿过隐藏空段时保持上一可见段高亮不熄灭。
    public static func activeBlockID(
        blocks: [(id: Int, isEmptyCorrectedAnchor: Bool)],
        blockTimes: [Double?],
        at position: Double,
        showEmptyCorrectedSegments: Bool
    ) -> Int? {
        guard !blocks.isEmpty else { return nil }
        let candidateIndices: [Int]
        let candidateTimes: [Double?]
        if showEmptyCorrectedSegments {
            candidateIndices = Array(blocks.indices)
            candidateTimes = blockTimes
        } else {
            var indices: [Int] = []
            var times: [Double?] = []
            indices.reserveCapacity(blocks.count)
            times.reserveCapacity(blocks.count)
            for idx in blocks.indices where !blocks[idx].isEmptyCorrectedAnchor {
                indices.append(idx)
                times.append(blockTimes.indices.contains(idx) ? blockTimes[idx] : nil)
            }
            candidateIndices = indices
            candidateTimes = times
        }
        guard let localIndex = TranscriptLocator.activeBlockIndex(at: position, timestamps: candidateTimes),
              candidateIndices.indices.contains(localIndex) else {
            return nil
        }
        return blocks[candidateIndices[localIndex]].id
    }
}

/// 标签页切换后的选中态落点。
public enum WorkspaceTabSelectionOutcome: Equatable, Sendable {
    case unchanged
    case activate(URL)
    case fallbackToRoot
}

/// 标签页状态迁移结果（无 UI 依赖，便于离线回归测试）。
public struct WorkspaceTabTransition: Equatable, Sendable {
    public let tabs: [URL]
    public let outcome: WorkspaceTabSelectionOutcome
    public let removedTabs: [URL]
    public let removedDeadTabs: [URL]

    public init(
        tabs: [URL],
        outcome: WorkspaceTabSelectionOutcome,
        removedTabs: [URL],
        removedDeadTabs: [URL]
    ) {
        self.tabs = tabs
        self.outcome = outcome
        self.removedTabs = removedTabs
        self.removedDeadTabs = removedDeadTabs
    }
}

/// 工作区文件标签命名消歧与失效标签自动清理策略（无 UI 依赖）。
public enum WorkspaceTabPolicy {
    /// 生成标签显示标题：
    /// - 无重名：显示课程名或去扩展名文件名；
    /// - 同目录不同扩展名：显示 `课名.ext`；
    /// - 同目录同扩展名仍重名：附加 `compactDate`（若同目录同时存在其他扩展名则保留 `.ext`；仍冲突或无日期前缀则退回完整文件名）；
    /// - 不同目录重名：附加父目录显示名（若父目录显示名仍冲突则附加父目录 `compactDate` 或完整目录名）。
    public static func title(for tab: URL, in openTabs: [URL]) -> String {
        let target = tab.standardizedFileURL
        let stem = target.deletingPathExtension().lastPathComponent
        let parts = Paths.parseRecordingName(stem)
        let baseTitle = parts?.displayTitle ?? stem

        var seen: Set<URL> = []
        var uniqueTabs: [URL] = []
        for candidate in openTabs.map(\.standardizedFileURL) where seen.insert(candidate).inserted {
            uniqueTabs.append(candidate)
        }
        if seen.insert(target).inserted {
            uniqueTabs.append(target)
        }

        let duplicates = uniqueTabs.filter { Self.baseTitle(for: $0) == baseTitle }
        guard duplicates.count > 1 else { return baseTitle }

        let parent = target.deletingLastPathComponent()
        let sameParent = duplicates.filter { $0.deletingLastPathComponent() == parent }
        let hasOtherParents = duplicates.count > sameParent.count

        let localTitle: String
        if sameParent.count > 1 {
            let ext = target.pathExtension
            let sameParentSameExt = sameParent.filter { $0.pathExtension.lowercased() == ext.lowercased() }
            let hasOtherExtInSameParent = sameParent.count > sameParentSameExt.count
            let titleWithExt = ext.isEmpty ? baseTitle : "\(baseTitle).\(ext)"
            if sameParentSameExt.count == 1 {
                localTitle = titleWithExt
            } else if let compactDate = parts?.compactDate {
                let sameCompactDate = sameParentSameExt.filter {
                    Paths.parseRecordingName($0.deletingPathExtension().lastPathComponent)?.compactDate == compactDate
                }
                if sameCompactDate.count == 1 {
                    let prefix = hasOtherExtInSameParent ? titleWithExt : baseTitle
                    localTitle = "\(prefix) · \(compactDate)"
                } else {
                    localTitle = target.lastPathComponent
                }
            } else {
                localTitle = target.lastPathComponent
            }
        } else {
            localTitle = baseTitle
        }

        guard hasOtherParents else { return localTitle }

        let distinctParents = Set(duplicates.map { $0.deletingLastPathComponent() })
        let parentSuffix = Self.parentDisambiguator(for: parent, among: distinctParents)
        return "\(localTitle) · \(parentSuffix)"
    }

    /// 激活指定标签；若磁盘文件已不存在则移除该失效标签并继续落到下一个存活标签（全失效时回退根目录）。
    public static func activate(
        _ url: URL,
        in openTabs: [URL],
        exists: (URL) -> Bool
    ) -> WorkspaceTabTransition {
        let key = url.standardizedFileURL
        var tabs = openTabs.map(\.standardizedFileURL)
        if exists(key) {
            return WorkspaceTabTransition(tabs: tabs, outcome: .activate(key), removedTabs: [], removedDeadTabs: [])
        }
        let index = tabs.firstIndex(of: key) ?? 0
        if let existingIndex = tabs.firstIndex(of: key) {
            tabs.remove(at: existingIndex)
        }
        var removedTabs = [key]
        var removedDeadTabs = [key]
        let outcome = selectNextLive(
            in: &tabs,
            startingAt: index,
            exists: exists,
            removedTabs: &removedTabs,
            removedDeadTabs: &removedDeadTabs
        )
        return WorkspaceTabTransition(
            tabs: tabs,
            outcome: outcome,
            removedTabs: removedTabs,
            removedDeadTabs: removedDeadTabs
        )
    }

    /// 关闭指定标签；若关闭的是当前选中标签，则自动跳过失效标签并落到下一个存活标签（全失效时回退根目录）。
    public static func close(
        _ url: URL,
        in openTabs: [URL],
        selectedURL: URL?,
        exists: (URL) -> Bool
    ) -> WorkspaceTabTransition {
        let key = url.standardizedFileURL
        var tabs = openTabs.map(\.standardizedFileURL)
        guard let index = tabs.firstIndex(of: key) else {
            return WorkspaceTabTransition(tabs: tabs, outcome: .unchanged, removedTabs: [], removedDeadTabs: [])
        }
        tabs.remove(at: index)
        var removedTabs = [key]
        var removedDeadTabs: [URL] = []
        guard selectedURL?.standardizedFileURL == key else {
            return WorkspaceTabTransition(tabs: tabs, outcome: .unchanged, removedTabs: removedTabs, removedDeadTabs: [])
        }
        let outcome = selectNextLive(
            in: &tabs,
            startingAt: index,
            exists: exists,
            removedTabs: &removedTabs,
            removedDeadTabs: &removedDeadTabs
        )
        return WorkspaceTabTransition(
            tabs: tabs,
            outcome: outcome,
            removedTabs: removedTabs,
            removedDeadTabs: removedDeadTabs
        )
    }

    /// 关闭除 `url` 之外的其他标签并激活 `url`；若保留项已失效则移除并回退根目录。
    public static func closeOthers(
        keeping url: URL,
        in openTabs: [URL],
        exists: (URL) -> Bool
    ) -> WorkspaceTabTransition {
        let key = url.standardizedFileURL
        let normalized = openTabs.map(\.standardizedFileURL)
        var removedTabs = normalized.filter { $0 != key }
        let kept = normalized.contains(key) ? [key] : []
        if exists(key) {
            return WorkspaceTabTransition(
                tabs: kept,
                outcome: .activate(key),
                removedTabs: removedTabs,
                removedDeadTabs: []
            )
        }
        if !removedTabs.contains(key) {
            removedTabs.append(key)
        }
        return WorkspaceTabTransition(
            tabs: [],
            outcome: .fallbackToRoot,
            removedTabs: removedTabs,
            removedDeadTabs: [key]
        )
    }

    /// 关闭 `url` 右侧全部标签；若当前选中项被关闭则激活 `url`，若 `url` 已失效则移除并继续落到下一个存活标签。
    public static func closeToRight(
        of url: URL,
        in openTabs: [URL],
        selectedURL: URL?,
        exists: (URL) -> Bool
    ) -> WorkspaceTabTransition {
        let key = url.standardizedFileURL
        var tabs = openTabs.map(\.standardizedFileURL)
        guard let index = tabs.firstIndex(of: key) else {
            return WorkspaceTabTransition(tabs: tabs, outcome: .unchanged, removedTabs: [], removedDeadTabs: [])
        }
        var removedTabs = Array(tabs.dropFirst(index + 1))
        tabs = Array(tabs.prefix(index + 1))
        guard let active = selectedURL?.standardizedFileURL, removedTabs.contains(active) else {
            return WorkspaceTabTransition(tabs: tabs, outcome: .unchanged, removedTabs: removedTabs, removedDeadTabs: [])
        }
        if exists(key) {
            return WorkspaceTabTransition(
                tabs: tabs,
                outcome: .activate(key),
                removedTabs: removedTabs,
                removedDeadTabs: []
            )
        }
        tabs.remove(at: index)
        removedTabs.append(key)
        var removedDeadTabs = [key]
        let outcome = selectNextLive(
            in: &tabs,
            startingAt: index,
            exists: exists,
            removedTabs: &removedTabs,
            removedDeadTabs: &removedDeadTabs
        )
        return WorkspaceTabTransition(
            tabs: tabs,
            outcome: outcome,
            removedTabs: removedTabs,
            removedDeadTabs: removedDeadTabs
        )
    }

    /// 按相对偏移切换标签（`⌘⌥[` / `⌘⌥]`）；沿切换方向自动跳过并移除失效标签，全部失效时回退根目录。
    public static func activateRelative(
        _ offset: Int,
        in openTabs: [URL],
        selectedTab: URL?,
        exists: (URL) -> Bool
    ) -> WorkspaceTabTransition {
        var tabs = openTabs.map(\.standardizedFileURL)
        guard !tabs.isEmpty else {
            return WorkspaceTabTransition(tabs: [], outcome: .unchanged, removedTabs: [], removedDeadTabs: [])
        }
        let step = offset < 0 ? -1 : 1
        let currentIndex = selectedTab.map(\.standardizedFileURL).flatMap { tabs.firstIndex(of: $0) }
        var candidateIndex: Int
        if let currentIndex {
            candidateIndex = ((currentIndex + offset) % tabs.count + tabs.count) % tabs.count
        } else {
            candidateIndex = step < 0 ? tabs.count - 1 : 0
        }
        var removedTabs: [URL] = []
        var removedDeadTabs: [URL] = []
        while !tabs.isEmpty {
            candidateIndex = ((candidateIndex % tabs.count) + tabs.count) % tabs.count
            let candidate = tabs[candidateIndex]
            if exists(candidate) {
                return WorkspaceTabTransition(
                    tabs: tabs,
                    outcome: .activate(candidate),
                    removedTabs: removedTabs,
                    removedDeadTabs: removedDeadTabs
                )
            }
            tabs.remove(at: candidateIndex)
            removedTabs.append(candidate)
            removedDeadTabs.append(candidate)
            if step < 0 {
                candidateIndex -= 1
            }
        }
        return WorkspaceTabTransition(
            tabs: [],
            outcome: .fallbackToRoot,
            removedTabs: removedTabs,
            removedDeadTabs: removedDeadTabs
        )
    }

    private static func baseTitle(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return Paths.parseRecordingName(stem)?.displayTitle ?? stem
    }

    private static func parentDisambiguator(for parent: URL, among distinctParents: Set<URL>) -> String {
        let parentName = parent.lastPathComponent
        let parentParts = Paths.parseRecordingName(parentName)
        let parentDisplay = parentParts?.displayTitle ?? parentName
        let sameDisplayCount = distinctParents.reduce(0) { count, candidate in
            let name = candidate.lastPathComponent
            let display = Paths.parseRecordingName(name)?.displayTitle ?? name
            return count + (display == parentDisplay ? 1 : 0)
        }
        guard sameDisplayCount > 1 else { return parentDisplay }
        if let compactDate = parentParts?.compactDate {
            let sameDateCount = distinctParents.reduce(0) { count, candidate in
                let parsed = Paths.parseRecordingName(candidate.lastPathComponent)
                let matches = parsed?.displayTitle == parentDisplay && parsed?.compactDate == compactDate
                return count + (matches ? 1 : 0)
            }
            if sameDateCount == 1 {
                return "\(parentDisplay) \(compactDate)"
            }
        }
        return parentName
    }

    private static func selectNextLive(
        in tabs: inout [URL],
        startingAt index: Int,
        exists: (URL) -> Bool,
        removedTabs: inout [URL],
        removedDeadTabs: inout [URL]
    ) -> WorkspaceTabSelectionOutcome {
        while !tabs.isEmpty {
            let candidateIndex = min(max(0, index), tabs.count - 1)
            let candidate = tabs[candidateIndex]
            if exists(candidate) {
                return .activate(candidate)
            }
            tabs.remove(at: candidateIndex)
            removedTabs.append(candidate)
            removedDeadTabs.append(candidate)
        }
        return .fallbackToRoot
    }
}
