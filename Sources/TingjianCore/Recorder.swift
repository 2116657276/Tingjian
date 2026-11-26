import Observation
import AVFoundation
import AppKit
import Foundation

public enum SaveState: Equatable {
    case idle, saving
    case saved(String)
    case pending(String, String)   // 本地路径, 原因
    case failed(String)
}

public enum TranscribeState: Equatable {
    case idle, preparing, running
    case recovering(Int)
    case needsModel, unsupported
    case failed(String)
    case finishing, done, incomplete
}

/// 一次录音会话的调度:音频采集 → 落盘 → 分流识别 → 保存。
@MainActor
@Observable
private final class RecordingMeter {
    var duration: Double = 0
    var level: Float = 0
}

@MainActor
public final class Recorder: ObservableObject {
    public enum Phase { case idle, starting, recording, paused, finalizing, finished }

    @Published public internal(set) var phase: Phase = .idle
    @Published public internal(set) var segments: [Segment] = []
    @Published public internal(set) var volatileText = ""
    private let meter = RecordingMeter()
    public internal(set) var duration: Double {
        get { meter.duration }
        set { meter.duration = newValue }
    }
    public private(set) var level: Float {
        get { meter.level }
        set { meter.level = newValue }
    }
    @Published public internal(set) var transcribe: TranscribeState = .idle
    @Published public internal(set) var save: SaveState = .idle
    @Published public internal(set) var message: String?
    @Published public internal(set) var inputIssue: String?
    @Published public internal(set) var deliveredDir: URL?
    @Published public internal(set) var deliveredFiles: DeliveryResult?
    @Published public private(set) var persistenceIssue: String?
    @Published public internal(set) var localDir: URL?
    @Published public internal(set) var speechModelState: ModelState?
    @Published public internal(set) var modelDownloadError: String?
    @Published public internal(set) var modelProgress: Double?
    @Published public internal(set) var finalStatus: TranscriptStatus?
    @Published public private(set) var activeInputUID: String?
    @Published public private(set) var activeInputName: String?
    @Published public private(set) var isChangingInput = false
    @Published public internal(set) var courseName = ""
    @Published public private(set) var silenceWarning: String?
    public internal(set) var sessionDraftID: UUID?
    var sessionPlacement: RecordingPlacement?
    /// 交付确认后在主线程同步通知工作区。
    public var onDelivery: ((DeliveryResult, UUID?) -> Void)?

    public var saveRoot: URL
    public var localRoot: URL
    /// 录音开始时固定输入设备;nil 表示首次准备时解析系统默认。
    public var preferredInputUID: String?
    public var hardwareEnvironment: HardwareInputEnvironment = SystemHardwareInputEnvironment()
    /// 连续低电平且无新转写达到该秒数时发出温和静音提示（不中断录音）。
    public var silenceWarningThreshold: TimeInterval = 45
    public var makeEngine: () -> TranscriptionEngine
    public var makeSource: (String?) -> AudioSource
    public var finishTimeout: TimeInterval = 20
    public var retryDelay: TimeInterval = 2
    @_spi(Testing) public var speechEnhancement = SpeechEnhancer.Config()

    var source: AudioSource?
    var pipeline: AudioPipeline?
    var store: SessionStore?
    var assembler = TranscriptAssembler()
    var engine: TranscriptionEngine?
    var engineGen = 0
    var engineLive = false
    var attempts = 0
    var engineTask: Task<Void, Never>?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var tickCount = 0
    private var quietTicks = 0
    var notes: [String] = []
    var pendingFiles: (base: String, m4a: URL?, md: URL)?
    var sleepObservers: [NSObjectProtocol] = []
    var stopping = false
    private var startupGeneration = 0
    private var startupSource: AudioSource?
    var sourceGeneration = 0
    var inputChain: Task<Void, Never>?
    var needsInputRebuild = false
    var interruptionRetried = false
    var sessionSaveRoot: URL?
    private var metadataError: String?
    var journalError: String?
    var hadPersistenceFailure = false
    var engineBoundary = 0.0
    var lastVolatilePersistTime: Date = .distantPast
    var lastPersistedVolatileText = ""
    var modelInstallGeneration = 0
    static let volatilePersistInterval: TimeInterval = 1.2
    static let timelineEpsilon = 0.0001
    public var deliverFiles: @Sendable (String, URL?, URL, URL, UUID) throws -> DeliveryResult = {
        try Deliverer.deliver(base: $0, audio: $1, markdown: $2, to: $3, id: $4)
    }

