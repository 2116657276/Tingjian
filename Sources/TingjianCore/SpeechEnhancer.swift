import Accelerate
import AVFoundation
import Foundation

/// 纯内存实时语音增强器（仅用于识别支路，不修改原始录音）：
/// 1. 四阶 Butterworth 高通滤波（两节级联 biquad，默认 105Hz，-24dB/oct），彻底压制 50Hz 工频嗡鸣与低频轰鸣
/// 2. 二阶 Peaking EQ 语音清晰度提亮（约 2.3kHz / +3.5dB，覆盖 1.2kHz–4kHz）
/// 3. 带语音频段侧链检波和平滑噪声门的自适应 AGC（底噪门限 -52dBFS，目标 -18dBFS，最大 +15dB）
/// 4. C1 连续 tanh 软限幅（峰值控制在 -1dBFS 内）与全链路 NaN/Inf 防毒化保护
///
/// 注意：本类**非线程安全**（内部维护 IIR 延迟线、复用的临时缓冲与包络状态），仅限在单一串行队列或同一隔离域内调用。
public final class SpeechEnhancer {
    public struct Config: Sendable {
        public var highPassCutoffHz: Double
        public var presenceCenterHz: Double
        public var presenceGainDB: Double
        public var presenceQ: Double
        public var gateSidechainHighPassHz: Double
        public var targetRMSdBFS: Float
        public var noiseGateThresholddBFS: Float
        public var noiseGateKneeDB: Float
        public var maxGainDB: Float
        public var envAttackSeconds: Double
        public var envReleaseSeconds: Double
        public var gainAttackSeconds: Double
        public var gainReleaseSeconds: Double
        public var gateReleaseSeconds: Double
        public var limiterCeilingdBFS: Float
        public var limiterKneeRatio: Float

        public init(
            highPassCutoffHz: Double = 105.0,
            presenceCenterHz: Double = 2300.0,
            presenceGainDB: Double = 3.5,
            presenceQ: Double = 0.85,
            gateSidechainHighPassHz: Double = 280.0,
            targetRMSdBFS: Float = -18.0,
            noiseGateThresholddBFS: Float = -52.0,
            noiseGateKneeDB: Float = 6.0,
            maxGainDB: Float = 15.0,
            envAttackSeconds: Double = 0.015,
            envReleaseSeconds: Double = 0.150,
            gainAttackSeconds: Double = 0.020,
            gainReleaseSeconds: Double = 0.250,
            gateReleaseSeconds: Double = 0.300,
            limiterCeilingdBFS: Float = -1.0,
            limiterKneeRatio: Float = 0.65
        ) {
            self.highPassCutoffHz = highPassCutoffHz
            self.presenceCenterHz = presenceCenterHz
            self.presenceGainDB = presenceGainDB
            self.presenceQ = presenceQ
            self.gateSidechainHighPassHz = gateSidechainHighPassHz
            self.targetRMSdBFS = targetRMSdBFS
            self.noiseGateThresholddBFS = noiseGateThresholddBFS
            self.noiseGateKneeDB = noiseGateKneeDB
            self.maxGainDB = maxGainDB
            self.envAttackSeconds = envAttackSeconds
            self.envReleaseSeconds = envReleaseSeconds
            self.gainAttackSeconds = gainAttackSeconds
            self.gainReleaseSeconds = gainReleaseSeconds
            self.gateReleaseSeconds = gateReleaseSeconds
            self.limiterCeilingdBFS = limiterCeilingdBFS
            self.limiterKneeRatio = limiterKneeRatio
        }
    }

    public let config: Config
    private var sampleRate: Double
    private var biquadSetup: vDSP_biquad_Setup?
    private var biquadDelay: [Float]
    private var sidechainSetup: vDSP_biquad_Setup?
    private var sidechainDelay: [Float]
    private var cleanInputScratch: [Float] = []
    private var sidechainScratch: [Float] = []
    private var envRMS: Float = 0
    private var gateEnvRMS: Float = 0
    private var currentGain: Float = 1.0
    private let safeMaxGainDB: Float
    private let safeTargetRMSdBFS: Float
    private let safeNoiseGateThresholddBFS: Float
    private let safeNoiseGateKneeDB: Float
    private let safeEnvAttackSeconds: Double
    private let safeEnvReleaseSeconds: Double
    private let safeGainAttackSeconds: Double
    private let safeGainReleaseSeconds: Double
    private let safeGateReleaseSeconds: Double
    private let maxLinearGain: Float
    private let limiterCeiling: Float
    private let limiterThreshold: Float
    private let limiterHeadroom: Float

