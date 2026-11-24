import Accelerate
import AVFoundation
import Foundation
@_spi(Testing) import TingjianCore

// MARK: - 代码评审补强回归：DSP 防毒化/声学、Recorder 时间轴重叠与过期 volatile、Retranscriber 边界

private final class DoubleLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Double] = []
    var values: [Double] { lock.withLock { items } }
    func append(_ v: Double) { lock.withLock { items.append(v) } }
}

private final class ScriptedCallbackEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "ScriptedCallback"
    let languageTag = "zh-CN"
    private let lock = NSLock()
    private var _callbacks: EngineCallbacks?

    var callbacks: EngineCallbacks? {
        lock.withLock { _callbacks }
    }

    func modelState() async -> ModelState { .ready }
    func installModel(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func start(callbacks: EngineCallbacks) async throws {
        lock.withLock { _callbacks = callbacks }
    }
    func feed(_ buffer: AVAudioPCMBuffer, start: Double) {}
    func finish() async -> Bool { true }
    func cancel() async {}
}

private func makeMonoFloatBuffer(_ samples: [Float], sampleRate: Double, interleaved: Bool = false) -> AVAudioPCMBuffer {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: interleaved)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    let dst = buf.floatChannelData![0]
    samples.withUnsafeBufferPointer { ptr in
        if let base = ptr.baseAddress {
            dst.update(from: base, count: samples.count)
        }
    }
    return buf
}

private func extractMonoFloatSamples(_ buf: AVAudioPCMBuffer) -> [Float] {
    guard let ptr = buf.floatChannelData?[0], buf.frameLength > 0 else { return [] }
    return Array(UnsafeBufferPointer(start: ptr, count: Int(buf.frameLength)))
}

private func measureRMSdBFS(_ samples: [Float]) -> Double {
    guard !samples.isEmpty else { return -140.0 }
    var rms: Float = 0
    vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
    guard rms.isFinite else { return Double.nan }
    return 20.0 * log10(max(Double(rms), 1e-7))
}

private func makeSineSamples(freqHz: Double, rmsDB: Double, sampleRate: Double, frames: Int, startSample: Int = 0) -> [Float] {
    let amp = Float(Double(2.0).squareRoot() * pow(10.0, rmsDB / 20.0))
    let w = 2.0 * Double.pi * freqHz / sampleRate
    var out = [Float](repeating: 0, count: frames)
    for i in 0..<frames {
        out[i] = amp * Float(sin(w * Double(startSample + i)))
    }
    return out
}

private func occurrenceCount(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var range = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, range: range) {
        count += 1
        range = found.upperBound..<haystack.endIndex
    }
    return count
}

func reviewRegressionChecks(includeRecognition: Bool = false) async {
    await dspReviewRegressionChecks()
    await recorderOverlapAndVolatileChecks()
    await recorderResamplingChecks()
    if includeRecognition { await retranscriberEdgeRegressionChecks() }
}

// MARK: 1. DSP 防毒化与声学特性测试