    public init(saveRoot: URL = Paths.defaultSaveRoot,
                localRoot: URL = Paths.defaultLocalRoot,
                makeEngine: @escaping () -> TranscriptionEngine = { SpeechEngine() },
                makeSource: @escaping (String?) -> AudioSource = { MicrophoneSource(deviceUID: $0) }) {
        self.saveRoot = saveRoot; self.localRoot = localRoot
        self.makeEngine = makeEngine; self.makeSource = makeSource
    }

    public var isActive: Bool { phase == .starting || phase == .recording || phase == .paused || phase == .finalizing }

    /// 本次会话的目标目录:开始时固定,保存与重试都写这里。
    public var sessionDestination: URL { sessionSaveRoot ?? saveRoot }

    public func clearMessage() {
        message = nil
    }

    // MARK: 开始 / 暂停 / 继续 / 结束

    @discardableResult
    public func start(course: String, draftID: UUID? = nil, destination: URL? = nil, placement: RecordingPlacement? = nil) async -> Bool {
        guard phase == .idle || phase == .finished else { return false }
        switch save {
        case .pending, .failed:
            message = "上次录音尚未保存到目标目录,请先重试保存,再开始新的录音。"
            return false
        default:
            break
        }
        resetForNewSession()
        sessionPlacement = placement
        sessionSaveRoot = placement?.directory ?? destination ?? saveRoot
        sessionDraftID = draftID
        phase = .starting
        startupGeneration += 1
        let generation = startupGeneration
        courseName = course
        let input = makeSource(preferredInputUID)
        if input.requiresHardwareInputGuard,
           let blocked = HardwareInputGuard.blockReason(for: preferredInputUID, environment: hardwareEnvironment) {
            phase = .idle
            sessionSaveRoot = nil
            message = blocked
            return false
        }
        startupSource = input
        let granted = await input.requestAccess()
        guard generation == startupGeneration, phase == .starting else { await input.stop(); return false }
        guard granted else {
            await input.stop(); startupSource = nil; phase = .idle
            message = "没有麦克风权限。请在系统设置的麦克风权限中允许听笺。"
            return false
        }
        var workDir: URL?
        var pendingPipeline: AudioPipeline?
        do {
            let dir = try Paths.makeUniqueDirectory(in: localRoot, base: Paths.baseName(date: Date(), course: course))
            workDir = dir
            let format = try await input.prepare()
            guard generation == startupGeneration, phase == .starting else {
                await input.stop()
                if startupSource === input { startupSource = nil }
                let readableFrames = (try? AVAudioFile(forReading: dir.appendingPathComponent(SessionFiles.audio)).length)
                if (readableFrames ?? 0) == 0 {
                    try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
                }
                return false
            }
            var info = SessionInfo(baseName: dir.lastPathComponent, course: course, startedAt: Date(), state: .recording)
            info.sampleRate = format.sampleRate
            info.draftID = draftID
            info.sessionDestination = sessionSaveRoot
            info.recordingPlacement = placement
            let store = SessionStore(dir: dir, info: info)
            let pipeline = try AudioPipeline(url: store.audioURL, sampleRate: format.sampleRate, enhancement: speechEnhancement)
            pendingPipeline = pipeline
            try store.prepare()
            pipeline.onWriteFailure = { [weak self] msg in Task { @MainActor in self?.handleWriteFailure(msg) } }
            sourceGeneration += 1
            let audioGeneration = sourceGeneration
            bindCallbacks(to: input, generation: audioGeneration, pipeline: pipeline)
            self.source = input; self.pipeline = pipeline; self.store = store; localDir = dir
            try await input.start()
            guard generation == startupGeneration, phase == .starting else {
                await input.stop()
                let samples = await pendingPipeline?.close() ?? 0
                if startupSource === input { startupSource = nil }
                if self.source === input { self.source = nil }
                if self.pipeline === pendingPipeline { self.pipeline = nil }
                if self.store === store { self.store = nil }
                if self.localDir == dir { self.localDir = nil }
                if generation == startupGeneration {
                    sourceGeneration += 1
                    phase = .idle
                    sessionSaveRoot = nil
                }
                let readableFrames = (try? AVAudioFile(forReading: dir.appendingPathComponent(SessionFiles.audio)).length)
                if samples == 0 && (readableFrames ?? 0) == 0 {
                    try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
                }
                return false
            }
            activeInputUID = input.activeDeviceUID
            activeInputName = input.activeDeviceName
            needsInputRebuild = false
            interruptionRetried = false
            startupSource = nil
            phase = .recording
            beginTicking(); observeSleep(); startEngine(replayFrom: 0)
            return true
        } catch {
            await input.stop()
            if startupSource === input { startupSource = nil }
            let samples = await pendingPipeline?.close() ?? 0
            let isEmptyWorkDir: Bool
            if let dir = workDir {
                let readableFrames = (try? AVAudioFile(forReading: dir.appendingPathComponent(SessionFiles.audio)).length)
                isEmptyWorkDir = samples == 0 && (readableFrames ?? 0) == 0
            } else {
                isEmptyWorkDir = false
            }
            guard generation == startupGeneration else {
                if let dir = workDir, isEmptyWorkDir {
                    try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
                }
                return false
            }
            self.source = nil; self.pipeline = nil; self.store = nil
            sourceGeneration += 1
            if let dir = workDir {
                if isEmptyWorkDir {
                    try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
                    localDir = nil
                } else {
                    localDir = dir
                }
            }
            phase = .idle
            sessionSaveRoot = nil
            message = "无法开始录音:\(error.localizedDescription)"
            return false
        }
    }

