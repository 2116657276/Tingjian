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