private func dspReviewRegressionChecks() async {
    section("评审补强:SpeechEnhancer 防毒化与声学特性")
    let sampleRate = 48_000.0

    // 1.1 NaN / Inf 防毒化：注入非有限采样后，后续干净 1kHz 正弦波必须全部有限且 RMS 正常（不坍缩静音）
    do {
        let enhancer = SpeechEnhancer(sampleRate: sampleRate)
        var poisoned = makeSineSamples(freqHz: 1000, rmsDB: -24, sampleRate: sampleRate, frames: 2400)
        poisoned[0] = .nan
        poisoned[17] = .infinity
        poisoned[128] = -.infinity
        poisoned[1024] = .nan
        poisoned[2399] = .infinity
        let poisonedOut = enhancer.process(makeMonoFloatBuffer(poisoned, sampleRate: sampleRate))
        let poisonedOutSamples = extractMonoFloatSamples(poisonedOut)
        await check("SpeechEnhancer 毒化块输出全部有限",
                    poisonedOutSamples.count == poisoned.count && poisonedOutSamples.allSatisfy(\.isFinite),
                    "count=\(poisonedOutSamples.count)")

        var allCleanFinite = true
        var steadySamples: [Float] = []
        let blockFrames = 4800
        for block in 0..<10 {
            let clean = makeSineSamples(freqHz: 1000, rmsDB: -24, sampleRate: sampleRate, frames: blockFrames, startSample: block * blockFrames)
            let out = enhancer.process(makeMonoFloatBuffer(clean, sampleRate: sampleRate))
            let samples = extractMonoFloatSamples(out)
            if samples.count != blockFrames || !samples.allSatisfy(\.isFinite) {
                allCleanFinite = false
            }
            if block >= 5 {
                steadySamples.append(contentsOf: samples)
            }
        }
        let cleanRmsDB = measureRMSdBFS(steadySamples)
        await check("SpeechEnhancer 毒化后后续 1kHz 输出全部有限且 RMS 正常(不坍缩静音)",
                    allCleanFinite && cleanRmsDB.isFinite && cleanRmsDB > -30.0 && cleanRmsDB < -1.0,
                    String(format: "allFinite=%@ rms=%.2fdBFS", "\(allCleanFinite)", cleanRmsDB))
    }

    // 1.2 50Hz 工频与 85Hz 低频嗡鸣不被净放大。
    for (frequency, levelDB) in [(50.0, -35.0), (50.0, -40.0), (85.0, -35.0)] {
        let enhancer = SpeechEnhancer(sampleRate: sampleRate)
        let blockFrames = 4800
        var inSteady: [Float] = []
        var outSteady: [Float] = []
        var inPostTransient: [Float] = []
        var outPostTransient: [Float] = []
        var allFinite = true

        for block in 0..<20 {
            let inputSamples = makeSineSamples(freqHz: frequency, rmsDB: levelDB, sampleRate: sampleRate, frames: blockFrames, startSample: block * blockFrames)
            let out = enhancer.process(makeMonoFloatBuffer(inputSamples, sampleRate: sampleRate))
            let outSamples = extractMonoFloatSamples(out)
            if outSamples.count != blockFrames || !outSamples.allSatisfy(\.isFinite) {
                allFinite = false
            }
            if block >= 2 {
                inPostTransient.append(contentsOf: inputSamples)
                outPostTransient.append(contentsOf: outSamples)
            }
            if block >= 10 {
                inSteady.append(contentsOf: inputSamples)
                outSteady.append(contentsOf: outSamples)
            }
        }
        let inSteadyDB = measureRMSdBFS(inSteady)
        let outSteadyDB = measureRMSdBFS(outSteady)
        let inPostDB = measureRMSdBFS(inPostTransient)
        let outPostDB = measureRMSdBFS(outPostTransient)
        let deltaSteady = outSteadyDB - inSteadyDB
        let deltaPost = outPostDB - inPostDB
        print(String(format: "  [%.0fHz探针] %.0fdBFS: 稳态 %.2f -> %.2fdBFS (Δ=%.2fdB) | 去瞬态 %.2f -> %.2fdBFS (Δ=%.2fdB)",
                     frequency, levelDB, inSteadyDB, outSteadyDB, deltaSteady, inPostDB, outPostDB, deltaPost))
        await check("SpeechEnhancer \(Int(frequency))Hz @ \(Int(levelDB))dBFS 不被净放大(输出RMS <= 输入RMS)",
                    allFinite && outSteadyDB <= inSteadyDB && outPostDB <= inPostDB,
                    String(format: "steadyΔ=%.2fdB postΔ=%.2fdB", deltaSteady, deltaPost))
    }

    // 1.3 单声道交错 Float32 缓冲（-38dBFS 1kHz）：正常增强、返回新实例、不原地修改输入
    do {
        let enhancer = SpeechEnhancer(sampleRate: sampleRate)
        let blockFrames = 4800
        var allNewInstance = true
        var allInputUnchanged = true
        var allFinite = true
        var inSteady: [Float] = []
        var outSteady: [Float] = []

        for block in 0..<10 {
            let inputSamples = makeSineSamples(freqHz: 1000, rmsDB: -38, sampleRate: sampleRate, frames: blockFrames, startSample: block * blockFrames)
            let inBuf = makeMonoFloatBuffer(inputSamples, sampleRate: sampleRate, interleaved: true)
            let outBuf = enhancer.process(inBuf)
            let afterInput = extractMonoFloatSamples(inBuf)
            let outSamples = extractMonoFloatSamples(outBuf)

            if outBuf === inBuf { allNewInstance = false }
            if afterInput != inputSamples { allInputUnchanged = false }
            if outSamples.count != blockFrames || !outSamples.allSatisfy(\.isFinite) { allFinite = false }
            if block >= 5 {
                inSteady.append(contentsOf: inputSamples)
                outSteady.append(contentsOf: outSamples)
            }
        }
        let inDB = measureRMSdBFS(inSteady)
        let outDB = measureRMSdBFS(outSteady)
        let boostDB = outDB - inDB
        await check("SpeechEnhancer 单声道交错 Float32 返回新实例且不原地修改输入",
                    allNewInstance && allInputUnchanged && allFinite,
                    "newInstance=\(allNewInstance) inputUnchanged=\(allInputUnchanged) finite=\(allFinite)")
        await check("SpeechEnhancer 单声道交错 Float32 (-38dBFS 1kHz) 正常增强",
                    boostDB >= 6.0 && outDB < -1.0,
                    String(format: "in=%.2fdBFS out=%.2fdBFS boost=+%.2fdB", inDB, outDB, boostDB))
    }

    // 1.4 SpeechEnhancer.Config 异常参数防崩溃：传入 NaN / Inf / 负频率 / 非正 Q 等非法参数时输出仍全部有限、无崩溃
    do {
        let invalidConfigs: [(String, SpeechEnhancer.Config)] = [
            ("q=inf/gain=nan/hp=-10", SpeechEnhancer.Config(
                highPassCutoffHz: -10,
                presenceCenterHz: .nan,
                presenceGainDB: .nan,
                presenceQ: .infinity,
                gateSidechainHighPassHz: -50,
                targetRMSdBFS: .nan,
                noiseGateThresholddBFS: .infinity,
                noiseGateKneeDB: -5,
                maxGainDB: .infinity,
                envAttackSeconds: -1,
                envReleaseSeconds: .nan,
                gainAttackSeconds: 0,
                gainReleaseSeconds: .infinity,
                gateReleaseSeconds: -.infinity,
                limiterCeilingdBFS: .nan,
                limiterKneeRatio: .infinity
            )),
            ("hp=inf/gain=inf/q=0", SpeechEnhancer.Config(
                highPassCutoffHz: .infinity,
                presenceCenterHz: 999_999,
                presenceGainDB: .infinity,
                presenceQ: 0,
                gateSidechainHighPassHz: .nan,
                maxGainDB: .nan,
                limiterCeilingdBFS: .infinity,
                limiterKneeRatio: -2
            )),
            ("gain=-inf/q=-1/maxGain=-100", SpeechEnhancer.Config(
                highPassCutoffHz: 0,
                presenceCenterHz: -100,
                presenceGainDB: -.infinity,
                presenceQ: -1,
                gateSidechainHighPassHz: .infinity,
                noiseGateKneeDB: .nan,
                maxGainDB: -100,
                limiterCeilingdBFS: -.infinity,
                limiterKneeRatio: 0
            )),
        ]
        let blockFrames = 4800
        var badCases: [String] = []
        for (label, cfg) in invalidConfigs {
            let enhancer = SpeechEnhancer(sampleRate: sampleRate, config: cfg)
            for block in 0..<5 {
                let clean = makeSineSamples(freqHz: 1000, rmsDB: -24, sampleRate: sampleRate, frames: blockFrames, startSample: block * blockFrames)
                let out = enhancer.process(makeMonoFloatBuffer(clean, sampleRate: sampleRate))
                let samples = extractMonoFloatSamples(out)
                if samples.count != blockFrames || !samples.allSatisfy(\.isFinite) {
                    badCases.append("\(label)#\(block)")
                    break
                }
            }
        }
        await check("SpeechEnhancer.Config 异常参数(q=inf/gain=nan/hp=-10 等)输出全部有限无崩溃",
                    badCases.isEmpty,
                    badCases.joined(separator: ", "))
    }
}