    public func cancelStarting() {
        guard phase == .starting else { return }
        startupGeneration += 1
        if let captured = startupSource {
            startupSource = nil
            Task { await captured.stop() }
        }
        phase = .idle
        sessionSaveRoot = nil
    }

    public func pause() async {
        guard phase == .recording else { return }
        phase = .paused
        level = 0
        clearSilenceWarning()
        await runInput { await self.source?.pause() }
    }

    /// 录音或暂停期间修改/补填课程名：只更新内存与交付用 baseName 并落盘 session.json，
    /// 不移动正在写入的 localDir，保证音频写入和强退恢复连续不断。
    public func updateCourseName(_ name: String) {
        guard phase == .recording || phase == .paused else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != courseName else { return }
        courseName = trimmed
        if let store {
            store.info.course = trimmed
            store.info.baseName = Paths.baseName(date: store.info.startedAt, course: trimmed)
            persistMetadata()
        }
    }

    public func resume() async {
        guard phase == .paused, !isChangingInput else { return }
        if let current = source, current.requiresHardwareInputGuard,
           let blocked = HardwareInputGuard.blockReason(for: activeInputUID ?? preferredInputUID, environment: hardwareEnvironment) {
            inputIssue = blocked
            return
        }
        let rebuild = needsInputRebuild
        needsInputRebuild = false
        interruptionRetried = false
        var failure: String?
        let current = source
        await runInput {
            guard self.phase == .paused, !self.stopping else { return }
            do {
                if rebuild { try await current?.restart() } else { try await current?.start() }
                guard !self.stopping, self.phase == .paused else { return }
                self.inputIssue = nil
                self.phase = .recording
            } catch {
                failure = error.localizedDescription
            }
        }
        if let failure, phase == .paused, !stopping {
            inputIssue = "无法继续录音:\(failure)。已保留已录部分,可更换输入设备后继续,或结束保存。"
            needsInputRebuild = true
        }
    }

