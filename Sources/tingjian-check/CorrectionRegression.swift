import Foundation
import TingjianCore

func continuousCorrectionChecks() async {
    section("连续多段纠正和时间轴")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let config = LLMConfig(baseURL: "http://localhost/v1", model: "synthetic", apiKey: "")
    let segments = [
        (time: "00:00:01", text: "风力有两种取……"),
        (time: "00:00:02", text: "取值，就是强和弱。"),
        (time: "00:00:03", text: "这个，这个，对吧？"),
        (time: "00:00:04", text: "为什么需要分类？"),
    ]
    func reply(_ content: String, finish: String? = nil) -> Data {
        var choice: [String: Any] = ["message": ["content": content]]
        if let finish { choice["finish_reason"] = finish }
        return try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
    }
    func envelope(_ entries: [[String: Any]]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["items": entries]), encoding: .utf8)!
    }
    func input(_ body: Data) -> ([String: String], [String: Any]) {
        let request = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        let messages = request["messages"] as! [[String: String]]
        let data = Data(messages[1]["content"]!.utf8)
        return (messages[0], try! JSONSerialization.jsonObject(with: data) as! [String: Any])
    }
    var captured: [[String: Any]] = []
    var systemText = ""
    MockURLProtocol.handler = { _, body in
        let (system, data) = input(body)
        if system["content"]!.contains("全文语境分析员") { return (200, reply("课堂讨论分类。")) }
        systemText = system["content"]!
        captured.append(data)
        let items = data["items"] as! [[String: Any]]
        let output = items.map { item -> [String: Any] in
            let id = item["id"] as! Int
            let values = [1: "风力有两种取值，", 2: "就是强和弱。", 3: "", 4: "为什么需要分类？"]
            return ["id": id, "text": values[id]!]
        }
        return (200, reply(envelope(output)))
    }
    let corrected = try? await TextCorrector(config: config, session: session, maxChunkItems: 2).correct(segments)
    await check("连续输入返回原段数量并允许空段", corrected == ["风力有两种取值，", "就是强和弱。", "", "为什么需要分类？"])
    await check("批内整体纠正和只读上下文指令", systemText.contains("先把所有 items 连起来") && systemText.contains("已校正并保留的前文"))
    let first = captured.first?["items"] as? [[String: Any]]
    let before = captured.last?["context_before"] as? [[String: Any]]
    await check("前批校正结果进入后批上下文",
                first?.count == 2 && before?.first?["text"] as? String == "风力有两种取值，"
                && before?.last?["text"] as? String == "就是强和弱。")

    let original = "# 示例\n\n[00:00:01] 风力有两种取……\n\n[00:00:02] 取值，就是强和弱。\n\n[00:00:03] 这个，这个，对吧？\n\n[00:00:04] 为什么需要分类？\n"
    if let corrected, let output = try? TextCorrector.buildCorrectedMarkdown(original: original, corrected: corrected, originalName: "原稿.md", model: "synthetic") {
        let parsed = MarkdownDoc.parseSegments(output)
        await check("空段时间戳保存并重新读取",
                    parsed.map(\.time) == segments.map(\.time) && parsed.map(\.text) == corrected
                    && output.contains("[00:00:03]\n"))
    } else {
        await check("空段时间戳保存并重新读取", false)
    }

    let cache = fresh("continuous-correction-cache")
    MockURLProtocol.requests = 0
    captured = []
    _ = try? await TextCorrector(config: config, session: session, maxChunkItems: 2,
                                 cacheDirectory: cache).correct(segments)
    let firstCount = MockURLProtocol.requests
    MockURLProtocol.requests = 0
    _ = try? await TextCorrector(config: config, session: session, maxChunkItems: 2,
                                 cacheDirectory: cache).correct(segments)
    await check("完整上下文相同时复用校正缓存", firstCount == 3 && MockURLProtocol.requests == 0)

    var written = config
    written.style = .written
    captured = []
    _ = try? await TextCorrector(config: written, session: session, maxChunkItems: 2,
                                 cacheDirectory: cache).correct(segments)
    await check("全面书面化使用独立缓存并发送对应指令",
                MockURLProtocol.requests == firstCount &&
                systemText.contains("全面书面化"))

    var calls = 0
    var splitBefore: [[String: Any]] = []
    MockURLProtocol.handler = { _, body in
        let (_, data) = input(body)
        calls += 1
        if calls == 1 { return (200, reply("{", finish: "length")) }
        let entries = data["items"] as! [[String: Any]]
        if calls == 3 { splitBefore = data["context_before"] as! [[String: Any]] }
        return (200, reply(envelope(entries.map { ["id": $0["id"]!, "text": "已校正\($0["id"]!)"] })))
    }
    let split = try? await TextCorrector(config: config, session: session).correct(segments)
    await check("截断重试保留顺序及已校正前文",
                split == ["已校正1", "已校正2", "已校正3", "已校正4"] && calls == 3
                && splitBefore.last?["text"] as? String == "已校正2")

    MockURLProtocol.handler = { _, _ in
        (200, reply(envelope([["id": 2, "text": "错误"], ["id": 1, "text": "错误"]])))
    }
    do {
        _ = try await TextCorrector(config: config, session: session).correct(Array(segments.prefix(2)))
        await check("错序 ID 被拒绝", false)
    } catch { await check("错序 ID 被拒绝", true) }

    MockURLProtocol.handler = { _, _ in (200, reply(envelope([["id": 1, "text": "缺少第二段"]]))) }
    do {
        _ = try await TextCorrector(config: config, session: session).correct(Array(segments.prefix(2)))
        await check("缺少段落被拒绝", false)
    } catch { await check("缺少段落被拒绝", true) }
}
