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
    case directory(URL)
    case document(URL)
    case audio(URL)

    var url: URL? {
        switch self {
        case .currentRecording: return nil
        case .directory(let url), .document(let url), .audio(let url): return url
        }
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

    /// 测试环境变量:TINGJIAN_TEST_ROOT 隔离目录与偏好;TINGJIAN_TEST_AUDIO 用合成音频代替麦克风。
    static let testRoot = ProcessInfo.processInfo.environment["TINGJIAN_TEST_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static let testAudio = ProcessInfo.processInfo.environment["TINGJIAN_TEST_AUDIO"].map { URL(fileURLWithPath: $0) }
    static let defaults: UserDefaults = testRoot != nil ? UserDefaults(suiteName: "com.local.tingjian.test")! : .standard

    @Published var saveRoot: URL {
        didSet {
            documentGeneration += 1
            Self.defaults.set(saveRoot.path, forKey: "saveRoot")
            library = ProjectLibrary(root: saveRoot)
            recordingProject = saveRoot
            childrenByDirectory = [:]
            directoryErrors = [:]
            expandedDirectories = []
            selection = .currentRecording
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
    @Published var llmEnabled: Bool { didSet { Self.defaults.set(llmEnabled, forKey: "llmEnabled") } }
    @Published var llmURL: String { didSet { Self.defaults.set(llmURL, forKey: "llmURL") } }
    @Published var llmModel: String { didSet { Self.defaults.set(llmModel, forKey: "llmModel") } }
    @Published var llmEffort: String { didSet { Self.defaults.set(llmEffort, forKey: "llmEffort") } }
    @Published var appearance: AppAppearance {
        didSet { Self.defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    @Published var audioInputUID: String? {
        didSet {
            if let audioInputUID { Self.defaults.set(audioInputUID, forKey: "audioInputUID") }
            else { Self.defaults.removeObject(forKey: "audioInputUID") }
            recorder.preferredInputUID = audioInputUID
        }
    }
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var gatewayModels: [GatewayModel] = []
    @Published var gatewayState: GatewayRefreshState = .idle
    @Published var apiKey: String
    @Published var unfinished: [URL] = []
    @Published var notice: String?
    @Published var course = ""
    @Published var atBottom = true
    @Published var showUnfinished = false
    @Published var trashed: Int?
    @Published var retranscribe: String?

    @Published var selection: WorkspaceSelection = .currentRecording
    @Published var openTabs: [URL] = []
    @Published var documentScrollAnchors: [URL: Int] = [:]
    @Published var documentScrollPoints: [URL: CGPoint] = [:]
    @Published var trashRequest: URL?
    @Published var recordingProject: URL
    @Published var expandedDirectories: Set<URL> = []
    @Published var childrenByDirectory: [URL: [LibraryEntry]] = [:]
    @Published var directoryErrors: [URL: String] = [:]
    @Published var libraryNotice: String?
    @Published var openDocument: OpenDocument?
    @Published var audioError: String?
    @Published var renameRequest: RenameRequest?
    @Published var newProjectRequest = false
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var showIssues = false
    @Published var seekMessage: String?
    @Published var renameDraft = ""
    @Published var newProjectDraft = ""
    @Published var correctionByDocument: [URL: CorrectionState] = [:]
    @Published var correctionUsage: [URL: CorrectionUsage] = [:]
    @Published private(set) var correctionRunning = false

    static let magpieURL = "http://127.0.0.1:3425/v1"
    static let defaultModel = "sdu/ByteDance-volcengine/DeepSeek-V4.1-Flash"
    var isTestMode: Bool { Self.testRoot != nil || Self.testAudio != nil }

    let recorder: Recorder
    let playback = PlaybackModel()
    private(set) var library: ProjectLibrary

    private var correctionTask: Task<Void, Never>?
    private var correctionDocument: URL?
    private var correctionToken = UUID()
    private var documentGeneration = 0
    private var documentsByURL: [URL: OpenDocument] = [:]
    private var audioPositions: [URL: Double] = [:]
    private var deviceObservers: [NSObjectProtocol] = []
    private var bag: Set<AnyCancellable> = []

    init() {
        let d = Self.defaults
        let root = Self.testRoot?.appendingPathComponent("saved", isDirectory: true)
            ?? d.string(forKey: "saveRoot").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Paths.defaultSaveRoot
        saveRoot = root
        recordingProject = root
        library = ProjectLibrary(root: root)
        // 默认走本机 Magpie 网关:DS SDU、推理强度 high
        llmEnabled = d.object(forKey: "llmEnabled") as? Bool ?? true
        llmURL = d.string(forKey: "llmURL") ?? Self.magpieURL
        llmModel = d.string(forKey: "llmModel") ?? Self.defaultModel
        llmEffort = d.string(forKey: "llmEffort") ?? "high"
        appearance = AppAppearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        audioInputUID = d.string(forKey: "audioInputUID")
        apiKey = Self.testRoot == nil ? (Keychain.read() ?? "") : ""
        let local = Self.testRoot?.appendingPathComponent("local", isDirectory: true) ?? Paths.defaultLocalRoot
        if let audio = Self.testAudio {
            recorder = Recorder(saveRoot: root, localRoot: local, makeSource: { _ in FileSource(url: audio, speed: 1) })
        } else {
            recorder = Recorder(saveRoot: root, localRoot: local)
        }
        recorder.preferredInputUID = audioInputUID
        refreshUnfinished()
        refreshInputDevices()
        playback.$position
            .receive(on: RunLoop.main)
            .sink { [weak self] position in
                guard let self, let url = self.playback.currentURL else { return }
                self.audioPositions[url.standardizedFileURL] = position
            }
            .store(in: &bag)
        observeDevices()
        observeRecorder()
        Task { await loadChildren(root, force: true) }
    }

    var selectedModel: GatewayModel? { gatewayModels.first { $0.id == llmModel } }
    var effortOptions: [String] { selectedModel?.levels ?? [] }

    // MARK: 外观与设备偏好

    var colorScheme: ColorScheme? { appearance.colorScheme }

    func refreshInputDevices() {
        inputDevices = AudioInputCatalog.devices()
    }

    /// 录音中切换先尝试真实切换,成功才提交偏好;失败恢复原选择。
    func selectInput(_ uid: String?) {
        if recorder.phase == .recording || recorder.phase == .paused {
            let resolved = uid ?? AudioInputCatalog.defaultUID
            guard let resolved else { libraryNotice = "没有可用的输入设备"; return }
            Task {
                do {
                    try await recorder.switchInput(to: resolved)
                    audioInputUID = uid
                    refreshInputDevices()
                } catch {
                    libraryNotice = "切换输入失败:\(error.localizedDescription)"
                    refreshInputDevices()
                }
            }
        } else {
            audioInputUID = uid
            recorder.preferredInputUID = uid
        }
    }

    var activeInputDescription: String {
        if let name = recorder.activeInputName { return name }
        if let uid = audioInputUID {
            return inputDevices.first { $0.id == uid }?.name ?? "设备不可用"
        }
        return "系统默认"
    }

    var savedInputUnavailable: Bool {
        guard let audioInputUID else { return false }
        return !inputDevices.contains { $0.id == audioInputUID }
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
                }
            },
        ]
    }

    private func observeRecorder() {
        recorder.$save
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                guard case .saved = state, let files = self.recorder.deliveredFiles else { return }
                Task { @MainActor in
                    self.recordingProject = files.directory.deletingLastPathComponent()
                    self.refreshUnfinished()
                    await self.reloadLibrary()
                    self.select(.document(files.markdown))
                }
            }
            .store(in: &bag)
    }

    // MARK: 资料库

    var currentDirectory: URL {
        switch selection {
        case .directory(let url): return url
        case .document(let url), .audio(let url): return url.deletingLastPathComponent()
        case .currentRecording: return recordingProject
        }
    }

    func loadChildren(_ directory: URL, force: Bool = false) async {
        let dir = directory.standardizedFileURL
        if !force, childrenByDirectory[dir] != nil { return }
        if !FileManager.default.fileExists(atPath: dir.path) {
            if dir == saveRoot.standardizedFileURL {
                // 资料库根尚未创建时显示空资料库;第一次录音或新建项目时才创建目录。
                childrenByDirectory[dir] = []
                directoryErrors[dir] = nil
            } else {
                childrenByDirectory[dir] = nil
                directoryErrors[dir] = "文件夹已移动或不存在:\(dir.path)"
            }
            return
        }
        do {
            let entries = try await library.children(of: dir)
            childrenByDirectory[dir] = entries
            directoryErrors[dir] = nil
        } catch {
            childrenByDirectory[dir] = nil
            directoryErrors[dir] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func reloadLibrary() async {
        childrenByDirectory = [:]
        directoryErrors = [:]
        await loadChildren(saveRoot, force: true)
        for dir in expandedDirectories.sorted(by: { $0.path < $1.path }) {
            await loadChildren(dir, force: true)
        }
        if case .directory(let dir) = selection {
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
        if let currentAudio = playback.currentURL?.standardizedFileURL {
            audioPositions[currentAudio] = playback.position
        }
        playback.stop()
        selection = newSelection
        switch newSelection {
        case .currentRecording:
            playback.stop()
            openDocument = nil
            audioError = nil
        case .directory(let url):
            recordingProject = url
            openDocument = nil
            audioError = nil
            playback.stop()
            Task { await loadChildren(url) }
        case .document(let url):
            ensureTab(url)
            playback.pause()
            if let cached = documentsByURL[url.standardizedFileURL] {
                openDocument = cached
                if let audio = cached.linkedAudio {
                    let generation = documentGeneration
                    Task { await loadAudio(audio, at: audioPositions[audio.standardizedFileURL] ?? 0, generation: generation) }
                } else {
                    playback.stop()
                }
            } else {
                let generation = documentGeneration
                Task { await loadDocument(url, generation: generation) }
            }
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
        guard let index = openTabs.firstIndex(of: key) else { return }
        openTabs.remove(at: index)
        documentScrollAnchors[key] = nil
        documentScrollPoints[key] = nil
        documentsByURL[key] = nil
        if selection.url?.standardizedFileURL == key {
            let replacement = openTabs.isEmpty ? nil : openTabs[min(index, openTabs.count - 1)]
            if let replacement { activateTab(replacement) }
            else { select(.currentRecording) }
        }
    }

    func closeActiveTab() {
        guard let url = selection.url else { return }
        closeTab(url)
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

    func activateRelativeTab(_ offset: Int) {
        guard !openTabs.isEmpty else { return }
        let index = selection.url.flatMap { openTabs.firstIndex(of: $0.standardizedFileURL) } ?? 0
        let next = (index + offset + openTabs.count) % openTabs.count
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
            await reloadLibrary()
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
        return walk(childrenByDirectory[saveRoot.standardizedFileURL] ?? [])
    }

    // MARK: 新建、改名、移动

    func newRecording() {
        guard !recorder.isActive else { return }
        course = ""
        selection = .currentRecording
        playback.stop()
        openDocument = nil
        if case .pending = recorder.save { libraryNotice = "上次录音尚未保存,请先重试保存。" }
    }

    func beginRecording() {
        guard !recorder.isActive else { return }
        switch recorder.save {
        case .pending, .failed:
            if recorder.phase == .finished {
                libraryNotice = "上次录音尚未保存到目标目录,请先重试保存。"
                return
            }
        default:
            break
        }
        recorder.saveRoot = recordingProject
        recorder.preferredInputUID = audioInputUID
        libraryNotice = nil
        selection = .currentRecording
        openDocument = nil
        playback.stop()
        Task { await recorder.start(course: course) }
    }

    var canStartRecording: Bool {
        if recorder.isActive { return false }
        if savedInputUnavailable { return false }
        if recorder.phase == .finished {
            if case .pending = recorder.save { return false }
            if case .failed = recorder.save { return false }
        }
        return true
    }

    func requestRename(_ url: URL) {
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

    func renameEntry(_ url: URL, to name: String) async {
        documentGeneration += 1
        let generation = documentGeneration
        await syncProtection()
        let playing = playback.currentURL
        let position = playback.position
        playback.stop()
        do {
            let renamed = try await library.rename(url, to: name)
            remapPaths(from: url, to: renamed)
            documentsByURL.removeAll()
            await reloadLibrary()
            if generation == documentGeneration, let playing {
                let mapped = remapURL(playing, from: url, to: renamed)
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

    func moveEntry(_ url: URL, into directory: URL) async {
        if url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL { return }
        documentGeneration += 1
        let generation = documentGeneration
        await syncProtection()
        let playing = playback.currentURL
        let position = playback.position
        playback.stop()
        do {
            let moved = try await library.move(url, into: directory)
            guard moved != url else { return }
            remapPaths(from: url, to: moved)
            documentsByURL.removeAll()
            await reloadLibrary()
            if generation == documentGeneration, let playing {
                let mapped = remapURL(playing, from: url, to: moved)
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

    func chooseMoveDestination(for url: URL) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = url.deletingLastPathComponent()
        panel.message = "选择当前资料库内的目标文件夹"
        panel.prompt = "移动到这里"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard ProjectLibrary.contains(saveRoot, destination) else {
            libraryNotice = "只能移动到当前资料库内:\(saveRoot.path)"
            return
        }
        Task { await moveEntry(url, into: destination) }
    }

    /// 录音文件夹内的文件按整份录音移动;普通目录或独立文件按自身移动。
    func dragUnit(for url: URL) -> URL {
        for ancestor in ancestors(of: url) {
            guard ancestor != url else { continue }
            if ProjectLibrary.isRecordingBundle(ancestor) { return ancestor }
        }
        return url
    }

    private func ancestors(of url: URL) -> [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL
        let root = saveRoot.standardizedFileURL
        while ProjectLibrary.contains(root, current) {
            result.append(current)
            if current == root { break }
            current = current.deletingLastPathComponent()
        }
        return result
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
        func map(_ url: URL) -> URL { remapURL(url, from: old, to: new) }
        expandedDirectories = Set(expandedDirectories.map(map))
        recordingProject = map(recordingProject)
        switch selection {
        case .currentRecording:
            break
        case .directory(let url): selection = .directory(map(url))
        case .document(let url): selection = .document(map(url))
        case .audio(let url): selection = .audio(map(url))
        }
        var corrections: [URL: CorrectionState] = [:]
        for (url, state) in correctionByDocument { corrections[map(url)] = state }
        correctionByDocument = corrections
        correctionUsage = Dictionary(uniqueKeysWithValues: correctionUsage.map { (map($0.key), $0.value) })
        if let doc = correctionDocument { correctionDocument = map(doc) }
        openTabs = openTabs.map(map)
        documentScrollAnchors = Dictionary(uniqueKeysWithValues: documentScrollAnchors.map { (map($0.key), $0.value) })
        documentScrollPoints = Dictionary(uniqueKeysWithValues: documentScrollPoints.map { (map($0.key), $0.value) })
        audioPositions = Dictionary(uniqueKeysWithValues: audioPositions.map { (map($0.key), $0.value) })
        documentsByURL = Dictionary(uniqueKeysWithValues: documentsByURL.map { key, doc in
            let mappedURL = map(key)
            let mappedDoc = OpenDocument(url: mappedURL, text: doc.text, lines: doc.lines,
                                         linkedAudio: doc.linkedAudio.map(map), error: doc.error)
            return (mappedURL, mappedDoc)
        })
        if let doc = openDocument {
            let mapped = map(doc.url)
            openDocument = OpenDocument(url: mapped, text: doc.text, lines: doc.lines,
                                        linkedAudio: doc.linkedAudio.map(map), error: doc.error)
        }
    }

    func remapURL(_ url: URL, from old: URL, to new: URL) -> URL {
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
        let resolvedURL = canonical(url)
        guard ProjectLibrary.contains(resolvedOld, resolvedURL) else { return url }
        let suffix = resolvedURL.pathComponents.dropFirst(resolvedOld.pathComponents.count)
        var result = new.standardizedFileURL
        for component in suffix { result.appendPathComponent(component) }
        return result
    }

    // MARK: 文稿与播放

    func loadDocument(_ url: URL, generation requestedGeneration: Int? = nil) async {
        let generation = requestedGeneration ?? documentGeneration
        guard generation == documentGeneration, selection == .document(url) else { return }
        audioError = nil
        playback.pause()
        guard FileManager.default.fileExists(atPath: url.path) else {
            openDocument = OpenDocument(url: url, text: "", lines: [], linkedAudio: nil,
                                        error: "文件已移动或不存在:\(url.path)。请刷新项目列表。")
            playback.stop()
            return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard generation == documentGeneration else { return }
            let lines = MarkdownDoc.parseSegments(text).enumerated().map {
                DocumentLine(id: $0.offset, time: $0.element.time, text: $0.element.text)
            }
            let audio = linkedAudio(in: text, nextTo: url)
            var doc = OpenDocument(url: url, text: text, lines: lines, linkedAudio: audio, error: nil)
            documentsByURL[url.standardizedFileURL] = doc
            if let audio {
                do {
                    try await playback.load(audio)
                    guard generation == documentGeneration else { return }
                    if let position = audioPositions[audio.standardizedFileURL], position > 0 {
                        playback.seek(to: position)
                    }
                }
                catch {
                    guard generation == documentGeneration else { return }
                    doc.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            } else {
                playback.stop()
            }
            guard generation == documentGeneration else { return }
            openDocument = doc
            documentsByURL[url.standardizedFileURL] = doc
        } catch {
            guard generation == documentGeneration else { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            openDocument = OpenDocument(url: url, text: "", lines: [], linkedAudio: nil,
                                        error: "无法读取文稿:\(message)")
            documentsByURL[url.standardizedFileURL] = openDocument
            playback.stop()
        }
    }

    func loadAudio(_ url: URL, at position: Double = 0, generation requestedGeneration: Int? = nil) async {
        let generation = requestedGeneration ?? documentGeneration
        guard generation == documentGeneration else { return }
        audioError = nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            openDocument = nil
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
        guard let text = try? String(contentsOf: document, encoding: .utf8),
              let audio = linkedAudio(in: text, nextTo: document) else {
            libraryNotice = "未找到可播放的关联音频: \(document.lastPathComponent)"
            return
        }
        select(.audio(audio))
    }

    func reloadOpenContent() async {
        switch selection {
        case .document(let url): await loadDocument(url)
        case .audio(let url): await loadAudio(url, at: audioPositions[url.standardizedFileURL] ?? 0)
        case .directory(let url): await loadChildren(url, force: true)
        case .currentRecording: break
        }
    }

    /// 返回 nil 表示已定位;否则返回不可定位的原因。
    @discardableResult
    func seek(toTimecode time: String) -> String? {
        guard !recorder.isActive else { return "录音进行中不能从文稿播放音频" }
        guard playback.currentURL != nil else { return "没有已加载的音频" }
        guard let seconds = Self.parseTimecode(time) else { return "时间戳无法解析" }
        guard playback.canSeek, seconds < playback.duration else { return "该时间点超出音频时长" }
        playback.seek(to: seconds)
        return nil
    }

    static func parseTimecode(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    func linkedAudio(in text: String, nextTo url: URL) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"!\[\[([^\]\n]+)\]\]"#) else { return nil }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges > 1 {
            let name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if ProjectLibrary.isAudio(candidate), FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: 网关与模型

    /// 从网关拉取模型清单;失败时保留手填能力。
    func refreshModels() async {
        guard gatewayState != .loading else { return }
        gatewayState = .loading
        do {
            let list = try await GatewayModel.fetch(baseURL: llmURL, apiKey: apiKey)
            gatewayModels = list
            gatewayState = .loaded(list.count)
            normalizeEffort()
        } catch {
            gatewayModels = []
            gatewayState = .failed(error.localizedDescription)
        }
    }

    /// 切换模型后,若原强度不可用,回落到 high(无 high 取最后一项)。
    func normalizeEffort() {
        guard let m = selectedModel, !m.levels.isEmpty, !m.levels.contains(llmEffort) else { return }
        llmEffort = m.defaultLevel
    }

    func saveAPIKey() {
        guard !isTestMode else { return }
        if !Keychain.write(apiKey) { notice = "无法写入系统钥匙串" }
    }

    func refreshUnfinished() {
        unfinished = Recorder.unfinishedSessions(in: recorder.localRoot)
    }

    func recoverFirst() async {
        guard let dir = unfinished.first else { return }
        await recorder.recover(dir: dir)
        refreshUnfinished()
    }

    func chooseSaveRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "选择"; p.message = "选择录音与转写文件的保存位置"
        p.directoryURL = saveRoot.deletingLastPathComponent()
        if p.runModal() == .OK, let u = p.url { saveRoot = u }
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
        !llmURL.trimmingCharacters(in: .whitespaces).isEmpty && !llmModel.trimmingCharacters(in: .whitespaces).isEmpty
            && (selectedModel?.supportsChat ?? true)
    }
    var gatewayHost: String { URL(string: llmURL).map { ($0.host ?? "") + ($0.port.map { ":\($0)" } ?? "") } ?? llmURL }

    func correctionState(for document: URL) -> CorrectionState {
        correctionByDocument[document.standardizedFileURL] ?? .idle
    }

    func correctionHelp(for document: URL) -> String {
        let endpoint = llmURL.isEmpty ? "尚未配置的服务" : llmURL
        let name = selectedModel?.displayName ?? llmModel
        return "仅把 \(document.lastPathComponent) 的转写文字发送到 \(endpoint),模型 \(name),推理强度 \(llmEffort)。不发送录音。"
    }

    func correctionWasAttempted(for document: URL) -> Bool {
        if case .idle = correctionState(for: document) { return false }
        return true
    }

    var isCorrecting: Bool { correctionRunning }

    func startCorrection(document: URL) {
        let url = document.standardizedFileURL
        guard !correctionRunning else { return }
        guard llmEnabled, llmConfigured else {
            correctionByDocument[url] = .failed("文字纠正未配置服务地址或模型")
            return
        }
        guard !recorder.isActive else {
            correctionByDocument[url] = .failed("录音进行中不能纠正文字")
            return
        }
        let config = LLMConfig(baseURL: llmURL, model: llmModel, apiKey: apiKey,
                               reasoningEffort: llmEffort)
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
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]; p.canChooseDirectories = false
        p.message = "选择要重新转写的录音(结果另存为 _重转写.md)"
        p.directoryURL = saveRoot
        guard p.runModal() == .OK, let url = p.url else { return }
        retranscribe = "正在转写…"
        Task {
            do {
                let asm = try await Retranscriber.run(audio: url)
                let dur = (try? AVAudioFileDuration(url)) ?? 0
                let out = try Retranscriber.writeMarkdown(audio: url, assembler: asm, duration: dur)
                retranscribe = "已生成 \(out.lastPathComponent)"
                if ProjectLibrary.contains(saveRoot, out) {
                    await loadChildren(out.deletingLastPathComponent(), force: true)
                    select(.document(out))
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
            } catch {
                retranscribe = "重新转写失败:\(error.localizedDescription)"
            }
        }
    }
}

import AVFoundation
func AVAudioFileDuration(_ url: URL) throws -> Double {
    let f = try AVAudioFile(forReading: url)
    return Double(f.length) / f.processingFormat.sampleRate
}