    /// 录音中或暂停时按 uniqueID 切换输入;切换期间不产生音频,但不插入虚构静音。
    public func switchInput(to uid: String) async throws {
        guard phase == .recording || phase == .paused, !stopping else {
            throw AudioError.captureFailed("当前状态不能切换输入设备")
        }
        guard !isChangingInput else { throw AudioError.captureFailed("正在切换输入设备,请稍候") }
        isChangingInput = true
        defer { isChangingInput = false }

        var failure: Error?

        await runInput {
            guard !self.stopping, self.phase == .recording || self.phase == .paused,
                  let pipeline = self.pipeline else {
                failure = AudioError.captureFailed("录音已经结束")
                return
            }
            let wasRecording = self.phase == .recording
            let previous = self.source
            let previousName = self.activeInputName
            let candidate = self.makeSource(uid)
            if candidate.requiresHardwareInputGuard,
               let blocked = HardwareInputGuard.blockReason(for: uid, environment: self.hardwareEnvironment) {
                failure = AudioError.clamshellBuiltInUnavailable(blocked)
                return
            }
            await previous?.pause()
            self.sourceGeneration += 1
            let generation = self.sourceGeneration
            self.bindCallbacks(to: candidate, generation: generation, pipeline: pipeline)
            do {
                _ = try await candidate.prepare()
                if self.stopping || self.phase == .finalizing {
                    failure = AudioError.captureFailed("录音已经结束")
                    await candidate.stop()
                    return
                }
                if wasRecording && self.phase == .recording { try await candidate.start() }
                if self.stopping {
                    failure = AudioError.captureFailed("录音已经结束")
                    await candidate.stop()
                    return
                }
            } catch {
                failure = error
                await candidate.stop()
                // 旧源的回调绑定到已失效的 generation,恢复前重新绑定。
                self.sourceGeneration += 1
                let restoreGeneration = self.sourceGeneration
                if let previous, let pipeline = self.pipeline {
                    self.bindCallbacks(to: previous, generation: restoreGeneration, pipeline: pipeline)
                    if wasRecording, self.phase == .recording, !self.stopping {
                        do { try await previous.start() }
                        catch {
                            self.phase = .paused
                            self.needsInputRebuild = true
                            self.inputIssue = "麦克风不可用,请选择输入设备或结束保存。\(error.localizedDescription)"
                            self.addNote("切换输入失败,原麦克风也无法恢复:\(error.localizedDescription)。录音已暂停。")
                        }
                    }
                } else if wasRecording, self.phase == .recording, !self.stopping {
                    self.phase = .paused
                    self.needsInputRebuild = true
                    self.inputIssue = "麦克风不可用,请选择输入设备或结束保存。"
                }
                return
            }
            self.source = candidate
            self.activeInputUID = candidate.activeDeviceUID
            self.activeInputName = candidate.activeDeviceName
            self.needsInputRebuild = false
            self.interruptionRetried = false
            if self.phase == .recording || !wasRecording {
                self.inputIssue = nil
            }
            if wasRecording && self.phase == .recording {
                let name = candidate.activeDeviceName ?? uid
                self.addNote("麦克风由 \(previousName ?? "原设备") 切换为 \(name),切换期间未采集声音。")
            }
            await previous?.stop()
        }
        if let failure { throw failure }
    }

    /// 系统通知的设备断开:不结束录音,转暂停并保留补救入口。
    public func inputDeviceDisconnected(_ uid: String) async {
        guard uid == activeInputUID, phase == .recording || phase == .paused, !stopping, !isChangingInput else { return }
        let wasRecording = phase == .recording
        if wasRecording { await pause() }
        guard uid == activeInputUID, phase == .paused, !stopping else { return }
        needsInputRebuild = true
        inputIssue = "输入设备已断开,录音已暂停。请选择可用的输入设备后继续,或结束保存。"
        if wasRecording { addNote("输入设备已断开,录音暂停。") }
    }

