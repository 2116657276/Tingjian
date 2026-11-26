import AVFoundation
import Foundation
import TingjianCore

// 验证工具:合成音频 + 故障注入 + 真实识别。不打开麦克风。

let skipCorrection = CommandLine.arguments.contains("--skip-correction")
let runStartedAt = ContinuousClock.now

if CommandLine.arguments.contains("--trash-smoke") {
    do {
        let root = tmp.appendingPathComponent("trash-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sample = root.appendingPathComponent("可恢复样本.md")
        try "临时验证".write(to: sample, atomically: true, encoding: .utf8)
        let library = ProjectLibrary(root: root)
        guard let trashed = try await library.trash(sample),
              !FileManager.default.fileExists(atPath: sample.path),
              FileManager.default.fileExists(atPath: trashed.path) else {
            throw LibraryError.operationFailed("没有返回可恢复的系统废纸篓路径")
        }
        try FileManager.default.moveItem(at: trashed, to: sample)
        guard FileManager.default.fileExists(atPath: sample.path) else {
            throw LibraryError.operationFailed("废纸篓恢复后样本未返回原路径")
        }
        print("TRASH_SMOKE_PASSED")
        exit(0)
    } catch {
        fputs("TRASH_SMOKE_FAILED: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--recording-target-only") {
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    await saveRootSnapshotChecks()
    finishAndExit(startedAt: runStartedAt)
}

if CommandLine.arguments.contains("--placement-only") {
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    await recordingPlacementChecks()
    finishAndExit(startedAt: runStartedAt)
}

if CommandLine.arguments.contains("--correction-only") {
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    await continuousCorrectionChecks()
    finishAndExit(startedAt: runStartedAt)
}

if CommandLine.arguments.contains("--workspace-state-only") {
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    await workspaceStateRegressionChecks()
    finishAndExit(startedAt: runStartedAt)
}

if CommandLine.arguments.contains("--weak-voice-bench") || CommandLine.arguments.contains("--weak-voice-holdout") {
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    await runWeakVoiceBenchmark(holdout: CommandLine.arguments.contains("--weak-voice-holdout"))
    finishAndExit(startedAt: runStartedAt)
}

if CommandLine.arguments.contains("--audio-regressions-only") {
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    await reviewRegressionChecks(includeRecognition: false)
    finishAndExit(startedAt: runStartedAt)
}

if CommandLine.arguments.contains("--long-only") {
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    await longRecordingCheck()
    finishAndExit(startedAt: runStartedAt)
}

@MainActor
func longRecordingCheck() async {
    section("30 分钟合成音频(模拟引擎):落盘、时长、内存")
    let long = tmp.appendingPathComponent("long.caf")
    makeTone(long, seconds: 1800)
    let local = fresh("long-local"), dest = fresh("long-dest")
    let r = Recorder(saveRoot: dest, localRoot: local, makeEngine: { MockEngine(.normal) },
                     makeSource: { _ in FileSource(url: long, speed: 0) })
    func rss() -> Double {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
    let started = ContinuousClock.now
    let m0 = rss()
    await r.start(course: "30分钟")
    var peak = m0
    while r.phase == .recording { peak = max(peak, rss()); try? await Task.sleep(for: .milliseconds(200)) }
    _ = await waitUntil(120) { r.phase == .finished }
    let dir = r.deliveredDir
    let sessionDir = (try? FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil))?.first
    let caf = sessionDir.map { audioSeconds($0.appendingPathComponent("audio.caf")) } ?? -1
    print("  墙钟 \(started.duration(to: .now))；音频 \(Int(caf)) 秒;内存起始 \(Int(m0)) MB,峰值 \(Int(peak)) MB")
    await check("落盘时长≈30 分钟", abs(caf - 1800) < 2, "\(caf)")
    let m4a = dir.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil).first { $0.pathExtension == "m4a" } }
    let m4aSecs = m4a == nil ? -1 : ((try? await AVURLAsset(url: m4a!).load(.duration).seconds) ?? -1)
    await check("M4A 时长与落盘偏差 <1 秒", abs(m4aSecs - caf) < 1, "\(m4aSecs)")
    await check("内存峰值增量 <400 MB(不随时长无限增长)", peak - m0 < 400, "\(peak - m0)")
}

// MARK: 模拟引擎

final class MockEngine: TranscriptionEngine, @unchecked Sendable {
    enum Mode { case normal, failAfter(Int), hangFinish, neverReady }
    let name = "Mock"; let languageTag = "zh-CN"
    var mode: Mode
    private let lock = NSLock()
    private var cb: EngineCallbacks?
    private(set) var fedStarts: [Double] = []
    private(set) var fedSeconds = 0.0
    private var nextEmit = 1.0
    private var lastEmitEnd = 0.0
    private var base = 0.0
    private var count = 0
    private var dead = false
    init(_ m: Mode) { mode = m }
    var firstStart: Double? { lock.withLock { fedStarts.first } }
    var model: ModelState = .ready
    var failInstall = false
    var modelQueryDelay: Duration?
    func modelState() async -> ModelState {
        let snapshot = model
        if let modelQueryDelay { try? await Task.sleep(for: modelQueryDelay) }
        return snapshot
    }
    func installModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        if failInstall { throw EngineError.modelMissing }
        progress(0.5)
        model = .ready
    }
    func start(callbacks: EngineCallbacks) async throws { lock.withLock { cb = callbacks } }
    func feed(_ buffer: AVAudioPCMBuffer, start: Double) {
        lock.lock()
        if dead { lock.unlock(); return }
        if fedStarts.isEmpty { base = start; lastEmitEnd = start; nextEmit = start + 1 }
        fedStarts.append(start); count += 1
        let end = start + Double(buffer.frameLength) / buffer.format.sampleRate
        fedSeconds = end
        let cb = self.cb
        var emit: (Double, Double)?
        var fail = false
        if case .failAfter(let n) = mode, count > n { dead = true; fail = true }
        if !fail, end >= nextEmit { emit = (lastEmitEnd, end); lastEmitEnd = end; nextEmit = end + 1 }
        lock.unlock()
        if let cb {
            if fail { Task { @MainActor in cb.failure(NSError(domain: "mock", code: 1, userInfo: [NSLocalizedDescriptionKey: "注入的识别故障"])) } }
            if let (s, e) = emit {
                Task { @MainActor in cb.final(s, e, "句@\(Int(s))") }
            }
        }
    }
    func finish() async -> Bool {
        if case .hangFinish = mode { try? await Task.sleep(for: .seconds(3600)); return true }
        let (cb, s, e, d) = lock.withLock { (self.cb, lastEmitEnd, fedSeconds, dead) }
        if let cb, e > s + 0.01, !d { await cb.final(s, e, "尾@\(Int(s))") }
        return !d
    }
    func cancel() async { lock.withLock { dead = true } }
}

