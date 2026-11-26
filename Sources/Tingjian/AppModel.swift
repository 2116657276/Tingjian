import AppKit
import AVFoundation
import Combine
import SwiftUI
import TingjianCore

enum CorrectionState: Equatable {
    case idle
    case running(Int, Int)
    case done(String)
    case failed(String)
}

enum GatewayRefreshState: Equatable {
    case idle
    case loading
    case loaded(Int)
    case failed(String)
}

enum WorkspaceSelection: Equatable, Hashable {
    case currentRecording
    case draft(UUID)
    case directory(URL)
    case document(URL)
    case audio(URL)

    var url: URL? {
        switch self {
        case .currentRecording, .draft: return nil
        case .directory(let url), .document(let url), .audio(let url): return url
        }
    }

    var draftID: UUID? {
        if case .draft(let id) = self { return id }
        return nil
    }
}

struct RecordingDraft: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    // nil uses the current library root.
    var project: URL?
    var placement: RecordingPlacement? = nil

    var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名录音" : trimmed
    }
}

struct DocumentLine: Identifiable, Equatable {
    let id: Int
    let time: String
    let text: String
}

struct DocumentBlockItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case segment(time: String, text: String)
        case gap(start: String, end: String, note: String)
    }

    let id: Int
    let kind: Kind

    var isEmptySegment: Bool {
        if case .segment(_, let text) = kind {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }
}

struct OpenDocument: Equatable {
    var url: URL
    var text: String
    var lines: [DocumentLine]
    var blocks: [DocumentBlockItem] = []
    var blockTimes: [Double?] = []
    var blockTexts: [String] = []
    var parsed: ParsedMarkdownDocument = ParsedMarkdownDocument()
    var linkedAudio: URL?
    var originalDocument: URL? = nil
    var correctedDocument: URL? = nil
    var error: String?
    var revision: DocumentRevision? = nil

    func remapping(_ map: (URL) -> URL) -> OpenDocument {
        OpenDocument(
            url: map(url),
            text: text,
            lines: lines,
            blocks: blocks,
            blockTimes: blockTimes,
            blockTexts: blockTexts,
            parsed: parsed,
            linkedAudio: linkedAudio.map(map),
            originalDocument: originalDocument.map(map),
            correctedDocument: correctedDocument.map(map),
            error: error,
            revision: revision
        )
    }
}

struct DocumentRevision: Equatable {
    let date: Date?
    let size: Int?
    let identity: String?

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey])
        date = values.contentModificationDate
        size = values.fileSize
        identity = values.fileResourceIdentifier.map { String(describing: $0) }
    }
}