// MARK: 2. Recorder 时间轴重叠与过期 volatile 测试

@MainActor
private func recorderOverlapAndVolatileChecks() async {
    section("评审补强:Recorder 时间轴重叠去重与过期 volatile 过滤")
    let source = GateSource()
    let engine = ScriptedCallbackEngine()
    let local = fresh("reg-overlap-local")
    let dest = fresh("reg-overlap-dest")
    let recorder = Recorder(saveRoot: dest, localRoot: local,
                            makeEngine: { engine },
                            makeSource: { _ in source })
    await recorder.start(course: "时间轴重叠回归")
    _ = await waitUntil(2) { recorder.transcribe == .running && engine.callbacks != nil }
    source.push(frames: 12000)

    guard let cb = engine.callbacks else {
        await check("ScriptedCallbackEngine 已就绪", false, "callbacks == nil")
        await recorder.stop()
        return
    }

    func joinedText() -> String {
        recorder.segments.filter { !$0.incomplete }.map(\.text).joined()
    }

    // 2.1 标点差异重叠不重复写入
    cb.final(0, 2, "第一句。")
    cb.final(1.5, 2.1, "第一句")
    let afterPunct = joinedText()
    await check("标点差异重叠不重复写入“第一句”",
                afterPunct == "第一句。" && occurrenceCount(of: "第一句", in: afterPunct) == 1,
                "got=\(afterPunct)")

    // 2.2 前缀扩展重叠剥离前缀并保留新增后缀
    cb.final(3, 8, "今天我们讲计算机网络")
    cb.final(4, 9.5, "今天我们讲计算机网络的第一章")
    let afterPrefix = joinedText()
    await check("前缀扩展重叠无重复前缀且不丢“的第一章”",
                afterPrefix.contains("今天我们讲计算机网络的第一章")
                && occurrenceCount(of: "今天我们讲计算机网络", in: afterPrefix) == 1
                && occurrenceCount(of: "的第一章", in: afterPrefix) == 1,
                "got=\(afterPrefix)")

    // 2.3 lastEnd == 9.5 后迟到旧 volatile 被过滤，不污染 volatileText
    cb.volatile("迟到的旧临时字", 2.0)
    await check("lastEnd=9.5 后迟到旧 volatile(2.0s) 被过滤不污染空 volatileText",
                recorder.volatileText.isEmpty,
                "volatile=\(recorder.volatileText)")

    cb.volatile("当前实时字", 9.6)
    let freshVolOK = recorder.volatileText == "当前实时字"
    cb.volatile("再次迟到的旧临时字", 2.0)
    cb.volatile("容忍窗内的迟到临时字", 9.4)
    cb.volatile("", 9.55)
    await check("有效 volatile 正常显示且不被后续迟到旧 volatile 覆盖",
                freshVolOK && recorder.volatileText == "当前实时字",
                "volatile=\(recorder.volatileText)")

    // 2.4 无时间重叠的真实复述正常保留不被误删
    cb.final(10, 12, "第一句")
    let afterRepeat = joinedText()
    await check("无时间重叠的真实复述(10~12s“第一句”)正常保留",
                occurrenceCount(of: "第一句", in: afterRepeat) == 2 && afterRepeat.hasSuffix("第一句"),
                "got=\(afterRepeat)")

    cb.final(12, 13, "版本 1.2。")
    cb.final(12.9, 14, "版本12。")
    await check("重叠去重保留小数点有语义的不同文字", joinedText().hasSuffix("版本 1.2。版本12。"), joinedText())

    await recorder.stop()
    let events = recorder.localDir.map { SessionStore.loadEvents(dir: $0).events.filter { $0.kind == .text } } ?? []
    let monotonic = zip(events, events.dropFirst()).allSatisfy { $1.start >= $0.end - 0.0001 }
    await check("重叠与复述会话收尾完成、无 gap 且落盘事件时间单调不重叠",
                recorder.finalStatus == .completed
                && recorder.segments.allSatisfy { !$0.incomplete }
                && events.count >= 6 && monotonic,
                "status=\(String(describing: recorder.finalStatus)) events=\(events.count)")
}