@MainActor
func makeRecorder(_ name: String, tone: URL, speed: Double = 1, engines: [() -> TranscriptionEngine]) -> (Recorder, URL, URL) {
    let local = fresh(name + "-local"), dest = fresh(name + "-dest")
    var idx = 0
    let r = Recorder(saveRoot: dest, localRoot: local,
                     makeEngine: { let e = engines[min(idx, engines.count - 1)](); idx += 1; return e },
                     makeSource: { _ in FileSource(url: tone, speed: speed) })
    r.finishTimeout = 1.5; r.retryDelay = 0.2
    return (r, local, dest)
}

// MARK: 子进程:录音中被强杀

if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--hang" {
    let local = URL(fileURLWithPath: CommandLine.arguments[2])
    let tone = URL(fileURLWithPath: CommandLine.arguments[3])
    let r = await MainActor.run {
        let r = Recorder(saveRoot: local.appendingPathComponent("never"), localRoot: local,
                         makeEngine: { MockEngine(.normal) }, makeSource: { _ in FileSource(url: tone, speed: 1) })
        return r
    }
    await r.start(course: "强杀测试")
    while r.duration < 4 { try? await Task.sleep(for: .milliseconds(100)) }
    print("READY"); fflush(stdout)
    try? await Task.sleep(for: .seconds(600))
    exit(0)
}

try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let tone = tmp.appendingPathComponent("tone.caf")
makeTone(tone, seconds: 12)

// MARK: 1 拼装器
section("转写拼装器")
do {
    var a = TranscriptAssembler()
    a.setVolatile("你好", start: 0)
    a.setVolatile("你好世界", start: 0)
    await check("临时结果被替换而不是追加", a.volatileText == "你好世界" && a.segments.isEmpty)
    a.commit(start: 0, end: 2, text: "你好世界。")
    await check("最终结果清除对应临时文字", a.volatileText.isEmpty && a.segments.count == 1)
    let dup = a.commit(start: 0, end: 2, text: "你好世界。")
    await check("重复的最终结果不再追加", dup == nil && a.segments.count == 1)
    a.commit(start: 3, end: 5, text: "今天讲网络。")
    await check("间隔 ≤2 秒合并为同一段", a.segments.count == 1 && a.segments[0].text == "你好世界。今天讲网络。" && a.segments[0].end == 5)
    a.commit(start: 9, end: 10, text: "新的一段。")
    await check("间隔 >2 秒另起一段", a.segments.count == 2 && a.segments[1].start == 9)
    a.markGap(start: 10, end: 14)
    await check("不完整区间单独成段", a.segments.count == 3 && a.segments[2].incomplete)
    a.commit(start: 14, end: 15, text: "之后。")
    await check("不完整区间之后另起一段", a.segments.count == 4 && !a.segments[3].incomplete)
    var b = TranscriptAssembler()
    for i in 0..<30 { b.commit(start: Double(i * 2), end: Double(i * 2 + 2), text: String(repeating: "字", count: 10)) }
    await check("段落长度不超过上限", b.segments.allSatisfy { $0.text.count <= 120 } && b.segments.count >= 3)
    await check("事件回放得到相同段落", TranscriptAssembler(events: a.events).segments == a.segments)
    await check("时间戳格式", Timecode.string(3725.9) == "01:02:05" && Timecode.string(0) == "00:00:00")
    var c = TranscriptAssembler(); c.commit(start: 0, end: 1, text: "使用"); c.commit(start: 1, end: 2, text: "Swift"); c.commit(start: 2, end: 3, text: "UI")
    await check("英文词之间补空格", c.segments[0].text == "使用Swift UI", c.segments[0].text)
}

// MARK: 2 Markdown 与保存
section("Markdown 与目录保存")
do {
    var a = TranscriptAssembler()
    a.commit(start: 0, end: 2, text: "第一句。"); a.markGap(start: 20, end: 30); a.commit(start: 65, end: 70, text: "第二句。")
    let doc = MarkdownDoc(title: "测试课", date: Date(), duration: 125, audioName: "x.m4a", engine: "E", language: "zh-CN",
                          status: .partial, notes: ["说明一"], segments: a.segments)
    let md = doc.render()
    await check("含时长/音频链接/引擎/状态", md.contains("00:02:05") && md.contains("![[x.m4a]]") && md.contains("zh-CN") && md.contains("部分完成"))
    await check("含时间戳正文与不完整标注", md.contains("[00:00:00] 第一句。") && md.contains("[00:01:05] 第二句。") && md.contains("转写不完整"))
    await check("解析只返回正文行", MarkdownDoc.parseSegments(md).count == 2)

    let dest = fresh("deliver")
    let src = fresh("src")
    let m = src.appendingPathComponent("a.md"); try! md.write(to: m, atomically: true, encoding: .utf8)
    let au = src.appendingPathComponent("a.m4a"); try! Data(count: 1000).write(to: au)
    let r1 = try! Deliverer.deliver(base: "2026-01-01_10-00-00_课", audio: au, markdown: m, to: dest)
    let r2 = try! Deliverer.deliver(base: "2026-01-01_10-00-00_课", audio: au, markdown: m, to: dest)
    await check("同名目录追加序号不覆盖", r1.directory != r2.directory && r2.directory.lastPathComponent.hasSuffix("_2"))
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: r1.directory.path).filter { $0.hasSuffix(".partial") }) ?? ["?"]
    await check("无遗留临时文件", leftovers.isEmpty)
    await check("课程名清理非法字符", Paths.sanitize("a/b:c") == "a-b-c" && Paths.baseName(date: Date(), course: "").count == 19)
    let transactionalRoot = fresh("delivery-transaction")
    let id = UUID()
    let missing = src.appendingPathComponent("missing.md")
    do {
        _ = try Deliverer.deliver(base: "lesson", audio: au, markdown: missing, to: transactionalRoot, id: id)
        await check("文稿复制失败被报告", false)
    } catch {
        let visible = try! FileManager.default.contentsOfDirectory(at: transactionalRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        await check("文稿复制失败无半份可见录音", visible.isEmpty)
    }
    let first = try! Deliverer.deliver(base: "lesson", audio: au, markdown: m, to: transactionalRoot, id: id)
    let retry = try! Deliverer.deliver(base: "lesson", audio: au, markdown: m, to: transactionalRoot, id: id)
    let published = try! FileManager.default.contentsOfDirectory(at: transactionalRoot, includingPropertiesForKeys: nil,
                                                                 options: .skipsHiddenFiles)
    await check("发布后重复同一交付只返回原目录",
                first.directory.resolvingSymlinksInPath() == retry.directory.resolvingSymlinksInPath()
                && published.count == 1)

}

