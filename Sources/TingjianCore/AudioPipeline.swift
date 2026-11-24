import AVFoundation
import Foundation

@_spi(Testing) public func drainPCM(_ converter: AVAudioConverter, maxIterations: Int = 64, consume: (AVAudioPCMBuffer) throws -> Void) throws {
    let limit = max(1, maxIterations)
    for _ in 0..<limit {
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4096) else {
            throw EngineError.conversion("无法分配重采样尾部缓冲")
        }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        if let error { throw EngineError.conversion(error.localizedDescription) }
        switch status {
        case .error:
            throw EngineError.conversion("重采样尾部转换失败")
        case .haveData:
            if output.frameLength > 0 {
                try consume(output)
            } else {
                return
            }
        case .inputRanDry, .endOfStream:
            if output.frameLength > 0 {
                try consume(output)
            }
            return
        @unknown default:
            if output.frameLength > 0 {
                try consume(output)
            }
            return
        }
    }
}

/// 最近一段已保存音频,用于转写中断恢复时补喂,避免丢字。
final class ReplayRing: @unchecked Sendable {
    struct Item { let start: Double; let end: Double; let buffer: AVAudioPCMBuffer }
    private let lock = NSLock()
    private var items: [Item] = []
    let maxSeconds = 120.0

    func append(start: Double, buffer: AVAudioPCMBuffer) {
        let end = start + Double(buffer.frameLength) / buffer.format.sampleRate
        lock.lock(); defer { lock.unlock() }
        items.append(Item(start: start, end: end, buffer: buffer))
        while let first = items.first, end - first.start > maxSeconds { items.removeFirst() }
    }

    /// 丢弃已被最终结果覆盖的音频。
    func trim(before time: Double) {
        lock.lock(); defer { lock.unlock() }
        while let first = items.first, first.end <= time { items.removeFirst() }
    }

    var firstStart: Double? { lock.lock(); defer { lock.unlock() }; return items.first?.start }

    func snapshot(from time: Double) -> [Item] {
        lock.lock(); defer { lock.unlock() }
        return items.compactMap { item in
            guard item.end > time else { return nil }
            guard item.start < time else { return item }
            let rate = item.buffer.format.sampleRate
            let offset = Int(ceil((time - item.start) * rate - 1e-7))
            let count = Int(item.buffer.frameLength) - offset
            guard count > 0, let source = item.buffer.floatChannelData?[0],
                  let clipped = AVAudioPCMBuffer(pcmFormat: item.buffer.format, frameCapacity: AVAudioFrameCount(count)),
                  let target = clipped.floatChannelData?[0] else { return nil }
            clipped.frameLength = AVAudioFrameCount(count)
            target.update(from: source.advanced(by: offset), count: count)
            return Item(start: item.start + Double(offset) / rate, end: item.end, buffer: clipped)
        }
    }
}