    /// 2 节四阶 Butterworth 高通 + 1 节 Peaking EQ。
    private static let biquadSections: vDSP_Length = 3
    /// 1 节二阶 Butterworth 高通用于 AGC 噪声门语音频段侧链检波。
    private static let sidechainSections: vDSP_Length = 1

    public init(sampleRate: Double, config: Config = Config()) {
        self.config = config
        self.sampleRate = sampleRate
        self.biquadDelay = [Float](repeating: 0, count: Int(2 * Self.biquadSections + 2))
        self.sidechainDelay = [Float](repeating: 0, count: Int(2 * Self.sidechainSections + 2))
        self.safeMaxGainDB = Self.sanitized(config.maxGainDB, fallback: 0, min: 0, max: 48)
        self.safeTargetRMSdBFS = Self.sanitized(config.targetRMSdBFS, fallback: -18.0, min: -60, max: 0)
        self.safeNoiseGateThresholddBFS = Self.sanitized(config.noiseGateThresholddBFS, fallback: -52.0, min: -120, max: 0)
        self.safeNoiseGateKneeDB = Self.sanitized(config.noiseGateKneeDB, fallback: 6.0, min: 0, max: 40)
        self.safeEnvAttackSeconds = Self.sanitized(config.envAttackSeconds, fallback: 0.015, min: 1e-4, max: 10.0)
        self.safeEnvReleaseSeconds = Self.sanitized(config.envReleaseSeconds, fallback: 0.150, min: 1e-4, max: 10.0)
        self.safeGainAttackSeconds = Self.sanitized(config.gainAttackSeconds, fallback: 0.020, min: 1e-4, max: 10.0)
        self.safeGainReleaseSeconds = Self.sanitized(config.gainReleaseSeconds, fallback: 0.250, min: 1e-4, max: 10.0)
        self.safeGateReleaseSeconds = Self.sanitized(config.gateReleaseSeconds, fallback: 0.300, min: 1e-4, max: 10.0)
        self.maxLinearGain = powf(10.0, self.safeMaxGainDB / 20.0)
        let safeLimiterCeilingdBFS = Self.sanitized(config.limiterCeilingdBFS, fallback: -1.0, min: -40, max: 0)
        let safeLimiterKneeRatio = Self.sanitized(config.limiterKneeRatio, fallback: 0.65, min: 0.1, max: 0.95)
        self.limiterCeiling = powf(10.0, safeLimiterCeilingdBFS / 20.0)
        self.limiterThreshold = self.limiterCeiling * safeLimiterKneeRatio
        self.limiterHeadroom = max(self.limiterCeiling - self.limiterThreshold, 1e-4)
        self.biquadSetup = Self.makeBiquadSetup(sampleRate: sampleRate, config: config)
        self.sidechainSetup = Self.makeSidechainSetup(sampleRate: sampleRate, config: config)
    }

    deinit {
        if let setup = biquadSetup {
            vDSP_biquad_DestroySetup(setup)
        }
        if let setup = sidechainSetup {
            vDSP_biquad_DestroySetup(setup)
        }
    }

    /// 重置滤波器与包络状态，适用于新录音/新文件开始前。
    public func reset() {
        for i in biquadDelay.indices { biquadDelay[i] = 0 }
        for i in sidechainDelay.indices { sidechainDelay[i] = 0 }
        envRMS = 0
        gateEnvRMS = 0
        currentGain = 1.0
    }

    /// 处理单声道 Float32 PCM 缓冲（兼容交错与非交错），返回新分配的同格式、同帧数缓冲，不修改输入缓冲。
    public func process(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let count = Int(input.frameLength)
        guard count > 0,
              input.format.channelCount == 1,
              input.format.commonFormat == .pcmFormatFloat32,
              let src = Self.monoFloatPointer(input),
              let output = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength),
              let dst = Self.monoFloatPointer(output) else {
            return input
        }
        output.frameLength = input.frameLength

        let rate = input.format.sampleRate
        if rate != sampleRate {
            reconfigure(sampleRate: rate)
        }