// MARK: 3 LLM
if !skipCorrection {
section("LLM 纠正(模拟服务)")
do {
    let sess = MockLLMFixture.session()
    let segs = (1...6).map { (time: "00:00:0\($0)", text: "原文\($0)") }
    let one = [(time: "00:00:01", text: "计算机网络的食盐")]

    func reply(_ items: [[String: Any]]) -> Data { MockLLMFixture.itemsReply(items) }
    func response(_ content: Any, finish: String? = nil, refusal: String? = nil,
                  usage: [String: Any]? = nil) -> Data {
        MockLLMFixture.chatResponse(content, finish: finish, refusal: refusal, usage: usage)
    }
    func items(_ body: Data) -> [[String: Any]] { MockLLMFixture.requestItems(body) }
    func envelope(_ text: String) -> String { MockLLMFixture.singleItemEnvelope(text) }
    var lastAuth: String?, lastURL: String?
    var sawAdjacentContext = false
    func upper(_ req: URLRequest, _ body: Data) -> (Int, Data) {
        lastAuth = req.value(forHTTPHeaderField: "Authorization"); lastURL = req.url?.absoluteString
        let messages = (try! JSONSerialization.jsonObject(with: body) as! [String: Any])["messages"] as! [[String: String]]
        if messages[0]["content"]?.contains("全文语境分析员") == true {
            return (200, response("全文主题：计算机网络课堂，术语和概念以转写上下文为准。"))
        }
        let envelope = try! JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: Any]
        sawAdjacentContext = sawAdjacentContext
            || ((envelope["context_before"] as? [[String: Any]])?.isEmpty == false)
            || ((envelope["context_after"] as? [[String: Any]])?.isEmpty == false)
        return (200, reply(items(body).map { ["id": $0["id"]!, "text": "校正:" + ($0["text"] as! String)] }))
    }

    let cfgL = LLMConfig(baseURL: "http://127.0.0.1:9/v1/", model: "m", apiKey: "sk-secret")
    MockURLProtocol.handler = upper
    let out = try? await TextCorrector(config: cfgL, session: sess).correct(segs)
    await check("成功返回逐段校正", out?.count == 6 && out?[0] == "校正:原文1")
    await check("端点与鉴权头", lastURL == "http://127.0.0.1:9/v1/chat/completions" && lastAuth == "Bearer sk-secret", "\(lastURL ?? "")")

    MockURLProtocol.requests = 0
    let out2 = try? await TextCorrector(config: cfgL, session: sess, maxChunkChars: 8).correct(segs)
    await check("全文主题分析后按段落边界分块", MockURLProtocol.requests == 4 && out2?.count == 6, "requests=\(MockURLProtocol.requests)")
    await check("分块请求携带只读相邻段落", sawAdjacentContext)
    MockURLProtocol.requests = 0
    MockURLProtocol.handler = { _, _ in (200, response(String(repeating: "术", count: 6_100))) }
    do {
        _ = try await TextCorrector(config: cfgL, session: sess, maxChunkItems: 2).correct(segs)
        await check("过长语境无法压缩时停止", false)
    } catch {
        await check("过长语境无法压缩时停止", MockURLProtocol.requests == 2)
    }
    MockURLProtocol.requests = 0
    MockURLProtocol.handler = upper
    let out3 = try? await TextCorrector(config: cfgL, session: sess, maxChunkItems: 2).correct(segs)
    await check("按条数分块并先分析全文", MockURLProtocol.requests == 4 && out3?.count == 6, "requests=\(MockURLProtocol.requests)")

    let cacheDirectory = fresh("llm-cache")
    let cachedCorrector = TextCorrector(config: cfgL, session: sess, maxChunkChars: 8, cacheDirectory: cacheDirectory)
    MockURLProtocol.requests = 0
    MockURLProtocol.handler = upper
    _ = try? await cachedCorrector.correct(segs)
    let cacheHits = TestCounter()
    MockURLProtocol.requests = 0
    _ = try? await cachedCorrector.correct(segs, usage: { if $0.localCacheHits > 0 { cacheHits.increment() } })
    await check("相同全文重试复用语境与已校正分块", MockURLProtocol.requests == 0 && cacheHits.count == 4,
                "requests=\(MockURLProtocol.requests),hits=\(cacheHits.count)")
    var changedConfig = cfgL
    changedConfig.model = "m-changed"
    MockURLProtocol.requests = 0
    _ = try? await TextCorrector(config: changedConfig, session: sess, maxChunkChars: 8,
                                 cacheDirectory: cacheDirectory).correct(segs)
    await check("模型变化后本地缓存失效", MockURLProtocol.requests == 4, "requests=\(MockURLProtocol.requests)")

    let usageInput = TestCounter(), usageOutput = TestCounter(), usageCached = TestCounter()
    MockURLProtocol.handler = { _, _ in
        (200, response(envelope("校正"), usage: ["prompt_tokens": 42, "completion_tokens": 8,
                                                   "prompt_tokens_details": ["cached_tokens": 16]]))
    }
    _ = try? await TextCorrector(config: cfgL, session: sess).correct(one, usage: { value in
        if let count = value.inputTokens { usageInput.add(count) }
        if let count = value.outputTokens { usageOutput.add(count) }
        if let count = value.cachedInputTokens { usageCached.add(count) }
    })
    await check("报告网关提供的 token 与缓存用量",
                usageInput.count == 42 && usageOutput.count == 8 && usageCached.count == 16)

    let progressLog = IntLog()
    MockURLProtocol.handler = upper
    _ = try? await TextCorrector(config: cfgL, session: sess, maxChunkChars: 8).correct(segs) { done, _ in
        progressLog.append(done)
    }
    await check("进度按已完成原文段数发布", progressLog.values == [2, 4, 6], "\(progressLog.values)")

    // 结构不匹配:数量、缺失 id、重复 id、乱序 id。
    MockURLProtocol.handler = { _, body in
        (200, reply(items(body).dropLast().map { ["id": $0["id"]!, "text": $0["text"]!] }))
    }
    do { _ = try await TextCorrector(config: cfgL, session: sess).correct(segs); await check("段落数不一致被拒绝", false) }
    catch { await check("段落数不一致被拒绝", error is CorrectionError, "\(error)") }

    MockURLProtocol.handler = { _, body in
        var out = items(body).map { ["id": $0["id"]!, "text": $0["text"]!] }
        out[5] = ["text": out[5]["text"]!]
        return (200, reply(out))
    }
    do { _ = try await TextCorrector(config: cfgL, session: sess).correct(segs); await check("缺失 id 被拒绝", false) }
    catch { await check("缺失 id 被拒绝", error is CorrectionError, "\(error)") }

    MockURLProtocol.handler = { _, body in
        let source = items(body)
        let out = source.enumerated().map { index, item -> [String: Any] in
            ["id": index == 5 ? 5 : item["id"]!, "text": item["text"]!]
        }
        return (200, reply(out))
    }
    do { _ = try await TextCorrector(config: cfgL, session: sess).correct(segs); await check("重复 id 被拒绝", false) }
    catch { await check("重复 id 被拒绝", error is CorrectionError, "\(error)") }

    MockURLProtocol.handler = { _, body in
        let source = items(body)
        var out = source.map { ["id": $0["id"]!, "text": $0["text"]!] }
        out[4]["id"] = 6; out[5]["id"] = 5
        return (200, reply(out))
    }
    do { _ = try await TextCorrector(config: cfgL, session: sess).correct(segs); await check("乱序 id 被拒绝", false) }
    catch { await check("乱序 id 被拒绝", error is CorrectionError, "\(error)") }

    // 内容包装:单行/多行围栏、前后说明、片段数组、引号括号反斜杠、尾空格。
    let cases: [(String, Any)] = [
        ("单行围栏", "```json " + envelope("时延") + " ```"),
        ("多行围栏", "```json\n" + envelope("时延") + "\n```"),
        ("前后说明", "以下是校对结果：\n" + envelope("时延") + "\n以上是全部段落。"),
    ]
    for (label, content) in cases {
        MockURLProtocol.handler = { _, _ in (200, response(content)) }
        let got = try? await TextCorrector(config: cfgL, session: sess).correct(one)
        await check("解析\(label)", got == ["时延"], "\(String(describing: got))")
    }
    do {
        let half = envelope("时延")
        let cut = half.index(half.startIndex, offsetBy: half.count / 2)
        let parts: [[String: Any]] = [["type": "text", "text": String(half[..<cut])],
                                      ["type": "text", "text": String(half[cut...])]]
        MockURLProtocol.handler = { _, _ in (200, response(parts)) }
        let got = try? await TextCorrector(config: cfgL, session: sess).correct(one)
        await check("解析内容片段数组", got == ["时延"], "\(String(describing: got))")
    }
    do {
        let tricky = "他说：“时延”(a{b}) \\\\ 路径"
        MockURLProtocol.handler = { _, _ in (200, response(envelope(tricky))) }
        let got = try? await TextCorrector(config: cfgL, session: sess).correct(one)
        await check("引号括号反斜杠原样保留", got == [tricky], "\(String(describing: got))")
    }
    MockURLProtocol.handler = { _, _ in (200, response(envelope("  时延  "))) }
    let trimmed = try? await TextCorrector(config: cfgL, session: sess).correct(one)
    await check("尾空格被规范化", trimmed == ["时延"], "\(String(describing: trimmed))")

    MockURLProtocol.handler = { _, _ in (200, response("好的，这里是结果。")) }
    do { _ = try await TextCorrector(config: cfgL, session: sess).correct(one); await check("非 JSON 被拒绝", false) }
    catch { await check("非 JSON 被拒绝", error is CorrectionError, "\(error)") }

    MockURLProtocol.handler = { _, _ in (200, response(envelope("一") + envelope("二"))) }
    do { _ = try await TextCorrector(config: cfgL, session: sess).correct(one); await check("多个 JSON 对象被拒绝", false) }
    catch { await check("多个 JSON 对象被拒绝", error is CorrectionError, "\(error)") }

    MockURLProtocol.handler = { _, _ in (200, response(envelope("   "))) }
    let blankOutput = try? await TextCorrector(config: cfgL, session: sess).correct(one)
    await check("纯语气词段允许清空", blankOutput == [""])

    MockURLProtocol.handler = { _, _ in (200, response(envelope("第一行\n第二行"))) }
    do { _ = try await TextCorrector(config: cfgL, session: sess).correct(one); await check("换行文本被拒绝", false) }
    catch { await check("换行文本被拒绝", error is CorrectionError, "\(error)") }

    MockURLProtocol.handler = { _, _ in (200, response(envelope("时延"), refusal: "无法处理这段内容")) }
    do { _ = try await TextCorrector(config: cfgL, session: sess).correct(one); await check("模型拒绝如实报告", false) }
    catch {
        if case CorrectionError.refused = error { await check("模型拒绝如实报告", true) }
        else { await check("模型拒绝如实报告", false, "\(error)") }
    }

    MockURLProtocol.handler = { _, _ in (500, Data("boom".utf8)) }
    do { _ = try await TextCorrector(config: cfgL, session: sess).correct(segs); await check("HTTP 错误如实报告", false) }
    catch { await check("HTTP 错误如实报告", "\(error)".contains("500") || (error as? CorrectionError).map { "\($0)".contains("http") } == true, "\(error)") }

    // 分块时第二块失败 → 整体失败,不返回半成品
    var n = 0
    MockURLProtocol.handler = { r, b in n += 1; return n == 2 ? (500, Data()) : upper(r, b) }
    do { _ = try await TextCorrector(config: cfgL, session: sess, maxChunkChars: 8).correct(segs); await check("部分成功不产出结果", false) }
    catch { await check("部分成功不产出结果", true) }

    // 明确 length 截断:多段对半拆分后保留完整顺序。
    var lengthCalls = 0
    MockURLProtocol.handler = { _, body in
        lengthCalls += 1
        if lengthCalls == 1 { return (200, response("{\"items\":[{\"id\":1,", finish: "length")) }
        return (200, reply(items(body).map { ["id": $0["id"]!, "text": "校正:" + ($0["text"] as! String)] }))
    }
    let split = try? await TextCorrector(config: cfgL, session: sess).correct(segs)
    await check("多段截断对半拆分后保留完整顺序",
                split == (1...6).map { "校正:原文\($0)" } && lengthCalls == 3,
                "\(String(describing: split)) calls=\(lengthCalls)")

    MockURLProtocol.handler = { _, _ in
        (200, response("{\"items\":[{\"id\":1,", finish: "length"))
    }
    do { _ = try await TextCorrector(config: cfgL, session: sess).correct(one); await check("单段截断明确报截断", false) }
    catch {
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        await check("单段截断明确报截断", message.contains("截断"), message)
    }

    // 取消
    MockURLProtocol.handler = upper
    let t = Task { try await TextCorrector(config: cfgL, session: sess).correct(segs) }
    t.cancel()
    do { _ = try await t.value; await check("取消被报告", false) } catch { await check("取消被报告", true) }
    let lateCancel = Task {
        try await TextCorrector(config: cfgL, session: sess).correct(segs) { i, total in
            if i == total { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    do { _ = try await lateCancel.value; await check("响应成功后临近写出取消仍失败", false) }
    catch { await check("响应成功后临近写出取消仍失败", true) }

    // 配置错误
    do { _ = try await TextCorrector(config: cfgL, session: sess, maxChunkChars: 0).correct(segs); await check("非正分块限制报配置错误", false) }
    catch {
        if case CorrectionError.invalidConfiguration = error { await check("非正分块限制报配置错误", true) }
        else { await check("非正分块限制报配置错误", false, "\(error)") }
    }

    // 校正版 Markdown
    var a = TranscriptAssembler(); a.commit(start: 0, end: 1, text: "你好"); a.commit(start: 10, end: 11, text: "再见")
    let original = MarkdownDoc(title: "T", date: Date(), duration: 11, audioName: "x.m4a", engine: "E", language: "zh-CN", status: .completed, notes: [], segments: a.segments).render()
    let fixed = try TextCorrector.buildCorrectedMarkdown(original: original, corrected: ["你好。", "再见。"], originalName: "x.md", model: "m")
    await check("校正版保留时间戳并替换文字", fixed.contains("[00:00:00] 你好。") && fixed.contains("[00:00:10] 再见。") && fixed.contains("[[x.md]]"))
    await check("文本中不含密钥", !fixed.contains("sk-secret"))
    // 未配置
    do { _ = try await TextCorrector(config: LLMConfig(baseURL: "", model: "", apiKey: "")).correct(segs); await check("未配置时报错而不崩溃", false) }
    catch { await check("未配置时报错而不崩溃", (error as? CorrectionError).map { "\($0)".contains("notConfigured") } == true) }
}

// MARK: 3b 网关清单与参数
section("网关模型清单与请求参数(模拟)")
do {
    let sess = MockLLMFixture.session()
    MockURLProtocol.handler = { _, _ in
        (200, Data(#"{"data":[{"id":"a/b","display_name":"A","reasoning_levels":["low","high","max"],"native_endpoints":["/v1/chat/completions"]},{"id":"c/d","display_name":"C","reasoning_levels":["low","medium"],"native_endpoints":["/v1/responses"]},{"id":"e","display_name":"E"}]}"#.utf8))
    }
    let ms = (try? await GatewayModel.fetch(baseURL: "http://x/v1", session: sess)) ?? []
    await check("解析模型清单", ms.count == 3 && ms[0].displayName == "A")
    await check("仅 responses 的模型标记为不支持纠正", ms[0].supportsChat && !ms[1].supportsChat && ms[2].supportsChat)
    await check("默认强度取最低档", ms[0].defaultLevel == "low" && ms[1].defaultLevel == "low")
    MockURLProtocol.handler = { _, body in
        let out = MockLLMFixture.requestItems(body).map { ["id": $0["id"]!, "text": $0["text"]!] }
        // 同时带 reasoning_content,应被忽略
        return (200, MockLLMFixture.chatResponse(MockLLMFixture.itemsEnvelope(out), reasoningContent: "思考过程"))
    }
    let c = LLMConfig(baseURL: "http://127.0.0.1:3425/v1", model: "m", apiKey: "", reasoningEffort: "high", course: "计算机网络")
    let r = try? await TextCorrector(config: c, session: sess).correct([(time: "00:00:01", text: "你好")])
    await check("忽略 reasoning_content", r == ["你好"])
}

}

// MARK: 4 录音链路(模拟引擎 + 合成音)
section("录音链路:暂停/继续与时间轴")
do {
    let (r, local, dest) = await MainActor.run { makeRecorder("pause", tone: tone, engines: [{ MockEngine(.normal) }]) }
    await r.start(course: "暂停测试")
    _ = await MainActor.run { r }.duration
    _ = await waitUntil(2.2) { r.duration >= 2 }
    await r.pause()
    let d1 = r.duration
    try? await Task.sleep(for: .seconds(1.5))
    let d2 = r.duration
    await check("暂停期间时长不增加", abs(d2 - d1) < 0.05, "\(d1) → \(d2)")
    await r.resume()
    _ = await waitUntil(1.5) { r.duration > d2 + 1 }
    await r.stop()
    let dir = r.deliveredDir
    let saveState = r.save
    await check("已保存到目标目录", dir != nil && saveState == .saved(dir!.path))
    let sessionDir = (try? FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil))?.first
    let caf = sessionDir!.appendingPathComponent("audio.caf")
    let cafSecs = audioSeconds(caf)
    let dur = r.duration
    await check("界面时长=落盘音频时长", abs(cafSecs - dur) < 0.05, "\(cafSecs) vs \(dur)")
    await check("音频长度≈采集时长而非含暂停", cafSecs < 5.5 && cafSecs > 3, "\(cafSecs)")
    let m4a = try? FileManager.default.contentsOfDirectory(at: dir!, includingPropertiesForKeys: nil).first { $0.pathExtension == "m4a" }
    let m4aSecs: Double
    if let m4a { m4aSecs = (try? await AVURLAsset(url: m4a).load(.duration).seconds) ?? -1 }
    else { m4aSecs = -1 }
    await check("M4A 可读且时长一致", m4aSecs >= 0 && abs(m4aSecs - cafSecs) < 0.5, "\(m4aSecs)")
    let md = (try? String(contentsOf: dir!.appendingPathComponent(dir!.lastPathComponent + ".md"), encoding: .utf8)) ?? ""
    let stamps = MarkdownDoc.parseSegments(md).map(\.time)
    await check("Markdown 含正文且时间戳不重置", !stamps.isEmpty && stamps == stamps.sorted(), "\(stamps)")
    await check("Markdown 状态为完成", md.contains("转写状态:完成"), md)
    _ = dest
}

section("识别故障:录音继续、不重复、不编造")
do {
    let first = MockEngine(.failAfter(8)); let second = MockEngine(.normal)
    let (r, local, _) = await MainActor.run { makeRecorder("fail", tone: tone, engines: [{ first }, { second }]) }
    await r.start(course: "")
    _ = await waitUntil(8) { r.duration > 7 }
    let dBefore = r.duration
    await check("识别故障后录音仍在继续", dBefore > 5)
    await r.stop()
    let sessionDir = (try? FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil))!.first!
    let cafSecs = audioSeconds(sessionDir.appendingPathComponent("audio.caf"))
    let durNow = r.duration
    await check("音频完整保存", cafSecs > dBefore - 0.2 && abs(cafSecs - durNow) < 0.05, "\(cafSecs)")
    await check("恢复引擎从中断位置补喂", (second.firstStart ?? 99) <= first.fedSeconds + 0.1, "second.first=\(second.firstStart ?? -1) first.fed=\(first.fedSeconds)")
    let events = SessionStore.loadEvents(dir: sessionDir).events
    let texts = events.filter { $0.kind == .text }
    let ok = zip(texts, texts.dropFirst()).allSatisfy { $1.start >= $0.end - 0.001 }
    await check("事件时间不重叠(无重复文字)", ok, "\(texts.map { ($0.start, $0.end) })")
    await check("无 gap(补喂覆盖了故障区间)", events.allSatisfy { $0.kind == .text })
    await check("最终状态完成", r.finalStatus == .completed)
}
do {
    // 全部引擎都失败:状态转为异常,音频不丢,Markdown 如实标注
    let (r, local, _) = await MainActor.run { makeRecorder("failall", tone: tone, engines: [{ MockEngine(.failAfter(2)) }]) }
    await r.start(course: "全失败")
    _ = await waitUntil(25) { r.phase == .finished }  // 12 秒音频播完后自动结束
    let sessionDir = (try? FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil))!.first!
    await check("重试耗尽后音频仍完整", audioSeconds(sessionDir.appendingPathComponent("audio.caf")) > 11, "\(audioSeconds(sessionDir.appendingPathComponent("audio.caf")))")
    let st = r.finalStatus
    await check("状态为部分完成/失败而非完成", st == .partial || st == .failed, "\(String(describing: st))")
    let md = (try? String(contentsOf: sessionDir.appendingPathComponent(sessionDir.lastPathComponent + ".md"), encoding: .utf8)) ?? ""
    await check("Markdown 标注转写不完整", md.contains("转写不完整") && !md.contains("转写状态:完成"))
    await check("仍然交付音频与文本", r.deliveredDir != nil)
}

section("结束时识别卡死")
do {
    let (r, _, _) = await MainActor.run { makeRecorder("hang", tone: tone, engines: [{ MockEngine(.hangFinish) }]) }
    await r.start(course: "")
    _ = await waitUntil(3) { r.duration > 2 }
    let t0 = Date()
    await r.stop()
    let el = Date().timeIntervalSince(t0)
    await check("超时后仍完成保存", r.deliveredDir != nil && el < 8, "用时 \(el)s")
    await check("状态为部分完成", r.finalStatus == .partial)
}

section("交付失败与重试")
do {
    let (r, local, dest) = await MainActor.run { makeRecorder("badsave", tone: tone, engines: [{ MockEngine(.normal) }]) }
    let injected = TestCounter()
    r.deliverFiles = { base, audio, markdown, root, id in
        if injected.count == 0 { injected.increment(); throw ExportError.copyVerify("注入的交付失败") }
        return try Deliverer.deliver(base: base, audio: audio, markdown: markdown, to: root, id: id)
    }
    await r.start(course: "")
    _ = await waitUntil(3) { r.duration > 2 }
    await r.stop()
    var pending = false
    if case .pending(let p, _) = r.save { pending = p.hasPrefix(local.path) }
    await check("交付失败时显示本地路径并保留文件", pending)
    let sessionDir = (try? FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil))!.first!
    await check("本地保留 M4A 与 Markdown", FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent(sessionDir.lastPathComponent + ".m4a").path)
          && FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent(sessionDir.lastPathComponent + ".md").path))
    await check("会话状态为待保存", SessionStore.readInfo(dir: sessionDir)?.state == .pendingSave)
    await r.retrySave()
    let retried = r.deliveredDir
    await check("重试后交付到同一目标目录", retried != nil && ProjectLibrary.contains(dest, retried!))
    await check("会话状态为已保存", SessionStore.readInfo(dir: sessionDir)?.state == .saved)
}

