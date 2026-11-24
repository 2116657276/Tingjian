import Foundation
import AVFoundation
import TingjianCore

/// 注入式音频源:不打开真实麦克风,可设置 UID、采样率、启动失败与延迟。
final class GateSource: AudioSource, @unchecked Sendable {
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onInterruption: (@Sendable (String) -> Void)?
    var onEnd: (@Sendable () -> Void)?
    var activeDeviceUID: String? { uid }
    var activeDeviceName: String? { uid.map { "Gate \($0)" } }

    var uid: String?
    var sampleRate: Double = 24000
    var granted = true
    var prepareDelay: Double = 0
    var onPrepare: (() throws -> Void)?
    var failStart = false
    var startDelay: Double = 0
    var stopDelay: Double = 0
    var starts = 0
    var stops = 0
    var prepares = 0
    var pauses = 0

    func requestAccess() async -> Bool {
        try? await Task.sleep(for: .milliseconds(150))
        return granted
    }

    func prepare() async throws -> AVAudioFormat {
        prepares += 1
        if prepareDelay > 0 { try? await Task.sleep(for: .seconds(prepareDelay)) }
        try onPrepare?()
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    func start() async throws {
        if startDelay > 0 { try? await Task.sleep(for: .seconds(startDelay)) }
        if failStart { throw AudioError.captureFailed("注入的启动失败") }
        starts += 1
        push()
    }

    func push(frames: AVAudioFrameCount = 2400, value: Float = 0.1) {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        b.frameLength = frames; b.floatChannelData![0].initialize(repeating: value, count: Int(frames))
        onBuffer?(b)
    }

    func restart() async throws { try await start() }

    func pause() async { pauses += 1 }

    func stop() async {
        if stopDelay > 0 { try? await Task.sleep(for: .seconds(stopDelay)) }
        stops += 1
    }
}

@MainActor
func additionalRegressionChecks() async {
    section("修复回归:启动、恢复数据与派生文件")
    let a = GateSource(), b = GateSource()
    var made = 0
    let r = Recorder(saveRoot: fresh("reg-start-dest"), localRoot: fresh("reg-start-local"),
                     makeEngine: { MockEngine(.normal) }, makeSource: { _ in made += 1; return made == 1 ? a : b })
    let first = Task { await r.start(course: "first") }
    try? await Task.sleep(for: .milliseconds(20))
    let second = Task { await r.start(course: "second") }
    let didStart = await first.value
    let didStartAgain = await second.value
    await check("权限等待期间重复开始只创建一个音源", didStart && !didStartAgain && made == 1 && a.starts == 1 && b.starts == 0)
    await r.stop()

    let denied = GateSource(); denied.granted = false
    let deniedRec = Recorder(saveRoot: fresh("reg-denied-dest"), localRoot: fresh("reg-denied-local"), makeSource: { _ in denied })
    let deniedStart = await deniedRec.start(course: "")
    await check("权限拒绝不启动音源且恢复空闲", !deniedStart && denied.starts == 0 && deniedRec.phase == .idle)

    let unloaded = MockEngine(.normal)
    unloaded.model = .needsDownload
    let modelSource = GateSource()
    let modelRecorder = Recorder(saveRoot: fresh("reg-model-dest"), localRoot: fresh("reg-model-local"),
                                 makeEngine: { unloaded }, makeSource: { _ in modelSource })
    await modelRecorder.refreshSpeechModelState()
    await check("开始录音前可检查中文模型状态", modelRecorder.speechModelState == .needsDownload && modelSource.starts == 0)
    await modelRecorder.start(course: "未安装模型")
    _ = await waitUntil(2) { modelRecorder.transcribe == .needsModel }
    modelSource.push(frames: 24000)
    await modelRecorder.stop()
    await check("缺模型时仍交付音频并保留模型状态", modelRecorder.deliveredFiles != nil && modelRecorder.speechModelState == .needsDownload)
    unloaded.failInstall = true
    await modelRecorder.installModel()
    await check("录后模型下载失败时保留重试状态", modelRecorder.modelProgress == nil && modelRecorder.modelDownloadError != nil)
    unloaded.failInstall = false
    await modelRecorder.installModel()
    await check("录后重试可准备模型，既有录音仍可用", modelRecorder.speechModelState == .ready && modelRecorder.modelDownloadError == nil && modelRecorder.deliveredFiles != nil)

    let staleProbe = MockEngine(.normal)
    staleProbe.model = .needsDownload
    staleProbe.modelQueryDelay = .milliseconds(300)
    let installed = MockEngine(.normal)
    let delayedSource = GateSource()
    var enginesCreated = 0
    let downloading = Recorder(saveRoot: fresh("reg-probe-dest"), localRoot: fresh("reg-probe-local"),
                               makeEngine: {
                                   enginesCreated += 1
                                   return enginesCreated == 1 ? staleProbe : installed
                               }, makeSource: { _ in delayedSource })
    await downloading.start(course: "录音开始时完成模型准备")
    try? await Task.sleep(for: .milliseconds(40))
    await downloading.installModel()
    let beganTranscribing = await waitUntil(2) { downloading.transcribe == .running }
    await check("模型准备完成后，迟到的旧状态不阻止识别",
                beganTranscribing && downloading.speechModelState == .ready)
    await downloading.stop()

    let dir = fresh("reg-events")
    var valid = try! JSONEncoder().encode(TranscriptEvent(kind: .text, start: 0, end: 1, text: "完整的确认文字"))
    valid.append(10); valid.append(contentsOf: [0x7B,0x22,0x78,0x22,0x3A,0x22,0xE4])
    try! valid.write(to: dir.appendingPathComponent("transcript.jsonl"))
    await check("UTF-8 残缺尾行不丢弃完整事件", SessionStore.loadEvents(dir: dir).events.count == 1)

    var asm = TranscriptAssembler(); asm.commit(start: 0, end: 1, text: "确认文字")
    let audio = dir.appendingPathComponent("synthetic.caf")
    let firstMD = try! Retranscriber.writeMarkdown(audio: audio, assembler: asm, duration: 1)
    try! "用户编辑".write(to: firstMD, atomically: true, encoding: .utf8)
    let secondMD = try! Retranscriber.writeMarkdown(audio: audio, assembler: asm, duration: 1)
    await check("重新转写保留已有文件和用户编辑", firstMD != secondMD && (try? String(contentsOf: firstMD, encoding: .utf8)) == "用户编辑")
    let canceled = GateSource()
    let canceledRec = Recorder(saveRoot: fresh("reg-cancel-dest"), localRoot: fresh("reg-cancel-local"), makeSource: { _ in canceled })
    let starting = Task { await canceledRec.start(course: "") }
    try? await Task.sleep(for: .milliseconds(20))
    canceledRec.cancelStarting()
    _ = await starting.value
    await check("取消启动后权限返回也不采集", canceled.starts == 0 && canceledRec.phase == .idle)

    let initLocal = fresh("reg-init-local"), blockedSource = GateSource()
    blockedSource.onPrepare = {
        let dir = try FileManager.default.contentsOfDirectory(at: initLocal, includingPropertiesForKeys: nil).first!
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("session.json"), withIntermediateDirectories: false)
    }
    let initRec = Recorder(saveRoot: fresh("reg-init-dest"), localRoot: initLocal, makeSource: { _ in blockedSource })
    await initRec.start(course: "")
    await check("首份元数据失败时不启动采集", blockedSource.starts == 0 && blockedSource.stops > 0 && initRec.phase == .idle)

