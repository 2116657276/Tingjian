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

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var segments: [Segment] = []
    @Published public private(set) var volatileText = ""
    private let meter = RecordingMeter()
    public private(set) var duration: Double {
        get { meter.duration }
        set { meter.duration = newValue }
    }
    public private(set) var level: Float {
        get { meter.level }
        set { meter.level = newValue }
    }
    @Published public private(set) var transcribe: TranscribeState = .idle
    @Published public private(set) var save: SaveState = .idle
    @Published public private(set) var message: String?
    @Published public private(set) var inputIssue: String?
    @Published public private(set) var deliveredDir: URL?
    @Published public private(set) var deliveredFiles: DeliveryResult?
    @Published public private(set) var persistenceIssue: String?
    @Published public private(set) var localDir: URL?
    @Published public private(set) var speechModelState: ModelState?
    @Published public private(set) var modelDownloadError: String?
    @Published public private(set) var modelProgress: Double?
    @Published public private(set) var finalStatus: TranscriptStatus?
    @Published public private(set) var activeInputUID: String?
    @Published public private(set) var activeInputName: String?
    @Published public private(set) var isChangingInput = false
    public private(set) var courseName = ""
    public private(set) var sessionDraftID: UUID?
    private var sessionPlacement: RecordingPlacement?
    /// 交付确认后在主线程同步通知工作区。
    public var onDelivery: ((DeliveryResult, UUID?) -> Void)?

    public var saveRoot: URL
    public var localRoot: URL
    /// 录音开始时固定输入设备;nil 表示首次准备时解析系统默认。
    public var preferredInputUID: String?
    public var makeEngine: () -> TranscriptionEngine
    public var makeSource: (String?) -> AudioSource
    public var finishTimeout: TimeInterval = 20
    public var retryDelay: TimeInterval = 2
    @_spi(Testing) public var speechEnhancement = SpeechEnhancer.Config()

    private var source: AudioSource?
    private var pipeline: AudioPipeline?
    private var store: SessionStore?
    private var assembler = TranscriptAssembler()
    private var engine: TranscriptionEngine?
    private var engineGen = 0
    private var engineLive = false
    private var attempts = 0
    private var engineTask: Task<Void, Never>?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var tickCount = 0
    private var notes: [String] = []
    private var pendingFiles: (base: String, m4a: URL?, md: URL)?
    private var sleepObservers: [NSObjectProtocol] = []
    private var stopping = false
    private var startupGeneration = 0
    private var startupSource: AudioSource?
    private var sourceGeneration = 0
    private var inputChain: Task<Void, Never>?
    private var needsInputRebuild = false
    private var interruptionRetried = false
    private var sessionSaveRoot: URL?
    private var metadataError: String?
    private var journalError: String?
    private var hadPersistenceFailure = false
    private var engineBoundary = 0.0
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
        let current = source
        await runInput { await current?.pause() }
    }

    public func resume() async {
        guard phase == .paused, !isChangingInput else { return }
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
            await previous?.pause()
            let candidate = self.makeSource(uid)
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
                if wasRecording { try await candidate.start() }
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
            self.inputIssue = nil
            if wasRecording {
                let name = candidate.activeDeviceName ?? uid
                self.addNote("麦克风由 \(previousName ?? "原设备") 切换为 \(name),切换期间未采集声音。")
            }
            await previous?.stop()
        }
        if let failure { throw failure }
    }

    /// 系统通知的设备断开:不结束录音,转暂停并保留补救入口。
    public func inputDeviceDisconnected(_ uid: String) async {
        guard uid == activeInputUID, phase == .recording || phase == .paused, !stopping else { return }
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
        phase = .finalizing
        sourceGeneration += 1
        let pendingChain = inputChain
        await pendingChain?.value
        let current = source
        await current?.stop()
        stopTicking()
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
        // 引擎没有覆盖到的末段标记为不完整,不编造内容
        let uncovered = duration - assembler.lastEnd
        if !engineOK && uncovered > 1 { record(assembler.markGap(start: assembler.lastEnd, end: duration)) }
        publishAssembler()
        let m4a = await m4aTask.value
        let status: TranscriptStatus
        if !assembler.events.contains(where: { $0.kind == .text }) && !engineOK { status = .failed }
        else if !engineOK || pipeline.failed || assembler.segments.contains(where: \.incomplete) { status = .partial }
        else { status = .completed }
        transcribe = status == .completed ? .done : .incomplete
        await finishSession(store: store, m4a: m4a, duration: duration, status: status)
        stopping = false
    }

    // MARK: 关闭应用 / 恢复

    /// 供应用退出时调用:同步等待音频落盘并写好 session.json,其余交给下次启动恢复。
    public func emergencyFlush() async {
        guard phase == .recording || phase == .paused, let store, let pipeline else { return }
        sourceGeneration += 1
        let pendingChain = inputChain
        await pendingChain?.value
        let current = source
        await current?.stop()
        let samples = await pipeline.close()
        store.info.savedSamples = samples
        store.info.notes = notes
        persistMetadata()
        do { try store.closeEvents() } catch { notePersistence(error, journal: true) }
    }

    public static func unfinishedSessions(in root: URL) -> [URL] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter {
            guard let i = SessionStore.readInfo(dir: $0) else { return FileManager.default.fileExists(atPath: $0.appendingPathComponent(SessionFiles.audio).path) }
            return i.state == .recording || i.state == .finalizing || i.state == .pendingSave
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 从本地会话目录恢复并保存(进程异常退出或保存未完成)。
    public func recover(dir: URL) async {
        guard phase == .idle || phase == .finished else { return }
        switch save {
        case .pending, .failed:
            guard localDir?.standardizedFileURL == dir.standardizedFileURL else {
                message = "上次录音尚未保存，请先重试保存。"
                return
            }
            await retrySave()
            return
        default:
            break
        }
        resetForNewSession()
        let original = SessionStore.readInfo(dir: dir)
        sessionSaveRoot = original?.sessionDestination ?? original?.deliveryRoot ?? saveRoot
        sessionDraftID = original?.draftID
        sessionPlacement = original?.recordingPlacement
        let date = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        var info = original ?? SessionInfo(baseName: dir.lastPathComponent, course: "", startedAt: date, state: .finalizing)
        phase = .finalizing; localDir = dir; courseName = info.course
        let store = SessionStore(dir: dir, info: info)
        self.store = store
        if let id = info.deliveryID, let root = info.deliveryRoot {
            do {
                let placement = sessionPlacement
                let existing = try await Task.detached {
                    if let placement {
                        return try Deliverer.placementPublication(placement, audioName: info.deliveryAudioName,
                                                                  markdownName: info.baseName + ".md", id: id)
                    }
                    return try Deliverer.published(base: info.baseName, audioName: info.deliveryAudioName,
                                            markdownName: info.baseName + ".md", in: root, id: id)
                }.value
                if let existing {
                    duration = info.durationSeconds
                    finalStatus = info.status
                    transcribe = info.status == .completed ? .done : .incomplete
                    acknowledgeDelivery(existing, store: store)
                    phase = .finished
                    return
                }
            } catch {
                // Keep the attempted destination so retry checks the same publication.
                sessionSaveRoot = root
            }
        }
        let loaded = SessionStore.loadEvents(dir: dir)
        assembler = TranscriptAssembler(events: loaded.events)
        notes = info.notes + loaded.issues
        if original == nil { notes.append("会话信息缺失或损坏，课程、原录制日期及转写状态未知；显示日期取工作目录创建时间，仅作恢复标识。") }
        var dur = info.durationSeconds
        if let f = try? AVAudioFile(forReading: store.audioURL) {
            dur = Double(f.length) / f.processingFormat.sampleRate
            info.sampleRate = f.processingFormat.sampleRate; info.savedSamples = f.length
        }
        store.info = info; duration = dur
        let uncertain = original == nil || info.state != .pendingSave || !loaded.issues.isEmpty
        if uncertain {
            notes.append("录音或文字曾被意外中断或损坏，已保留完整记录；转写可能不完整。")
            if dur > assembler.lastEnd { record(assembler.markGap(start: assembler.lastEnd, end: dur)) }
        }
        publishAssembler()
        let m4a = await exportAudio(store: store)
        let hasText = assembler.events.contains { $0.kind == .text }
        var status = info.status ?? (hasText ? .partial : .failed)
        if uncertain || assembler.segments.contains(where: \.incomplete) {
            status = info.status == .failed || !hasText ? .failed : .partial
        }
        transcribe = status == .completed ? .done : .incomplete
        await finishSession(store: store, m4a: m4a, duration: dur, status: status)
    }

    // MARK: 保存

    private func exportAudio(store: SessionStore) async -> URL? {
        let m4a = store.dir.appendingPathComponent(store.info.baseName + ".m4a")
        do {
            _ = try await AudioExporter.exportM4A(from: store.audioURL, to: m4a)
            return m4a
        } catch {
            notes.append("M4A 转换失败(\(error.localizedDescription)),原始录音保留为 audio.caf。")
            if FileManager.default.fileExists(atPath: m4a.path) { try? FileManager.default.trashItem(at: m4a, resultingItemURL: nil) }
            return nil
        }
    }

    private func finishSession(store: SessionStore, m4a: URL?, duration: Double, status: TranscriptStatus) async {
        attemptPersistence(forceJournal: true)
        let status = journalError != nil && status == .completed ? TranscriptStatus.partial : status
        finalStatus = status
        transcribe = status == .completed ? .done : .incomplete
        if hadPersistenceFailure {
            let note = persistenceIssue == nil ? "录制期间曾有文本或恢复信息保存异常，结束时已重新保存。" : "本地文本或恢复信息仍未完整保存:\(persistenceIssue!)"
            if !notes.contains(note) { notes.append(note) }
        }
        if assembler.segments.contains(where: \.incomplete) && !notes.contains(where: { $0.contains("不完整") }) {
            notes.append("部分时间段的转写不完整,已在正文中标注。")
        }
        let engineName = engine?.name ?? SpeechEngine().name
        let lang = engine?.languageTag ?? "zh-CN"
        let title = store.info.course.isEmpty ? "课堂录音" : store.info.course
        let audioName = (m4a ?? store.audioURL).lastPathComponent
        let doc = MarkdownDoc(title: title, date: store.info.startedAt, duration: duration, audioName: audioName,
                              engine: engineName, language: lang, status: status, notes: notes,
                              segments: assembler.segments)
        let md = store.dir.appendingPathComponent(store.info.baseName + ".md")
        do { try doc.render().write(to: md, atomically: true, encoding: .utf8) }
        catch { save = .failed("无法写入 Markdown:\(error.localizedDescription)。本地文件:\(store.dir.path)"); phase = .finished; return }
        store.info.status = status; store.info.notes = notes
        pendingFiles = (store.info.baseName, m4a ?? store.audioURL, md)
        await deliver(store: store)
        phase = .finished
    }

    public func retrySave(in newParent: URL? = nil) async {
        guard let store, phase == .finished else { return }
        switch save { case .pending, .failed: break; default: return }
        phase = .finalizing
        if let newParent {
            let oldInfo = store.info
            let oldPlacement = sessionPlacement
            if let id = oldInfo.deliveryID, let root = oldInfo.deliveryRoot {
                do {
                    let previous = try await Task.detached {
                        if let oldPlacement {
                            return try Deliverer.placementPublication(oldPlacement, audioName: oldInfo.deliveryAudioName,
                                                                      markdownName: oldInfo.baseName + ".md", id: id)
                        }
                        return try Deliverer.published(base: oldInfo.baseName, audioName: oldInfo.deliveryAudioName,
                                                       markdownName: oldInfo.baseName + ".md", in: root, id: id)
                    }.value
                    if let previous {
                        acknowledgeDelivery(previous, store: store)
                        phase = .finished
                        return
                    }
                } catch {
                    // A missing/replaced or incomplete target can be left behind after explicit reselection.
                }
            }
            store.info.sessionDestination = newParent
            store.info.recordingPlacement = nil
            store.info.deliveryID = nil
            store.info.deliveryRoot = nil
            do { try store.save() }
            catch {
                store.info = oldInfo
                save = .pending(store.dir.path, error.localizedDescription)
                phase = .finished
                return
            }
            sessionSaveRoot = newParent
            sessionPlacement = nil
        }
        if pendingFiles == nil {
            let audio = store.dir.appendingPathComponent(store.info.baseName + ".m4a")
            await finishSession(store: store, m4a: FileManager.default.fileExists(atPath: audio.path) ? audio : nil,
                                duration: duration, status: finalStatus ?? .partial)
        } else {
            attemptPersistence(forceJournal: true)
            await deliver(store: store)
            phase = .finished
        }
    }

    private func deliver(store: SessionStore) async {
        guard let f = pendingFiles else { return }
        save = .saving
        let destination = sessionDestination
        let operation = deliverFiles
        let placement = sessionPlacement
        do {
            let id = store.info.deliveryID ?? UUID()
            store.info.deliveryID = id
            store.info.deliveryRoot = destination
            store.info.deliveryAudioName = f.m4a?.lastPathComponent
            store.info.state = .pendingSave
            try store.save()
            let result = try await Task.detached {
                if let placement {
                    return try Deliverer.fill(placement, audio: f.m4a, markdown: f.md, id: id)
                }
                return try operation(f.base, f.m4a, f.md, destination, id)
            }.value
            acknowledgeDelivery(result, store: store)
        } catch {
            store.info.state = .pendingSave
            persistMetadata()
            save = .pending(store.dir.path, error.localizedDescription)
        }
    }

    private func acknowledgeDelivery(_ result: DeliveryResult, store: SessionStore) {
        deliveredFiles = result
        deliveredDir = result.directory
        store.info.destination = result.directory.path
        store.info.state = .saved
        persistMetadata()
        save = .saved(result.directory.path)
        onDelivery?(result, sessionDraftID)
    }

    // MARK: 识别引擎

    private func startEngine(replayFrom: Double) {
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

    private var modelInstallGeneration = 0

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

    private static let timelineEpsilon = 0.0001

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
            return
        }
        if isRollback {
            guard let display = assembler.resolveOverlappingVolatile(text: trimmed, start: start) else {
                assembler.clearVolatileIfNotAfter(boundary + Self.timelineEpsilon)
                volatileText = assembler.volatileText
                return
            }
            assembler.setVolatile(display, start: clampedStart)
        } else {
            assembler.setVolatile(trimmed, start: clampedStart)
        }
        if volatileText != assembler.volatileText { volatileText = assembler.volatileText }
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
        record(assembler.commit(start: clampedStart, end: end, text: effectiveText))
        publishAssembler()
        pipeline?.ring.trim(before: assembler.lastEnd)
    }

    private func onEngineFailure(_ gen: Int, _ error: Error) {
        guard gen == engineGen, !stopping else { return }
        engineLive = false
        pipeline?.attach(nil, replayFrom: nil)
        let old = engine
        Task { await old?.cancel() }
        assembler.clearVolatile()
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

    private func record(_ e: TranscriptEvent?) {
        guard let e, let store else { return }
        do { try store.append(e) }
        catch { notePersistence(error, journal: true) }
    }

    private func publishAssembler() {
        segments = assembler.segments
        volatileText = assembler.volatileText
    }

    // MARK: 输入设备

    private func bindCallbacks(to input: AudioSource, generation: Int, pipeline: AudioPipeline) {
        input.onBuffer = { [pipeline] b in pipeline.accept(b) }
        input.onInterruption = { [weak self] msg in
            Task { @MainActor in self?.handleInterruption(msg, generation: generation) }
        }
        input.onEnd = { [weak self] in
            Task { @MainActor in self?.handleEnd(generation: generation) }
        }
    }

    private func runInput(_ operation: @escaping @MainActor () async -> Void) async {
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

    private func handleWriteFailure(_ msg: String) {
        failStop(msg)
    }

    /// 无法继续录音:明确提示并安全结束,保留已保存部分。
    private func failStop(_ msg: String) {
        guard phase == .recording || phase == .paused else { return }
        message = "录音已中止:\(msg)"
        addNote("录音在 \(Timecode.string(duration)) 处中止:\(msg)")
        Task { await self.stop() }
    }

    private func addNote(_ n: String) {
        notes.append("[\(Timecode.string(duration))] \(n)")
        store?.info.notes = notes
    }

    private func observeSleep() {
        let c = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            c.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase == .recording else { return }
                    self.addNote("系统进入睡眠,睡眠期间没有录音。")
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

    private func stopTicking() {
        timer?.invalidate(); timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        for o in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        sleepObservers = []
    }

    private func tick() {
        guard let pipeline, let store, phase == .recording || phase == .paused else { return }
        duration = pipeline.savedSeconds
        let raw = pipeline.takeLevel()
        level = phase == .recording ? max(raw, level * 0.85) : 0
        tickCount += 1
        if tickCount % 50 == 0 {
            store.info.savedSamples = pipeline.savedSamples
            store.info.notes = notes
            attemptPersistence()
        }
    }

    private func notePersistence(_ error: Error, journal: Bool) {
        hadPersistenceFailure = true
        if journal { journalError = error.localizedDescription } else { metadataError = error.localizedDescription }
        refreshPersistenceIssue()
    }

    private func refreshPersistenceIssue() {
        let problems = [journalError.map { "文本: \($0)" }, metadataError.map { "恢复信息: \($0)" }].compactMap { $0 }
        persistenceIssue = problems.isEmpty ? nil : problems.joined(separator: "；") + "。本地路径: \(store?.dir.path ?? "")"
    }

    private func persistMetadata() {
        guard let store else { return }
        do { try store.save(); metadataError = nil; refreshPersistenceIssue() }
        catch { notePersistence(error, journal: false) }
    }

    private func attemptPersistence(forceJournal: Bool = false) {
        guard let store else { return }
        if forceJournal || store.journalNeedsRepair || journalError != nil {
            do { try store.rewriteEvents(assembler.events); journalError = nil; refreshPersistenceIssue() }
            catch { notePersistence(error, journal: true) }
        }
        store.info.notes = notes
        persistMetadata()
    }

    private func resetForNewSession() {
        segments = []; volatileText = ""; duration = 0; level = 0
        stopTicking()
        transcribe = .idle; save = .idle; message = nil; deliveredDir = nil; deliveredFiles = nil; localDir = nil
        finalStatus = nil; inputIssue = nil
        assembler = TranscriptAssembler(); notes = []; attempts = 0; stopping = false
        engine = nil; engineLive = false; pendingFiles = nil
        metadataError = nil; journalError = nil; persistenceIssue = nil; hadPersistenceFailure = false; engineBoundary = 0; tickCount = 0
        sessionSaveRoot = nil
        sessionDraftID = nil
        sessionPlacement = nil
        activeInputUID = nil; activeInputName = nil; isChangingInput = false
        needsInputRebuild = false; interruptionRetried = false
        source = nil; pipeline = nil; store = nil
    }
}