section("录音中被强制终止后的恢复")
do {
    let local = fresh("kill-local"), dest = fresh("kill-dest")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = ["--hang", local.path, tone.path]
    let pipe = Pipe(); p.standardOutput = pipe
    try! p.run()
    var ready = false
    let h = pipe.fileHandleForReading
    let deadline = Date().addingTimeInterval(20)
    var buf = Data()
    while Date() < deadline, !ready {
        let d = h.availableData
        if d.isEmpty { break }
        buf.append(d); ready = String(decoding: buf, as: UTF8.self).contains("READY")
    }
    kill(p.processIdentifier, SIGKILL); p.waitUntilExit()
    await check("子进程已录音并被强杀", ready)
    let unfinished = Recorder.unfinishedSessions(in: local)
    await check("启动扫描发现未完成会话", unfinished.count == 1)
    if let dir = unfinished.first {
        await check("强杀后 CAF 仍可读取", audioSeconds(dir.appendingPathComponent("audio.caf")) > 2, "\(audioSeconds(dir.appendingPathComponent("audio.caf")))")
        let r = await MainActor.run { Recorder(saveRoot: dest, localRoot: local, makeEngine: { MockEngine(.normal) }, makeSource: { _ in FileSource(url: tone) }) }
        await r.recover(dir: dir)
        let out = r.deliveredDir
        await check("恢复后生成并交付 M4A+Markdown", out != nil
              && (try? FileManager.default.contentsOfDirectory(atPath: out!.path).contains { $0.hasSuffix(".m4a") }) == true
              && (try? FileManager.default.contentsOfDirectory(atPath: out!.path).contains { $0.hasSuffix(".md") }) == true)
        let md = out.flatMap { try? String(contentsOf: $0.appendingPathComponent($0.lastPathComponent + ".md"), encoding: .utf8) } ?? ""
        await check("Markdown 保留强杀前的已确认文字并说明中断", !MarkdownDoc.parseSegments(md).isEmpty && md.contains("意外中断"), md)
        await check("恢复后不再出现在未完成列表", Recorder.unfinishedSessions(in: local).isEmpty)
    }
}