    let brokenStoreDir = fresh("reg-store-errors")
    let brokenStore = SessionStore(dir: brokenStoreDir, info: SessionInfo(baseName: "probe", course: "", startedAt: Date(), state: .recording))
    try! FileManager.default.createDirectory(at: brokenStoreDir.appendingPathComponent("session.json"), withIntermediateDirectories: false)
    do { try brokenStore.save(); await check("元数据写入错误向调用者报告", false) }
    catch { await check("元数据写入错误向调用者报告", true) }
    try! FileManager.default.createDirectory(at: brokenStoreDir.appendingPathComponent("transcript.jsonl"), withIntermediateDirectories: false)
    let event = TranscriptEvent(kind: .text, start: 0, end: 1, text: "确认文字")
    do { try brokenStore.append(event); await check("日志写入错误停止后续盲目追加", false) }
    catch { await check("日志写入错误停止后续盲目追加", brokenStore.journalNeedsRepair) }

    var mixed = try! JSONEncoder().encode(event); mixed.append(10)
    mixed.append(Data("坏行\n".utf8)); mixed.append(try! JSONEncoder().encode(event)); mixed.append(10)
    try! mixed.write(to: dir.appendingPathComponent("transcript.jsonl"))
    let loaded = SessionStore.loadEvents(dir: dir)
    await check("坏行前后有效记录均保留并报告损坏", loaded.events.count == 2 && loaded.issues.count == 1)

    let live = GateSource()
    let liveRec = Recorder(saveRoot: fresh("reg-live-dest"), localRoot: fresh("reg-live-local"), makeEngine: { MockEngine(.normal) }, makeSource: { _ in live })
    await liveRec.start(course: "保存故障恢复")
    _ = await waitUntil(2) { liveRec.transcribe == .running }
    let liveDir = liveRec.localDir!
    let eventPath = liveDir.appendingPathComponent("transcript.jsonl")
    let infoPath = liveDir.appendingPathComponent("session.json")
    try! FileManager.default.moveItem(at: eventPath, to: liveDir.appendingPathComponent("events-backup"))
    try! FileManager.default.moveItem(at: infoPath, to: liveDir.appendingPathComponent("info-backup"))
    try! FileManager.default.createDirectory(at: eventPath, withIntermediateDirectories: false)
    try! FileManager.default.createDirectory(at: infoPath, withIntermediateDirectories: false)
    live.push(frames: 28800)
    _ = await waitUntil(6) { liveRec.persistenceIssue?.contains("恢复信息") == true }
    let before = liveRec.duration
    live.push(frames: 28800)
    _ = await waitUntil(2) { liveRec.duration > before }
    await check("日志和元数据保存失败时音频仍继续且外显异常", liveRec.phase == .recording && liveRec.duration > before && liveRec.persistenceIssue != nil)
    try! FileManager.default.moveItem(at: eventPath, to: liveDir.appendingPathComponent("blocked-events"))
    try! FileManager.default.moveItem(at: infoPath, to: liveDir.appendingPathComponent("blocked-info"))
    _ = await waitUntil(6) { liveRec.persistenceIssue == nil }
    await check("周期保存重建完整日志并恢复健康状态", liveRec.persistenceIssue == nil && SessionStore.loadEvents(dir: liveDir).events.filter { $0.kind == .text }.count >= 2)
    await liveRec.stop()

    let restoreDir = fresh("reg-restore-failed")
    makeTone(restoreDir.appendingPathComponent("audio.caf"), seconds: 0.1)
    var failedInfo = SessionInfo(baseName: restoreDir.lastPathComponent, course: "短录音", startedAt: Date(), state: .pendingSave)
    failedInfo.sampleRate = 24000; failedInfo.savedSamples = 2400; failedInfo.status = .failed
    try! SessionStore(dir: restoreDir, info: failedInfo).prepare()
    let restore = Recorder(saveRoot: fresh("reg-restore-dest"), localRoot: restoreDir.deletingLastPathComponent())
    await restore.recover(dir: restoreDir)
    await check("待保存失败会话恢复不升级为完成", restore.finalStatus == .failed)
    let orphan = fresh("reg-orphan"); makeTone(orphan.appendingPathComponent("audio.caf"), seconds: 0.2)
    await check("缺失元数据但存在 CAF 会被发现", Recorder.unfinishedSessions(in: orphan.deletingLastPathComponent()).contains { $0.resolvingSymlinksInPath().path == orphan.resolvingSymlinksInPath().path })
    await restore.recover(dir: orphan)
    await check("孤立 CAF 可恢复且不会虚报完整转写", restore.deliveredFiles != nil && restore.finalStatus != .completed)

    let quiet = Recorder(saveRoot: fresh("reg-quiet-dest"), localRoot: fresh("reg-quiet-local"), makeEngine: { QuietEngine() }, makeSource: { _ in GateSource() })
    await quiet.start(course: "静音")
    _ = await waitUntil(2) { quiet.transcribe == .running }
    await quiet.stop()
    await check("正常完成无文字会话不会误报失败", quiet.finalStatus == .completed && quiet.segments.isEmpty)
    let quietDir = quiet.localDir!
    var quietInfo = SessionStore.readInfo(dir: quietDir)!; quietInfo.state = .pendingSave
    try! SessionStore(dir: quietDir, info: quietInfo).save()
    await restore.recover(dir: quietDir)
    await check("正常无文字待保存会话恢复仍为完成", restore.finalStatus == .completed)

    if !skipCorrection {
        section("修复回归:纠正结构与交付路径")
        for newline in ["\n", "\r", "\u{2028}", "\u{2029}"] {
            do {
                _ = try TextCorrector.buildCorrectedMarkdown(original: "[00:00:01] 原文", corrected: ["文字" + newline + "[00:00:30] 额外内容"], originalName: "x.md", model: "probe")
                await check("拒绝换行或 Unicode 段落分隔符", false)
            } catch { await check("拒绝换行或 Unicode 段落分隔符", true) }
        }
        let goodMD = try! TextCorrector.buildCorrectedMarkdown(original: "[00:00:01] 原文", corrected: ["纠正。"], originalName: "x.md", model: "probe")
        let derivative = try! Paths.writeUniqueMarkdown(goodMD, base: "x_校正版", in: dir)
        let derivative2 = try! Paths.writeUniqueMarkdown(goodMD, base: "x_校正版", in: dir)
        await check("校正版同名时另存不覆盖", derivative != derivative2)
        let cleaned = try! TextCorrector.buildCorrectedMarkdown(
            original: "# 课堂\n\n[00:00:01] 啊啊\n\n[00:00:02] 决策树的根节点。",
            corrected: ["", "决策树的根节点。"], originalName: "课堂.md", model: "probe")
        let cleanedSegments = MarkdownDoc.parseSegments(cleaned)
        await check("纯语气词段保留空时间锚点",
                    cleanedSegments.map(\.time) == ["00:00:01", "00:00:02"]
                    && cleanedSegments.map(\.text) == ["", "决策树的根节点。"])

    }

