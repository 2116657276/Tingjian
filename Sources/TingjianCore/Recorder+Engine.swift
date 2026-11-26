import AppKit
import Foundation

extension Recorder {
    // MARK: 识别引擎

    func startEngine(replayFrom: Double) {
        engineGen += 1
        let gen = engineGen
        transcribe = attempts == 0 ? .preparing : .recovering(attempts)
        let eng = makeEngine()
        engine = eng
        engineLive = false
        engineTask = Task { [weak self] in
            let state = await eng.modelState()
            guard self?.engineGen == gen else { return }
            if self?.modelProgress == nil { self?.speechModelState = state }
            switch state {
            case .unsupported: self?.engineUnavailable(gen, .unsupported); return
            case .needsDownload: self?.engineUnavailable(gen, .needsModel); return
            case .ready: break
            }
            let cb = EngineCallbacks(
                volatile: { [weak self] t, s in self?.onVolatile(gen, t, s) },
                final: { [weak self] s, e, t in self?.onFinal(gen, s, e, t) },
                failure: { [weak self] err in self?.onEngineFailure(gen, err) })
            do {
                try await eng.start(callbacks: cb)
                await self?.attachEngine(eng, gen: gen, replayFrom: replayFrom)
            } catch {
                self?.onEngineFailure(gen, error)
            }
        }
    }

    private func attachEngine(_ eng: TranscriptionEngine, gen: Int, replayFrom: Double) async {
        guard gen == engineGen, !stopping, phase == .recording || phase == .paused, let pipeline else { Task { await eng.cancel() }; return }
        var from = replayFrom
        if let first = pipeline.ring.firstStart, first > from + 0.5 {
            // 缓存已不足以补回,这一段如实标记
            record(assembler.markGap(start: from, end: first)); publishAssembler()
            from = first
        }
        engineBoundary = from
        engineLive = true
        transcribe = .running
        pipeline.attach(eng, replayFrom: from)
    }

    private func engineUnavailable(_ gen: Int, _ s: TranscribeState) {
        guard gen == engineGen else { return }
        transcribe = s
        if s == .unsupported { message = "本机不支持中文识别。录音继续。" }
    }

    public func refreshSpeechModelState() async {
        guard modelProgress == nil else { return }
        let generation = modelInstallGeneration
        let state = await makeEngine().modelState()
        guard modelProgress == nil, generation == modelInstallGeneration else { return }
        speechModelState = state
    }

    public func installModel() async {
        guard modelProgress == nil else { return }
        let installer = makeEngine()
        modelInstallGeneration += 1
        modelProgress = 0
        modelDownloadError = nil
        defer { modelProgress = nil }
        do {
            try await installer.installModel { [weak self] progress in
                Task { @MainActor in
                    if self?.modelProgress != nil { self?.modelProgress = progress }
                }
            }
            let state = await installer.modelState()
            speechModelState = state
            guard state == .ready else { throw EngineError.modelMissing }
            if transcribe == .needsModel || transcribe == .preparing,
               phase == .recording || phase == .paused {
                engineTask?.cancel()
                startEngine(replayFrom: assembler.lastEnd)
            }
        } catch {
            modelDownloadError = "模型下载失败：\(error.localizedDescription)"
        }
    }

    private func onVolatile(_ gen: Int, _ text: String, _ start: Double) {
        guard gen == engineGen, start.isFinite else { return }
        let boundary = max(engineBoundary, assembler.lastEnd)
        // 允许弱音/气口声学重切分带来的轻微回退,但过滤明显早于已提交/恢复边界的迟到旧结果
        guard start + 0.25 >= boundary else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let clampedStart = max(start, boundary)
        guard assembler.canUpdateVolatile(at: clampedStart + Self.timelineEpsilon) else { return }
        let isRollback = start + Self.timelineEpsilon < boundary
        if trimmed.isEmpty {
            assembler.clearVolatile()
            volatileText = assembler.volatileText
            clearVolatileSnapshot()
            return
        }
        if isRollback {
            guard let display = assembler.resolveOverlappingVolatile(text: trimmed, start: start) else {
                assembler.clearVolatileIfNotAfter(boundary + Self.timelineEpsilon)
                volatileText = assembler.volatileText
                if volatileText.isEmpty { clearVolatileSnapshot() }
                return
            }
            assembler.setVolatile(display, start: clampedStart)
        } else {
            assembler.setVolatile(trimmed, start: clampedStart)
        }
        if volatileText != assembler.volatileText {
            volatileText = assembler.volatileText
            if !volatileText.isEmpty { clearSilenceWarning() }
        }
        persistVolatileSnapshot(force: false)
    }