    /// 结束:先保证音频落盘并导出,再收取剩余识别结果。
    public func stop() async {
        guard phase == .recording || phase == .paused, !stopping, let store, let pipeline else { return }
        stopping = true
        defer { endActivity() }
        clearSilenceWarning()
        phase = .finalizing
        sourceGeneration += 1
        let pendingChain = inputChain
        await pendingChain?.value
        let current = source
        await current?.stop()
        stopTicking(endActivity: false)
        let samples = await pipeline.close()
        if pipeline.failed, !notes.contains(where: { $0.contains("音频无法写入") }) {
            addNote("音频写入或重采样收尾失败，已保留可读取的录音。")
        }
        store.info.savedSamples = samples
        store.info.state = .finalizing
        persistMetadata()
        duration = Double(samples) / pipeline.fileRate
        level = 0

        // 识别收尾与音频导出并行;识别无法结束不阻塞音频保存
        let m4aTask = Task { await self.exportAudio(store: store) }
        var engineOK = true
        if engineLive, let engine {
            transcribe = .finishing
            engineOK = await race(timeout: finishTimeout, onTimeout: false) { await engine.finish() }
            if !engineOK { notes.append("转写收尾失败或超时，末尾部分文字可能缺失。") }
        } else {
            engineTask?.cancel()
            engineOK = false
        }
        engineLive = false
        engineGen += 1
        if !engineOK, let engine { Task { await engine.cancel() } }
        // 结束时清空未转正的临时文本,避免界面残留幽灵 volatile
        assembler.clearVolatile()
        clearVolatileSnapshot()
        // 引擎没有覆盖到的末段标记为不完整,不编造内容
        let uncovered = duration - assembler.lastEnd
        if !engineOK && uncovered > 1 { record(assembler.markGap(start: assembler.lastEnd, end: duration)) }
        publishAssembler()
        let m4a = await m4aTask.value
        let hasText = assembler.segments.contains {
            !$0.incomplete && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let status: TranscriptStatus
        if !hasText && !engineOK { status = .failed }
        else if !hasText || !engineOK || pipeline.failed || assembler.segments.contains(where: \.incomplete) { status = .partial }
        else { status = .completed }
        if !hasText && engineOK && !notes.contains(where: { $0.contains("未识别出文字") }) {
            notes.append("本次录音未识别出文字（可能为静音、设备无有效输入或音频过弱）。")
        }
        transcribe = status == .completed ? .done : .incomplete
        await finishSession(store: store, m4a: m4a, duration: duration, status: status)
        stopping = false
    }

    // MARK: 计时与状态

    private func beginTicking() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "听笺正在录音")
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTicking(endActivity shouldEndActivity: Bool = true) {
        timer?.invalidate(); timer = nil
        if shouldEndActivity { endActivity() }
        for o in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        sleepObservers = []
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func tick() {
        guard let pipeline, let store, phase == .recording || phase == .paused else { return }
        duration = pipeline.savedSeconds
        let raw = pipeline.takeLevel()
        level = phase == .recording ? max(raw, level * 0.85) : 0
        if phase == .recording {
            if raw >= 0.015 || level >= 0.015 {
                clearSilenceWarning()
            } else {
                quietTicks += 1
                let threshold = max(0.2, silenceWarningThreshold)
                if silenceWarning == nil, Double(quietTicks) * 0.1 >= threshold {
                    silenceWarning = "持续未检测到有效输入声音，请检查麦克风是否静音或设备是否正确。"
                }
            }
        } else {
            clearSilenceWarning()
        }
        tickCount += 1
        if tickCount % 50 == 0 {
            store.info.savedSamples = pipeline.savedSamples
            store.info.notes = notes
            attemptPersistence()
        }
    }

    func clearSilenceWarning() {
        quietTicks = 0
        if silenceWarning != nil { silenceWarning = nil }
    }

    func notePersistence(_ error: Error, journal: Bool) {
        hadPersistenceFailure = true
        if journal { journalError = error.localizedDescription } else { metadataError = error.localizedDescription }
        refreshPersistenceIssue()
    }

    private func refreshPersistenceIssue() {
        let problems = [journalError.map { "文本: \($0)" }, metadataError.map { "恢复信息: \($0)" }].compactMap { $0 }
        persistenceIssue = problems.isEmpty ? nil : problems.joined(separator: "；") + "。本地路径: \(store?.dir.path ?? "")"
    }

    func persistMetadata() {
        guard let store else { return }
        do { try store.save(); metadataError = nil; refreshPersistenceIssue() }
        catch { notePersistence(error, journal: false) }
    }

    func attemptPersistence(forceJournal: Bool = false) {
        guard let store else { return }
        if forceJournal || store.journalNeedsRepair || journalError != nil {
            do { try store.rewriteEvents(assembler.events); journalError = nil; refreshPersistenceIssue() }
            catch { notePersistence(error, journal: true) }
        }
        store.info.notes = notes
        persistMetadata()
    }

    func resetForNewSession() {
        segments = []; volatileText = ""; duration = 0; level = 0
        stopTicking()
        transcribe = .idle; save = .idle; message = nil; deliveredDir = nil; deliveredFiles = nil; localDir = nil
        finalStatus = nil; inputIssue = nil; silenceWarning = nil; quietTicks = 0
        assembler = TranscriptAssembler(); notes = []; attempts = 0; stopping = false
        engine = nil; engineLive = false; pendingFiles = nil
        metadataError = nil; journalError = nil; persistenceIssue = nil; hadPersistenceFailure = false; engineBoundary = 0; tickCount = 0
        lastVolatilePersistTime = .distantPast; lastPersistedVolatileText = ""
        sessionSaveRoot = nil
        sessionDraftID = nil
        sessionPlacement = nil
        activeInputUID = nil; activeInputName = nil; isChangingInput = false
        needsInputRebuild = false; interruptionRetried = false
        source = nil; pipeline = nil; store = nil
    }
}