/// 采集线程只做单声道拷贝,写盘、重采样、送识别都在独立串行队列,互不阻塞。
final class AudioPipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "tingjian.audio.writer", qos: .userInitiated)
    let fileRate: Double
    let ring = ReplayRing()
    var onWriteFailure: (@Sendable (String) -> Void)?

    private var file: AVAudioFile?
    private let lock = NSLock()
    private var _samples: Int64 = 0
    private var _level: Float = 0
    private var _failed = false
    private var engine: TranscriptionEngine?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let enhancer: SpeechEnhancer

    init(url: URL, sampleRate: Double, enhancement: SpeechEnhancer.Config) throws {
        fileRate = sampleRate
        enhancer = SpeechEnhancer(sampleRate: sampleRate, config: enhancement)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    var savedSamples: Int64 { lock.lock(); defer { lock.unlock() }; return _samples }
    var savedSeconds: Double { Double(savedSamples) / fileRate }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return _failed }
    /// 读取并衰减电平,供界面轮询。
    func takeLevel() -> Float {
        lock.lock(); defer { lock.unlock() }
        let v = _level; _level = 0; return v
    }

    /// 采集线程入口:同步拷贝(tap 缓冲区会被复用),其余异步处理。
    func accept(_ buffer: AVAudioPCMBuffer) {
        guard let mono = Self.monoCopy(buffer) else { return }
        queue.async { [self] in process(mono) }
    }

    /// 在写盘队列中切换识别引擎,并补喂 ring 中从 replayFrom 起的音频,保证不丢不重。
    func attach(_ engine: TranscriptionEngine?, replayFrom: Double?) {
        queue.async { [self] in
            self.engine = engine
            guard let engine, let from = replayFrom else { return }
            for item in ring.snapshot(from: from) {
                engine.feed(item.buffer, start: item.start)
            }
        }
    }

    /// 排空队列并关闭文件,返回最终已保存采样数。
    func close() async -> Int64 {
        await withCheckedContinuation { (c: CheckedContinuation<Int64, Never>) in
            queue.async { [self] in
                if !failed {
                    do { try flushConverter() }
                    catch { reportWriteFailure(error) }
                }
                file = nil
                c.resume(returning: savedSamples)
            }
        }
    }

    private func process(_ mono: AVAudioPCMBuffer) {
        guard !failed, file != nil else { return }
        do {
            if converterInput != mono.format { try flushConverter() }
            if mono.format.sampleRate == fileRate {
                try write(mono)
            } else {
                try resampleAndWrite(mono)
            }
        } catch {
            reportWriteFailure(error)
        }
    }

    private func reportWriteFailure(_ error: Error) {
        lock.lock(); _failed = true; lock.unlock()
        onWriteFailure?("音频无法写入:\(error.localizedDescription)")
    }

    private func flushConverter() throws {
        guard let converter else { return }
        defer { self.converter = nil; converterInput = nil }
        try drainPCM(converter, consume: write)
    }

    private func write(_ buf: AVAudioPCMBuffer) throws {
        guard let file else { return }
        try file.write(from: buf)
        updateLevel(buf)
        let start = savedSeconds
        lock.lock(); _samples += Int64(buf.frameLength); lock.unlock()
        let enhanced = enhancer.process(buf)
        ring.append(start: start, buffer: enhanced)
        engine?.feed(enhanced, start: start)
    }

    private func updateLevel(_ b: AVAudioPCMBuffer) {
        guard let p = b.floatChannelData?[0], b.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(b.frameLength) { sum += p[i] * p[i] }
        let rms = (sum / Float(b.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        let v = min(1, max(0, (db + 60) / 60))
        lock.lock(); _level = max(_level, v); lock.unlock()
    }

    /// 输入设备采样率变化后,统一重采样到文件采样率,时间轴继续累加。
    private func resampleAndWrite(_ b: AVAudioPCMBuffer) throws {
        if converter == nil {
            guard let target = file?.processingFormat,
                  let next = AVAudioConverter(from: b.format, to: target) else {
                throw EngineError.conversion("不支持的录音采样率：\(b.format.sampleRate)")
            }
            next.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = next
            converterInput = b.format
        }
        guard let converter else { throw EngineError.noFormat }
        let ratio = fileRate / b.format.sampleRate
        let cap = AVAudioFrameCount(ceil(Double(b.frameLength) * ratio)) + 1024
        var supplied = false
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: cap) else {
                throw EngineError.conversion("无法分配录音重采样缓冲")
            }
            var err: NSError?
            let status = converter.convert(to: out, error: &err) { _, st in
                if supplied { st.pointee = .noDataNow; return nil }
                supplied = true; st.pointee = .haveData; return b
            }
            if let err { throw err }
            if status == .error { throw EngineError.conversion("录音重采样失败") }
            if out.frameLength > 0 { try write(out) }
            if status != .haveData || out.frameLength < cap { return }
        }
    }

    static func monoCopy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let ch = b.floatChannelData, b.frameLength > 0 else { return nil }
        let n = Int(b.frameLength), c = Int(b.format.channelCount)
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: b.format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: b.frameLength),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = b.frameLength
        if b.format.isInterleaved {
            for i in 0..<n {
                var s: Float = 0
                for k in 0..<c { s += ch[0][i * c + k] }
                dst[i] = s / Float(c)
            }
        } else if c == 1 {
            dst.update(from: ch[0], count: n)
        } else {
            for i in 0..<n {
                var s: Float = 0
                for k in 0..<c { s += ch[k][i] }
                dst[i] = s / Float(c)
            }
        }
        return out
    }
}