private final class DryDrainConverter: AVAudioConverter, @unchecked Sendable {
    var calls = 0
    override func convert(to outputBuffer: AVAudioBuffer,
                          error outError: NSErrorPointer,
                          withInputFrom inputBlock: AVAudioConverterInputBlock) -> AVAudioConverterOutputStatus {
        calls += 1
        var status: AVAudioConverterInputStatus = .haveData
        _ = inputBlock(1, &status)
        if let pcm = outputBuffer as? AVAudioPCMBuffer {
            pcm.frameLength = 0
        }
        return .inputRanDry
    }
}

@MainActor
private func recorderResamplingChecks() async {
    section("录音采样率切换与尾帧")
    let source = GateSource()
    source.sampleRate = 48_000
    let recorder = Recorder(saveRoot: fresh("reg-rate-dest"), localRoot: fresh("reg-rate-local"),
                            makeEngine: { ScriptedCallbackEngine() }, makeSource: { _ in source })
    await recorder.start(course: "采样率切换")
    _ = await waitUntil(2) { recorder.transcribe == .running }
    source.sampleRate = 44_100
    source.push(frames: 4410, value: 0.2)
    source.sampleRate = 48_000
    source.push(frames: 4800, value: 0.3)
    source.sampleRate = 32_000
    source.push(frames: 3200, value: 0.4)
    await recorder.stop()
    do {
        guard let directory = recorder.localDir else { throw AudioError.noInput }
        let audio = try AVAudioFile(forReading: directory.appendingPathComponent("audio.caf"))
        let expected: AVAudioFramePosition = 2400 + 4800 + 4800 + 4800
        let pcm = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(expected + 1024))!
        try audio.read(into: pcm)
        let samples = extractMonoFloatSamples(pcm)
        let markers = [7190, 7200, 11990, 12010, Int(expected) - 12]
        let orderCorrect = markers.allSatisfy { $0 < samples.count }
            && abs(samples[7190] - 0.2) < 0.04 && abs(samples[11990] - 0.3) < 0.04
            && abs(samples[Int(expected) - 12] - 0.4) < 0.04
        await check("换采样率及关文件后帧数与各段末尾完整", audio.length == expected && orderCorrect,
                    "帧数=\(audio.length)/\(expected) 标记=\(markers.map { $0 < samples.count ? samples[$0] : 0 })")
    } catch {
        await check("换采样率及关文件后帧数与各段末尾完整", false, error.localizedDescription)
    }

    // 重采样排空边界：0 帧 .inputRanDry 及空转换器安全结束而不抛错
    do {
        let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        guard let dry = DryDrainConverter(from: inFmt, to: outFmt),
              let realConverter = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw AudioError.captureFailed("无法创建重采样转换器")
        }
        var consumedDry = 0
        try drainPCM(dry) { _ in consumedDry += 1 }
        var consumedReal = 0
        try drainPCM(realConverter) { _ in consumedReal += 1 }
        try drainPCM(realConverter) { _ in consumedReal += 1 }
        await check("AudioPipeline.drainPCM 遇 0 帧 .inputRanDry 安全结束不抛错",
                    dry.calls == 1 && consumedDry == 0 && consumedReal == 0,
                    "dryCalls=\(dry.calls) consumedDry=\(consumedDry) consumedReal=\(consumedReal)")
    } catch {
        await check("AudioPipeline.drainPCM 遇 0 帧 .inputRanDry 安全结束不抛错", false, "\(error)")
    }
}

