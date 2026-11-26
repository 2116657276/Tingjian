import AppKit
import Foundation
import TingjianCore

extension AppModel {
    // MARK: 录音草稿与会话控制

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

    /// 录音或暂停期间修改当前会话的课程名，防抖后同步到暂存区标题与最终交付文件名，不反向覆盖输入框。
    func scheduleActiveCourseNameSync() {
        courseNameSyncTask?.cancel()
        courseNameSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.flushActiveCourseName()
        }
    }

    func flushActiveCourseName() {
        courseNameSyncTask?.cancel()
        courseNameSyncTask = nil
        guard recorder.phase == .recording || recorder.phase == .paused else { return }
        let name = activeCourseNameDraft
        recorder.updateCourseName(name)
        if let activeID = activeDraftID, let index = drafts.firstIndex(where: { $0.id == activeID }) {
            drafts[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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

    var saveNeedsRetry: Bool {
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
        activeCourseNameDraft = name
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
        return !recordingBusy && !isDraftLocked(id) && !nextInputUnavailable && !isRetranscribing && !isCorrecting
    }

    func requestStopRecording() {
        if recorder.phase == .starting {
            recorder.cancelStarting()
            return
        }
        guard recorder.phase == .recording || recorder.phase == .paused else { return }
        flushActiveCourseName()
        if recorder.duration < 30 {
            Task { await recorder.stop() }
        } else {
            stopConfirmationRequested = true
        }
    }

    func confirmStopRecording() {
        stopConfirmationRequested = false
        flushActiveCourseName()
        Task { await recorder.stop() }
    }

    func recordingDelivered(_ files: DeliveryResult, draftID: UUID?) {
        courseNameSyncTask?.cancel()
        courseNameSyncTask = nil
        activeCourseNameDraft = ""
        inputSwitchError = nil
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
        refreshLocalBackupsSummary()
        guard ProjectLibrary.contains(saveRoot, files.directory) else { return }
        Task {
            await loadChildren(files.directory.deletingLastPathComponent(), force: true)
            await loadChildren(files.directory, force: true)
        }
    }

    // MARK: 未完成会话与恢复

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

    func reconcileDrafts() {
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

    func recoverSession(_ dir: URL) async {
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
}
