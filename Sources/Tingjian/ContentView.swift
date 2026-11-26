import AppKit
import SwiftUI
import TingjianCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var rec: Recorder
    @EnvironmentObject var playback: PlaybackModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            NavigationSplitView(columnVisibility: $model.columnVisibility) {
                SidebarPanel()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
            } detail: {
                detailPane
            }
            .onChange(of: geo.size.width, initial: true) { previousWidth, width in
                if width < 860, (previousWidth >= 860 || previousWidth == width), model.columnVisibility != .detailOnly {
                    model.sidebarHiddenForWidth = true
                    model.columnVisibility = .detailOnly
                } else if width >= 860, model.sidebarHiddenForWidth {
                    model.sidebarHiddenForWidth = false
                    model.columnVisibility = .all
                }
            }
            .onChange(of: model.columnVisibility) { _, visibility in
                if visibility != .detailOnly { model.sidebarHiddenForWidth = false }
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .foregroundStyle(TingjianTheme.ink)
        .tint(TingjianTheme.accent)
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.needsInitialSetup) {
            InitialSetupView()
                .interactiveDismissDisabled()
        }
        .sheet(item: $model.renameRequest) { request in
            RenameSheet(request: request)
        }
        .sheet(isPresented: $model.newProjectRequest) {
            NewProjectSheet()
        }
        .alert("移入废纸篓？", isPresented: Binding(
            get: { model.trashRequest != nil },
            set: { if !$0 { model.trashRequest = nil } }
        )) {
            Button("取消", role: .cancel) { model.trashRequest = nil }
            Button("移入废纸篓", role: .destructive) { model.confirmTrash() }
        } message: {
            Text(trashConfirmation)
        }
        .alert("结束并保存本次录音？", isPresented: $model.stopConfirmationRequested) {
            Button("继续录音", role: .cancel) { model.stopConfirmationRequested = false }
            Button("结束并保存") { model.confirmStopRecording() }
        } message: {
            Text("当前已录制 \(Timecode.string(rec.duration))。结束后会保存音频与转写文稿并关闭本次会话。")
        }
        .onAppear { model.refreshUnfinished() }
    }

    // MARK: 顶部工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.columnVisibility == .detailOnly {
                Button { model.newRecording() } label: {
                    Label("新建录音", systemImage: "record.circle")
                }
            }
            Menu {
                Button("更改保存位置…") { model.chooseSaveRoot() }
                    .disabled(rec.isActive)
                Button("在 Finder 中显示资料库") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.saveRoot])
                }
                Divider()
                Button("复制资料库路径") { copyPath(model.saveRoot.path) }
            } label: {
                Label("保存位置", systemImage: "externaldrive")
            }
            .accessibilityLabel("保存位置")
            .accessibilityValue(model.saveRoot.path)
            .help(model.saveRoot.path)
        }
    }

    // MARK: 主区

    private var detailPane: some View {
        VStack(spacing: 0) {
            header
            if model.recordingBusy, !model.isRecordingSelection {
                recordingBanner
            }
            if let banner = severeBanner {
                issueBanner(banner)
            }
            if rec.phase == .recording, let silence = rec.silenceWarning {
                silenceBanner(silence)
            }
            Rectangle().fill(TingjianTheme.hairline).frame(height: 1)
            content
            Rectangle().fill(TingjianTheme.hairline).frame(height: 1)
            if rec.isActive || playback.isLoaded || hasSaveIssue { ControlBand() }
            StatusBar(showIssues: $model.showIssues, issues: issues)
        }
        .background(TingjianPaperBackground())
    }

    private var isCurrentRecording: Bool { model.isRecordingSelection }

    private var header: some View {
        HStack(spacing: 12) {
            if !model.openTabs.isEmpty {
                if model.selectedFileTab == nil {
                    HStack(spacing: 6) {
                        Image(systemName: contextIcon)
                            .font(.system(size: 11))
                            .foregroundStyle(isCurrentRecording ? TingjianTheme.record : TingjianTheme.accent)
                        Text(contextTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 160, alignment: .leading)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(TingjianTheme.controlSurface))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TingjianTheme.hairline, lineWidth: 1))
                    .help(contextPath)
                }
                tabBar.frame(maxWidth: .infinity)
            } else if isCurrentRecording || model.selection.draftID != nil {
                Text(contextTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            } else if case .directory = model.selection {
                Text(contextTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .help(contextPath)
            }

            Spacer(minLength: 12)

            WorkspaceRefreshButton(title: "刷新当前内容", refreshing: model.refreshingContent) {
                await model.refreshOpenContent()
            }

            selectedItemMenu
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private var contextIcon: String {
        switch model.selection {
        case .currentRecording, .draft: return "record.circle"
        case .directory(let url): return model.isRecordingDirectory(url) ? "waveform.badge.mic" : "folder"
        case .document: return "doc.text"
        case .audio: return "waveform"
        }
    }

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(model.openTabs, id: \.self) { tab in
                        let active = model.selectedFileTab == tab
                        HStack(spacing: 5) {
                            Image(systemName: ProjectLibrary.isAudio(tab) ? "waveform" : "doc.text")
                                .font(.system(size: 10))
                                .foregroundStyle(active ? TingjianTheme.accent : TingjianTheme.tertiaryInk)
                            Button { model.activateTab(tab) } label: {
                                Text(tabTitle(for: tab))
                                    .font(.system(size: 11, weight: active ? .medium : .regular))
                                    .lineLimit(1)
                                    .frame(maxWidth: 170, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help(tab.path)
                            Button { model.closeTab(tab) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .semibold))
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("关闭 \(tabTitle(for: tab))")
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 4)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 5).fill(active ? TingjianTheme.controlSurface : .clear))
                        .contentShape(Rectangle())
                        .id(tab)
                        .contextMenu {
                            Button("关闭标签页") { model.closeTab(tab) }
                            Button("关闭其他文件标签") { model.closeOtherTabs(keeping: tab) }
                            Button("关闭右侧文件标签") { model.closeTabsToRight(of: tab) }
                                .disabled(model.openTabs.last == tab)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.selectedFileTab) { _, tab in
                guard let tab else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(tab, anchor: .center) }
            }
            .onAppear {
                if let tab = model.selectedFileTab { proxy.scrollTo(tab, anchor: .center) }
            }
        }
        .frame(height: 34)
        .background(TingjianTheme.windowSurface)
        .overlay(alignment: .bottom) { TingjianTheme.hairline.frame(height: 1) }
    }

    private func tabTitle(for tab: URL) -> String {
        let base = tab.deletingPathExtension().lastPathComponent
        let parts = Paths.parseRecordingName(base)
        let title = parts?.displayTitle ?? base
        let duplicates = model.openTabs.filter { candidate in
            let name = candidate.deletingPathExtension().lastPathComponent
            return (Paths.parseRecordingName(name)?.displayTitle ?? name) == title
        }
        guard duplicates.count > 1 else { return title }
        let sameParent = duplicates.filter { $0.deletingLastPathComponent() == tab.deletingLastPathComponent() }
        if sameParent.count > 1 { return title + "." + tab.pathExtension }
        return "\(title) · \(parts?.compactDate ?? tab.deletingLastPathComponent().lastPathComponent)"
    }

    private var hasSaveIssue: Bool {
        switch rec.save {
        case .pending, .failed: true
        default: false
        }
    }

    private var trashConfirmation: String {
        guard let url = model.trashRequest else { return "" }
        var isDirectory: ObjCBool = false
        let directory = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        if directory { return "“\(url.lastPathComponent)”及其全部内容将移入系统废纸篓。你可以之后从废纸篓恢复。" }
        if ProjectLibrary.isAudio(url) { return "“\(url.lastPathComponent)”将移入系统废纸篓；关联文稿将无法从应用内播放此音频。" }
        return "“\(url.lastPathComponent)”将移入系统废纸篓。你可以之后从废纸篓恢复。"
    }

    @ViewBuilder
    private var selectedItemMenu: some View {
        if let url = model.selection.url {
            Menu {
                switch model.selection {
                case .document(let document):
                    if let audio = model.openDocument?.linkedAudio {
                        Button("打开关联音频") { model.select(.audio(audio)) }
                        Button("重新转写关联音频") { model.retranscribeAudio(audio) }
                            .disabled(model.isRetranscribing || rec.isActive)
                    }
                    if let original = model.originalDocumentURL(for: document) {
                        Button("查看原始转写") { model.select(.document(original)) }
                    } else if let corrected = model.correctedDocumentURL(for: document) {
                        Button("打开校正版") { model.select(.document(corrected)) }
                    }
                    if model.openDocument?.lines.isEmpty == false && model.llmEnabled {
                        Button(model.correctionWasAttempted(for: document) ? "再次纠正文本" : "纠正文本") {
                            model.startCorrection(document: document)
                        }
                        .disabled(!model.llmConfigured || model.isCorrecting || rec.isActive)
                        .help(model.correctionHelp)
                    }
                    Divider()
                    Button("在默认应用中打开") { NSWorkspace.shared.open(document) }
                    LibraryEntryManageMenuItems(url: document, mutationDisabled: rec.isActive, separateLocationSection: false)
                case .audio(let audio):
                    Button("重新转写") { model.retranscribeAudio(audio) }
                        .disabled(model.isRetranscribing || rec.isActive)
                    Divider()
                    LibraryEntryManageMenuItems(url: audio, mutationDisabled: rec.isActive, separateLocationSection: false)
                case .directory(let directory):
                    Button("在此录音") { model.newRecording(in: directory) }
                    Button("在此新建项目…") { model.select(.directory(directory)); model.newProjectRequest = true }
                    Divider()
                    LibraryEntryManageMenuItems(
                        url: directory,
                        mutationDisabled: rec.isActive || !model.canModifyLibrarySelection,
                        separateLocationSection: false
                    )
                case .currentRecording, .draft:
                    EmptyView()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("当前项目操作")
            .help(url.path)
        } else if let id = model.selection.draftID {
            Menu {
                Button("选择保存位置…") { model.chooseDraftPlacement(id) }
                    .disabled(model.isDraftLocked(id))
                if let folder = model.recordingDestination(for: id),
                   !model.isRootDirectory(folder),
                   !(model.draft(id: id)?.placement != nil && model.isRootDirectory(folder.deletingLastPathComponent())) {
                    Button("改存到根目录") { model.useRoot(for: id) }
                        .disabled(model.isDraftLocked(id))
                }
                Button("关闭草稿") { model.closeDraft(id) }
                    .disabled(model.isDraftLocked(id))
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("草稿操作")
        }
    }

    private var contextTitle: String {
        switch model.selection {
        case .currentRecording:
            return rec.courseName.isEmpty ? "当前录音" : rec.courseName
        case .draft(let id):
            return model.draft(id: id)?.title ?? "未命名录音"
        case .directory(let url):
            if model.isRootDirectory(url) { return "资料库根目录" }
            return Paths.parseRecordingName(url.lastPathComponent)?.displayTitle ?? url.lastPathComponent
        case .document(let url), .audio(let url):
            let stem = url.deletingPathExtension().lastPathComponent
            return Paths.parseRecordingName(stem)?.displayTitle ?? url.lastPathComponent
        }
    }

    private var contextPath: String {
        switch model.selection {
        case .currentRecording:
            return rec.sessionDestination.path
        case .draft(let id):
            return model.recordingDestination(for: id)?.path ?? ""
        case .directory(let url), .document(let url), .audio(let url):
            return url.path
        }
    }

    private var recordingBanner: some View {
        HStack(spacing: 8) {
            Circle().fill(TingjianTheme.record).frame(width: 7, height: 7)
            Text(recordingBannerText)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("查看") { model.showCurrentRecording() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(TingjianTheme.record.opacity(0.07))
    }

    private var recordingBannerText: String {
        if rec.phase == .paused { return "录音已暂停" }
        if rec.phase == .finalizing { return "正在保存录音" }
        if !rec.isActive { return "录音等待保存" }
        return "正在录音"
    }

    private var severeBanner: IssueItem? {
        issues.first {
            switch $0.remedy {
            case .retrySave, .recover, .installModel: return true
            default:
                return $0.id == "persistence" || $0.id == "input" || $0.id == "start" || $0.id == "input-switch"
            }
        }
    }

    private func issueBanner(_ issue: IssueItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: issue.tone == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.tone.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title).font(.system(size: 12, weight: .semibold))
                Text(issue.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(TingjianTheme.secondaryInk)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if issues.count > 1 {
                Text("共 \(issues.count) 个问题")
                    .font(.system(size: 11))
                    .foregroundStyle(TingjianTheme.secondaryInk)
            }
            Button("处理") { model.showIssues = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(issue.tone.color.opacity(0.06))
    }

    private func silenceBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash")
                .font(.system(size: 11))
                .foregroundStyle(TingjianTheme.warning)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(TingjianTheme.secondaryInk)
                .lineLimit(2)
            Spacer(minLength: 8)
            Text("可在底栏切换设备")
                .font(.system(size: 11))
                .foregroundStyle(TingjianTheme.tertiaryInk)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(TingjianTheme.warning.opacity(0.06))
    }

    @ViewBuilder
    private var content: some View {
        switch model.selection {
        case .currentRecording, .draft:
            CurrentRecordingView()
        case .directory(let url):
            DirectoryDetail(url: url)
        case .document(let url):
            DocumentDetail(url: url)
        case .audio(let url):
            AudioDetail(url: url)
        }
    }

    // MARK: 问题清单

    private var issues: [IssueItem] {
        var items: [IssueItem] = []
        if !model.unfinished.isEmpty, !rec.isActive {
            for (index, dir) in model.unfinished.enumerated() {
                let info = SessionStore.readInfo(dir: dir)
                let label = info.flatMap { $0.course.isEmpty ? nil : $0.course }
                    ?? Paths.parseRecordingName(dir.lastPathComponent)?.displayTitle
                    ?? dir.lastPathComponent
                let suffix = model.unfinished.count > 1 ? "（第 \(index + 1)/\(model.unfinished.count) 份）" : ""
                items.append(IssueItem(
                    id: "unfinished-\(dir.standardizedFileURL.path)",
                    title: "发现未完成录音：\(label)\(suffix)",
                    detail: "上次录音被意外中断，本地保留着音频和已确认文字。",
                    path: dir.path,
                    tone: .warning, remedy: .recover(dir)))
            }
        }
        if let persistence = rec.persistenceIssue {
            items.append(IssueItem(id: "persistence", title: "文本/恢复信息保存异常",
                                   detail: persistence, path: rec.localDir?.path, tone: .error, remedy: .none))
        }
        if rec.transcribe == .needsModel || (rec.phase == .finished && rec.speechModelState == .needsDownload) {
            items.append(IssueItem(id: "model", title: "需要简体中文识别模型",
                                   detail: rec.modelDownloadError ?? (rec.isActive ? "录音会继续。模型下载完成后会补转最近两分钟。" : "下载后可在音频页或文稿页重新转写录音。"),
                                   path: rec.localDir?.path, tone: .warning, remedy: .installModel))
        } else if case .failed(let message) = rec.transcribe {
            items.append(IssueItem(id: "transcribe", title: "语音转写异常",
                                   detail: message, path: rec.localDir?.path, tone: .warning, remedy: .none))
        }
        if let message = rec.message, !message.isEmpty {
            let issueID = rec.phase == .idle ? "start" : "message"
            items.append(IssueItem(id: issueID,
                                   title: rec.phase == .idle ? "无法开始录音" : "麦克风或录音提示",
                                   detail: message, path: rec.localDir?.path, tone: .error, remedy: .dismiss(issueID)))
        }
        if let inputIssue = rec.inputIssue {
            items.append(IssueItem(id: "input", title: "录音输入异常",
                                   detail: inputIssue, path: rec.localDir?.path, tone: .warning, remedy: .none))
        }
        if let error = model.inputSwitchError {
            items.append(IssueItem(id: "input-switch", title: "输入设备切换失败",
                                   detail: error, path: nil, tone: .error, remedy: .dismiss("input-switch")))
        }
        switch rec.save {
        case .pending(let path, let reason):
            items.append(IssueItem(id: "save", title: "尚未写入目标目录",
                                   detail: "音频和文字已保留在本地。\(reason)", path: path,
                                   tone: .error, remedy: .retrySave))
        case .failed(let reason):
            items.append(IssueItem(id: "save", title: "文字文件保存失败",
                                   detail: reason, path: rec.localDir?.path, tone: .error, remedy: .retrySave))
        case .idle, .saving, .saved:
            break
        }
        if let url = model.selection.url,
           case .failed(let detail) = model.correctionState(for: url) {
            items.append(IssueItem(id: "correction",
                                   title: detail.contains("已取消") ? "文字纠正已取消" : "文字纠正未完成",
                                   detail: detail, path: url.deletingLastPathComponent().path,
                                   tone: .warning, remedy: .retryCorrection(url)))
        }
        if let notice = model.libraryNotice {
            items.append(IssueItem(id: "library", title: "资料库操作未完成",
                                   detail: notice, path: nil, tone: .warning, remedy: .dismiss("library")))
        }
        if let error = model.audioError ?? model.playback.error {
            items.append(IssueItem(id: "playback", title: "音频无法播放",
                                   detail: error, path: model.playback.currentURL?.path,
                                   tone: .warning, remedy: .none))
        }
        if let sel = model.selection.url, let error = model.directoryErrors[sel.standardizedFileURL] {
            items.append(IssueItem(id: "directory", title: "无法读取文件夹",
                                   detail: error, path: sel.path, tone: .error, remedy: .none))
        }
        if let message = model.seekMessage {
            items.append(IssueItem(id: "seek", title: "无法定位播放位置",
                                   detail: message, path: nil, tone: .warning, remedy: .dismiss("seek")))
        }
        return items
    }
}