struct RenameRequest: Identifiable {
    let id = UUID()
    let url: URL
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 应用级状态:设置、录音器、资料库、文稿浏览与播放、课后纠正。
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// 测试环境变量:TINGJIAN_TEST_ROOT 隔离目录与偏好;TINGJIAN_TEST_AUDIO 仅在同时设置 TINGJIAN_TEST_ROOT 时生效,避免误写入正式资料库。
    static let testRoot: URL? = {
        guard let value = ProcessInfo.processInfo.environment["TINGJIAN_TEST_ROOT"], !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }()
    static let testAudio: URL? = {
        guard testRoot != nil,
              let value = ProcessInfo.processInfo.environment["TINGJIAN_TEST_AUDIO"], !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value)
    }()
    static let defaults: UserDefaults = {
        guard let root = testRoot else { return .standard }
        let suite = Data(root.standardizedFileURL.path.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        return UserDefaults(suiteName: "com.local.tingjian.test." + suite)!
    }()

    @Published var saveRoot: URL {
        didSet {
            documentGeneration += 1
            documentRead?.cancel()
            for task in directoryLoads.values { task.cancel() }
            directoryLoads.removeAll()
            pendingDirectoryReloads.removeAll()
            Self.defaults.set(saveRoot.path, forKey: "saveRoot")
            library = ProjectLibrary(root: saveRoot)
            childrenByDirectory = [:]
            recordingDirectoryFlags = [:]
            directoryErrors = [:]
            expandedDirectories = []
            if selection.url != nil { selection = .directory(saveRoot) }
            openDocument = nil
            openTabs = []
            documentScrollAnchors = [:]
            documentScrollPoints = [:]
            documentsByURL = [:]
            audioPositions = [:]
            audioError = nil
            playback.stop()
            if !recorder.isActive { recorder.saveRoot = saveRoot }
            Task { await loadChildren(saveRoot, force: true) }
        }
    }
    @Published var needsInitialSetup: Bool
    @Published var correctionStyle: CorrectionStyle {
        didSet { Self.defaults.set(correctionStyle.rawValue, forKey: "correctionStyle") }
    }
    @Published var llmEnabled: Bool { didSet { Self.defaults.set(llmEnabled, forKey: "llmEnabled") } }
    @Published var gatewayChoice: GatewayChoice {
        didSet {
            guard gatewayChoice != oldValue else { return }
            Self.defaults.set(gatewayChoice.rawValue, forKey: "gatewayChoice")
            activateGateway()
        }
    }
    @Published var customGatewayAddress: String {
        didSet {
            Self.defaults.set(customGatewayAddress, forKey: "customGatewayAddress")
            if gatewayChoice == .custom, GatewayEndpoint(oldValue) != gatewayEndpoint { activateGateway() }
        }
    }
    var llmURL: String { gatewayChoice == .custom ? customGatewayAddress : gatewayChoice.address }
    var gatewayEndpoint: GatewayEndpoint? { GatewayEndpoint(llmURL) }
    @Published var llmModel: String {
        didSet {
            guard llmModel != oldValue else { return }
            if let gatewayEndpoint {
                Self.defaults.set(llmModel, forKey: "gatewayModel:" + gatewayEndpoint.identity)
            }
            llmEffort = ""
        }
    }
    @Published var llmEffort = ""
    @Published var appearance: AppAppearance {
        didSet {
            Self.defaults.set(appearance.rawValue, forKey: "appearance")
            let value: NSAppearance?
            switch appearance {
            case .system: value = nil
            case .light: value = NSAppearance(named: .aqua)
            case .dark: value = NSAppearance(named: .darkAqua)
            }
            for window in NSApp.windows { window.appearance = value }
        }
    }
    @Published var audioInputUID: String? {
        didSet {
            if let audioInputUID {
                Self.defaults.set(audioInputUID, forKey: "audioInputUID")
                if let matched = inputDevices.first(where: { $0.id == audioInputUID }) {
                    savedAudioInputName = matched.name
                    Self.defaults.set(matched.name, forKey: "audioInputName")
                }
            } else {
                Self.defaults.removeObject(forKey: "audioInputUID")
                savedAudioInputName = nil
                Self.defaults.removeObject(forKey: "audioInputName")
            }
        }
    }
    @Published private(set) var savedAudioInputName: String?
    @Published var librarySortOrder: LibrarySortOrder {
        didSet {
            guard librarySortOrder != oldValue else { return }
            Self.defaults.set(librarySortOrder.rawValue, forKey: "librarySortOrder")
            for (dir, entries) in childrenByDirectory {
                childrenByDirectory[dir] = ProjectLibrary.sortEntries(entries, order: librarySortOrder)
            }
        }
    }
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var gatewayModels: [GatewayModel] = []
    @Published var gatewayState: GatewayRefreshState = .idle
    @Published var apiKey: String {
        didSet { if apiKey != oldValue { invalidateModelRefresh() } }
    }
    @Published var apiKeyStatus: String?
    var refreshToken = UUID()
    var isolatedKeys: [GatewayEndpoint: String] = [:]
    @Published var unfinished: [URL] = []
    @Published var notice: String?
    @Published var atBottom = true
    @Published var trashed: Int?
    @Published private(set) var localBackupCount = 0
    @Published private(set) var localBackupBytes: Int64 = 0
    @Published private(set) var isTrashingBackups = false
    @Published var retranscribe: String?
    @Published var isRetranscribing = false
    @Published var retranscribingAudioURL: URL?

    @Published var selection: WorkspaceSelection
    @Published var drafts: [RecordingDraft] {
        didSet {
            if let data = try? JSONEncoder().encode(drafts) {
                Self.defaults.set(data, forKey: "recordingDrafts")
            }
        }
    }
    @Published var activeDraftID: UUID?
    @Published var activeCourseNameDraft = ""
    @Published var recordingOperation = false
    @Published var placingDrafts: Set<UUID> = []
    @Published var interruptedDrafts: [UUID: URL] = [:]
    @Published var openTabs: [URL] = []
    var documentScrollAnchors: [URL: Int] = [:]
    var documentScrollPoints: [URL: CGPoint] = [:]
    @Published var trashRequest: URL?
    @Published var expandedDirectories: Set<URL> = []
    @Published var childrenByDirectory: [URL: [LibraryEntry]] = [:]
    @Published var recordingDirectoryFlags: [URL: Bool] = [:]
    @Published var directoryErrors: [URL: String] = [:]
    @Published var libraryNotice: String?
    @Published var openDocument: OpenDocument?
    @Published var audioError: String?
    @Published var renameRequest: RenameRequest?
    @Published var syncRenamePrefixes = false
    @Published var newProjectRequest = false
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    var sidebarHiddenForWidth = false
    @Published var showIssues = false
    @Published var stopConfirmationRequested = false
    @Published var seekMessage: String?
    @Published var renameDraft = ""
    @Published var newProjectDraft = ""
    @Published var correctionByDocument: [URL: CorrectionState] = [:]
    @Published var correctionOutputByDocument: [URL: URL] = [:]
    @Published var correctionUsage: [URL: CorrectionUsage] = [:]
    @Published var correctionRunning = false
    @Published var refreshingLibrary = false
    @Published var refreshingContent = false

    @Published var activeDocumentBlockID: Int?
    @Published var followPlaybackScroll = false
    @Published var showEmptyCorrectedSegments = false {
        didSet { updateActiveDocumentBlock(at: playback.position) }
    }
    @Published var isDocumentSearchPresented = false
    @Published var documentSearchQuery = "" {
        didSet { recomputeDocumentSearchMatches(resetIndex: true) }
    }
    @Published var documentSearchMatches: [Int] = []
    @Published var documentSearchCurrentIndex = 0

    var activeSearchBlockID: Int? {
        guard isDocumentSearchPresented, documentSearchMatches.indices.contains(documentSearchCurrentIndex) else { return nil }
        return documentSearchMatches[documentSearchCurrentIndex]
    }

    var isTestMode: Bool { Self.testRoot != nil || Self.testAudio != nil }

    let recorder: Recorder
    let playback: PlaybackModel
    private(set) var library: ProjectLibrary

    var correctionTask: Task<Void, Never>?
    var courseNameSyncTask: Task<Void, Never>?
    var correctionDocument: URL?
    weak var mainWindow: NSWindow?
    var correctionToken = UUID()
    var documentGeneration = 0
    var documentRead: Task<OpenDocument?, Error>?
    var directoryLoads: [URL: Task<Void, Never>] = [:]
    var pendingDirectoryReloads: Set<URL> = []

    var documentsByURL: [URL: OpenDocument] = [:]
    var audioPositions: [URL: Double] = [:]
    private var deviceObservers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var bag: Set<AnyCancellable> = []

    enum NextInput { case configuredDefault, systemDefault, device(String) }
    @Published var nextInput: NextInput = .configuredDefault
    @Published var inputSwitchError: String?

    init() {
        let d = Self.defaults
        playback = PlaybackModel(defaults: d)
        let storedRoot = d.string(forKey: "saveRoot").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let root = storedRoot ?? Self.testRoot?.appendingPathComponent("saved", isDirectory: true) ?? Paths.defaultSaveRoot
        needsInitialSetup = !d.bool(forKey: "initialSetupCompleted")
        correctionStyle = d.string(forKey: "correctionStyle").flatMap(CorrectionStyle.init(rawValue:)) ?? .light
        saveRoot = root
        let storedDrafts = d.data(forKey: "recordingDrafts").flatMap {
            try? JSONDecoder().decode([RecordingDraft].self, from: $0)
        }
        let initialDrafts = storedDrafts ?? [RecordingDraft(id: UUID(), name: "", project: nil)]
        let lastDraft = d.string(forKey: "lastRecordingDraft").flatMap(UUID.init(uuidString:))
        drafts = initialDrafts
        selection = (initialDrafts.first { $0.id == lastDraft } ?? initialDrafts.first)
            .map { .draft($0.id) } ?? .directory(root)
        library = ProjectLibrary(root: root)
        let preferences = GatewayPreferences(defaults: d)
        let choice = preferences.choice
        let endpoint = GatewayEndpoint(choice == .custom ? preferences.customAddress : choice.address)
        llmEnabled = d.object(forKey: "llmEnabled") as? Bool ?? (d.string(forKey: "llmURL") != nil || d.string(forKey: "gatewayChoice") != nil)
        gatewayChoice = choice
        customGatewayAddress = preferences.customAddress
        llmModel = preferences.model(for: endpoint, choice: choice)
        appearance = AppAppearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        audioInputUID = d.string(forKey: "audioInputUID")
        savedAudioInputName = d.string(forKey: "audioInputName")
        librarySortOrder = d.string(forKey: "librarySortOrder").flatMap(LibrarySortOrder.init(rawValue:)) ?? .newestFirst
        apiKey = Self.testRoot == nil && Self.testAudio == nil
            ? Self.readAPIKey(for: endpoint, preferences: preferences) : ""
        let local = Self.testRoot?.appendingPathComponent("local", isDirectory: true) ?? Paths.defaultLocalRoot
        if let audio = Self.testAudio {
            recorder = Recorder(saveRoot: root, localRoot: local, makeSource: { _ in FileSource(url: audio, speed: 1) })
        } else {
            recorder = Recorder(saveRoot: root, localRoot: local)
        }
        reconcileDrafts()
        if storedDrafts == nil, let data = try? JSONEncoder().encode(drafts) {
            d.set(data, forKey: "recordingDrafts")
        }
        refreshInputDevices()
        observeDevices()
        observeRecorder()
        observePlayback()
        installSpacebarPlaybackMonitor()
        DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        Task { await loadChildren(root, force: true) }
        refreshLocalBackupsSummary()
    }

    // MARK: 外观与设备偏好

    var colorScheme: ColorScheme? {
        if appearance == .system {
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        }
        return appearance.colorScheme
    }

    func refreshInputDevices() {
        inputDevices = AudioInputCatalog.devices()
        if let uid = audioInputUID, let matched = inputDevices.first(where: { $0.id == uid }),
           savedAudioInputName != matched.name {
            savedAudioInputName = matched.name
            Self.defaults.set(matched.name, forKey: "audioInputName")
        }
    }

    var savedInputDisplayName: String {
        if let uid = audioInputUID, let matched = inputDevices.first(where: { $0.id == uid }) {
            return matched.name
        }
        return savedAudioInputName ?? "已保存设备"
    }

    var nextInputUID: String? {
        switch nextInput {
        case .configuredDefault: return audioInputUID
        case .systemDefault: return nil
        case .device(let uid): return uid
        }
    }

    var canSelectQuickInput: Bool {
        switch recorder.phase {
        case .recording, .paused: return !recorder.isChangingInput
        case .idle, .finished: return !recordingOperation
        case .starting, .finalizing: return false
        }
    }

    var isUsingConfiguredInput: Bool {
        if case .configuredDefault = nextInput { return true }
        return false
    }

    var quickInputUID: String? {
        recorder.isActive ? recorder.activeInputUID : nextInputUID
    }

    func useConfiguredInput() {
        guard canSelectQuickInput, !recorder.isActive else { return }
        nextInput = .configuredDefault
        inputSwitchError = nil
        recorder.clearMessage()
    }

    func selectQuickInput(_ uid: String?) {
        guard canSelectQuickInput else { return }
        inputSwitchError = nil
        if recorder.phase == .recording || recorder.phase == .paused {
            guard let resolved = uid ?? AudioInputCatalog.defaultUID else {
                inputSwitchError = "没有可用的输入设备"
                return
            }
            Task {
                do {
                    try await recorder.switchInput(to: resolved)
                    recorder.clearMessage()
                } catch {
                    inputSwitchError = "切换输入失败：\(error.localizedDescription)"
                }
                refreshInputDevices()
            }
        } else {
            nextInput = uid.map(NextInput.device) ?? .systemDefault
            recorder.clearMessage()
        }
    }

    func dismissIssue(id: String) {
        switch id {
        case "start", "message":
            recorder.clearMessage()
        case "input-switch":
            inputSwitchError = nil
        case "library":
            libraryNotice = nil
        case "seek":
            seekMessage = nil
        default:
            break
        }
    }

    private func inputDescription(_ uid: String?) -> String {
        guard let uid else { return "系统默认" }
        return inputDevices.first { $0.id == uid }?.name ?? "设备不可用"
    }

    var defaultInputDescription: String { inputDescription(audioInputUID) }

    var quickInputDescription: String {
        if Self.testAudio != nil { return "合成音频" }
        if recorder.isActive { return recorder.activeInputName ?? inputDescription(nextInputUID) }
        let name = inputDescription(nextInputUID)
        return isUsingConfiguredInput ? name : "下次：\(name)"
    }

    var savedInputUnavailable: Bool {
        guard let uid = audioInputUID else { return false }
        return !inputDevices.contains { $0.id == uid }
    }

    var nextInputUnavailable: Bool {
        guard Self.testAudio == nil, let uid = nextInputUID else { return false }
        return !inputDevices.contains { $0.id == uid }
    }

    private func observeDevices() {
        let center = NotificationCenter.default
        deviceObservers = [
            center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshInputDevices() }
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshInputDevices()
                    if let device = note.object as? AVCaptureDevice, device.uniqueID == self.recorder.activeInputUID {
                        await self.recorder.inputDeviceDisconnected(device.uniqueID)
                    }
                }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshInputDevices()
                    await self.reloadLibrary()
                    if case .document(let url) = self.selection {
                        await self.loadDocument(url, force: false)
                    }
                }
            },
        ]
    }

    private func observeRecorder() {
        recorder.onDelivery = { [weak self] files, draftID in
            self?.recordingDelivered(files, draftID: draftID)
        }
        recorder.$phase
            .sink { [weak self] phase in
                guard let self else { return }
                if phase != .recording && phase != .paused {
                    self.courseNameSyncTask?.cancel()
                    self.courseNameSyncTask = nil
                    if self.stopConfirmationRequested {
                        self.stopConfirmationRequested = false
                    }
                }
            }
            .store(in: &bag)
    }

    private func observePlayback() {
        playback.onTimeChanged = { [weak self] seconds in
            self?.updateActiveDocumentBlock(at: seconds)
        }
    }

    private func installSpacebarPlaybackMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                return event
            }
            guard self.canControlPlayback,
                  !self.needsInitialSetup,
                  self.renameRequest == nil,
                  !self.newProjectRequest,
                  self.trashRequest == nil,
                  !self.showIssues,
                  !self.stopConfirmationRequested,
                  NSApp.modalWindow == nil,
                  let keyWindow = NSApp.keyWindow,
                  keyWindow.attachedSheet == nil,
                  !(keyWindow is NSPanel) else {
                return event
            }
            let isMainWindow: Bool = {
                if let main = self.mainWindow {
                    return keyWindow === main
                }
                return keyWindow.identifier?.rawValue == "main"
            }()
            guard isMainWindow else {
                return event
            }
            if let responder = keyWindow.firstResponder,
               responder is NSText || responder is NSTextView || responder is NSTextField {
                return event
            }
            switch self.selection {
            case .document, .audio:
                self.playback.togglePlay()
                return nil
            case .currentRecording, .draft, .directory:
                return event
            }
        }
    }

    // MARK: 初始化与本地备份

    func completeInitialSetup() {
        Self.defaults.set(saveRoot.path, forKey: "saveRoot")
        Self.defaults.set(llmEnabled, forKey: "llmEnabled")
        Self.defaults.set(correctionStyle.rawValue, forKey: "correctionStyle")
        Self.defaults.set(true, forKey: "initialSetupCompleted")
        needsInitialSetup = false
    }

    func chooseSaveRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "选择"; p.message = "选择录音与转写文件的保存位置"
        p.directoryURL = saveRoot.deletingLastPathComponent()
        guard p.runModal() == .OK, let url = p.url else { return }
        if let root = Self.testRoot, !ProjectLibrary.contains(root.resolvingSymlinksInPath(), url.resolvingSymlinksInPath()) {
            libraryNotice = "请选择本次测试目录内的位置。"
            return
        }
        libraryNotice = nil
        saveRoot = url
    }

    func refreshLocalBackupsSummary() {
        let root = recorder.localRoot
        Task { [weak self] in
            let summary = await Task.detached(priority: .utility) {
                Paths.savedLocalBackupSummary(in: root)
            }.value
            guard let self else { return }
            self.localBackupCount = summary.count
            self.localBackupBytes = summary.totalBytes
        }
    }

    func trashSavedBackupsAsync() {
        guard !isTrashingBackups else { return }
        isTrashingBackups = true
        let root = recorder.localRoot
        Task { [weak self] in
            let result: (removed: Int, remaining: LocalBackupSummary) = await Task.detached(priority: .userInitiated) {
                let before = Paths.savedLocalBackupSummary(in: root)
                var removed = 0
                for d in before.directories {
                    if (try? FileManager.default.trashItem(at: d, resultingItemURL: nil)) != nil { removed += 1 }
                }
                let after = Paths.savedLocalBackupSummary(in: root)
                return (removed, after)
            }.value
            guard let self else { return }
            self.isTrashingBackups = false
            self.trashed = result.removed
            self.localBackupCount = result.remaining.count
            self.localBackupBytes = result.remaining.totalBytes
        }
    }
}

func AVAudioFileDuration(_ url: URL) throws -> Double {
    let f = try AVAudioFile(forReading: url)
    let sampleRate = f.processingFormat.sampleRate
    guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
    return Double(f.length) / sampleRate
}
