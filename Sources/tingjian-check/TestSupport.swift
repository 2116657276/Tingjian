import AVFoundation
import Foundation
import TingjianCore

// MARK: 并发安全计数与日志辅助

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

// MARK: 断言、汇总与隔离临时目录

private let passCounter = TestCounter()
private let failureCounter = TestCounter()
var passedChecks: Int { passCounter.count }
var failures: Int { failureCounter.count }

func check(_ name: String, _ cond: @autoclosure () async -> Bool, _ detail: String = "") async {
    if await cond() {
        passCounter.increment()
        print("  ✓ \(name)")
    } else {
        failureCounter.increment()
        print("  ✗ \(name) \(detail)")
    }
}

func section(_ s: String) { print("\n[\(s)]") }

func finishAndExit(startedAt: ContinuousClock.Instant) -> Never {
    let elapsed = startedAt.duration(to: .now)
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let formatted = String(format: "%.2f", seconds)
    print("\n总计：通过 \(passedChecks) / 失败 \(failures)（耗时 \(formatted)s）")
    exit(failures == 0 ? 0 : 1)
}

let tmp = ProcessInfo.processInfo.environment["TINGJIAN_CHECK_ROOT"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tingjian-check", isDirectory: true)

func fresh(_ name: String) -> URL {
    let u = tmp.appendingPathComponent(name, isDirectory: true)
    if FileManager.default.fileExists(atPath: u.path) {
        try! FileManager.default.trashItem(at: u, resultingItemURL: nil)
    }
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@MainActor
func waitUntil(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return cond()
}

func audioSeconds(_ url: URL) -> Double {
    guard let f = try? AVAudioFile(forReading: url) else { return -1 }
    return Double(f.length) / f.processingFormat.sampleRate
}

/// 生成 24k 单声道测试音(非语音),用于不依赖识别的链路测试。
func makeTone(_ url: URL, seconds: Double) {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    let f = try! AVAudioFile(forWriting: url, settings: fmt.settings)
    let n = AVAudioFrameCount(seconds * 24000)
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
    b.frameLength = n
    for i in 0..<Int(n) { b.floatChannelData![0][i] = 0.3 * sin(Float(i) * 2 * .pi * 440 / 24000) }
    try! f.write(from: b)
}

// MARK: 模拟网络协议与 LLM Fixture

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, Data))?
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while s.hasBytesAvailable {
                let n = s.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            s.close()
        }
        let (code, data) = Self.handler!(request, body)
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum MockLLMFixture {
    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    static func itemsEnvelope(_ entries: [[String: Any]]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["items": entries]), encoding: .utf8)!
    }

    static func singleItemEnvelope(_ text: String, id: Int = 1) -> String {
        itemsEnvelope([["id": id, "text": text]])
    }

    static func chatResponse(
        _ content: Any,
        finish: String? = nil,
        refusal: String? = nil,
        usage: [String: Any]? = nil,
        reasoningContent: String? = nil
    ) -> Data {
        var message: [String: Any] = ["content": content]
        if let refusal { message["refusal"] = refusal }
        if let reasoningContent { message["reasoning_content"] = reasoningContent }
        var choice: [String: Any] = ["message": message]
        if let finish { choice["finish_reason"] = finish }
        var result: [String: Any] = ["choices": [choice]]
        if let usage { result["usage"] = usage }
        return try! JSONSerialization.data(withJSONObject: result)
    }

    static func itemsReply(
        _ items: [[String: Any]],
        finish: String? = nil,
        refusal: String? = nil,
        usage: [String: Any]? = nil
    ) -> Data {
        chatResponse(itemsEnvelope(items), finish: finish, refusal: refusal, usage: usage)
    }

    static func requestPayload(_ body: Data) -> (system: [String: String], userEnvelope: [String: Any]) {
        let request = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        let messages = request["messages"] as! [[String: String]]
        let data = Data(messages[1]["content"]!.utf8)
        let envelope = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (messages[0], envelope)
    }

    static func requestItems(_ body: Data) -> [[String: Any]] {
        requestPayload(body).userEnvelope["items"] as! [[String: Any]]
    }
}