    let slowSource = GateSource()
    let slow = Recorder(saveRoot: fresh("reg-slow-dest"), localRoot: fresh("reg-slow-local"), makeEngine: { MockEngine(.normal) }, makeSource: { _ in slowSource })
    let copies = TestCounter()
    slow.deliverFiles = { base, audio, markdown, root, id in
        copies.increment()
        Thread.sleep(forTimeInterval: 0.4)
        return try Deliverer.deliver(base: base, audio: audio, markdown: markdown, to: root, id: id)
    }
    await slow.start(course: "后台复制")
    _ = await waitUntil(2) { slow.transcribe == .running }
    try! FileManager.default.createDirectory(at: slow.saveRoot.appendingPathComponent(slow.localDir!.lastPathComponent), withIntermediateDirectories: true)
    let ending = Task { await slow.stop() }
    _ = await waitUntil(2) { slow.save == .saving }
    var beats = 0
    while slow.phase == .finalizing { beats += 1; try? await Task.sleep(for: .milliseconds(20)) }
    await ending.value
    await check("慢复制期间主执行器仍可运行", beats >= 8)
    if let files = slow.deliveredFiles {
        await check("录音器提供实际 Markdown 和音频地址", FileManager.default.fileExists(atPath: files.markdown.path) && files.audio.map { FileManager.default.fileExists(atPath: $0.path) } == true && files.directory.lastPathComponent != files.markdown.deletingPathExtension().lastPathComponent)
    } else { await check("录音器提供实际 Markdown 和音频地址", false) }
    let retrySource = GateSource()
    let retryRec = Recorder(saveRoot: fresh("reg-retry-dest"), localRoot: fresh("reg-retry-local"),
                            makeEngine: { MockEngine(.normal) }, makeSource: { _ in retrySource })
    let retryCopies = TestCounter()
    let injected = TestCounter()
    retryRec.deliverFiles = { base, audio, markdown, root, id in
        if injected.count == 0 { injected.increment(); throw ExportError.copyVerify("注入的交付失败") }
        retryCopies.increment()
        Thread.sleep(forTimeInterval: 0.3)
        return try Deliverer.deliver(base: base, audio: audio, markdown: markdown, to: root, id: id)
    }
    await retryRec.start(course: "重复重试")
    _ = await waitUntil(2) { retryRec.transcribe == .running }
    await retryRec.stop()
    if case .pending = retryRec.save {} else { await check("注入交付失败进入待保存", false) }
    let beforeRetry = retryCopies.count, beforeStarts = retrySource.starts
    let retryOne = Task { await retryRec.retrySave() }
    let retryTwo = Task { await retryRec.retrySave() }
    try? await Task.sleep(for: .milliseconds(50))
    await retryRec.start(course: "不应开始")
    await retryOne.value; await retryTwo.value
    await check("重试期间禁止新录音且重复重试只交付一次",
                retryCopies.count == beforeRetry + 1 && retrySource.starts == beforeStarts && retryRec.courseName == "重复重试")
    let afterRetry = retryCopies.count
    await retryRec.retrySave()
    await check("已保存会话不重复交付", retryCopies.count == afterRetry)

    // 阶段 2 A 类修复回归：0 字识别全程失败标 .failed（不再误标 .partial）
    let zeroFailSource = GateSource()
    let zeroFailLocal = fresh("reg-zerofail-local")
    let zeroFailRec = Recorder(saveRoot: fresh("reg-zerofail-dest"), localRoot: zeroFailLocal,
                               makeEngine: { MockEngine(.failAfter(0)) }, makeSource: { _ in zeroFailSource })
    zeroFailRec.retryDelay = 0.02
    let zeroFailStarted = await zeroFailRec.start(course: "零字失败")
    zeroFailSource.push(frames: 48_000)
    _ = await waitUntil(5) {
        if case .failed = zeroFailRec.transcribe { return zeroFailRec.duration >= 1.8 }
        return false
    }
    await zeroFailRec.stop()
    let zeroFailTexts = zeroFailRec.localDir.map { SessionStore.loadEvents(dir: $0).events.filter { $0.kind == .text } } ?? []
    await check("录制 >1.5s 且 0 字识别全程失败收尾标 .failed",
                zeroFailStarted && zeroFailRec.duration > 1.5 && zeroFailTexts.isEmpty
                && zeroFailRec.finalStatus == .failed && zeroFailRec.deliveredFiles != nil,
                "dur=\(zeroFailRec.duration) status=\(String(describing: zeroFailRec.finalStatus)) texts=\(zeroFailTexts.count)")

    // 阶段 2 A 类修复回归：启动准备失败（无 audio.caf）清理空目录且 localDir == nil
    let prepFailLocal = fresh("reg-prepfail-local")
    let prepFailSource = GateSource()
    prepFailSource.onPrepare = { throw AudioError.captureFailed("注入的 prepare 失败") }
    let prepFailRec = Recorder(saveRoot: fresh("reg-prepfail-dest"), localRoot: prepFailLocal,
                               makeEngine: { MockEngine(.normal) }, makeSource: { _ in prepFailSource })
    let prepFailStarted = await prepFailRec.start(course: "准备失败")
    let prepFailLeftovers = (try? FileManager.default.contentsOfDirectory(atPath: prepFailLocal.path)) ?? ["?"]
    await check("启动准备失败时清理 localRoot 空目录且 localDir 为空",
                !prepFailStarted && prepFailRec.phase == .idle && prepFailRec.localDir == nil && prepFailLeftovers.isEmpty,
                "localDir=\(String(describing: prepFailRec.localDir)) leftovers=\(prepFailLeftovers)")

    // 阶段 2 A 类修复回归：prepare 等待期间 cancelStarting 同样清理空目录
    let prepCancelLocal = fresh("reg-prepcancel-local")
    let prepCancelSource = GateSource()
    prepCancelSource.prepareDelay = 0.25
    let prepCancelRec = Recorder(saveRoot: fresh("reg-prepcancel-dest"), localRoot: prepCancelLocal,
                                 makeEngine: { MockEngine(.normal) }, makeSource: { _ in prepCancelSource })
    let prepCancelTask = Task { await prepCancelRec.start(course: "准备取消") }
    _ = await waitUntil(2) { prepCancelSource.prepares == 1 }
    prepCancelRec.cancelStarting()
    let prepCancelStarted = await prepCancelTask.value
    let prepCancelLeftovers = (try? FileManager.default.contentsOfDirectory(atPath: prepCancelLocal.path)) ?? ["?"]
    await check("启动准备期间取消时清理 localRoot 空目录且 localDir 为空",
                !prepCancelStarted && prepCancelRec.phase == .idle && prepCancelRec.localDir == nil
                && prepCancelSource.starts == 0 && prepCancelLeftovers.isEmpty,
                "localDir=\(String(describing: prepCancelRec.localDir)) leftovers=\(prepCancelLeftovers)")
}