    private func onFinal(_ gen: Int, _ start: Double, _ end: Double, _ text: String) {
        guard gen == engineGen, start.isFinite, end.isFinite else { return }
        let boundary = max(engineBoundary, assembler.lastEnd)
        // 完全落于已提交边界之前的旧结果(如故障重启后的历史重复补喂)直接忽略
        guard end > boundary + Self.timelineEpsilon else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let effectiveText: String
        // 仅在时间戳回退重叠时做去重/前缀剥离;无时间重叠的真实复述不做去重
        if start + Self.timelineEpsilon < boundary {
            guard let resolved = assembler.resolveOverlappingFinal(text: trimmed, start: start, end: end, boundary: boundary) else {
                return
            }
            effectiveText = resolved
        } else {
            effectiveText = trimmed
        }
        // 正常流式识别中弱音/气口重切分导致的轻微时间戳重叠:钳位起始时间并保留有效文字,不误标 gap
        let clampedStart = max(start, boundary)
        attempts = 0
        clearSilenceWarning()
        record(assembler.commit(start: clampedStart, end: end, text: effectiveText))
        publishAssembler()
        if assembler.volatileText.isEmpty {
            clearVolatileSnapshot()
        } else {
            persistVolatileSnapshot(force: true)
        }
        pipeline?.ring.trim(before: assembler.lastEnd)
    }