// MARK: 5 真实识别(合成中文语音)
if CommandLine.arguments.contains("--real") {
    section("真实 SpeechTranscriber(合成中文语音,非课堂录音)")
    let say: URL
    do {
        say = try networkLectureAudio(generatedAt: tmp.appendingPathComponent("say.aiff"))
    } catch {
        await check("合成讲稿音频可用", false, "\(error.localizedDescription)")
        exit(1)
    }
    let total = audioSeconds(say)
    print("  合成音频时长 \(String(format: "%.1f", total)) 秒")
    let local = fresh("real-local"), dest = fresh("real-dest")
    let r = await MainActor.run {
        Recorder(saveRoot: dest, localRoot: local, makeEngine: { SpeechEngine() }, makeSource: { _ in FileSource(url: say, speed: 1) })
    }
    await r.start(course: "合成语音测试")
    // 录音进行中(尚未结束)是否已出现文字
    var firstText: Double?
    let t0 = Date()
    while r.phase == .recording, Date().timeIntervalSince(t0) < total + 20 {
        let any = !r.segments.isEmpty || !r.volatileText.isEmpty
        if any, firstText == nil { firstText = Date().timeIntervalSince(t0) }
        try? await Task.sleep(for: .milliseconds(100))
    }
    await r.stop()
    _ = await waitUntil(60) { r.phase == .finished }
    print("  首次出现文字:\(firstText.map { String(format: "%.1f 秒", $0) } ?? "无")(音频共 \(String(format: "%.1f", total)) 秒)")
    await check("录音进行中就出现文字(非结束后批量)", (firstText ?? 999) < total - 3)
    let segs = r.segments
    let joined = segs.map(\.text).joined()
    print("  识别结果:\(joined)")
    await check("识别出中文内容", joined.contains("计算机网络") && joined.contains("分组"))
    await check("句尾未丢失(最后一个词“排队”及其后文字在)", joined.contains("排队"))
    print("  注:合成语音里“时延”被同音误识为“食盐”,属识别准确率,不影响链路验证")
    await check("状态为完成", r.finalStatus == .completed, "\(String(describing: r.finalStatus))")
    await check("时间戳在音频时长内且递增", segs.allSatisfy { $0.start <= total + 1 } && zip(segs, segs.dropFirst()).allSatisfy { $1.start >= $0.start })
    if let dir = r.deliveredDir {
        print("  交付目录:\(dir.path)")
        let md = (try? String(contentsOf: dir.appendingPathComponent(dir.lastPathComponent + ".md"), encoding: .utf8)) ?? ""
        print(md)
    }
    // 从已保存录音重新转写
    if let dir = r.deliveredDir, let m4a = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "m4a" }) {
        do {
            let asm = try await Retranscriber.run(audio: m4a)
            let out = try Retranscriber.writeMarkdown(audio: m4a, assembler: asm, duration: audioSeconds(m4a))
            let t = asm.segments.map(\.text).joined()
            await check("重新转写可用且另存", t.contains("计算机网络") && out.lastPathComponent.hasSuffix("_重转写.md"), t)
        } catch { await check("重新转写可用且另存", false, "\(error)") }
    }
}