/// 保存目标在会话开始时固定:开始后再改 saveRoot 不影响本次交付。
@MainActor
func saveRootSnapshotChecks() async {
    section("修复回归:保存目标快照")
    let dest1 = fresh("reg-snapshot-dest1"), dest2 = fresh("reg-snapshot-dest2")
    let source = GateSource()
    let draftID = UUID()
    let r = Recorder(saveRoot: dest1, localRoot: fresh("reg-snapshot-local"),
                     makeEngine: { MockEngine(.normal) }, makeSource: { _ in source })
    await r.start(course: "快照", draftID: draftID, destination: dest1)
    _ = await waitUntil(2) { r.transcribe == .running }
    let info = r.localDir.flatMap { SessionStore.readInfo(dir: $0) }
    await check("启动时持久化草稿和目标", info?.draftID == draftID && info?.sessionDestination == dest1)
    r.saveRoot = dest2
    source.push(frames: 24000)
    _ = await waitUntil(2) { r.duration >= 0.9 }
    await r.stop()
    let delivered = r.deliveredDir
    await check("开始后改变 saveRoot 仍交付到开始时的目标",
              delivered != nil && ProjectLibrary.contains(dest1, delivered!) && !ProjectLibrary.contains(dest2, delivered!),
              delivered?.path ?? "无")
    await check("sessionDestination 使用快照", r.sessionDestination.standardizedFileURL == dest1.standardizedFileURL)

    // 待保存状态下禁止开始新录音,避免丢掉补救入口。
    let failing = GateSource()
    let blockedDest = fresh("reg-snapshot-blocked")
    let blocked = Recorder(saveRoot: blockedDest, localRoot: fresh("reg-snapshot-local2"),
                           makeEngine: { MockEngine(.normal) }, makeSource: { _ in failing })
    blocked.deliverFiles = { _, _, _, _, _ in throw ExportError.copyVerify("注入的交付失败") }
    await blocked.start(course: "待保存")
    _ = await waitUntil(2) { blocked.transcribe == .running }
    _ = await waitUntil(2) { blocked.duration > 0.05 }
    await blocked.stop()
    if case .pending = blocked.save {} else { await check("注入交付失败进入待保存", false) }
    if let unfinishedDir = blocked.localDir {
        let restored = Recorder(saveRoot: dest2, localRoot: fresh("reg-snapshot-recover"),
                                makeEngine: { MockEngine(.normal) }, makeSource: { _ in GateSource() })
        await restored.recover(dir: unfinishedDir)
        await check("恢复使用启动时记录的目标", restored.deliveredDir.map { ProjectLibrary.contains(blockedDest, $0) } == true)
    } else {
        await check("恢复使用启动时记录的目标", false)
    }
    let beforeStarts = failing.starts
    await blocked.start(course: "不应开始")
    await check("待保存时禁止开始新录音", blocked.courseName == "待保存" && failing.starts == beforeStarts && blocked.phase == .finished)
    blocked.deliverFiles = { base, audio, markdown, root, id in
        try Deliverer.deliver(base: base, audio: audio, markdown: markdown, to: root, id: id)
    }
    await blocked.retrySave()
    await check("重试保存使用同一快照目标并成功", blocked.deliveredDir != nil
                && ProjectLibrary.contains(blockedDest, blocked.deliveredDir!))
}

// MARK: 资料库

func libraryFixture(_ root: URL) throws -> (bundle: URL, audio: URL, doc: URL, corrected: URL) {
    let fm = FileManager.default
    let projectA = root.appendingPathComponent("项目甲", isDirectory: true)
    let bundle = projectA.appendingPathComponent("录音一", isDirectory: true)
    let projectB = root.appendingPathComponent("项目乙", isDirectory: true)
    try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
    try fm.createDirectory(at: projectB, withIntermediateDirectories: true)
    let audio = bundle.appendingPathComponent("音频.caf")
    try Data(repeating: 1, count: 64).write(to: audio)
    let doc = bundle.appendingPathComponent("原稿.md")
    try "# 课堂示例\n\n- 音频:![[音频.caf]]\n\n[00:00:01] 计算机网络的食盐。\n".write(to: doc, atomically: true, encoding: .utf8)
    let corrected = bundle.appendingPathComponent("原稿_校正版.md")
    try "> 本文件为 LLM 文字校正版。原始转写:[[原稿.md]]\n\n- 音频:![[音频.caf]]\n\n[00:00:01] 计算机网络的时延。\n".write(to: corrected, atomically: true, encoding: .utf8)
    return (bundle, audio, doc, corrected)
}

