import Darwin
import Foundation
import TingjianCore

func workspaceStateRegressionChecks() async {
    section("工作区状态纯算法:路径重映射与文稿高亮定位")

    // MARK: WorkspacePathMapper
    let base = fresh("workspace-state")
    let realRoot = base.appendingPathComponent("real-root", isDirectory: true)
    let symlinkRoot = base.appendingPathComponent("link-root", isDirectory: true)
    let fm = FileManager.default
    try! fm.createDirectory(at: realRoot, withIntermediateDirectories: true)
    try! fm.createSymbolicLink(at: symlinkRoot, withDestinationURL: realRoot)

    let oldDir = realRoot.appendingPathComponent("课程A", isDirectory: true)
    let newDir = realRoot.appendingPathComponent("归档/课程A-新", isDirectory: true)
    let nestedFile = oldDir.appendingPathComponent("第一讲/笔记.md")
    let siblingDir = realRoot.appendingPathComponent("课程A2/笔记.md")
    let outsideFile = base.appendingPathComponent("outside/笔记.md")

    let mapper = WorkspacePathMapper(saveRoot: realRoot, from: oldDir, to: newDir)
    await check("WorkspacePathMapper 映射自身目录及多级子路径",
                mapper.map(oldDir) == newDir.standardizedFileURL
                && mapper.map(nestedFile) == newDir.appendingPathComponent("第一讲/笔记.md").standardizedFileURL)
    await check("WorkspacePathMapper 不修改根目录外、兄弟目录与同前缀路径",
                mapper.map(outsideFile) == outsideFile
                && mapper.map(siblingDir) == siblingDir)

    // 符号链接规范化：saveRoot 经由 symlink 传入，old/url 分别经由 symlink 与 realpath 真实路径传入
    let linkMapper = WorkspacePathMapper(
        saveRoot: symlinkRoot,
        from: symlinkRoot.appendingPathComponent("课程A", isDirectory: true),
        to: newDir
    )
    var realBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
    let resolvedRealRoot = realpath(realRoot.path, &realBuf) != nil
        ? URL(fileURLWithPath: String(cString: realBuf), isDirectory: true)
        : realRoot
    let symlinkNested = symlinkRoot.appendingPathComponent("课程A/第一讲/笔记.md")
    let resolvedNested = resolvedRealRoot.appendingPathComponent("课程A/第一讲/笔记.md")
    let expectedNested = newDir.appendingPathComponent("第一讲/笔记.md").standardizedFileURL
    await check("WorkspacePathMapper 符号链接规范化后仍正确映射",
                linkMapper.map(symlinkNested) == expectedNested
                && linkMapper.map(resolvedNested) == expectedNested,
                "symlink=\(linkMapper.map(symlinkNested).path) resolved=\(linkMapper.map(resolvedNested).path) expected=\(expectedNested.path)")

    // 字典重映射与覆盖语义
    let destNested = newDir.appendingPathComponent("第一讲/笔记.md").standardizedFileURL
    let untouched = realRoot.appendingPathComponent("其他/文档.md").standardizedFileURL
    let sourceDict: [URL: String] = [
        nestedFile: "新移入内容",
        destNested: "旧滞留内容",
        untouched: "保持不变",
    ]
    let remappedDict = mapper.remapDictionary(sourceDict)
    await check("WorkspacePathMapper.remapDictionary 保留未移键并以移入值覆盖目标旧值",
                remappedDict.count == 2
                && remappedDict[destNested] == "新移入内容"
                && remappedDict[untouched] == "保持不变"
                && remappedDict[nestedFile] == nil)

    // 标签页重映射与去重语义：从已有标签移入目标优先于旧滞留标签且去重
    let tabsWithStaleFirst = [untouched, destNested, nestedFile, nestedFile]
    let remappedTabs1 = mapper.remapTabs(tabsWithStaleFirst)
    await check("WorkspacePathMapper.remapTabs 移入标签优先于旧滞留标签并去重",
                remappedTabs1 == [untouched, destNested])

    let tabsWithMovedFirst = [nestedFile, untouched, destNested, untouched]
    let remappedTabs2 = mapper.remapTabs(tabsWithMovedFirst)
    await check("WorkspacePathMapper.remapTabs 保持移入标签原始顺序并去重",
                remappedTabs2 == [destNested, untouched])

    // MARK: DocumentHighlightResolver
    // 块序列：标题(无时间戳) + 0s 空锚点 + 10s 可见段 + 20s 空锚点 + 30s 空锚点 + 40s 可见段
    let blocks: [(id: Int, isEmptyCorrectedAnchor: Bool)] = [
        (id: 0, isEmptyCorrectedAnchor: false),
        (id: 1, isEmptyCorrectedAnchor: true),
        (id: 2, isEmptyCorrectedAnchor: false),
        (id: 3, isEmptyCorrectedAnchor: true),
        (id: 4, isEmptyCorrectedAnchor: true),
        (id: 5, isEmptyCorrectedAnchor: false),
    ]
    let times: [Double?] = [nil, 0.0, 10.0, 20.0, 30.0, 40.0]

    await check("DocumentHighlightResolver 显示空锚点时命中空锚点块",
                DocumentHighlightResolver.activeBlockID(blocks: blocks, blockTimes: times, at: 2.0, showEmptyCorrectedSegments: true) == 1
                && DocumentHighlightResolver.activeBlockID(blocks: blocks, blockTimes: times, at: 25.0, showEmptyCorrectedSegments: true) == 3
                && DocumentHighlightResolver.activeBlockID(blocks: blocks, blockTimes: times, at: 35.0, showEmptyCorrectedSegments: true) == 4)

    await check("DocumentHighlightResolver 隐藏空锚点时穿过空段保持上一可见段高亮",
                DocumentHighlightResolver.activeBlockID(blocks: blocks, blockTimes: times, at: 12.0, showEmptyCorrectedSegments: false) == 2
                && DocumentHighlightResolver.activeBlockID(blocks: blocks, blockTimes: times, at: 25.0, showEmptyCorrectedSegments: false) == 2
                && DocumentHighlightResolver.activeBlockID(blocks: blocks, blockTimes: times, at: 35.0, showEmptyCorrectedSegments: false) == 2
                && DocumentHighlightResolver.activeBlockID(blocks: blocks, blockTimes: times, at: 40.0, showEmptyCorrectedSegments: false) == 5)

    await check("DocumentHighlightResolver 首段可见块之前返回 nil",
                DocumentHighlightResolver.activeBlockID(blocks: blocks, blockTimes: times, at: 0.0, showEmptyCorrectedSegments: false) == nil
                && DocumentHighlightResolver.activeBlockID(blocks: blocks, blockTimes: times, at: 5.0, showEmptyCorrectedSegments: false) == nil)

    let allEmpty: [(id: Int, isEmptyCorrectedAnchor: Bool)] = [
        (id: 10, isEmptyCorrectedAnchor: true),
        (id: 11, isEmptyCorrectedAnchor: true),
    ]
    await check("DocumentHighlightResolver 空输入、全空隐藏与非法位置返回 nil",
                DocumentHighlightResolver.activeBlockID(blocks: [], blockTimes: [], at: 1.0, showEmptyCorrectedSegments: true) == nil
                && DocumentHighlightResolver.activeBlockID(blocks: allEmpty, blockTimes: [0.0, 5.0], at: 6.0, showEmptyCorrectedSegments: false) == nil
                && DocumentHighlightResolver.activeBlockID(blocks: blocks, blockTimes: times, at: -1.0, showEmptyCorrectedSegments: true) == nil)
}