        // 0. 滤波前对输入样本执行有限值清洗，防止单个 NaN/Inf 毒化 IIR 延迟线
        if cleanInputScratch.count < count {
            cleanInputScratch = [Float](repeating: 0, count: count)
        }
        cleanInputScratch.withUnsafeMutableBufferPointer { scratch in
            guard let base = scratch.baseAddress else { return }
            for i in 0..<count {
                let x = src[i]
                // 同时拦截非有限值与极端溢出量级，避免双二阶乘加产生 Inf/NaN
                base[i] = (x.isFinite && abs(x) <= 1e6) ? x : 0
            }

            // 1 + 2. 级联四阶 Butterworth 高通滤波 + 语音频段清晰度提亮
            if let setup = biquadSetup {
                vDSP_biquad(setup, &biquadDelay, base, 1, dst, 1, vDSP_Length(count))
                if !Self.allFinite(biquadDelay) {
                    for i in biquadDelay.indices { biquadDelay[i] = 0 }
                    Self.sanitizeBuffer(dst, count: count)
                }
            } else {
                dst.update(from: base, count: count)
            }
        }

        // 3. 带语音频段侧链检波和平滑噪声门的自适应 AGC（按 ~5ms 子块平滑斜坡增益，无咔嗒声）
        if let sidechain = sidechainSetup {
            if sidechainScratch.count < count {
                sidechainScratch = [Float](repeating: 0, count: count)
            }
            sidechainScratch.withUnsafeMutableBufferPointer { scBuf in
                guard let scBase = scBuf.baseAddress else { return }
                vDSP_biquad(sidechain, &sidechainDelay, dst, 1, scBase, 1, vDSP_Length(count))
                if !Self.allFinite(sidechainDelay) {
                    for i in sidechainDelay.indices { sidechainDelay[i] = 0 }
                    Self.sanitizeBuffer(scBase, count: count)
                }
                applyAdaptiveAGC(dst, gateSamples: scBase, count: count, sampleRate: rate)
            }
        } else {
            applyAdaptiveAGC(dst, gateSamples: dst, count: count, sampleRate: rate)
        }

        // 4. 末端 tanh 软限幅（峰值控制在 -1dBFS 内，并保证所有输出样本严格有限）
        applySoftLimiter(dst, count: count)