func libraryRegressionChecks() async {
    section("修复回归:资料库项目树与链接维护")
    do {
        let sampleRoot = fresh("prefix-rename")
        let project = sampleRoot.appendingPathComponent("课程")
        let child = project.appendingPathComponent("子目录")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data([1, 2]).write(to: project.appendingPathComponent("课程录音.caf"))
        try "![[课程录音.caf]]".write(to: project.appendingPathComponent("课程文稿.md"), atomically: true, encoding: .utf8)
        try "保留".write(to: child.appendingPathComponent("课程.md"), atomically: true, encoding: .utf8)
        let result = try await ProjectLibrary(root: sampleRoot).rename(project, to: "新课", syncFilePrefixes: true)
        let text = try String(contentsOf: result.appendingPathComponent("新课文稿.md"), encoding: .utf8)
        await check("同步直属文件名前缀及文稿链接，保留子目录", text == "![[新课录音.caf]]" && FileManager.default.fileExists(atPath: result.appendingPathComponent("新课录音.caf").path) && FileManager.default.fileExists(atPath: result.appendingPathComponent("子目录/课程.md").path))
    } catch { await check("同步直属文件名前缀及文稿链接，保留子目录", false, "\(error)") }
    do {
        let sampleRoot = fresh("prefix-conflict")
        let project = sampleRoot.appendingPathComponent("课程")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let original = project.appendingPathComponent("课程文稿.md")
        try "原稿".write(to: original, atomically: true, encoding: .utf8)
        try "已有文件".write(to: project.appendingPathComponent("新课文稿.md"), atomically: true, encoding: .utf8)
        do {
            _ = try await ProjectLibrary(root: sampleRoot).rename(project, to: "新课", syncFilePrefixes: true)
            await check("同步改名冲突时保留原项目", false)
        } catch {
            let text = try String(contentsOf: original, encoding: .utf8)
            await check("同步改名冲突时保留原项目", text == "原稿" && !FileManager.default.fileExists(atPath: sampleRoot.appendingPathComponent("新课").path))
        }
    } catch { await check("同步改名冲突时保留原项目", false, "\(error)") }
    let root = fresh("library-root")
    let fixture: (bundle: URL, audio: URL, doc: URL, corrected: URL)
    do { fixture = try libraryFixture(root) } catch {
        await check("建立资料库夹具", false, "\(error)")
        return
    }
    let library = ProjectLibrary(root: root)
    let outside = fresh("library-outside")

    do {
        let entries = try await library.children(of: root)
        await check("只枚举当前目录且目录在前", entries.count == 2 && entries[0].kind == .directory
                    && entries.map(\.name) == ["项目甲", "项目乙"])
        let bundleEntries = try await library.children(of: fixture.bundle)
        await check("录音文件夹可直接枚举音频与文稿", bundleEntries.map(\.kind) == [.audio, .document, .document],
                    "\(bundleEntries.map(\.name))")
        let projects = try await library.children(of: root)
        let a = projects.first { $0.name == "项目甲" }!
        let aEntries = try await library.children(of: a.url)
        await check("录音文件夹按直属音频识别", aEntries.first?.isRecordingBundle == true && aEntries.first?.name == "录音一")
    } catch { await check("枚举资料库", false, "\(error)") }

    do {
        let renamed = try await library.rename(fixture.audio, to: "新音频")
        let docText = try String(contentsOf: fixture.doc, encoding: .utf8)
        let correctedText = try String(contentsOf: fixture.corrected, encoding: .utf8)
        await check("音频改名保留扩展名并同步两份文稿链接",
                    renamed.lastPathComponent == "新音频.caf"
                    && docText.contains("![[新音频.caf]]") && !docText.contains("[[音频.caf]]")
                    && correctedText.contains("![[新音频.caf]]") && correctedText.contains("[[原稿.md]]"))
    } catch { await check("音频改名保留扩展名并同步两份文稿链接", false, "\(error)") }

    do {
        let renamed = try await library.rename(fixture.doc, to: "课堂记录")
        let correctedText = try String(contentsOf: fixture.corrected, encoding: .utf8)
        await check("文稿改名后校正版来源链接同步且正文不变",
                    renamed.lastPathComponent == "课堂记录.md"
                    && correctedText.contains("[[课堂记录.md]]") && !correctedText.contains("[[原稿.md]]")
                    && correctedText.contains("[00:00:01] 计算机网络的时延。"))
    } catch { await check("文稿改名后校正版来源链接同步且正文不变", false, "\(error)") }

    do {
        let file = root.appendingPathComponent("自引用.md")
        try "[[自引用.md]]".write(to: file, atomically: true, encoding: .utf8)
        let result = try await library.rename(file, to: "课件")
        let updated = try String(contentsOf: result, encoding: .utf8)
        await check("改名更新自引用且旧位置无副本",
                    updated == "[[课件.md]]" && !FileManager.default.fileExists(atPath: file.path))
        let unit = try await library.movePlan(for: fixture.bundle.appendingPathComponent("新音频.caf"))
        let fromDocument = try await library.movePlan(for: fixture.bundle.appendingPathComponent("课堂记录.md"))
        let independent = try await library.movePlan(for: result)
        let expectedFolder = fixture.bundle.standardizedFileURL.path
        await check("从音频或文稿移动整份独立录音，普通文稿只移动自身",
                    unit.sources.map { $0.path } == [expectedFolder]
                    && fromDocument.sources.map { $0.path } == [expectedFolder]
                    && Set(fromDocument.recordings) == Set(["新音频.caf", "课堂记录.md", fixture.corrected.lastPathComponent])
                    && independent.sources.map { $0.path } == [result.standardizedFileURL.path],
                    "音频 \(unit.recordings)，文稿 \(fromDocument.recordings)")
    } catch { await check("自引用改名与移动对象", false, error.localizedDescription) }

    do {
        let source = root.appendingPathComponent("混放项目", isDirectory: true)
        let target = root.appendingPathComponent("项目乙", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let audio = source.appendingPathComponent("旧录音]第二版.m4a")
        let doc = source.appendingPathComponent("课堂.md")
        let corrected = source.appendingPathComponent("课堂校正版.md")
        let unrelated = source.appendingPathComponent("另一个项目说明.md")
        try Data([1, 2, 3]).write(to: audio)
        let reference = "# 课堂\n![[旧录音]第二版.m4a]]\n"
        try reference.write(to: doc, atomically: true, encoding: .utf8)
        try reference.write(to: corrected, atomically: true, encoding: .utf8)
        try "保留在原处".write(to: unrelated, atomically: true, encoding: .utf8)
        await check("旧录音名称含右方括号时仍可识别",
                    ProjectLibrary.linkedAudio(in: reference, beside: doc)?.lastPathComponent == audio.lastPathComponent)
        let plan = try await library.movePlan(for: doc)
        await check("混放项目只确认移动配对音频和关联文稿",
                    Set(plan.sources.map(\.lastPathComponent)) == Set([audio.lastPathComponent, doc.lastPathComponent, corrected.lastPathComponent]))
        let collision = target.appendingPathComponent(corrected.lastPathComponent)
        try "目标已存在".write(to: collision, atomically: true, encoding: .utf8)
        do {
            _ = try await library.move(plan, into: target)
            await check("同名冲突时整组保留在原目录", false)
        } catch {
            await check("同名冲突时整组保留在原目录",
                        plan.sources.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
                        && !FileManager.default.fileExists(atPath: target.appendingPathComponent(audio.lastPathComponent).path))
        }
        let otherTarget = root.appendingPathComponent("配对移动目标", isDirectory: true)
        try FileManager.default.createDirectory(at: otherTarget, withIntermediateDirectories: false)
        _ = try await library.move(plan, into: otherTarget)
        let movedDoc = otherTarget.appendingPathComponent(doc.lastPathComponent)
        let movedAudio = otherTarget.appendingPathComponent(audio.lastPathComponent)
        await check("混放项目移动后音频和文稿同目录，其他材料留在原处",
                    ProjectLibrary.linkedAudio(in: reference, beside: movedDoc)?.lastPathComponent == audio.lastPathComponent
                    && FileManager.default.fileExists(atPath: unrelated.path)
                    && plan.sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

        let renamed = try await library.rename(movedAudio, to: "可回听的录音")
        let updated = try String(contentsOf: movedDoc, encoding: .utf8)
        await check("已有方括号文件改为普通名称后更新并读回音频引用",
                    ProjectLibrary.linkedAudio(in: updated, beside: movedDoc)?.lastPathComponent == renamed.lastPathComponent)
        do {
            _ = try await library.rename(renamed, to: "录音]第三版")
            await check("拒绝会破坏 Markdown 引用的新名称", false)
        } catch LibraryError.invalidName {
            await check("拒绝会破坏 Markdown 引用的新名称",
                        FileManager.default.fileExists(atPath: renamed.path)
                        && (try? String(contentsOf: movedDoc, encoding: .utf8)) == updated)
        }
        await check("新录音文件名清理方括号，正常课程名保持可用", Paths.sanitize("网络[实验]") == "网络-实验-")
    } catch { await check("配对移动与方括号兼容", false, error.localizedDescription) }

    do {
        _ = try await library.createProject(named: "项目丙", in: root)
        await check("新建项目创建真实文件夹", FileManager.default.fileExists(atPath: root.appendingPathComponent("项目丙").path))
    } catch { await check("新建项目创建真实文件夹", false, "\(error)") }

    for (name, reason) in [("", "空名"), ("..", "点目录"), ("a/b", "非法字符"), ("项目甲", "同名")] {
        do {
            _ = try await library.createProject(named: name, in: root)
            await check("拒绝\(reason)项目名", false)
        } catch { await check("拒绝\(reason)项目名", true) }
    }
    do {
        try "# 占位\n".write(to: fixture.bundle.deletingLastPathComponent().appendingPathComponent("占位.md"),
                             atomically: true, encoding: .utf8)
        _ = try await library.rename(fixture.bundle, to: "占位.md")
        await check("拒绝目录改成已有文件名", false)
    } catch { await check("拒绝目录改成已有文件名", true) }

    var movedBundle: URL?
    do {
        let projectB = root.appendingPathComponent("项目乙", isDirectory: true)
        movedBundle = try await library.move(fixture.bundle, into: projectB)
        let docText = try String(contentsOf: projectB.appendingPathComponent("录音一/课堂记录.md"), encoding: .utf8)
        await check("整份录音移动到项目后文件与正文完整",
                    movedBundle?.lastPathComponent == "录音一"
                    && !FileManager.default.fileExists(atPath: fixture.bundle.path)
                    && docText.contains("![[新音频.caf]]"))
    } catch { await check("整份录音移动到项目后文件与正文完整", false, "\(error)") }
    if let movedBundle {
        do {
            _ = try await library.move(movedBundle, into: root.appendingPathComponent("项目乙/录音一", isDirectory: true))
            await check("拒绝移动到自身子目录", false)
        } catch { await check("拒绝移动到自身子目录", true) }
        do {
            _ = try await library.move(outside, into: root)
            await check("拒绝根外路径", false)
        } catch { await check("拒绝根外路径", true) }
        do {
            let projectC = try await library.createProject(named: "项目丁", in: root)
            try FileManager.default.createDirectory(at: projectC.appendingPathComponent("录音一"), withIntermediateDirectories: false)
            do {
                _ = try await library.move(movedBundle, into: projectC)
                await check("拒绝同名目标", false)
            } catch { await check("拒绝同名目标", true) }
        } catch { await check("拒绝同名目标", false, "\(error)") }
        do {
            let projectB = root.appendingPathComponent("项目乙", isDirectory: true)
            await library.setProtected([movedBundle])
            do {
                _ = try await library.rename(projectB, to: "项目乙改")
                await check("活动会话的祖先禁止改名", false)
            } catch { await check("活动会话的祖先禁止改名", true) }
            await library.setProtected([])
        }
        do {
            let renamedDir = try await library.rename(movedBundle, to: "录音二")
            let docText = try String(contentsOf: renamedDir.appendingPathComponent("课堂记录.md"), encoding: .utf8)
            await check("目录改名不改正文与内部文件名", renamedDir.lastPathComponent == "录音二"
                        && docText.contains("![[新音频.caf]]") && docText.contains("[[课堂记录.md]]") == false)
        } catch { await check("目录改名不改正文与内部文件名", false, "\(error)") }
    }

    do {
        _ = try await library.rename(root, to: "根改名")
        await check("资料库根不能改名", false)
    } catch { await check("资料库根不能改名", true) }
    do {
        _ = try await library.trash(root)
        await check("资料库根不能移入废纸篓", false)
    } catch { await check("资料库根不能移入废纸篓", true) }

    do {
        let trashFixture = root.appendingPathComponent("废纸篓恢复样本.md")
        try "可恢复".write(to: trashFixture, atomically: true, encoding: .utf8)
        do {
            let trashedURL = try await library.trash(trashFixture)
            var restored = false
            if let trashedURL, FileManager.default.fileExists(atPath: trashedURL.path) {
                try FileManager.default.moveItem(at: trashedURL, to: trashFixture)
                restored = FileManager.default.fileExists(atPath: trashFixture.path)
            }
            await check("所选文件进入系统废纸篓并可恢复", !FileManager.default.fileExists(atPath: trashedURL?.path ?? "") && restored)
        } catch {
            await check("系统废纸篓不可用时报告错误且保留原文件",
                        FileManager.default.fileExists(atPath: trashFixture.path), "\(error.localizedDescription)")
        }
    } catch { await check("建立废纸篓测试样本", false, "\(error)") }

    do {
        let guarded = root.appendingPathComponent("受保护项目", isDirectory: true)
        try! FileManager.default.createDirectory(at: guarded, withIntermediateDirectories: true)
        let guardedDoc = guarded.appendingPathComponent("活动文稿.md")
        try! "活动".write(to: guardedDoc, atomically: true, encoding: .utf8)
        await library.setProtected([guardedDoc])
        do {
            _ = try await library.trash(guarded)
            await check("正在使用的文稿会保护所属录音文件夹", false)
        } catch { await check("正在使用的文稿会保护所属录音文件夹", true) }
        await library.setProtected([])
    }

    do {
        let target = outside.appendingPathComponent("外部.txt")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("外部链接")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do {
            _ = try await library.move(link, into: root.appendingPathComponent("项目乙", isDirectory: true))
            await check("拒绝符号链接目标", false)
        } catch { await check("拒绝符号链接目标", true) }
        await check("符号链接原路径未被破坏", FileManager.default.fileExists(atPath: link.path))
    } catch { await check("拒绝符号链接目标", false, "\(error)") }

    do {
        let onlyAudio = root.appendingPathComponent("仅音频", isDirectory: true)
        try FileManager.default.createDirectory(at: onlyAudio, withIntermediateDirectories: true)
        try Data(count: 8).write(to: onlyAudio.appendingPathComponent("a.wav"))
        let onlyDoc = root.appendingPathComponent("仅文稿", isDirectory: true)
        try FileManager.default.createDirectory(at: onlyDoc, withIntermediateDirectories: true)
        try "# 仅文稿\n".write(to: onlyDoc.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        let entries = try await library.children(of: root)
        let audioEntry = entries.first { $0.name == "仅音频" }
        let docEntry = entries.first { $0.name == "仅文稿" }
        let docEntries = try await library.children(of: onlyDoc)
        await check("只有音频或只有文稿的目录仍可枚举",
                    audioEntry?.isRecordingBundle == true && docEntry?.isRecordingBundle == false
                    && docEntries.map(\.kind) == [.document])
    } catch { await check("只有音频或只有文稿的目录仍可枚举", false, "\(error)") }

    // 阶段 2 A 类修复回归：混放目录含非 UTF-8 无关 .md 时，正常文件 movePlan / move 不被阻塞
    do {
        let mixedDir = root.appendingPathComponent("混放含坏编码", isDirectory: true)
        let moveDest = root.appendingPathComponent("坏编码移动目标", isDirectory: true)
        try FileManager.default.createDirectory(at: mixedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moveDest, withIntermediateDirectories: true)
        let goodAudio = mixedDir.appendingPathComponent("课堂.m4a")
        let goodDoc = mixedDir.appendingPathComponent("课堂.md")
        let badEncodingDoc = mixedDir.appendingPathComponent("损坏编码.md")
        try Data([1, 2, 3, 4]).write(to: goodAudio)
        try "# 课堂\n![[课堂.m4a]]\n".write(to: goodDoc, atomically: true, encoding: .utf8)
        try Data([0x80, 0xFF, 0xFE, 0xC0]).write(to: badEncodingDoc)

        let docPlan = try await library.movePlan(for: goodDoc)
        let audioPlan = try await library.movePlan(for: goodAudio)
        let expectedNames = Set([goodAudio.lastPathComponent, goodDoc.lastPathComponent])
        _ = try await library.move(docPlan, into: moveDest)
        await check("混放目录非 UTF-8 无关 .md 不阻塞正常文件移动",
                    Set(docPlan.sources.map(\.lastPathComponent)) == expectedNames
                    && Set(audioPlan.sources.map(\.lastPathComponent)) == expectedNames
                    && FileManager.default.fileExists(atPath: moveDest.appendingPathComponent(goodDoc.lastPathComponent).path)
                    && FileManager.default.fileExists(atPath: moveDest.appendingPathComponent(goodAudio.lastPathComponent).path)
                    && FileManager.default.fileExists(atPath: badEncodingDoc.path),
                    "docPlan=\(docPlan.sources.map(\.lastPathComponent))")
    } catch {
        await check("混放目录非 UTF-8 无关 .md 不阻塞正常文件移动", false, "\(error)")
    }
}

// MARK: 输入切换

@MainActor
func inputSwitchRegressionChecks() async {
    section("修复回归:输入设备切换")
    let a = GateSource(); a.uid = "mic-a"; a.sampleRate = 24000
    let b = GateSource(); b.uid = "mic-b"; b.sampleRate = 24000
    var created: [GateSource] = []
    let r = Recorder(saveRoot: fresh("reg-input-dest"), localRoot: fresh("reg-input-local"),
                     makeEngine: { MockEngine(.normal) }, makeSource: { uid in
        switch uid {
        case "mic-a": created.append(a); return a
        case "mic-b": created.append(b); return b
        default: let s = GateSource(); s.uid = uid; created.append(s); return s
        }
    })
    r.preferredInputUID = "mic-a"
    await r.start(course: "切换")
    await check("开始时使用偏好设备", r.activeInputUID == "mic-a")
    a.push(frames: 24000)
    _ = await waitUntil(2) { r.duration >= 0.9 }
    var switchError: Error?
    do { try await r.switchInput(to: "mic-b") } catch { switchError = error }
    await check("录音中切换输入成功且设备状态更新",
                switchError == nil && r.activeInputUID == "mic-b" && r.phase == .recording && b.starts == 1,
                "\(String(describing: switchError))")
    b.push(frames: 24000)
    _ = await waitUntil(2) { r.duration >= 1.9 }
    // 旧源的迟到中断不能影响新会话
    a.onInterruption?("旧设备迟到中断")
    try? await Task.sleep(for: .milliseconds(100))
    await check("旧源迟到中断不改变录音状态", r.phase == .recording && r.activeInputUID == "mic-b")
    let durationBeforeStop = r.duration
    await r.stop()
    await check("切换前后为同一份录音且时长连续",
                durationBeforeStop >= 2.1 && abs(durationBeforeStop - 2.2) < 0.1,
                "\(durationBeforeStop)")
    if let files = r.deliveredFiles {
        let md = (try? String(contentsOf: files.markdown, encoding: .utf8)) ?? ""
        let stamps = MarkdownDoc.parseSegments(md).map(\.time)
        await check("切换后转写时间戳不重置", stamps == stamps.sorted() && md.contains("切换期间未采集声音"))
    } else { await check("切换后转写时间戳不重置", false) }

    // 暂停中切换:不产生新采样,也不自行开始采集。
    let c = GateSource(); c.uid = "mic-c"
    let d = GateSource(); d.uid = "mic-d"
    let paused = Recorder(saveRoot: fresh("reg-input2-dest"), localRoot: fresh("reg-input2-local"),
                          makeEngine: { MockEngine(.normal) }, makeSource: { uid in uid == "mic-d" ? d : c })
    paused.preferredInputUID = "mic-c"
    await paused.start(course: "暂停切换")
    _ = await waitUntil(2) { paused.transcribe == .running }
    try? await Task.sleep(for: .milliseconds(300))
    await paused.pause()
    let beforeDuration = paused.duration
    var pausedError: Error?
    do { try await paused.switchInput(to: "mic-d") } catch { pausedError = error }
    try? await Task.sleep(for: .milliseconds(150))
    await check("暂停时切换设备不开始采集",
                pausedError == nil && paused.phase == .paused && d.starts == 0 && abs(paused.duration - beforeDuration) < 0.05)
    await paused.stop()
    await check("暂停中切换后仍可结束保存", paused.deliveredFiles != nil)

    let oldInput = GateSource(); oldInput.uid = "old-input"
    let newInput = GateSource(); newInput.uid = "new-input"
    let queued = Recorder(saveRoot: fresh("reg-input-queued-dest"), localRoot: fresh("reg-input-queued-local"),
                          makeEngine: { MockEngine(.normal) }, makeSource: { uid in uid == "new-input" ? newInput : oldInput })
    await queued.start(course: "继续时更换设备")
    await queued.inputDeviceDisconnected("old-input")
    await check("输入断开出现暂停提示", queued.phase == .paused && queued.inputIssue != nil)
    oldInput.startDelay = 0.2
    let resume = Task { await queued.resume() }
    try? await Task.sleep(for: .milliseconds(30))
    do { try await queued.switchInput(to: "new-input") }
    catch { await check("继续录音时排队换麦", false, error.localizedDescription) }
    await resume.value
    await check("慢速继续后接续换麦，新音源开始采集",
                queued.phase == .recording && queued.activeInputUID == "new-input" && newInput.starts == 1)
    await check("换麦恢复后清除设备断开提示", queued.inputIssue == nil)
    await queued.stop()

    // 新设备启动失败:恢复旧源并继续录音。
    let e = GateSource(); e.uid = "mic-e"
    let f = GateSource(); f.uid = "mic-f"; f.failStart = true
    let recover = Recorder(saveRoot: fresh("reg-input3-dest"), localRoot: fresh("reg-input3-local"),
                           makeEngine: { MockEngine(.normal) }, makeSource: { uid in uid == "mic-f" ? f : e })
    recover.preferredInputUID = "mic-e"
    await recover.start(course: "切换失败")
    e.push(frames: 24000)
    _ = await waitUntil(2) { recover.duration >= 0.9 }
    let startsBefore = e.starts
    do { try await recover.switchInput(to: "mic-f"); await check("切换失败时报错", false) }
    catch { await check("切换失败时报错", true) }
    await check("切换失败恢复旧源并继续录音",
                recover.phase == .recording && recover.activeInputUID == "mic-e" && e.starts > startsBefore)
    e.push(frames: 24000)
    _ = await waitUntil(2) { recover.duration >= 1.9 }
    await recover.stop()
    await check("切换失败后已录部分仍能保存", recover.deliveredFiles != nil)

    // 继续失败:保持暂停,仍可结束保存。
    let g = GateSource(); g.uid = "mic-g"
    let stuck = Recorder(saveRoot: fresh("reg-input4-dest"), localRoot: fresh("reg-input4-local"),
                         makeEngine: { MockEngine(.normal) }, makeSource: { _ in g })
    stuck.preferredInputUID = "mic-g"
    await stuck.start(course: "无法恢复")
    g.push(frames: 24000)
    _ = await waitUntil(2) { stuck.duration >= 0.9 }
    await stuck.pause()
    g.failStart = true
    await stuck.resume()
    await check("继续失败保持暂停并保留补救入口", stuck.phase == .paused && stuck.inputIssue != nil)
    await stuck.stop()
    await check("无法恢复时仍可结束保存", stuck.deliveredFiles != nil)

    // 新设备与原设备都无法启动:保持暂停,已录部分仍可结束保存。
    let h = GateSource(); h.uid = "mic-h"
    let i = GateSource(); i.uid = "mic-i"; i.failStart = true
    let bothFail = Recorder(saveRoot: fresh("reg-input6-dest"), localRoot: fresh("reg-input6-local"),
                            makeEngine: { MockEngine(.normal) }, makeSource: { uid in uid == "mic-i" ? i : h })
    bothFail.preferredInputUID = "mic-h"
    await bothFail.start(course: "双失败")
    h.push(frames: 24000)
    _ = await waitUntil(2) { bothFail.duration >= 0.9 }
    h.failStart = true
    do { try await bothFail.switchInput(to: "mic-i"); await check("原设备与新设备都失败时报错", false) }
    catch { await check("原设备与新设备都失败时报错", true) }
    await check("原设备与新设备都失败时保持暂停", bothFail.phase == .paused && bothFail.inputIssue != nil)
    await bothFail.stop()
    await check("双设备失败后仍可结束并保存已录部分", bothFail.deliveredFiles != nil)

    // 启动中取消:迟到的启动结果不能采集或污染新会话。
    let slow = GateSource(); slow.startDelay = 0.3
    let cancelRec = Recorder(saveRoot: fresh("reg-input5-dest"), localRoot: fresh("reg-input5-local"),
                             makeEngine: { MockEngine(.normal) }, makeSource: { _ in slow })
    let starting = Task { await cancelRec.start(course: "取消") }
    try? await Task.sleep(for: .milliseconds(180))
    cancelRec.cancelStarting()
    _ = await starting.value
    try? await Task.sleep(for: .milliseconds(400))
    await check("取消启动后迟到返回不进入录音", cancelRec.phase == .idle && cancelRec.deliveredFiles == nil)
}

final class HangingCleanupEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "HangingCleanup"; let languageTag = "zh-CN"
    var callbacks: EngineCallbacks?
    var preparing = false
    func modelState() async -> ModelState {
        if preparing { return await withUnsafeContinuation { (_: UnsafeContinuation<ModelState, Never>) in } }
        return .ready
    }
    func installModel(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func start(callbacks: EngineCallbacks) async throws { self.callbacks = callbacks }
    func feed(_ buffer: AVAudioPCMBuffer, start: Double) {}
    func finish() async -> Bool { await withUnsafeContinuation { (_: UnsafeContinuation<Bool, Never>) in } }
    func cancel() async { await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in } }
}

final class BoundaryFailureEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "BoundaryFailure"; let languageTag = "zh-CN"
    var callbacks: EngineCallbacks?
    var fired = false
    let boundary: Double
    init(_ boundary: Double) { self.boundary = boundary }
    func modelState() async -> ModelState { .ready }
    func installModel(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func start(callbacks: EngineCallbacks) async throws { self.callbacks = callbacks }
    func feed(_ buffer: AVAudioPCMBuffer, start: Double) {
        guard !fired, start + Double(buffer.frameLength) / buffer.format.sampleRate > boundary, let cb = callbacks else { return }
        fired = true
        Task { @MainActor in
            cb.final(0, boundary, "第一句")
            cb.failure(NSError(domain: "boundary", code: 1))
        }
    }
    func finish() async -> Bool { false }
    func cancel() async {}
}

@MainActor
func finishAndReplayRegressionChecks() async {
    section("修复回归:取消挂起、迟到回调与补喂边界")
    for preparing in [false, true] {
        let e = HangingCleanupEngine(); e.preparing = preparing
        let source = GateSource()
        var count = 0
        let r = Recorder(saveRoot: fresh("reg-hanging-\(preparing)-dest"), localRoot: fresh("reg-hanging-\(preparing)-local"),
                         makeEngine: { count += 1; return count == 1 ? e : MockEngine(.normal) }, makeSource: { _ in source })
        r.finishTimeout = 0.15
        await r.start(course: "取消挂起")
        if !preparing { _ = await waitUntil(2) { r.transcribe == .running } }
        let ended = Task { await r.stop() }
        let finished = await waitUntil(3) { r.phase == .finished }
        await check(preparing ? "识别准备与取消挂起仍能保存" : "结束与取消均挂起仍能保存", finished && r.deliveredFiles != nil)
        if finished {
            await ended.value
            let before = r.segments
            e.callbacks?.final(0, 99, "迟到的旧结果")
            await check("收尾后迟到回调不能改动结果", r.segments == before)
            await r.start(course: "新会话")
            e.callbacks?.final(0, 99, "旧会话结果")
            await check("迟到回调不能污染新会话", !r.segments.contains { $0.text.contains("旧") })
            await r.stop()
        }
    }
    for boundary in [1.0, 1.00013] {
        let first = BoundaryFailureEngine(boundary), next = MockEngine(.normal), source = GateSource()
        var index = 0
        let r = Recorder(saveRoot: fresh("reg-boundary-\(boundary)-dest"), localRoot: fresh("reg-boundary-\(boundary)-local"),
                         makeEngine: { index += 1; return index == 1 ? first : next }, makeSource: { _ in source })
        r.retryDelay = 0.02
        await r.start(course: "边界")
        _ = await waitUntil(2) { r.transcribe == .running }
        source.push(frames: 48000)
        _ = await waitUntil(3) { next.firstStart != nil }
        let start = next.firstStart ?? -1
        await check("补喂首块裁剪到确认边界且误差不到一帧", start >= boundary - 1e-8 && start - boundary < 1.0 / 24000)
        await r.stop()
        let events = SessionStore.loadEvents(dir: r.localDir!).events.filter { $0.kind == .text }
        await check("恢复后的确认事件时间不重叠", zip(events, events.dropFirst()).allSatisfy { $1.start >= $0.end - 0.0001 })
    }
}

final class QuietEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "Quiet"; let languageTag = "zh-CN"
    func modelState() async -> ModelState { .ready }
    func installModel(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func start(callbacks: EngineCallbacks) async throws {}
    func feed(_ buffer: AVAudioPCMBuffer, start: Double) {}
    func finish() async -> Bool { true }
    func cancel() async {}
}

final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { add(1) }
    func add(_ amount: Int) { lock.withLock { value += amount } }
}

final class IntLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int] = []
    var values: [Int] { lock.withLock { items } }
    func append(_ value: Int) { lock.withLock { items.append(value) } }
}