    private func onEngineFailure(_ gen: Int, _ error: Error) {
        guard gen == engineGen, !stopping else { return }
        engineLive = false
        pipeline?.attach(nil, replayFrom: nil)
        let old = engine
        Task { await old?.cancel() }
        assembler.clearVolatile()
        clearVolatileSnapshot()
        publishAssembler()
        attempts += 1
        guard attempts <= 3, phase == .recording || phase == .paused else {
            transcribe = .failed(error.localizedDescription)
            message = "录音继续,转写异常:\(error.localizedDescription)"
            return
        }
        transcribe = .recovering(attempts)
        let wait = retryDelay * Double(attempts)
        let from = assembler.lastEnd
        engineGen += 1  // 使旧引擎的迟到回调失效
        let gen2 = engineGen
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, self.engineGen == gen2, !self.stopping, self.phase == .recording || self.phase == .paused else { return }
            self.startEngine(replayFrom: from)
        }
    }

    private func persistVolatileSnapshot(force: Bool) {
        guard let store else { return }
        let text = assembler.volatileText
        guard !text.isEmpty else {
            clearVolatileSnapshot()
            return
        }
        guard text != lastPersistedVolatileText else { return }
        let now = Date()
        let isFirst = lastPersistedVolatileText.isEmpty
        guard force || isFirst || now.timeIntervalSince(lastVolatilePersistTime) >= Self.volatilePersistInterval else { return }
        try? store.saveVolatile(VolatileSnapshot(start: assembler.volatileStart, text: text))
        lastPersistedVolatileText = text
        lastVolatilePersistTime = now
    }

    func clearVolatileSnapshot() {
        if !lastPersistedVolatileText.isEmpty {
            store?.clearVolatile()
            lastPersistedVolatileText = ""
            lastVolatilePersistTime = .distantPast
        } else {
            store?.clearVolatile()
        }
    }

    func record(_ e: TranscriptEvent?) {
        guard let e, let store else { return }
        do { try store.append(e) }
        catch { notePersistence(error, journal: true) }
    }

    func publishAssembler() {
        segments = assembler.segments
        volatileText = assembler.volatileText
    }

    // MARK: 输入设备

    func bindCallbacks(to input: AudioSource, generation: Int, pipeline: AudioPipeline) {
        input.onBuffer = { [pipeline] b in pipeline.accept(b) }
        input.onInterruption = { [weak self] msg in
            Task { @MainActor in self?.handleInterruption(msg, generation: generation) }
        }
        input.onEnd = { [weak self] in
            Task { @MainActor in self?.handleEnd(generation: generation) }
        }
    }

    func runInput(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = inputChain
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        inputChain = task
        await task.value
    }

    private func handleEnd(generation: Int) {
        guard generation == sourceGeneration else { return }
        Task { await self.stop() }
    }

    private func handleInterruption(_ reason: String, generation: Int) {
        guard generation == sourceGeneration, !stopping,
              phase == .recording || phase == .paused else { return }
        if let uid = activeInputUID, AudioInputCatalog.device(forUID: uid) == nil {
            Task { await self.pauseForMissingInput(reason) }
            return
        }
        if phase == .paused {
            needsInputRebuild = true
            inputIssue = "\(reason)。录音已暂停,继续前会重新打开输入设备。"
            return
        }
        Task { await self.recoverInput(reason: reason, generation: generation) }
    }

    private func pauseForMissingInput(_ reason: String) async {
        guard phase == .recording else { return }
        await pause()
        needsInputRebuild = true
        inputIssue = "\(reason)。请选择可用的输入设备或结束保存;已录部分保留。"
        addNote("\(reason),录音暂停。")
    }

    /// 运行时错误只尝试同 UID 重建一次,失败即暂停,不无限重试、不自动换设备。
    private func recoverInput(reason: String, generation: Int) async {
        guard phase == .recording, sourceGeneration == generation, !stopping else { return }
        if let current = source, current.requiresHardwareInputGuard,
           let blocked = HardwareInputGuard.blockReason(for: activeInputUID ?? preferredInputUID, environment: hardwareEnvironment) {
            await pause()
            guard sourceGeneration == generation, phase == .paused, !stopping else { return }
            needsInputRebuild = true
            inputIssue = blocked
            addNote("\(reason)，\(blocked)录音已暂停。")
            persistMetadata()
            return
        }
        guard !interruptionRetried else {
            await pause()
            needsInputRebuild = true
            inputIssue = "\(reason)。录音已暂停,请选择输入设备或结束保存。"
            return
        }
        interruptionRetried = true
        var failure: String?
        let current = source
        await runInput {
            guard self.phase == .recording, self.sourceGeneration == generation else { return }
            do { try await current?.restart() }
            catch { failure = error.localizedDescription }
        }
        if let failure {
            await pause()
            needsInputRebuild = true
            inputIssue = "麦克风不可用,请选择输入设备或结束保存。\(failure)"
            addNote("\(reason),无法自动恢复录音:\(failure)。录音已暂停。")
        } else if phase == .recording {
            addNote("\(reason),已自动恢复录音。")
        }
    }

    func handleWriteFailure(_ msg: String) {
        failStop(msg)
    }

    /// 无法继续录音:明确提示并安全结束,保留已保存部分。
    private func failStop(_ msg: String) {
        guard phase == .recording || phase == .paused else { return }
        message = "录音已中止:\(msg)"
        addNote("录音在 \(Timecode.string(duration)) 处中止:\(msg)")
        Task { await self.stop() }
    }

    func addNote(_ n: String) {
        notes.append("[\(Timecode.string(duration))] \(n)")
        store?.info.notes = notes
    }

    func observeSleep() {
        let c = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            c.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase == .recording else { return }
                    self.addNote("系统进入睡眠,睡眠期间没有录音。")
                    self.persistMetadata()
                }
            },
            c.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase == .recording else { return }
                    self.handleInterruption("系统从睡眠中唤醒", generation: self.sourceGeneration)
                }
            },
        ]
    }
}