if !skipCorrection, CommandLine.arguments.contains("--magpie") {
    section("真实 Magpie 网关(合成文字,非录音)")
    let url = "http://127.0.0.1:3425/v1"
    let models = (try? await GatewayModel.fetch(baseURL: url)) ?? []
    await check("读取到网关模型清单", !models.isEmpty, "\(models.count)")
    let m = models.first { $0.id == "sdu/ByteDance-volcengine/DeepSeek-V4.1-Flash" }
    await check("包含 DS SDU 且强度含 high", m != nil && (m?.levels.contains("high") ?? false) && (m?.supportsChat ?? false))
    let segs: [(time: String, text: String)] = [
        ("00:00:00", "同学们好今天我们讲计算机网络的第一章"), ("00:00:08", "接下来介绍网络的食盐包括发送食盐和传播食盐"),
        ("00:00:20", "分组交换把数据分成一个个小的分组"), ("00:00:28", "每个分组独立地在网络中传输"), ("00:00:35", "这样可以提高线路的利用率")]
    do {
        let cfg = LLMConfig(baseURL: url, model: m?.id ?? "", apiKey: "", reasoningEffort: "high", course: "计算机网络")
        let t0 = Date()
        let out = try await TextCorrector(config: cfg).correct(segs)
        print("  用时 \(String(format: "%.1f", Date().timeIntervalSince(t0))) 秒")
        for (a, b) in zip(segs, out) { print("  \(a.time) \(a.text)\n         → \(b)") }
        await check("返回段落数与原文一致", out.count == segs.count)
        await check("未编造摘要(每段长度不超过原文 2 倍)", zip(segs, out).allSatisfy { $1.count <= $0.text.count * 2 + 6 })
        var a = TranscriptAssembler()
        for s in segs { a.commit(start: Double(Int(s.time.suffix(2))! + Int(s.time.dropLast(3).suffix(2))! * 60), end: Double(Int(s.time.suffix(2))! + 1 + Int(s.time.dropLast(3).suffix(2))! * 60), text: s.text) }
        let original = MarkdownDoc(title: "合成", date: Date(), duration: 40, audioName: "x.m4a", engine: "E", language: "zh-CN", status: .completed, notes: [], segments: a.segments).render()
        let parsed = MarkdownDoc.parseSegments(original)
        let fixedMD = try TextCorrector.buildCorrectedMarkdown(original: original, corrected: Array(out.prefix(parsed.count)), originalName: "x.md", model: cfg.model)
        await check("校正版与原稿时间戳一一对应", MarkdownDoc.parseSegments(fixedMD).map(\.time) == parsed.map(\.time))
        let folder = fresh("magpie-files")
        let raw = folder.appendingPathComponent("原始.md")
        try original.write(to: raw, atomically: true, encoding: .utf8)
        let resultFile = try Paths.writeUniqueMarkdown(fixedMD, base: "原始_校正版", in: folder)
        let unchanged = try String(contentsOf: raw, encoding: .utf8)
        await check("真实纠正另存且原稿保持不变", unchanged == original && resultFile != raw)

    } catch { await check("Magpie 纠正调用成功", false, "\(error)") }
}

