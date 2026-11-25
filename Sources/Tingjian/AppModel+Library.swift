import AppKit
import SwiftUI
import TingjianCore

extension AppModel {
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
                let sortOrder = self.librarySortOrder
                let result = await Task.detached {
                    try Task.checkCancellation()
                    return try await source.children(of: dir, classifyDirectories: false, sortOrder: sortOrder)
                }.result
                guard !Task.isCancelled, self.library === source else { return }
                switch result {
                case .success(let entries):
                    if self.childrenByDirectory[dir] != entries { self.childrenByDirectory[dir] = entries }
                    self.recordingDirectoryFlags[dir] = entries.contains { $0.kind == .audio }
                    self.directoryErrors[dir] = nil
                    let subdirs = entries.filter { $0.kind == .directory }.map(\.url)
                    if !subdirs.isEmpty {
                        self.probeRecordingDirectories(subdirs, source: source)
                    }
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

    /// 后台轻量探测一级子目录是否含直属音频，避免未展开的录音目录在侧栏缺失录音标记。
    private func probeRecordingDirectories(_ directories: [URL], source: ProjectLibrary) {
        let targets = directories.map(\.standardizedFileURL)
        Task { [weak self] in
            let flags: [URL: Bool] = await Task.detached(priority: .utility) {
                var result: [URL: Bool] = [:]
                for dir in targets {
                    if Task.isCancelled { break }
                    result[dir] = ProjectLibrary.isRecordingBundle(dir)
                }
                return result
            }.value
            guard let self, self.library === source else { return }
            for (dir, isRecording) in flags where self.recordingDirectoryFlags[dir] != isRecording {
                self.recordingDirectoryFlags[dir] = isRecording
            }
        }
    }

    func isRecordingDirectory(_ url: URL) -> Bool {
        let key = url.standardizedFileURL
        if let entries = childrenByDirectory[key] {
            return entries.contains { $0.kind == .audio }
        }
        return recordingDirectoryFlags[key] == true
    }

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
        activeDocumentBlockID = nil
        showEmptyCorrectedSegments = false
        if case .document = newSelection {
            // 保留查找栏打开状态并在新文稿加载后自动重算
        } else if isDocumentSearchPresented {
            dismissDocumentSearch()
        }
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
                correctionOutputByDocument[tab] = nil
            }
            correctionOutputByDocument = correctionOutputByDocument.filter { !ProjectLibrary.contains(target, $0.value) }
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

    func syncProtection() async {
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

    func remapPaths(from old: URL, to new: URL) {
        let mapper = WorkspacePathMapper(saveRoot: saveRoot, from: old, to: new)
        let map: (URL) -> URL = mapper.map
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
        recordingDirectoryFlags = mapper.remapDictionary(recordingDirectoryFlags)
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
        correctionByDocument = mapper.remapDictionary(correctionByDocument)
        correctionOutputByDocument = mapper.remapDictionary(correctionOutputByDocument).mapValues(map)
        correctionUsage = mapper.remapDictionary(correctionUsage)
        if let doc = correctionDocument { correctionDocument = map(doc) }
        openTabs = mapper.remapTabs(openTabs)
        documentScrollAnchors = mapper.remapDictionary(documentScrollAnchors)
        documentScrollPoints = mapper.remapDictionary(documentScrollPoints)
        audioPositions = mapper.remapDictionary(audioPositions)
        documentsByURL = mapper.remapDictionary(documentsByURL).mapValues { $0.remapping(map) }
        if let doc = openDocument {
            openDocument = doc.remapping(map)
        }
    }

    func remapURL(_ url: URL, from old: URL, to new: URL) -> URL {
        WorkspacePathMapper(saveRoot: saveRoot, from: old, to: new).map(url)
    }
}
