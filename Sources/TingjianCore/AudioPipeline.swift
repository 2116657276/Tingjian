import AVFoundation
import Foundation

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

    init(url: URL, sampleRate: Double) throws {
        fileRate = sampleRate
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
                file = nil
                c.resume(returning: savedSamples)
            }
        }
    }

    private func process(_ mono: AVAudioPCMBuffer) {
        guard !failed, file != nil else { return }
        var buf = mono
        if mono.format.sampleRate != fileRate {
            guard let r = resample(mono) else { return }
            buf = r
        }
        updateLevel(buf)
        do {
            try file?.write(from: buf)
        } catch {
            lock.lock(); _failed = true; lock.unlock()
            onWriteFailure?("音频无法写入:\(error.localizedDescription)")
            return
        }
        let start = savedSeconds
        lock.lock(); _samples += Int64(buf.frameLength); lock.unlock()
        ring.append(start: start, buffer: buf)
        engine?.feed(buf, start: start)
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
    private func resample(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converterInput != b.format {
            let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fileRate, channels: 1, interleaved: false)!
            converter = AVAudioConverter(from: b.format, to: target)
            converterInput = b.format
        }
        guard let converter else { return nil }
        let ratio = fileRate / b.format.sampleRate
        let cap = AVAudioFrameCount(Double(b.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: cap) else { return nil }
        var supplied = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, st in
            if supplied { st.pointee = .noDataNow; return nil }
            supplied = true; st.pointee = .haveData; return b
        }
        return err == nil && out.frameLength > 0 ? out : nil
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