// MARK: 3. Retranscriber 边界测试（0.3s 极短音频 + 44.1kHz 立体声低音量音频）

private func retranscriberEdgeRegressionChecks() async {
    section("评审补强:Retranscriber 边界(0.3s 极短音频 + 44.1kHz 立体声低音量)")
    let modelState = await SpeechEngine().modelState()
    guard modelState == .ready else {
        await check("Retranscriber 边界测试前提：本机中文模型已就绪", false, "modelState=\(modelState)")
        return
    }

    let dir = fresh("reg-retranscribe-edge")

    // 3.1 0.3s 极短音频（24kHz 单声道 7200 帧 < 8192 分块，单块即触发尾冲刷）
    do {
        let shortURL = dir.appendingPathComponent("short_0_3s.caf")
        let sr = 24_000.0
        let frames = Int(sr * 0.3)
        let samples = makeSineSamples(freqHz: 440, rmsDB: -20, sampleRate: sr, frames: frames)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: shortURL, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: makeMonoFloatBuffer(samples, sampleRate: sr))

        let beforeData = try Data(contentsOf: shortURL)
        let prog = DoubleLog()
        _ = try await Retranscriber.run(audio: shortURL) { p in prog.append(p) }
        let afterData = try Data(contentsOf: shortURL)
        let validProg = prog.values.allSatisfy { $0.isFinite && $0 >= 0.0 && $0 <= 1.0 }
        await check("Retranscriber 0.3s 极短音频正常完成、进度有限且原文件未改动",
                    validProg && beforeData == afterData,
                    "progress=\(prog.values) unchanged=\(beforeData == afterData)")
    } catch {
        await check("Retranscriber 0.3s 极短音频正常完成、进度有限且原文件未改动", false, "\(error)")
    }

    // 3.2 44.1kHz 立体声低音量音频重转写
    do {
        let rawSayURL = try networkLectureAudio(generatedAt: dir.appendingPathComponent("raw_say.aiff"))

        // 重采样至 44.1kHz 并降增益 -22dB，构造 44.1kHz 立体声低音量 CAF
        let inFile = try AVAudioFile(forReading: rawSayURL)
        let inFmt = inFile.processingFormat
        let inFrames = AVAudioFrameCount(inFile.length)
        let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inFrames)!
        try inFile.read(into: inBuf)

        let mono44Fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let conv = AVAudioConverter(from: inFmt, to: mono44Fmt)!
        conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        let outCap = AVAudioFrameCount(Double(inFrames) * (44_100.0 / inFmt.sampleRate)) + 4096
        let mono44Buf = AVAudioPCMBuffer(pcmFormat: mono44Fmt, frameCapacity: outCap)!
        var supplied = false
        var convErr: NSError?
        conv.convert(to: mono44Buf, error: &convErr) { _, st in
            if supplied { st.pointee = .endOfStream; return nil }
            supplied = true; st.pointee = .haveData; return inBuf
        }
        if let convErr { throw convErr }

        let count = Int(mono44Buf.frameLength)
        let srcPtr = mono44Buf.floatChannelData![0]
        let stereoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let stereoBuf = AVAudioPCMBuffer(pcmFormat: stereoFmt, frameCapacity: AVAudioFrameCount(count))!
        stereoBuf.frameLength = AVAudioFrameCount(count)
        let left = stereoBuf.floatChannelData![0]
        let right = stereoBuf.floatChannelData![1]
        let gain = powf(10.0, -22.0 / 20.0)
        for i in 0..<count {
            let s = srcPtr[i] * gain
            left[i] = s
            right[i] = s * 0.9
        }

        let stereoURL = dir.appendingPathComponent("stereo_44k_low.caf")
        let outFile = try AVAudioFile(forWriting: stereoURL, settings: stereoFmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try outFile.write(from: stereoBuf)

        let verifyFile = try AVAudioFile(forReading: stereoURL)
        let formatOK = verifyFile.processingFormat.sampleRate == 44_100 && verifyFile.processingFormat.channelCount == 2

        let beforeData = try Data(contentsOf: stereoURL)
        let prog = DoubleLog()
        let asm = try await Retranscriber.run(audio: stereoURL) { p in prog.append(p) }
        let afterData = try Data(contentsOf: stereoURL)

        let text = asm.segments.map(\.text).joined()
        let validProg = !prog.values.isEmpty && prog.values.allSatisfy { $0.isFinite && $0 >= 0.0 && $0 <= 1.0 }
        await check("Retranscriber 44.1kHz 立体声低音量重转写正常完成、进度有限且原文件未改动",
                    formatOK && validProg && !text.isEmpty && beforeData == afterData,
                    "formatOK=\(formatOK) progress=\(prog.values) text=\(text) unchanged=\(beforeData == afterData)")
    } catch {
        await check("Retranscriber 44.1kHz 立体声低音量重转写正常完成、进度有限且原文件未改动", false, "\(error)")
    }
}
