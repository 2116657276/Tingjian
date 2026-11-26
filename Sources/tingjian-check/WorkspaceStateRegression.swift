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

    // MARK: WorkspaceTabPolicy 命名消歧
    let tabRoot = fresh("workspace-tabs")
    let dirA = tabRoot.appendingPathComponent("2026-11-20_09-00-00_高等数学", isDirectory: true)
    let dirB = tabRoot.appendingPathComponent("线性代数", isDirectory: true)

    let sameDirMd = dirA.appendingPathComponent("2026-11-26_10-00-00_微积分.md")
    let sameDirM4a = dirA.appendingPathComponent("2026-11-26_10-00-00_微积分.m4a")
    let uniqueDoc = dirB.appendingPathComponent("2026-11-26_08-00-00_矩阵.md")
    await check("WorkspaceTabPolicy 无重名仅显示课名，同目录不同扩展名显示 课名.ext",
                WorkspaceTabPolicy.title(for: uniqueDoc, in: [sameDirMd, sameDirM4a, uniqueDoc]) == "矩阵"
                && WorkspaceTabPolicy.title(for: sameDirMd, in: [sameDirMd, sameDirM4a, uniqueDoc]) == "微积分.md"
                && WorkspaceTabPolicy.title(for: sameDirM4a, in: [sameDirMd, sameDirM4a, uniqueDoc]) == "微积分.m4a")

    let sameDirEarlier = dirA.appendingPathComponent("2026-11-26_10-00-00_微积分.md")
    let sameDirLater = dirA.appendingPathComponent("2026-11-26_11-30-00_微积分.md")
    await check("WorkspaceTabPolicy 同目录同扩展名重名附加 compactDate",
                WorkspaceTabPolicy.title(for: sameDirEarlier, in: [sameDirEarlier, sameDirLater]) == "微积分 · 11-26 10:00"
                && WorkspaceTabPolicy.title(for: sameDirLater, in: [sameDirEarlier, sameDirLater]) == "微积分 · 11-26 11:30")

    let sameMinute1 = dirA.appendingPathComponent("2026-11-26_10-00-01_微积分.md")
    let sameMinute2 = dirA.appendingPathComponent("2026-11-26_10-00-02_微积分.md")
    await check("WorkspaceTabPolicy 同目录同扩展名且 compactDate 仍冲突退回完整文件名",
                WorkspaceTabPolicy.title(for: sameMinute1, in: [sameMinute1, sameMinute2]) == "2026-11-26_10-00-01_微积分.md"
                && WorkspaceTabPolicy.title(for: sameMinute2, in: [sameMinute1, sameMinute2]) == "2026-11-26_10-00-02_微积分.md")

    let plainSameName = dirA.appendingPathComponent("微积分.md")
    await check("WorkspaceTabPolicy 同目录同扩展名混合无日期前缀文件名正确消歧",
                WorkspaceTabPolicy.title(for: sameDirEarlier, in: [sameDirEarlier, plainSameName]) == "微积分 · 11-26 10:00"
                && WorkspaceTabPolicy.title(for: plainSameName, in: [sameDirEarlier, plainSameName]) == "微积分.md")

    let otherDirDoc = dirB.appendingPathComponent("2026-11-26_10-00-00_微积分.md")
    await check("WorkspaceTabPolicy 不同目录重名附加父目录显示名",
                WorkspaceTabPolicy.title(for: sameDirEarlier, in: [sameDirEarlier, otherDirDoc]) == "微积分 · 高等数学"
                && WorkspaceTabPolicy.title(for: otherDirDoc, in: [sameDirEarlier, otherDirDoc]) == "微积分 · 线性代数")

    // 同目录同时存在多时间戳 + 多扩展名：保留 .ext 且附加 compactDate，避免 .md/.m4a 撞名
    let sameDirEarlierM4a = dirA.appendingPathComponent("2026-11-26_10-00-00_微积分.m4a")
    let sameDirLaterM4a = dirA.appendingPathComponent("2026-11-26_11-30-00_微积分.m4a")
    let multiExtAndDate = [sameDirEarlier, sameDirLater, sameDirEarlierM4a, sameDirLaterM4a]
    await check("WorkspaceTabPolicy 同目录多时间戳且多扩展名同时保留扩展名与 compactDate",
                WorkspaceTabPolicy.title(for: sameDirEarlier, in: multiExtAndDate) == "微积分.md · 11-26 10:00"
                && WorkspaceTabPolicy.title(for: sameDirEarlierM4a, in: multiExtAndDate) == "微积分.m4a · 11-26 10:00"
                && WorkspaceTabPolicy.title(for: sameDirLater, in: multiExtAndDate) == "微积分.md · 11-26 11:30"
                && WorkspaceTabPolicy.title(for: sameDirLaterM4a, in: multiExtAndDate) == "微积分.m4a · 11-26 11:30")

    // 同目录不同扩展名 + 跨目录重名同时出现：同时消歧扩展名与父目录
    let otherDirM4a = dirB.appendingPathComponent("2026-11-26_10-00-00_微积分.m4a")
    let sameAndCrossDir = [sameDirMd, sameDirM4a, otherDirDoc, otherDirM4a]
    await check("WorkspaceTabPolicy 同目录与跨目录重名并存时同时区分扩展名与父目录",
                WorkspaceTabPolicy.title(for: sameDirMd, in: sameAndCrossDir) == "微积分.md · 高等数学"
                && WorkspaceTabPolicy.title(for: sameDirM4a, in: sameAndCrossDir) == "微积分.m4a · 高等数学"
                && WorkspaceTabPolicy.title(for: otherDirDoc, in: sameAndCrossDir) == "微积分.md · 线性代数"
                && WorkspaceTabPolicy.title(for: otherDirM4a, in: sameAndCrossDir) == "微积分.m4a · 线性代数")

    // 不同录音目录但父目录显示名相同：附加父目录 compactDate 消歧
    let dirA2 = tabRoot.appendingPathComponent("2026-11-27_09-00-00_高等数学", isDirectory: true)
    let noteInDirA = dirA.appendingPathComponent("笔记.md")
    let noteInDirA2 = dirA2.appendingPathComponent("笔记.md")
    await check("WorkspaceTabPolicy 不同目录但父目录显示名冲突时附加父目录 compactDate",
                WorkspaceTabPolicy.title(for: noteInDirA, in: [noteInDirA, noteInDirA2]) == "笔记 · 高等数学 11-20 09:00"
                && WorkspaceTabPolicy.title(for: noteInDirA2, in: [noteInDirA, noteInDirA2]) == "笔记 · 高等数学 11-27 09:00")

    // 列表含重复 URL 时不误判为重名
    await check("WorkspaceTabPolicy openTabs 含重复 URL 时不误触发消歧",
                WorkspaceTabPolicy.title(for: uniqueDoc, in: [uniqueDoc, uniqueDoc]) == "矩阵")

    // MARK: WorkspaceTabPolicy 死标签自动移除与切换回退
    let live0 = tabRoot.appendingPathComponent("live0.md").standardizedFileURL
    let dead1 = tabRoot.appendingPathComponent("dead1.md").standardizedFileURL
    let dead2 = tabRoot.appendingPathComponent("dead2.md").standardizedFileURL
    let live3 = tabRoot.appendingPathComponent("live3.m4a").standardizedFileURL
    let liveSet: Set<URL> = [live0, live3]
    let exists: (URL) -> Bool = { liveSet.contains($0.standardizedFileURL) }

    // 1. activate 命中死标签：移除失效标签并跳过连续死标签落到下一个存活标签
    let act1 = WorkspaceTabPolicy.activate(dead1, in: [live0, dead1, dead2, live3], exists: exists)
    await check("WorkspaceTabPolicy.activate 移除死标签并落到下一存活标签",
                act1.tabs == [live0, live3]
                && act1.outcome == .activate(live3)
                && act1.removedDeadTabs == [dead1, dead2])

    // 2. activate 全失效：清空标签并安全回退根目录
    let actAllDead = WorkspaceTabPolicy.activate(dead1, in: [dead1, dead2], exists: exists)
    await check("WorkspaceTabPolicy.activate 全部失效时清空并回退根目录",
                actAllDead.tabs.isEmpty
                && actAllDead.outcome == .fallbackToRoot
                && actAllDead.removedDeadTabs == [dead1, dead2])

    // 3. close 当前标签后，后续位置为死标签：自动移除死标签并落到存活标签
    let closeJump = WorkspaceTabPolicy.close(live0, in: [live0, dead1, dead2, live3], selectedURL: live0, exists: exists)
    await check("WorkspaceTabPolicy.close 关闭当前标签自动跳过并清理死标签",
                closeJump.tabs == [live3]
                && closeJump.outcome == .activate(live3)
                && closeJump.removedTabs == [live0, dead1, dead2]
                && closeJump.removedDeadTabs == [dead1, dead2])

    let closeAllDead = WorkspaceTabPolicy.close(live0, in: [live0, dead1, dead2], selectedURL: live0, exists: exists)
    await check("WorkspaceTabPolicy.close 剩余全死时清空并回退根目录",
                closeAllDead.tabs.isEmpty
                && closeAllDead.outcome == .fallbackToRoot
                && closeAllDead.removedDeadTabs == [dead1, dead2])

    // 4. closeOthers 保留项为死标签：移除死标签并回退根目录
    let othersDead = WorkspaceTabPolicy.closeOthers(keeping: dead1, in: [live0, dead1, live3], exists: exists)
    await check("WorkspaceTabPolicy.closeOthers 保留项失效时移除并回退根目录",
                othersDead.tabs.isEmpty
                && othersDead.outcome == .fallbackToRoot
                && othersDead.removedDeadTabs == [dead1]
                && Set(othersDead.removedTabs) == Set([live0, dead1, live3]))

    // 5. closeToRight 当前选中在右侧且锚点为死标签：移除锚点死标签并回退到左侧存活标签
    let rightDeadAnchor = WorkspaceTabPolicy.closeToRight(of: dead1, in: [live0, dead1, live3], selectedURL: live3, exists: exists)
    await check("WorkspaceTabPolicy.closeToRight 锚点失效时移除并回退到左侧存活标签",
                rightDeadAnchor.tabs == [live0]
                && rightDeadAnchor.outcome == .activate(live0)
                && rightDeadAnchor.removedDeadTabs == [dead1]
                && Set(rightDeadAnchor.removedTabs) == Set([live3, dead1]))

    // 6. activateRelative 正向/反向跳过连续死标签，不卡死，全死回退根目录
    let relForward = WorkspaceTabPolicy.activateRelative(1, in: [live0, dead1, dead2, live3], selectedTab: live0, exists: exists)
    await check("WorkspaceTabPolicy.activateRelative 正向跳过并移除连续死标签",
                relForward.tabs == [live0, live3]
                && relForward.outcome == .activate(live3)
                && relForward.removedDeadTabs == [dead1, dead2])

    let relBackward = WorkspaceTabPolicy.activateRelative(-1, in: [live0, dead1, dead2, live3], selectedTab: live3, exists: exists)
    await check("WorkspaceTabPolicy.activateRelative 反向跳过并移除连续死标签",
                relBackward.tabs == [live0, live3]
                && relBackward.outcome == .activate(live0)
                && relBackward.removedDeadTabs == [dead2, dead1])

    let relWrapBackward = WorkspaceTabPolicy.activateRelative(-1, in: [dead1, live0, live3], selectedTab: live0, exists: exists)
    await check("WorkspaceTabPolicy.activateRelative 反向跨首尾跳过死标签",
                relWrapBackward.tabs == [live0, live3]
                && relWrapBackward.outcome == .activate(live3)
                && relWrapBackward.removedDeadTabs == [dead1])

    let relAllDead = WorkspaceTabPolicy.activateRelative(1, in: [dead1, dead2], selectedTab: dead1, exists: exists)
    await check("WorkspaceTabPolicy.activateRelative 全部失效时不卡死并回退根目录",
                relAllDead.tabs.isEmpty
                && relAllDead.outcome == .fallbackToRoot
                && Set(relAllDead.removedDeadTabs) == Set([dead1, dead2]))

    // 7. 关闭非当前标签 / 关闭右侧但当前选中在左侧：不抢焦点（outcome == .unchanged）
    let closeInactive = WorkspaceTabPolicy.close(live3, in: [live0, dead1, live3], selectedURL: live0, exists: exists)
    await check("WorkspaceTabPolicy.close 关闭非当前标签不改变选中焦点",
                closeInactive.tabs == [live0, dead1]
                && closeInactive.outcome == .unchanged
                && closeInactive.removedTabs == [live3]
                && closeInactive.removedDeadTabs.isEmpty)

    let closeRightKeepLeft = WorkspaceTabPolicy.closeToRight(of: live0, in: [live0, dead1, live3], selectedURL: live0, exists: exists)
    await check("WorkspaceTabPolicy.closeToRight 当前选中未受影响时不抢焦点",
                closeRightKeepLeft.tabs == [live0]
                && closeRightKeepLeft.outcome == .unchanged
                && Set(closeRightKeepLeft.removedTabs) == Set([dead1, live3]))

    // 8. 停留在目录/录音页（selectedTab == nil）时用 ⌘⌥] / ⌘⌥[ 切入首/尾存活标签并清理沿途死标签
    let relFromDirFwd = WorkspaceTabPolicy.activateRelative(1, in: [dead1, live0, live3], selectedTab: nil, exists: exists)
    let relFromDirBwd = WorkspaceTabPolicy.activateRelative(-1, in: [live0, live3, dead2], selectedTab: nil, exists: exists)
    await check("WorkspaceTabPolicy.activateRelative 从非标签页切入首尾存活标签并清理死标签",
                relFromDirFwd.tabs == [live0, live3]
                && relFromDirFwd.outcome == .activate(live0)
                && relFromDirFwd.removedDeadTabs == [dead1]
                && relFromDirBwd.tabs == [live0, live3]
                && relFromDirBwd.outcome == .activate(live3)
                && relFromDirBwd.removedDeadTabs == [dead2])

    // 9. 同分钟同名录音父目录冲突时退回完整目录名消歧
    let sameMinDir1 = tabRoot.appendingPathComponent("2026-11-27_09-00-01_高等数学", isDirectory: true)
    let sameMinDir2 = tabRoot.appendingPathComponent("2026-11-27_09-00-02_高等数学", isDirectory: true)
    let noteSameMin1 = sameMinDir1.appendingPathComponent("笔记.md")
    let noteSameMin2 = sameMinDir2.appendingPathComponent("笔记.md")
    await check("WorkspaceTabPolicy 父目录 compactDate 仍冲突时退回完整目录名消歧",
                WorkspaceTabPolicy.title(for: noteSameMin1, in: [noteSameMin1, noteSameMin2]) == "笔记 · 2026-11-27_09-00-01_高等数学"
                && WorkspaceTabPolicy.title(for: noteSameMin2, in: [noteSameMin1, noteSameMin2]) == "笔记 · 2026-11-27_09-00-02_高等数学")
}
