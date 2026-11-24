import AppKit
import AVFoundation
import Combine
import Darwin
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

struct OpenDocument: Equatable {
    var url: URL
    var text: String
    var lines: [DocumentLine]
    var linkedAudio: URL?
    var error: String?
    var revision: DocumentRevision? = nil
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
            if let audioInputUID { Self.defaults.set(audioInputUID, forKey: "audioInputUID") }
            else { Self.defaults.removeObject(forKey: "audioInputUID") }
        }
    }
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var gatewayModels: [GatewayModel] = []
    @Published var gatewayState: GatewayRefreshState = .idle
    @Published var apiKey: String {
        didSet { if apiKey != oldValue { invalidateModelRefresh() } }
    }
    @Published private(set) var apiKeyStatus: String?
    private var refreshToken = UUID()
    private var isolatedKeys: [GatewayEndpoint: String] = [:]
    @Published var unfinished: [URL] = []
    @Published var notice: String?
    @Published var atBottom = true
    @Published var showUnfinished = false
    @Published var trashed: Int?
    @Published var retranscribe: String?
    @Published private(set) var isRetranscribing = false

    @Published private(set) var selection: WorkspaceSelection
    @Published private(set) var drafts: [RecordingDraft] {
        didSet {
            if let data = try? JSONEncoder().encode(drafts) {
                Self.defaults.set(data, forKey: "recordingDrafts")
            }
        }
    }
    @Published private(set) var activeDraftID: UUID?
    @Published private var recordingOperation = false
    @Published private var placingDrafts: Set<UUID> = []
    @Published private var interruptedDrafts: [UUID: URL] = [:]
    @Published var openTabs: [URL] = []
    @Published var documentScrollAnchors: [URL: Int] = [:]
    @Published var documentScrollPoints: [URL: CGPoint] = [:]
    @Published var trashRequest: URL?
    @Published var expandedDirectories: Set<URL> = []
    @Published var childrenByDirectory: [URL: [LibraryEntry]] = [:]
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
    @Published var seekMessage: String?
    @Published var renameDraft = ""
    @Published var newProjectDraft = ""
    @Published var correctionByDocument: [URL: CorrectionState] = [:]
    @Published var correctionUsage: [URL: CorrectionUsage] = [:]
    @Published private(set) var correctionRunning = false

    var isTestMode: Bool { Self.testRoot != nil || Self.testAudio != nil }

    let recorder: Recorder
    let playback = PlaybackModel()
    private(set) var library: ProjectLibrary

    private var correctionTask: Task<Void, Never>?
    private var correctionDocument: URL?
    private var correctionToken = UUID()
    private var documentGeneration = 0
    private var documentRead: Task<OpenDocument?, Error>?
    private var directoryLoads: [URL: Task<Void, Never>] = [:]
    private var pendingDirectoryReloads: Set<URL> = []

    private var documentsByURL: [URL: OpenDocument] = [:]
    private var audioPositions: [URL: Double] = [:]
    private var deviceObservers: [NSObjectProtocol] = []
    private var bag: Set<AnyCancellable> = []

    init() {
        let d = Self.defaults
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
        DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        Task { await loadChildren(root, force: true) }
    }

    var selectedModel: GatewayModel? { gatewayModels.first { $0.id == llmModel } }
    var effortOptions: [String] {
        if let selectedModel { return selectedModel.levels }
        if let gatewayEndpoint,
           let levels = GatewayPreferences(defaults: Self.defaults).levels(for: gatewayEndpoint, model: llmModel) {
            return levels
        }
        switch (gatewayChoice, llmModel) {
        case (.magpie, GatewayChoice.magpie.defaultModel): return ["low", "high"]
        case (.deepSeek, "deepseek-flash"), (.deepSeek, "deepseek-v4-pro"): return ["low", "high", "max"]
        default: return []
        }
    }

    var defaultEffort: String { GatewayModel.minimumLevel(effortOptions) }
    var effectiveEffort: String { llmEffort.isEmpty ? defaultEffort : llmEffort }

    // MARK: 外观与设备偏好

    var colorScheme: ColorScheme? {
        if appearance == .system {
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        }
        return appearance.colorScheme
    }

    func refreshInputDevices() {
        inputDevices = AudioInputCatalog.devices()
    }

    private enum NextInput { case configuredDefault, systemDefault, device(String) }
    @Published private var nextInput: NextInput = .configuredDefault
    @Published private(set) var inputSwitchError: String?

    private var nextInputUID: String? {
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
                do { try await recorder.switchInput(to: resolved) }
                catch { inputSwitchError = "切换输入失败：\(error.localizedDescription)" }
                refreshInputDevices()
            }
        } else {
            nextInput = uid.map(NextInput.device) ?? .systemDefault
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
    }

    private func recordingDelivered(_ files: DeliveryResult, draftID: UUID?) {
        let showDocument = draftID.map { selection.draftID == $0 } ?? (selection == .currentRecording)
        if let draftID {
            drafts.removeAll { $0.id == draftID }
            interruptedDrafts[draftID] = nil
        }
        activeDraftID = nil
        if showDocument {
            if ProjectLibrary.contains(saveRoot, files.markdown) { select(.document(files.markdown)) }
            else { select(.directory(saveRoot)) }
        }
        refreshUnfinished()
        guard ProjectLibrary.contains(saveRoot, files.directory) else { return }
        Task {
            await loadChildren(files.directory.deletingLastPathComponent(), force: true)
            await loadChildren(files.directory, force: true)
        }
    }

    // MARK: 资料库

    var currentDirectory: URL {
        switch selection {
        case .directory(let url): return url
        case .document(let url), .audio(let url): return url.deletingLastPathComponent()
        case .currentRecording, .draft: return saveRoot
        }
    }

    func loadChildren(_ directory: URL, force: Bool = false) async {
        let dir = directory.standardizedFileURL
        if !force, childrenByDirectory[dir] != nil { return }
        if let existing = directoryLoads[dir] {
            if force { pendingDirectoryReloads.insert(dir) }
            await existing.value
            return
        }
        let source = library
        let loadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.library === source {
                    self.directoryLoads[dir] = nil
                    self.pendingDirectoryReloads.remove(dir)
                }
            }
            repeat {
                self.pendingDirectoryReloads.remove(dir)
                let result = await Task.detached {
                    try Task.checkCancellation()
                    return try await source.children(of: dir, classifyDirectories: false)
                }.result
                guard !Task.isCancelled, self.library === source else { return }
                switch result {
                case .success(let entries):
                    if self.childrenByDirectory[dir] != entries { self.childrenByDirectory[dir] = entries }
                    self.directoryErrors[dir] = nil
                case .failure(let error):
                    if case LibraryError.notFound = error, dir == self.saveRoot.standardizedFileURL {
                        self.childrenByDirectory[dir] = []
                        self.directoryErrors[dir] = nil
                    } else {
                        if case LibraryError.notFound = error { self.childrenByDirectory[dir] = nil }
                        self.directoryErrors[dir] = error.localizedDescription
                    }
                }
            } while !Task.isCancelled && self.pendingDirectoryReloads.contains(dir)
        }
        directoryLoads[dir] = loadTask
        await loadTask.value
    }

    func isRecordingDirectory(_ url: URL) -> Bool {
        childrenByDirectory[url.standardizedFileURL]?.contains { $0.kind == .audio } == true
    }

    @Published private(set) var refreshingLibrary = false
    @Published private(set) var refreshingContent = false

    func refreshLibrary() async {
        guard !refreshingLibrary else { return }
        refreshingLibrary = true
        defer { refreshingLibrary = false }
        let clock = ContinuousClock()
        let feedbackEnd = clock.now + .milliseconds(300)
        await reloadLibrary(includeSelectedDirectory: false)
        try? await clock.sleep(until: feedbackEnd)
    }

    func refreshOpenContent() async {
        guard !refreshingContent else { return }
        refreshingContent = true
        defer { refreshingContent = false }
        let clock = ContinuousClock()
        let feedbackEnd = clock.now + .milliseconds(300)
        await reloadOpenContent()
        try? await clock.sleep(until: feedbackEnd)
    }

    func reloadLibrary(includeSelectedDirectory: Bool = true) async {
        var directories = expandedDirectories
        directories.insert(saveRoot.standardizedFileURL)
        if includeSelectedDirectory, case .directory(let dir) = selection { directories.insert(dir.standardizedFileURL) }
        let source = library
        for dir in directories.sorted(by: { $0.path < $1.path }) {
            guard !Task.isCancelled, library === source else { return }
            await loadChildren(dir, force: true)
        }
    }

    func toggleExpansion(_ directory: URL) {
        let dir = directory.standardizedFileURL
        if expandedDirectories.contains(dir) {
            expandedDirectories.remove(dir)
        } else {
            expandedDirectories.insert(dir)
            Task { await loadChildren(dir) }
        }
    }

    func select(_ newSelection: WorkspaceSelection) {
        documentGeneration += 1
        documentRead?.cancel()
        audioError = nil
        seekMessage = nil
        if let currentAudio = playback.currentURL?.standardizedFileURL {
            audioPositions[currentAudio] = playback.position
        }
        playback.stop()
        selection = newSelection
        switch newSelection {
        case .currentRecording, .draft:
            if let id = newSelection.draftID { Self.defaults.set(id.uuidString, forKey: "lastRecordingDraft") }
            playback.stop()
            openDocument = nil
            audioError = nil
        case .directory(let url):
            openDocument = nil
            audioError = nil
            playback.stop()
            Task { await loadChildren(url) }
        case .document(let url):
            ensureTab(url)
            openDocument = documentsByURL[url.standardizedFileURL]
            let generation = documentGeneration
            Task { await loadDocument(url, generation: generation, force: false) }
        case .audio(let url):
            openDocument = nil
            ensureTab(url)
            let generation = documentGeneration
            Task { await loadAudio(url, at: audioPositions[url.standardizedFileURL] ?? 0, generation: generation) }
        }
    }

    private func ensureTab(_ url: URL) {
        let key = url.standardizedFileURL
        if !openTabs.contains(key) { openTabs.append(key) }
    }

    func activateTab(_ url: URL) {
        let key = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: key.path) else {
            libraryNotice = "文件已移动或不存在:\(key.path)"
            return
        }
        if ProjectLibrary.isAudio(key) { select(.audio(key)) }
        else { select(.document(key)) }
    }

    func closeTab(_ url: URL) {
        let key = url.standardizedFileURL
        let index = openTabs.firstIndex(of: key)
        guard let index else { return }
        openTabs.removeAll { $0 == key }
        documentScrollAnchors[key] = nil
        documentScrollPoints[key] = nil
        documentsByURL[key] = nil
        if selection.url?.standardizedFileURL == key {
            selectTabAfterClosing(at: index)
        }
    }

    func closeActiveTab() {
        if let tab = selectedFileTab { closeTab(tab) }
    }

    func closeOtherTabs(keeping url: URL) {
        let key = url.standardizedFileURL
        for tab in openTabs where tab != key {
            documentScrollAnchors[tab] = nil
            documentScrollPoints[tab] = nil
            documentsByURL[tab] = nil
        }
        openTabs = openTabs.contains(key) ? [key] : []
        activateTab(key)
    }

    func closeTabsToRight(of url: URL) {
        let key = url.standardizedFileURL
        guard let index = openTabs.firstIndex(of: key) else { return }
        let removed = Array(openTabs.dropFirst(index + 1))
        for tab in removed {
            documentScrollAnchors[tab] = nil
            documentScrollPoints[tab] = nil
            documentsByURL[tab] = nil
        }
        openTabs = Array(openTabs.prefix(index + 1))
        if let active = selection.url?.standardizedFileURL, removed.contains(active) { activateTab(key) }
    }

    var selectedFileTab: URL? {
        guard let url = selection.url?.standardizedFileURL, openTabs.contains(url) else { return nil }
        return url
    }

    var canCloseActiveTab: Bool { selectedFileTab != nil }

    private func selectTabAfterClosing(at index: Int) {
        if openTabs.isEmpty { select(.directory(saveRoot)) }
        else { activateTab(openTabs[min(index, openTabs.count - 1)]) }
    }

    func activateRelativeTab(_ offset: Int) {
        guard !openTabs.isEmpty else { return }
        let index = selectedFileTab.flatMap { openTabs.firstIndex(of: $0) }
        let next = index.map { ($0 + offset + openTabs.count) % openTabs.count }
            ?? (offset < 0 ? openTabs.count - 1 : 0)
        activateTab(openTabs[next])
    }

    func scrollAnchor(for url: URL) -> Int? { documentScrollAnchors[url.standardizedFileURL] }

    func setScrollAnchor(_ id: Int?, for url: URL) {
        documentScrollAnchors[url.standardizedFileURL] = id
    }

    func scrollPoint(for url: URL) -> CGPoint? { documentScrollPoints[url.standardizedFileURL] }

    func setScrollPoint(_ point: CGPoint?, for url: URL) {
        documentScrollPoints[url.standardizedFileURL] = point
    }

    func requestTrash(_ url: URL) {
        guard url.standardizedFileURL != saveRoot.standardizedFileURL else {
            libraryNotice = "不能移除资料库根目录"
            return
        }
        trashRequest = url.standardizedFileURL
    }

    func requestTrashSelection() {
        guard let url = selection.url else { return }
        requestTrash(url)
    }

    func confirmTrash() {
        guard let url = trashRequest else { return }
        trashRequest = nil
        Task { await trashEntry(url) }
    }

    private func trashEntry(_ url: URL) async {
        await syncProtection()
        let target = url.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        let activeAudio = playback.currentURL
        let selectedInside = selection.url.map { ProjectLibrary.contains(target, $0) } ?? false
        do {
            try await library.trash(target)
            if selectedInside || activeAudio.map({ ProjectLibrary.contains(target, $0) }) == true { playback.stop() }
            let removedTabs = openTabs.filter { ProjectLibrary.contains(target, $0) }
            openTabs.removeAll { ProjectLibrary.contains(target, $0) }
            for tab in removedTabs {
                documentsByURL[tab] = nil
                documentScrollAnchors[tab] = nil
                documentScrollPoints[tab] = nil
                audioPositions[tab] = nil
                correctionUsage[tab] = nil
                correctionByDocument[tab] = nil
            }
            if let docURL = openDocument?.url, ProjectLibrary.contains(target, docURL) { openDocument = nil }
            if let selectedURL = selection.url, ProjectLibrary.contains(target, selectedURL) {
                select(.directory(parent))
            }
            await loadChildren(parent, force: true)
            libraryNotice = nil
        } catch {
            libraryNotice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func collapseAllDirectories() { expandedDirectories.removeAll() }

    func navigateSidebar(_ direction: MoveCommandDirection) {
        let entries = visibleSidebarEntries()
        let current = selection.url?.standardizedFileURL
        switch direction {
        case .up, .down:
            let step = direction == .up ? -1 : 1
            guard !entries.isEmpty else { return }
            let index = current.flatMap { selected in entries.firstIndex(where: { $0.url.standardizedFileURL == selected }) }
            let next = min(max(0, (index ?? (step > 0 ? -1 : entries.count)) + step), entries.count - 1)
            selectEntry(entries[next])
        case .right:
            if let current, isRootDirectory(current) {
                if let first = childrenByDirectory[current]?.first { selectEntry(first) }
                return
            }
            guard let current, let entry = entries.first(where: { $0.url.standardizedFileURL == current }), entry.kind == .directory else { return }
            if !expandedDirectories.contains(current) { toggleExpansion(current) }
            else if let child = childrenByDirectory[current]?.first { selectEntry(child) }
        case .left:
            guard let current else { return }
            if expandedDirectories.contains(current) { toggleExpansion(current) }
            else if current != saveRoot.standardizedFileURL { select(.directory(current.deletingLastPathComponent())) }
        default:
            break
        }
    }

    private func selectEntry(_ entry: LibraryEntry) {
        switch entry.kind {
        case .directory:
            select(.directory(entry.url))
        case .document:
            select(.document(entry.url))
        case .audio:
            select(.audio(entry.url))
        }
    }

    private func visibleSidebarEntries() -> [LibraryEntry] {
        func walk(_ entries: [LibraryEntry]) -> [LibraryEntry] {
            entries.flatMap { entry in
                [entry] + (entry.kind == .directory && expandedDirectories.contains(entry.url.standardizedFileURL)
                           ? walk(childrenByDirectory[entry.url.standardizedFileURL] ?? []) : [])
            }
        }
        let root = saveRoot.standardizedFileURL
        let rootEntry = LibraryEntry(url: root, name: "资料库根目录", kind: .directory, isRecordingBundle: false)
        return [rootEntry] + walk(childrenByDirectory[root] ?? [])
    }

    // MARK: 新建、改名、移动

    func isRootDirectory(_ url: URL) -> Bool {
        url.standardizedFileURL == saveRoot.standardizedFileURL
    }

    var canModifyLibrarySelection: Bool {
        selection.url.map { !isRootDirectory($0) } ?? false
    }

    func draft(id: UUID) -> RecordingDraft? { drafts.first { $0.id == id } }

    func newRecording(in directory: URL? = nil) {
        let project = directory.flatMap { isRootDirectory($0) ? nil : $0.standardizedFileURL }
        let draft = RecordingDraft(id: UUID(), name: "", project: project)
        drafts.append(draft)
        select(.draft(draft.id))
    }

    func renameDraft(id: UUID, to name: String) {
        guard !isDraftLocked(id), let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].name = name
    }

    func useRoot(for id: UUID) {
        guard !isDraftLocked(id), let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        if drafts[index].placement != nil {
            Task { await placeDraft(id, in: saveRoot) }
        } else {
            drafts[index].project = nil
        }
    }

    func placeDraft(_ id: UUID, in parent: URL) async {
        guard let draft = draft(id: id), !isDraftLocked(id) else { return }
        placingDrafts.insert(id)
        defer { placingDrafts.remove(id) }
        let source = library
        await syncProtection()
        do {
            let placement: RecordingPlacement
            if let previous = draft.placement, (try? previous.validateEmpty()) != nil {
                placement = try await source.moveRecordingPlacement(previous, into: parent)
            } else {
                placement = try await source.createRecordingPlacement(named: draft.title, in: parent)
            }
            guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
            if let previous = draft.placement, previous.directory != placement.directory,
               previous.directory.path != placement.directory.path,
               !FileManager.default.fileExists(atPath: previous.directory.path) {
                remapPaths(from: previous.directory, to: placement.directory)
            }
            drafts[index].placement = placement
            if source === library {
                expandedDirectories.insert(parent.standardizedFileURL)
                if let previous = draft.placement {
                    await loadChildren(previous.directory.deletingLastPathComponent(), force: true)
                }
                await loadChildren(parent, force: true)
            }
            libraryNotice = nil
        } catch {
            libraryNotice = error.localizedDescription
        }
    }

    func chooseDraftPlacement(_ id: UUID) {
        guard !isDraftLocked(id), let parent = choosePlacementParent(message: "选择录音文件夹所在的位置") else { return }
        Task { await placeDraft(id, in: parent) }
    }

    private func choosePlacementParent(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.directoryURL = saveRoot
        panel.message = message
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let parent = panel.url?.standardizedFileURL else { return nil }
        guard ProjectLibrary.contains(saveRoot, parent),
              ProjectLibrary.contains(saveRoot.resolvingSymlinksInPath(), parent.resolvingSymlinksInPath()) else {
            libraryNotice = "请选择资料库中的文件夹。"
            return nil
        }
        return parent
    }

    var canChangePendingSaveDestination: Bool { saveNeedsRetry && recorder.phase == .finished }

    func choosePendingSaveDestination() {
        guard canChangePendingSaveDestination,
              let parent = choosePlacementParent(message: "选择新位置保存已录制的音频和文稿") else { return }
        Task { await recorder.retrySave(in: parent) }
    }

    func closeDraft(_ id: UUID) {
        guard !isDraftLocked(id), let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts.remove(at: index)
        if selection.draftID == id {
            if drafts.isEmpty { select(.directory(saveRoot)) }
            else { select(.draft(drafts[min(index, drafts.count - 1)].id)) }
        }
    }

    func isDraftLocked(_ id: UUID) -> Bool {
        activeDraftID == id || interruptedDrafts[id] != nil || placingDrafts.contains(id)
    }

    func recordingDestination(for id: UUID) -> URL? {
        if activeDraftID == id, recorder.isActive || saveNeedsRetry {
            return recorder.sessionDestination
        }
        if let dir = interruptedDrafts[id], let destination = SessionStore.readInfo(dir: dir)?.sessionDestination {
            return destination
        }
        return draft(id: id).map { $0.placement?.directory ?? $0.project ?? saveRoot }
    }

    func recordingTargetIssue(for id: UUID) -> String? {
        guard let draft = draft(id: id), !isDraftLocked(id),
              let project = draft.placement?.directory ?? draft.project else { return nil }
        guard ProjectLibrary.contains(saveRoot, project),
              ProjectLibrary.contains(saveRoot.resolvingSymlinksInPath(), project.resolvingSymlinksInPath()) else {
            return "目标项目不在当前资料库中。请改存到根目录。"
        }
        if let placement = draft.placement {
            do { try placement.validateEmpty() }
            catch { return error.localizedDescription }
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return "目标项目已不存在。请改存到根目录。" }
        return nil
    }

    private var saveNeedsRetry: Bool {
        switch recorder.save {
        case .pending, .failed: return true
        default: return false
        }
    }

    var recordingBusy: Bool { recordingOperation || recorder.isActive || saveNeedsRetry }

    var isRecordingSelection: Bool {
        if let activeDraftID { return selection.draftID == activeDraftID }
        return selection == .currentRecording
    }

    var hasCurrentRecording: Bool { recordingBusy || !unfinished.isEmpty }

    func showCurrentRecording() {
        if let id = activeDraftID ?? unfinished.first.flatMap({ SessionStore.readInfo(dir: $0)?.draftID }),
           draft(id: id) != nil {
            select(.draft(id))
        } else if hasCurrentRecording {
            select(.currentRecording)
        }
    }

    func beginRecording() {
        guard canStartRecording, let id = selection.draftID, let draft = draft(id: id),
              let destination = recordingDestination(for: id) else { return }
        if let issue = recordingTargetIssue(for: id) {
            libraryNotice = issue
            return
        }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        recorder.preferredInputUID = nextInputUID
        inputSwitchError = nil
        libraryNotice = nil
        recordingOperation = true
        activeDraftID = id
        Task {
            if await recorder.start(course: name, draftID: id, destination: destination, placement: draft.placement) {
                nextInput = .configuredDefault
            }
            recordingOperation = false
            if !recorder.isActive && !saveNeedsRetry { activeDraftID = nil }
        }
    }

    var canStartRecording: Bool {
        guard let id = selection.draftID else { return false }
        return !recordingBusy && !isDraftLocked(id) && !nextInputUnavailable
    }

    func requestRename(_ url: URL) {
        guard !isRootDirectory(url) else { return }
        guard !recorder.isActive else {
            libraryNotice = "录音进行中不能改名,请先结束录音。"
            return
        }
        renameRequest = RenameRequest(url: url)
    }

    func requestRenameSelection() {
        if let url = selection.url { requestRename(url) }
    }

    func createProject(named name: String) async {
        await syncProtection()
        let parent = currentDirectory.standardizedFileURL
        if !FileManager.default.fileExists(atPath: parent.path) {
            guard parent == saveRoot.standardizedFileURL else {
                libraryNotice = "目标文件夹已不存在:\(parent.path)。请刷新后重试。"
                return
            }
            do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
            catch {
                libraryNotice = "无法创建资料库根目录:\(error.localizedDescription)"
                return
            }
        }
        do {
            let url = try await library.createProject(named: name, in: parent)
            expandedDirectories.insert(parent.standardizedFileURL)
            await loadChildren(parent, force: true)
            select(.directory(url))
            libraryNotice = nil
        } catch {
            libraryNotice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func renameEntry(_ url: URL, to name: String, syncFilePrefixes: Bool = false) async {
        documentGeneration += 1
        let generation = documentGeneration
        await syncProtection()
        let playing = playback.currentURL
        let position = playback.position
        playback.stop()
        do {
            let files = syncFilePrefixes ? (try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])).filter {
                let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values?.isRegularFile == true && values?.isSymbolicLink != true && $0.lastPathComponent.hasPrefix(url.lastPathComponent)
            } : []
            let renamed = try await library.rename(url, to: name, syncFilePrefixes: syncFilePrefixes)
            remapPaths(from: url, to: renamed)
            for file in files {
                let old = renamed.appendingPathComponent(file.lastPathComponent)
                let newName = renamed.lastPathComponent + file.lastPathComponent.dropFirst(url.lastPathComponent.count)
                remapPaths(from: old, to: renamed.appendingPathComponent(String(newName)))
            }
            documentsByURL.removeAll()
            await loadChildren(renamed.deletingLastPathComponent(), force: true)
            let renamedDir = renamed.standardizedFileURL
            var isRenamedDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: renamedDir.path, isDirectory: &isRenamedDirectory),
               isRenamedDirectory.boolValue,
               expandedDirectories.contains(renamedDir)
                || childrenByDirectory[renamedDir] != nil
                || currentDirectory.standardizedFileURL == renamedDir {
                await loadChildren(renamedDir, force: true)
            }
            if generation == documentGeneration, let playing {
                var mapped = remapURL(playing, from: url, to: renamed)
                for file in files {
                    let old = renamed.appendingPathComponent(file.lastPathComponent)
                    let newName = renamed.lastPathComponent + file.lastPathComponent.dropFirst(url.lastPathComponent.count)
                    mapped = remapURL(mapped, from: old, to: renamed.appendingPathComponent(String(newName)))
                }
                audioPositions[mapped.standardizedFileURL] = position
                if FileManager.default.fileExists(atPath: mapped.path) {
                    try? await playback.load(mapped)
                    if generation == documentGeneration {
                        playback.seek(to: position)
                        playback.pause()
                    }
                } else {
                    playback.stop()
                }
            }
            if generation == documentGeneration, case .document(let selected) = selection {
                await loadDocument(selected, generation: generation)
            }
            libraryNotice = nil
        } catch {
            libraryNotice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if generation == documentGeneration { await reloadOpenContent() }
        }
    }

    func requestMove(_ item: URL, into directory: URL? = nil) {
        guard !isRootDirectory(item) else { return }
        guard !recorder.isActive else {
            libraryNotice = "录音结束后再移动文件。"
            return
        }
        Task {
            do {
                let plan = try await library.movePlan(for: item)
                guard !recorder.isActive else { return }
                guard let destination = directory ?? chooseMoveDestination(for: plan) else { return }
                if directory != nil || !plan.recordings.isEmpty {
                    guard plan.sources.first?.deletingLastPathComponent().resolvingSymlinksInPath()
                            != destination.resolvingSymlinksInPath() else {
                        libraryNotice = "该项目已在此文件夹中。"
                        return
                    }
                    let alert = NSAlert()
                    alert.messageText = plan.recordings.isEmpty ? "移动「" + plan.item.lastPathComponent + "」？" : "移动这份录音？"
                    let target = "目标文件夹为「" + destination.lastPathComponent + "」。"
                    alert.informativeText = ([target] + plan.recordings).joined(separator: "\n")
                    alert.addButton(withTitle: "移动")
                    alert.addButton(withTitle: "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                await moveEntry(plan, into: destination)
            } catch { libraryNotice = error.localizedDescription }
        }
    }

    private func moveEntry(_ plan: LibraryMovePlan, into directory: URL) async {
        guard !recorder.isActive, let source = plan.sources.first,
              source.deletingLastPathComponent().resolvingSymlinksInPath() != directory.resolvingSymlinksInPath() else { return }
        documentGeneration += 1
        let generation = documentGeneration
        await syncProtection()
        let playing = playback.currentURL
        let position = playback.position
        playback.stop()
        do {
            let destinations = try await library.move(plan, into: directory)
            let changes = Array(zip(plan.sources, destinations))
            for (before, after) in changes { remapPaths(from: before, to: after) }
            documentsByURL.removeAll()
            await loadChildren(source.deletingLastPathComponent(), force: true)
            await loadChildren(directory, force: true)
            for moved in destinations {
                let movedDir = moved.standardizedFileURL
                var isMovedDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: movedDir.path, isDirectory: &isMovedDirectory),
                      isMovedDirectory.boolValue else { continue }
                if expandedDirectories.contains(movedDir)
                    || childrenByDirectory[movedDir] != nil
                    || currentDirectory.standardizedFileURL == movedDir {
                    await loadChildren(movedDir, force: true)
                }
            }
            if generation == documentGeneration, let playing {
                let mapped = changes.reduce(playing) { remapURL($0, from: $1.0, to: $1.1) }
                audioPositions[mapped.standardizedFileURL] = position
                if FileManager.default.fileExists(atPath: mapped.path) {
                    try? await playback.load(mapped)
                    if generation == documentGeneration {
                        playback.seek(to: position)
                        playback.pause()
                    }
                } else {
                    playback.stop()
                }
            }
            if generation == documentGeneration, case .document(let selected) = selection {
                await loadDocument(selected, generation: generation)
            }
            libraryNotice = nil
        } catch {
            libraryNotice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if generation == documentGeneration { await reloadOpenContent() }
        }
    }

    private func chooseMoveDestination(for plan: LibraryMovePlan) -> URL? {
        let url = plan.sources.first ?? plan.item
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = plan.recordings.isEmpty ? url.deletingLastPathComponent() : saveRoot
        panel.message = plan.recordings.isEmpty ? "为「" + url.lastPathComponent + "」选择目标文件夹" : "为这份录音选择目标文件夹"
        panel.prompt = "移动到这里"
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        guard ProjectLibrary.contains(saveRoot, destination) else {
            libraryNotice = "只能移动到当前资料库内:\(saveRoot.path)"
            return nil
        }
        return destination
    }

    private func syncProtection() async {
        var urls: [URL] = []
        switch recorder.phase {
        case .starting, .recording, .paused, .finalizing:
            urls.append(recorder.sessionDestination)
            if let local = recorder.localDir { urls.append(local) }
        case .idle, .finished:
            break
        }
        if case .pending = recorder.save { urls.append(recorder.sessionDestination) }
        if case .failed = recorder.save { urls.append(recorder.sessionDestination) }
        if let doc = correctionDocument { urls.append(doc) }
        await library.setProtected(urls)
    }

    private func remapPaths(from old: URL, to new: URL) {
        let map = pathMapper(from: old, to: new)
        expandedDirectories = Set(expandedDirectories.map(map))
        let cachedChildren = childrenByDirectory
        childrenByDirectory = cachedChildren.filter { map($0.key) == $0.key }
        for (directory, entries) in cachedChildren {
            let target = map(directory)
            guard target != directory else { continue }
            childrenByDirectory[target] = entries.map { entry in
                let url = map(entry.url)
                return LibraryEntry(url: url, name: url.lastPathComponent, kind: entry.kind, isRecordingBundle: entry.isRecordingBundle)
            }
        }
        directoryErrors = directoryErrors.filter { map($0.key) == $0.key }
        for index in drafts.indices where activeDraftID != drafts[index].id && interruptedDrafts[drafts[index].id] == nil {
            if let placement = drafts[index].placement, map(placement.directory) != placement.directory {
                drafts[index].placement?.directory = map(placement.directory)
            }
            if let project = drafts[index].project, map(project) != project {
                drafts[index].project = map(project)
            }
        }
        switch selection {
        case .currentRecording, .draft:
            break
        case .directory(let url): selection = .directory(map(url))
        case .document(let url): selection = .document(map(url))
        case .audio(let url): selection = .audio(map(url))
        }
        // A file moved from an existing tab takes precedence over a stale destination tab.
        func remapped<Value>(_ values: [URL: Value]) -> [URL: Value] {
            var result = values.filter { map($0.key) == $0.key }
            for (url, value) in values {
                let target = map(url)
                if target != url { result[target] = value }
            }
            return result
        }
        correctionByDocument = remapped(correctionByDocument)
        correctionUsage = remapped(correctionUsage)
        if let doc = correctionDocument { correctionDocument = map(doc) }
        let movedTabs = Set(openTabs.compactMap { map($0) == $0 ? nil : map($0) })
        var seen: Set<URL> = []
        openTabs = openTabs.compactMap { url in
            let mapped = map(url)
            guard mapped != url || !movedTabs.contains(url), seen.insert(mapped).inserted else { return nil }
            return mapped
        }
        documentScrollAnchors = remapped(documentScrollAnchors)
        documentScrollPoints = remapped(documentScrollPoints)
        audioPositions = remapped(audioPositions)
        documentsByURL = remapped(documentsByURL).mapValues { doc in
            OpenDocument(url: map(doc.url), text: doc.text, lines: doc.lines,
                         linkedAudio: doc.linkedAudio.map(map), error: doc.error)
        }
        if let doc = openDocument {
            let mapped = map(doc.url)
            openDocument = OpenDocument(url: mapped, text: doc.text, lines: doc.lines,
                                        linkedAudio: doc.linkedAudio.map(map), error: doc.error)
        }
    }

    func remapURL(_ url: URL, from old: URL, to new: URL) -> URL {
        pathMapper(from: old, to: new)(url)
    }

    private func pathMapper(from old: URL, to new: URL) -> (URL) -> URL {
        let root = saveRoot.standardizedFileURL
        var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedRoot: URL
        if realpath(root.path, &resolvedPath) != nil {
            resolvedRoot = URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: true)
        } else {
            resolvedRoot = root
        }
        func canonical(_ value: URL) -> URL {
            let path = value.standardizedFileURL
            guard ProjectLibrary.contains(root, path) else { return path }
            var result = resolvedRoot
            for component in path.pathComponents.dropFirst(root.pathComponents.count) {
                result.appendPathComponent(component)
            }
            return result
        }
        let resolvedOld = canonical(old)
        return { url in
            let resolvedURL = canonical(url)
            guard ProjectLibrary.contains(resolvedOld, resolvedURL) else { return url }
            let suffix = resolvedURL.pathComponents.dropFirst(resolvedOld.pathComponents.count)
            return suffix.reduce(new.standardizedFileURL) { $0.appendingPathComponent($1) }.standardizedFileURL
        }
    }

    // MARK: 文稿与播放

    func loadDocument(_ url: URL, generation requestedGeneration: Int? = nil, force: Bool = true) async {
        let generation = requestedGeneration ?? documentGeneration
        guard generation == documentGeneration, selection == .document(url) else { return }
        let key = url.standardizedFileURL
        if let audio = playback.currentURL?.standardizedFileURL { audioPositions[audio] = playback.position }
        let cached = documentsByURL[key]
        documentRead?.cancel()
        let task = Task.detached(priority: .userInitiated) { () throws -> OpenDocument? in
            let revision = try DocumentRevision(url: key)
            if !force, let cached, cached.revision == revision { return nil }
            try Task.checkCancellation()
            let text = try String(contentsOf: key, encoding: .utf8)
            try Task.checkCancellation()
            let lines = MarkdownDoc.parseSegments(text).enumerated().map {
                DocumentLine(id: $0.offset, time: $0.element.time, text: $0.element.text)
            }
            try Task.checkCancellation()
            return OpenDocument(url: url, text: text, lines: lines,
                                linkedAudio: ProjectLibrary.linkedAudio(in: text, beside: key), error: nil, revision: revision)
        }
        documentRead = task
        do {
            let loaded = try await task.value
            guard !task.isCancelled, generation == documentGeneration else { return }
            guard let doc = loaded ?? cached else { return }
            if let loaded {
                openDocument = loaded
                documentsByURL[key] = loaded
            }
            if let audio = doc.linkedAudio {
                if playback.currentURL?.standardizedFileURL != audio.standardizedFileURL || force {
                    await loadAudio(audio, at: audioPositions[audio.standardizedFileURL] ?? 0, generation: generation)
                }
            } else {
                playback.stop()
                audioError = nil
            }
        } catch {
            guard !task.isCancelled, generation == documentGeneration else { return }
            openDocument = OpenDocument(url: url, text: "", lines: [], linkedAudio: nil,
                                        error: "无法读取文稿：" + error.localizedDescription)
            documentsByURL[key] = nil
            playback.stop()
        }
    }

    func loadAudio(_ url: URL, at position: Double = 0, generation requestedGeneration: Int? = nil) async {
        let generation = requestedGeneration ?? documentGeneration
        guard generation == documentGeneration else { return }
        audioError = nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            playback.stop()
            audioError = "文件已移动或不存在:\(url.path)。请刷新项目列表。"
            return
        }
        do {
            try await playback.load(url)
            guard generation == documentGeneration else { return }
            if position > 0 { playback.seek(to: position) }
        }
        catch {
            guard generation == documentGeneration else { return }
            audioError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func openLinkedAudio(for document: URL) {
        let generation = documentGeneration
        Task {
            let audio = await Task.detached {
                guard let text = try? String(contentsOf: document, encoding: .utf8) else { return Optional<URL>.none }
                return ProjectLibrary.linkedAudio(in: text, beside: document)
            }.value
            guard generation == documentGeneration else { return }
            guard let audio else {
                libraryNotice = "未找到可播放的关联音频：" + document.lastPathComponent
                return
            }
            select(.audio(audio))
        }
    }

    func reloadOpenContent() async {
        switch selection {
        case .document(let url): await loadDocument(url)
        case .audio(let url): await loadAudio(url, at: playback.currentURL != nil ? playback.position : (audioPositions[url.standardizedFileURL] ?? 0))
        case .directory(let url): await loadChildren(url, force: true)
        case .draft, .currentRecording:
            refreshUnfinished()
        }
    }

    func seek(toTimecode time: String) async {
        let generation = documentGeneration
        guard !recorder.isActive, let audio = openDocument?.linkedAudio,
              let seconds = Self.parseTimecode(time) else { return }
        if playback.currentURL?.standardizedFileURL != audio.standardizedFileURL {
            await loadAudio(audio, generation: generation)
        }
        guard generation == documentGeneration, !recorder.isActive else { return }
        guard playback.currentURL?.standardizedFileURL == audio.standardizedFileURL, playback.canSeek else {
            seekMessage = audioError ?? "关联音频暂时无法播放"
            return
        }
        guard seconds < playback.duration else {
            seekMessage = "该时间点超出音频时长"
            return
        }
        playback.seek(to: seconds)
        seekMessage = nil
    }

    static func parseTimecode(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    func linkedAudio(in text: String, nextTo url: URL) -> URL? {
        ProjectLibrary.linkedAudio(in: text, beside: url)
    }

    // MARK: 网关与模型

    private func invalidateModelRefresh() {
        refreshToken = UUID()
        gatewayModels = []
        gatewayState = .idle
        apiKeyStatus = nil
    }

    private func activateGateway() {
        invalidateModelRefresh()
        let preferences = GatewayPreferences(defaults: Self.defaults)
        llmModel = preferences.model(for: gatewayEndpoint, choice: gatewayChoice)
        llmEffort = ""
        if isTestMode {
            apiKey = gatewayEndpoint.flatMap { isolatedKeys[$0] } ?? ""
        } else {
            apiKey = Self.readAPIKey(for: gatewayEndpoint, preferences: preferences)
        }
    }

    private static func readAPIKey(for endpoint: GatewayEndpoint?, preferences: GatewayPreferences) -> String {
        guard let endpoint else { return "" }
        if let key = Keychain.read(gateway: endpoint) { return key }
        guard preferences.allowsLegacyKey(for: endpoint), let key = Keychain.read() else { return "" }
        Keychain.write(key, gateway: endpoint)
        return key
    }

    /// 从网关拉取模型清单；配置改变后，正在进行的请求失去更新资格。
    func refreshModels(session: URLSession = .shared) async {
        guard gatewayState != .loading, let endpoint = gatewayEndpoint else { return }
        let token = UUID()
        refreshToken = token
        gatewayState = .loading
        do {
            let list = try await GatewayModel.fetch(baseURL: llmURL, apiKey: apiKey, session: session)
            guard refreshToken == token else { return }
            gatewayModels = list
            gatewayState = .loaded(list.count)
            let preferences = GatewayPreferences(defaults: Self.defaults)
            for model in list {
                preferences.saveLevels(model.levels, for: endpoint, model: model.id)
            }
            if let selectedModel, !selectedModel.levels.contains(llmEffort) {
                llmEffort = ""
            }
        } catch {
            guard refreshToken == token else { return }
            gatewayModels = []
            gatewayState = .failed(error.localizedDescription)
        }
    }

    func saveAPIKey() {
        guard let gatewayEndpoint else { return }
        if isTestMode {
            isolatedKeys[gatewayEndpoint] = apiKey
            apiKeyStatus = "已保存到本次测试会话"
        } else {
            apiKeyStatus = Keychain.write(apiKey, gateway: gatewayEndpoint)
                ? (apiKey.isEmpty ? "已清空当前网关密钥" : "已保存到钥匙串")
                : "无法写入系统钥匙串"
        }
    }

    func refreshUnfinished() {
        let current = (recorder.isActive || saveNeedsRetry) ? recorder.localDir?.standardizedFileURL : nil
        unfinished = Recorder.unfinishedSessions(in: recorder.localRoot).filter {
            $0.standardizedFileURL != current
        }
        var interrupted: [UUID: URL] = [:]
        for dir in unfinished {
            if let id = SessionStore.readInfo(dir: dir)?.draftID { interrupted[id] = dir }
        }
        interruptedDrafts = interrupted
    }

    private func reconcileDrafts() {
        let directories = (try? FileManager.default.contentsOfDirectory(at: recorder.localRoot,
                                                                         includingPropertiesForKeys: nil)) ?? []
        let delivered = Set(directories.compactMap { dir -> UUID? in
            guard let info = SessionStore.readInfo(dir: dir), info.state == .saved else { return nil }
            return info.draftID
        })
        if !delivered.isEmpty { drafts.removeAll { delivered.contains($0.id) } }
        refreshUnfinished()
        for dir in unfinished {
            guard let info = SessionStore.readInfo(dir: dir), let id = info.draftID,
                  draft(id: id) == nil else { continue }
            drafts.append(RecordingDraft(id: id, name: info.course, project: info.sessionDestination, placement: info.recordingPlacement))
        }
        if let id = selection.draftID, draft(id: id) == nil {
            selection = drafts.first.map { .draft($0.id) } ?? .directory(saveRoot)
        }
    }

    func recoverFirst() async {
        guard let dir = unfinished.first else { return }
        await recoverRecording(dir)
    }

    func recoverDraft(_ id: UUID) async {
        guard let dir = interruptedDrafts[id] else { return }
        await recoverRecording(dir)
    }

    private func recoverRecording(_ dir: URL) async {
        guard !recordingBusy else { return }
        recordingOperation = true
        let id = SessionStore.readInfo(dir: dir)?.draftID
        activeDraftID = id
        select(id.map(WorkspaceSelection.draft) ?? .currentRecording)
        await recorder.recover(dir: dir)
        if !saveNeedsRetry { activeDraftID = nil }
        recordingOperation = false
        refreshUnfinished()
    }

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

    /// 已写入目标目录且校验通过的本地备份(可移入废纸篓)。
    func savedLocalBackups() -> [URL] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: recorder.localRoot, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { SessionStore.readInfo(dir: $0)?.state == .saved }
    }

    func trashSavedBackups() -> Int {
        var n = 0
        for d in savedLocalBackups() { if (try? FileManager.default.trashItem(at: d, resultingItemURL: nil)) != nil { n += 1 } }
        return n
    }

    // MARK: 课后纠正

    var llmConfigured: Bool {
        gatewayEndpoint != nil && !llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (selectedModel?.supportsChat ?? true)
    }
    var gatewayHost: String { URL(string: llmURL).map { ($0.host ?? "") + ($0.port.map { ":\($0)" } ?? "") } ?? llmURL }

    func correctionState(for document: URL) -> CorrectionState {
        correctionByDocument[document.standardizedFileURL] ?? .idle
    }

    var correctionHelp: String {
        let endpoint = llmURL.isEmpty ? "尚未配置的服务" : llmURL
        let name = selectedModel?.displayName ?? llmModel
        return "会向 \(endpoint) 的 \(name) 模型发送转写文字、项目和录音目录名、文稿名及部分文稿开头信息。校正结果与上下文摘要会缓存在本机。"
    }

    func correctionWasAttempted(for document: URL) -> Bool {
        if case .idle = correctionState(for: document) { return false }
        return true
    }

    var isCorrecting: Bool { correctionRunning }

    func startCorrection(document: URL) {
        let url = document.standardizedFileURL
        guard !correctionRunning else { return }
        guard llmEnabled else {
            correctionByDocument[url] = .failed("文字纠正已关闭。可在「设置 → 文字纠正」中启用。")
            return
        }
        guard llmConfigured else {
            correctionByDocument[url] = .failed("文字纠正未配置服务地址或模型")
            return
        }
        guard !recorder.isActive else {
            correctionByDocument[url] = .failed("录音进行中不能纠正文字")
            return
        }
        let config = LLMConfig(baseURL: llmURL, model: llmModel.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: apiKey,
                               reasoningEffort: effectiveEffort, style: correctionStyle)
        let token = UUID()
        correctionToken = token
        correctionDocument = url
        correctionRunning = true
        correctionByDocument[url] = .running(0, 0)
        correctionUsage[url] = CorrectionUsage()
        correctionTask = Task { [weak self] in
            await self?.runCorrection(document: url, config: config, token: token)
        }
    }

    func cancelCorrection() {
        correctionTask?.cancel()
        if let url = correctionDocument {
            correctionByDocument[url] = .failed("已取消,未生成校正版")
        }
    }

    private func runCorrection(document url: URL, config: LLMConfig, token: UUID) async {
        defer {
            if correctionToken == token {
                correctionRunning = false
                correctionDocument = nil
                correctionTask = nil
            }
        }
        do {
            let original = try String(contentsOf: url, encoding: .utf8)
            let segments = MarkdownDoc.parseSegments(original)
            guard !segments.isEmpty else { throw CorrectionError.noSegments }
            var documentConfig = config
            let metadata = original.components(separatedBy: "\n").prefix(16)
                .prefix(while: { !$0.hasPrefix("## 转写") }).joined(separator: "\n")
            let projectFolder = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            documentConfig.course = [projectFolder, url.deletingLastPathComponent().lastPathComponent,
                                     url.deletingPathExtension().lastPathComponent, metadata]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            let cache = Self.testRoot?.appendingPathComponent("cache/text-correction", isDirectory: true)
                ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("com.local.tingjian/TextCorrection", isDirectory: true)
            let corrected = try await TextCorrector(config: documentConfig, cacheDirectory: cache)
                .correct(segments, progress: { [weak self] done, total in
                Task { @MainActor in
                    guard let self, self.correctionToken == token else { return }
                    self.correctionByDocument[url] = .running(done, total)
                }
            }, usage: { [weak self] update in
                Task { @MainActor in
                    guard let self, self.correctionToken == token else { return }
                    var total = self.correctionUsage[url] ?? CorrectionUsage()
                    total.add(update)
                    self.correctionUsage[url] = total
                }
            })
            try Task.checkCancellation()
            guard correctionToken == token else { return }
            // 写出前重读原稿:被外部修改则放弃,不基于旧版本生成校正版。
            let current = try String(contentsOf: url, encoding: .utf8)
            guard current == original else {
                throw CorrectionError.mismatch("原稿已更改,请重新纠正")
            }
            let base = url.deletingPathExtension().lastPathComponent
            let markdown = try TextCorrector.buildCorrectedMarkdown(
                original: original, corrected: corrected,
                originalName: url.lastPathComponent, model: config.model)
            try Task.checkCancellation()
            guard correctionToken == token else { return }
            let output = try Paths.writeUniqueMarkdown(markdown, base: base + "_校正版", in: url.deletingLastPathComponent())
            guard correctionToken == token else { return }
            correctionByDocument[url] = .done(output.lastPathComponent)
            await loadChildren(url.deletingLastPathComponent(), force: true)
            if selection == .document(url) { select(.document(output)) }
        } catch is CancellationError {
            correctionByDocument[url] = .failed("已取消,未生成校正版")
        } catch {
            correctionByDocument[url] = .failed("\(error.localizedDescription)。未生成校正版,原始转写不受影响")
        }
    }

    // MARK: 重新转写

    func retranscribeFile() {
        guard !isRetranscribing else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]; p.canChooseDirectories = false
        p.message = "选择要重新转写的录音(结果另存为 _重转写.md)"
        p.directoryURL = saveRoot
        guard p.runModal() == .OK, let url = p.url else { return }
        isRetranscribing = true
        retranscribe = "正在转写…"
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRetranscribing = false }
            do {
                let asm = try await Retranscriber.run(audio: url) { [weak self] ratio in
                    let percent = Int((min(1.0, max(0.0, ratio)) * 100).rounded())
                    Task { @MainActor [weak self] in
                        guard let self, self.isRetranscribing else { return }
                        self.retranscribe = "正在转写… \(percent)%"
                    }
                }
                let dur = (try? AVAudioFileDuration(url)) ?? 0
                let out = try Retranscriber.writeMarkdown(audio: url, assembler: asm, duration: dur)
                self.retranscribe = "已生成 \(out.lastPathComponent)"
                if ProjectLibrary.contains(self.saveRoot, out) {
                    await self.loadChildren(out.deletingLastPathComponent(), force: true)
                    self.select(.document(out))
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
            } catch {
                self.retranscribe = "重新转写失败:\(error.localizedDescription)"
            }
        }
    }
}

func AVAudioFileDuration(_ url: URL) throws -> Double {
    let f = try AVAudioFile(forReading: url)
    let sampleRate = f.processingFormat.sampleRate
    guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
    return Double(f.length) / sampleRate
}