        return output
    }

    private func reconfigure(sampleRate newRate: Double) {
        if let setup = biquadSetup {
            vDSP_biquad_DestroySetup(setup)
        }
        if let setup = sidechainSetup {
            vDSP_biquad_DestroySetup(setup)
        }
        sampleRate = newRate
        biquadSetup = Self.makeBiquadSetup(sampleRate: newRate, config: config)
        sidechainSetup = Self.makeSidechainSetup(sampleRate: newRate, config: config)
        reset()
    }

    private func applyAdaptiveAGC(
        _ samples: UnsafeMutablePointer<Float>,
        gateSamples: UnsafePointer<Float>,
        count: Int,
        sampleRate: Double
    ) {
        guard sampleRate.isFinite, sampleRate > 0 else { return }
        if !envRMS.isFinite || envRMS < 0 { envRMS = 0 }
        if !gateEnvRMS.isFinite || gateEnvRMS < 0 { gateEnvRMS = 0 }
        if !currentGain.isFinite || currentGain < 1.0 || currentGain > maxLinearGain {
            currentGain = 1.0
        }

        let subBlockSize = max(64, Int((sampleRate * 0.005).rounded()))
        let gateHalfKnee = safeNoiseGateKneeDB * 0.5
        let gateLowDB = safeNoiseGateThresholddBFS - gateHalfKnee
        let gateHighDB = safeNoiseGateThresholddBFS + gateHalfKnee

        var offset = 0
        while offset < count {
            let blockLen = min(subBlockSize, count - offset)
            let ptr = samples.advanced(by: offset)
            let gatePtr = gateSamples.advanced(by: offset)
            let dt = Double(blockLen) / sampleRate

            var blockRMS: Float = 0
            vDSP_rmsqv(ptr, 1, &blockRMS, vDSP_Length(blockLen))
            if !blockRMS.isFinite || blockRMS < 0 {
                Self.sanitizeBuffer(ptr, count: blockLen)
                vDSP_rmsqv(ptr, 1, &blockRMS, vDSP_Length(blockLen))
                if !blockRMS.isFinite || blockRMS < 0 { blockRMS = 0 }
            }

            var gateBlockRMS: Float = 0
            vDSP_rmsqv(gatePtr, 1, &gateBlockRMS, vDSP_Length(blockLen))
            if !gateBlockRMS.isFinite || gateBlockRMS < 0 {
                gateBlockRMS = 0
            }

            let envTau = blockRMS > envRMS ? safeEnvAttackSeconds : safeEnvReleaseSeconds
            let envAlpha = Float(1.0 - exp(-dt / max(envTau, 1e-4)))
            envRMS += envAlpha * (blockRMS - envRMS)
            if !envRMS.isFinite || envRMS < 0 { envRMS = 0 }

            let gateTau = gateBlockRMS > gateEnvRMS ? safeEnvAttackSeconds : safeEnvReleaseSeconds
            let gateAlpha = Float(1.0 - exp(-dt / max(gateTau, 1e-4)))
            gateEnvRMS += gateAlpha * (gateBlockRMS - gateEnvRMS)
            if !gateEnvRMS.isFinite || gateEnvRMS < 0 { gateEnvRMS = 0 }

            let envDB = 20.0 * log10f(max(envRMS, 1e-7))
            let gateEnvDB = 20.0 * log10f(max(gateEnvRMS, 1e-7))

            let gateFactor: Float
            if gateEnvDB <= gateLowDB {
                gateFactor = 0
            } else if gateEnvDB >= gateHighDB {
                gateFactor = 1
            } else {
                let t = (gateEnvDB - gateLowDB) / max(gateHighDB - gateLowDB, 1e-4)
                gateFactor = t * t * (3.0 - 2.0 * t)
            }

            let targetGain: Float
            if gateFactor > 0 {
                let desiredBoostDB = max(0, min(safeMaxGainDB, safeTargetRMSdBFS - envDB))
                let computed = powf(10.0, (desiredBoostDB * gateFactor) / 20.0)
                targetGain = computed.isFinite ? min(max(computed, 1.0), maxLinearGain) : 1.0
            } else {
                targetGain = 1.0
            }

            let gainTau: Double
            if targetGain < currentGain {
                gainTau = gateFactor == 0 ? safeGateReleaseSeconds : safeGainAttackSeconds
            } else {
                gainTau = safeGainReleaseSeconds
            }
            let gainAlpha = Float(1.0 - exp(-dt / max(gainTau, 1e-4)))
            var nextGain = currentGain + gainAlpha * (targetGain - currentGain)
            if !nextGain.isFinite || nextGain < 1.0 || nextGain > maxLinearGain {
                currentGain = 1.0
                nextGain = 1.0
            }

            if abs(currentGain - 1.0) > 1e-4 || abs(nextGain - 1.0) > 1e-4 {
                var startGain = currentGain
                var step = blockLen > 1 ? (nextGain - currentGain) / Float(blockLen) : 0
                vDSP_vrampmul(ptr, 1, &startGain, &step, ptr, 1, vDSP_Length(blockLen))
            }
            currentGain = nextGain
            offset += blockLen
        }
    }

    private func applySoftLimiter(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        let threshold = limiterThreshold
        let headroom = limiterHeadroom
        let invHeadroom = 1.0 / headroom
        for i in 0..<count {
            let x = samples[i]
            if !x.isFinite {
                samples[i] = 0
                continue
            }
            let mag = abs(x)
            if mag > threshold {
                let limited = threshold + headroom * tanhf((mag - threshold) * invHeadroom)
                samples[i] = x >= 0 ? limited : -limited
            }
        }
    }

    private static func monoFloatPointer(_ buffer: AVAudioPCMBuffer) -> UnsafeMutablePointer<Float>? {
        if let ptr = buffer.floatChannelData?[0] {
            return ptr
        }
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        return list.first?.mData?.assumingMemoryBound(to: Float.self)
    }

    private static func allFinite(_ values: [Float]) -> Bool {
        for v in values where !v.isFinite {
            return false
        }
        return true
    }

    private static func sanitizeBuffer(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count where !samples[i].isFinite {
            samples[i] = 0
        }
    }

    private static func sanitized<T: BinaryFloatingPoint>(_ value: T, fallback: T, min lower: T, max upper: T) -> T {
        guard value.isFinite else { return fallback }
        return Swift.min(Swift.max(value, lower), upper)
    }

    private static func makeBiquadSetup(sampleRate: Double, config: Config) -> vDSP_biquad_Setup? {
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        // 四阶 Butterworth 高通由两节不同 Q 值的二阶高通级联而成（先低 Q 后高 Q 避免内部峰值过冲）
        let q1 = 1.0 / (2.0 * cos(Double.pi / 8.0))
        let q2 = 1.0 / (2.0 * cos(3.0 * Double.pi / 8.0))
        let hpf1 = highPassCoefficients(sampleRate: sampleRate, cutoffHz: config.highPassCutoffHz, q: q1)
        let hpf2 = highPassCoefficients(sampleRate: sampleRate, cutoffHz: config.highPassCutoffHz, q: q2)
        let presence = peakingEQCoefficients(
            sampleRate: sampleRate,
            centerHz: config.presenceCenterHz,
            gainDB: config.presenceGainDB,
            q: config.presenceQ
        )
        let coeffs = hpf1 + hpf2 + presence
        guard coeffs.allSatisfy(\.isFinite) else { return nil }
        return coeffs.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return nil }
            return vDSP_biquad_CreateSetup(base, biquadSections)
        }
    }

    private static func makeSidechainSetup(sampleRate: Double, config: Config) -> vDSP_biquad_Setup? {
        guard sampleRate.isFinite, sampleRate > 0,
              config.gateSidechainHighPassHz.isFinite,
              config.gateSidechainHighPassHz > 0,
              config.gateSidechainHighPassHz < sampleRate * 0.45 else {
            return nil
        }
        let q = 1.0 / Double(2.0).squareRoot()
        let coeffs = highPassCoefficients(sampleRate: sampleRate, cutoffHz: config.gateSidechainHighPassHz, q: q)
        guard coeffs.allSatisfy(\.isFinite) else { return nil }
        return coeffs.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return nil }
            return vDSP_biquad_CreateSetup(base, sidechainSections)
        }
    }

    /// 二阶高通滤波器系数 [b0, b1, b2, a1, a2]（支持任意 Q，用于级联高阶 Butterworth）。
    private static func highPassCoefficients(sampleRate: Double, cutoffHz: Double, q: Double) -> [Double] {
        guard sampleRate.isFinite, sampleRate > 0,
              cutoffHz.isFinite, cutoffHz > 0, cutoffHz < sampleRate * 0.45,
              q.isFinite, q > 0 else {
            return [1, 0, 0, 0, 0]
        }
        let safeQ = min(max(q, 0.1), 20.0)
        let w0 = 2.0 * Double.pi * cutoffHz / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * safeQ)

        let b0 = (1.0 + cosW0) * 0.5
        let b1 = -(1.0 + cosW0)
        let b2 = (1.0 + cosW0) * 0.5
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha

        let coeffs = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
        guard a0.isFinite, a0 != 0, coeffs.allSatisfy(\.isFinite) else {
            return [1, 0, 0, 0, 0]
        }
        return coeffs
    }

    /// 二阶 Peaking EQ 滤波器系数 [b0, b1, b2, a1, a2]。
    private static func peakingEQCoefficients(
        sampleRate: Double,
        centerHz: Double,
        gainDB: Double,
        q: Double
    ) -> [Double] {
        guard sampleRate.isFinite, sampleRate > 0,
              centerHz.isFinite, centerHz > 0, centerHz < sampleRate * 0.45,
              gainDB.isFinite, abs(gainDB) > 1e-3,
              q.isFinite, q > 0 else {
            return [1, 0, 0, 0, 0]
        }
        let safeGainDB = min(max(gainDB, -24.0), 24.0)
        let safeQ = min(max(q, 0.1), 20.0)
        let a = pow(10.0, safeGainDB / 40.0)
        let w0 = 2.0 * Double.pi * centerHz / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * safeQ)

        let b0 = 1.0 + alpha * a
        let b1 = -2.0 * cosW0
        let b2 = 1.0 - alpha * a
        let a0 = 1.0 + alpha / a
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha / a

        let coeffs = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
        guard a0.isFinite, a0 != 0, coeffs.allSatisfy(\.isFinite) else {
            return [1, 0, 0, 0, 0]
        }
        return coeffs
    }
}