if CommandLine.arguments.contains("--long") {
    await longRecordingCheck()
}

if CommandLine.arguments.contains("--real5") {
    section("真实识别 5 分钟(合成中文语音,实时速度)")
    let base = "同学们好,今天我们讲计算机网络的物理层。物理层要解决的问题是如何在连接各种计算机的传输媒体上传输数据比特流。传输媒体分为导向传输媒体和非导向传输媒体。双绞线、同轴电缆和光纤属于导向传输媒体。"
    let say = tmp.appendingPathComponent("say5.aiff")
    let sp = Process(); sp.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    sp.arguments = ["-v", "Eddy (中文(中国大陆))", "-o", say.path, String(repeating: base, count: 22)]
    try! sp.run(); sp.waitUntilExit()
    let total = audioSeconds(say)
    print("  合成音频 \(Int(total)) 秒")
    let r = await MainActor.run {
        Recorder(saveRoot: fresh("real5-dest"), localRoot: fresh("real5-local"), makeEngine: { SpeechEngine() }, makeSource: { _ in FileSource(url: say, speed: 1) })
    }
    await r.start(course: "")
    var lastCount = 0; var maxStall = 0.0; var lastChange = Date()
    while r.phase == .recording {
        let c = r.segments.count + (r.segments.last?.text.count ?? 0)
        if c != lastCount { lastCount = c; maxStall = max(maxStall, Date().timeIntervalSince(lastChange)); lastChange = Date() }
        try? await Task.sleep(for: .milliseconds(250))
    }
    let t0 = Date()
    await r.stop()
    _ = await waitUntil(90) { r.phase == .finished }
    print("  结束收尾用时 \(String(format: "%.1f", Date().timeIntervalSince(t0))) 秒;录音中最长无新增文字间隔 \(String(format: "%.1f", maxStall)) 秒")
    let joined = r.segments.map(\.text).joined()
    await check("5 分钟内持续出文字", joined.count > 600, "\(joined.count) 字")
    await check("状态为完成", r.finalStatus == .completed)
    await check("收尾耗时 <20 秒", Date().timeIntervalSince(t0) < 20)
}


await additionalRegressionChecks()
await finishAndReplayRegressionChecks()
await saveRootSnapshotChecks()
await recordingPlacementChecks()
if !skipCorrection {
    await continuousCorrectionChecks()
}
await inputSwitchRegressionChecks()
await libraryRegressionChecks()
await phase1DocumentParsingRegressionChecks()
await phase2PlaybackAndLocatorRegressionChecks()
await phase3InSessionSafetyRegressionChecks()
await phase4LibraryAndNamingRegressionChecks()
await workspaceStateRegressionChecks()
await build30RecoveryRegressionChecks()
await reviewRegressionChecks(includeRecognition: CommandLine.arguments.contains("--real"))

finishAndExit(startedAt: runStartedAt)
