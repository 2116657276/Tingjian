import AppKit
import SwiftUI
import TingjianCore

private func recordingNameParts(_ name: String) -> (course: String, date: String)? {
    guard let parts = name.wholeMatch(of: #/(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-\d{2}_(.+)/#) else { return nil }
    return (String(parts.output.4), "\(parts.output.1) \(parts.output.2):\(parts.output.3)")
}

private enum WorkspaceDragItem: Codable {
    case draft(UUID)
    case file(URL)

    static let type = "com.local.tingjian.workspace-item"

    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        guard let data = try? JSONEncoder().encode(self) else { return provider }
        provider.registerDataRepresentation(forTypeIdentifier: Self.type, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func receive(_ providers: [NSItemProvider], in directory: URL, model: AppModel) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type) }) else {
            return false
        }
        _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            Task { @MainActor in
                guard let data, let item = try? JSONDecoder().decode(Self.self, from: data) else {
                    model.libraryNotice = "无法读取拖入的项目，请重试。"
                    return
                }
                switch item {
                case .draft(let id):
                    await model.placeDraft(id, in: directory)
                case .file(let url):
                    model.requestMove(url, into: directory)
                }
            }
        }
        return true
    }
}

private final class DropHighlight: ObservableObject {
    @Published var targeted = false
}

private struct WorkspaceRefreshButton: View {
    let title: String
    let refreshing: Bool
    let action: @MainActor () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Group {
                if refreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .disabled(refreshing)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(refreshing ? "刷新中" : "")
    }
}

private struct TranscriptScrollSnapshot: Equatable {
    let contentHeight: CGFloat
    let distanceFromBottom: CGFloat
}

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
        let title = recordingNameParts(base)?.course ?? base
        let duplicates = model.openTabs.filter { candidate in
            let name = candidate.deletingPathExtension().lastPathComponent
            return (recordingNameParts(name)?.course ?? name) == title
        }
        guard duplicates.count > 1 else { return title }
        let sameParent = duplicates.filter { $0.deletingLastPathComponent() == tab.deletingLastPathComponent() }
        if sameParent.count > 1 { return title + "." + tab.pathExtension }
        return "\(title) · \(recordingNameParts(base)?.date ?? tab.deletingLastPathComponent().lastPathComponent)"
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
                    }
                    Button(model.correctionWasAttempted(for: document) ? "再次纠正文本" : "纠正文本") {
                        model.startCorrection(document: document)
                    }
                    .disabled(!model.llmConfigured || model.isCorrecting || rec.isActive)
                    .help(model.correctionHelp)
                    Divider()
                    Button("重命名…") { model.requestRename(document) }.disabled(rec.isActive)
                    Button("移动到…") { model.requestMove(document) }.disabled(rec.isActive)
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([document]) }
                    Button("复制路径") { copyPath(document.path) }
                    Divider()
                    Button("移入废纸篓…", role: .destructive) { model.requestTrash(document) }.disabled(rec.isActive)
                case .audio(let audio):
                    Button("重命名…") { model.requestRename(audio) }.disabled(rec.isActive)
                    Button("移动到…") { model.requestMove(audio) }.disabled(rec.isActive)
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([audio]) }
                    Button("复制路径") { copyPath(audio.path) }
                    Divider()
                    Button("移入废纸篓…", role: .destructive) { model.requestTrash(audio) }.disabled(rec.isActive)
                case .directory(let directory):
                    Button("在此录音") { model.newRecording(in: directory) }
                    Button("在此新建项目…") { model.select(.directory(directory)); model.newProjectRequest = true }
                    Divider()
                    Button("重命名…") { model.requestRename(directory) }.disabled(rec.isActive || !model.canModifyLibrarySelection)
                    Button("移动到…") { model.requestMove(directory) }.disabled(rec.isActive || !model.canModifyLibrarySelection)
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                    Button("复制路径") { copyPath(directory.path) }
                    Divider()
                    Button("移入废纸篓…", role: .destructive) { model.requestTrash(directory) }.disabled(rec.isActive || !model.canModifyLibrarySelection)
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
                if let folder = model.recordingDestination(for: id), !model.isRootDirectory(folder) {
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
            return model.isRootDirectory(url) ? "资料库根目录" : url.lastPathComponent
        case .document(let url), .audio(let url):
            return url.lastPathComponent
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
        issues.first { $0.remedy == .retrySave || $0.remedy == .recover || $0.remedy == .installModel
            || $0.id == "persistence" || $0.id == "input" || $0.id == "start" || $0.id == "input-switch" }
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
            items.append(IssueItem(
                id: "unfinished",
                title: "发现未完成录音",
                detail: "上次录音被意外中断,本地保留着音频和已确认文字(\(model.unfinished.count) 份)。",
                path: model.unfinished.first?.path,
                tone: .warning, remedy: .recover))
        }
        if let persistence = rec.persistenceIssue {
            items.append(IssueItem(id: "persistence", title: "文本/恢复信息保存异常",
                                   detail: persistence, path: rec.localDir?.path, tone: .error, remedy: .none))
        }
        if rec.transcribe == .needsModel || (rec.phase == .finished && rec.speechModelState == .needsDownload) {
            items.append(IssueItem(id: "model", title: "需要简体中文识别模型",
                                   detail: rec.modelDownloadError ?? (rec.isActive ? "录音会继续。模型下载完成后会补转最近两分钟。" : "下载后可在「保存与恢复」中重新转写录音。"),
                                   path: rec.localDir?.path, tone: .warning, remedy: .installModel))
        } else if case .failed(let message) = rec.transcribe {
            items.append(IssueItem(id: "transcribe", title: "语音转写异常",
                                   detail: message, path: rec.localDir?.path, tone: .warning, remedy: .none))
        }
        if let message = rec.message, !message.isEmpty {
            items.append(IssueItem(id: rec.phase == .idle ? "start" : "message",
                                   title: rec.phase == .idle ? "无法开始录音" : "麦克风或录音提示",
                                   detail: message, path: rec.localDir?.path, tone: .error, remedy: .none))
        }
        if let inputIssue = rec.inputIssue {
            items.append(IssueItem(id: "input", title: "录音输入异常",
                                   detail: inputIssue, path: rec.localDir?.path, tone: .warning, remedy: .none))
        }
        if let error = model.inputSwitchError {
            items.append(IssueItem(id: "input-switch", title: "输入设备切换失败",
                                   detail: error, path: nil, tone: .error, remedy: .none))
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
                                   detail: notice, path: nil, tone: .warning, remedy: .none))
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
                                   detail: message, path: nil, tone: .warning, remedy: .none))
        }
        return items
    }
}

// MARK: - 侧栏

private struct SidebarPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var rec: Recorder

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    model.newRecording()
                } label: {
                    Label("新建录音", systemImage: "record.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("新建录音（⌘N），默认保存到资料库根目录")

                Spacer(minLength: 4)

                Button {
                    model.newProjectRequest = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("在当前文件夹新建项目")
                .accessibilityLabel("新建项目")

                WorkspaceRefreshButton(title: "刷新项目列表", refreshing: model.refreshingLibrary) {
                    await model.refreshLibrary()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    RootDirectoryRow()

                    Text("暂存")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TingjianTheme.tertiaryInk)
                        .padding(.horizontal, 12)
                        .padding(.top, 5.3)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(model.drafts) { draft in
                        RecordingDraftRow(draft: draft)
                    }

                    if let entries = model.childrenByDirectory[model.saveRoot.standardizedFileURL] {
                        if entries.isEmpty {
                            Text("还没有项目。录音会自动生成文件夹,也可以用加号新建。")
                                .font(.system(size: 11))
                                .foregroundStyle(TingjianTheme.tertiaryInk)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("项目")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(TingjianTheme.tertiaryInk)
                                .padding(.horizontal, 12)
                                .padding(.top, 8.45)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(entries) { entry in
                                SidebarRow(entry: entry, depth: 0)
                            }
                        }
                    } else if let error = model.directoryErrors[model.saveRoot.standardizedFileURL] {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(TingjianTheme.warning)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("正在读取项目…").font(.system(size: 11)).foregroundStyle(TingjianTheme.secondaryInk)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .contextMenu {
                Button("在资料库根目录新建项目…") {
                    model.select(.directory(model.saveRoot))
                    model.newProjectRequest = true
                }
                Button("刷新项目树") { Task { await model.refreshLibrary() } }
                    .disabled(model.refreshingLibrary)
                Button("折叠全部文件夹") { model.collapseAllDirectories() }
                Divider()
                Button("在 Finder 中显示资料库") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.saveRoot])
                }
            }
            .onMoveCommand(perform: model.navigateSidebar)
            .focusable()
            .focusEffectDisabled()

            Rectangle().fill(TingjianTheme.hairline).frame(height: 1)

            HStack(spacing: 10) {
                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("设置")

                Spacer(minLength: 4)

                Button {
                    model.chooseSaveRoot()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .disabled(rec.isActive)
                .help("保存位置:\(model.saveRoot.path)")
                .accessibilityLabel("更改保存位置")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(TingjianTheme.windowSurface)
    }
}

private struct RecordingDraftRow: View {
    let draft: RecordingDraft
    @EnvironmentObject private var model: AppModel

    private var isSelected: Bool { model.selection.draftID == draft.id }
    private var isLocked: Bool { model.isDraftLocked(draft.id) }

    private var row: some View {
        HStack(spacing: 6) {
            Button { model.select(.draft(draft.id)) } label: {
                HStack(spacing: 7) {
                    Image(systemName: model.activeDraftID == draft.id ? "waveform" : "record.circle")
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    Text(draft.title).lineLimit(1)
                    Spacer(minLength: 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .help(model.recordingDestination(for: draft.id)?.path ?? draft.title)

            Button { model.closeDraft(draft.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(isLocked)
            .accessibilityLabel("关闭 \(draft.title)")
        }
        .font(.system(size: 12))
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? TingjianTheme.accentSoft : .clear))
        .contextMenu {
            Button("选择保存位置…") { model.chooseDraftPlacement(draft.id) }
                .disabled(isLocked)
            Button("关闭草稿") { model.closeDraft(draft.id) }
                .disabled(isLocked)
        }
    }

    var body: some View {
        if isLocked { row }
        else { row.onDrag { WorkspaceDragItem.draft(draft.id).provider() } }
    }
}

private struct RootDirectoryRow: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var dropHighlight = DropHighlight()

    private var selected: Bool {
        if case .directory(let url) = model.selection { return model.isRootDirectory(url) }
        return false
    }

    var body: some View {
        Button { model.select(.directory(model.saveRoot)) } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(TingjianTheme.accent)
                    .frame(width: 14)
                Text("资料库根目录")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(
                selected || dropHighlight.targeted ? TingjianTheme.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [WorkspaceDragItem.type], isTargeted: $dropHighlight.targeted) { providers in
            WorkspaceDragItem.receive(providers, in: model.saveRoot, model: model)
        }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(model.saveRoot.path)
    }
}

private struct SidebarRow: View {
    let entry: LibraryEntry
    let depth: Int
    @EnvironmentObject private var model: AppModel
    @StateObject private var dropHighlight = DropHighlight()

    private var key: URL { entry.url.standardizedFileURL }
    private var expanded: Bool { model.expandedDirectories.contains(key) }
    private var selected: Bool { model.selection.url?.standardizedFileURL == key }

    private var icon: String {
        switch entry.kind {
        case .directory: return model.isRecordingDirectory(entry.url) ? "waveform.badge.mic" : "folder"
        case .audio: return "waveform"
        case .document: return "doc.text"
        }
    }

    private var iconColor: Color {
        switch entry.kind {
        case .directory: return TingjianTheme.secondaryInk
        case .audio: return TingjianTheme.accent
        case .document: return TingjianTheme.secondaryInk
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row
            if entry.kind == .directory, expanded {
                children
            }
        }
    }

    private var displayName: String {
        guard entry.kind == .directory else { return entry.name }
        return recordingNameParts(entry.name)?.course ?? entry.name
    }

    private var draggableRow: some View {
        HStack(spacing: 4) {
            if entry.kind == .directory {
                Button { model.toggleExpansion(entry.url) } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(TingjianTheme.tertiaryInk)
                        .frame(width: 17, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "折叠文件夹" : "展开文件夹")
            } else {
                Color.clear.frame(width: 17, height: 1)
            }
            Button {
                tap()
            } label: {
                HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(iconColor)
                    .frame(width: 14)
                Text(displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.isRecordingDirectory(entry.url), entry.kind == .directory {
                    Circle().fill(TingjianTheme.record).frame(width: 4, height: 4)
                }
                Spacer(minLength: 0)
                }
                .padding(.trailing, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected || dropHighlight.targeted ? TingjianTheme.accentSoft : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.kind == .directory ? "文件夹" : "文件") \(displayName)")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
        }
        .padding(.leading, CGFloat(depth) * 14 + 8)
        .help(entry.url.path)
        .contextMenu { menu }
        .onDrag { WorkspaceDragItem.file(entry.url).provider() }
    }

    @ViewBuilder
    private var row: some View {
        if entry.kind == .directory {
            draggableRow.onDrop(of: [WorkspaceDragItem.type], isTargeted: $dropHighlight.targeted) { providers in
                WorkspaceDragItem.receive(providers, in: entry.url, model: model)
            }
        } else {
            draggableRow
        }
    }

    @ViewBuilder
    private var children: some View {
        if let entries = model.childrenByDirectory[key] {
            if entries.isEmpty {
                Text("空文件夹")
                    .font(.system(size: 10))
                    .foregroundStyle(TingjianTheme.tertiaryInk)
                    .padding(.leading, CGFloat(depth + 1) * 14 + 26)
                    .padding(.vertical, 2)
            } else {
                ForEach(entries) { child in
                    SidebarRow(entry: child, depth: depth + 1)
                }
            }
        } else if let error = model.directoryErrors[key] {
            Text(error)
                .font(.system(size: 10))
                .foregroundStyle(TingjianTheme.warning)
                .padding(.leading, CGFloat(depth + 1) * 14 + 26)
                .padding(.vertical, 2)
                .textSelection(.enabled)
        } else {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("读取中…").font(.system(size: 10)).foregroundStyle(TingjianTheme.tertiaryInk)
            }
            .padding(.leading, CGFloat(depth + 1) * 14 + 26)
            .padding(.vertical, 2)
        }
    }

    private func tap() {
        if entry.kind == .directory {
            model.select(.directory(entry.url))
        } else if entry.kind == .audio {
            model.select(.audio(entry.url))
        } else {
            model.select(.document(entry.url))
        }
    }

    @ViewBuilder
    private var menu: some View {
        if entry.kind == .directory {
            Button(expanded ? "折叠文件夹" : "展开文件夹") { model.toggleExpansion(entry.url) }
            Button("打开文件夹") { model.select(.directory(entry.url)) }
            Divider()
            Button("在此录音") {
                model.newRecording(in: entry.url)
            }
            Button("在此新建项目…") {
                model.select(.directory(entry.url))
                model.newProjectRequest = true
            }
        } else {
            Button("打开") { tap() }
            if entry.kind == .document {
                Button("打开关联音频") { model.openLinkedAudio(for: entry.url) }
            }
        }
        Divider()
        Button("重命名…") { model.requestRename(entry.url) }
            .disabled(model.recorder.isActive)
        Button("移动到…") {
            model.requestMove(entry.url)
        }
            .disabled(model.recorder.isActive)
        Divider()
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        Button("复制路径") { copyPath(entry.url.path) }
        Divider()
        Button("移入废纸篓…", role: .destructive) { model.requestTrash(entry.url) }
            .disabled(model.recorder.isActive)
    }
}

private struct RenameSheet: View {
    let request: RenameRequest
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var isDirectory: Bool {
        var value: ObjCBool = false
        FileManager.default.fileExists(atPath: request.url.path, isDirectory: &value)
        return value.boolValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名").font(.system(size: 15, weight: .semibold))
            Text(request.url.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(TingjianTheme.secondaryInk)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField(isDirectory ? "新名称" : "新名称(扩展名保持不变)", text: $model.renameDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            if isDirectory {
                Toggle("同步更换直属文件名前缀", isOn: $model.syncRenamePrefixes)
            }
            Text(isDirectory
                 ? "仅替换直属文件名中与原项目名相同的开头，不修改子文件夹。"
                 : "同目录文稿中的音频引用与来源链接会同步更新;同名目标会被拒绝。")
                .font(.system(size: 11))
                .foregroundStyle(TingjianTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("重命名") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 430)
        .onAppear {
            model.syncRenamePrefixes = false
            model.renameDraft = isDirectory ? request.url.lastPathComponent : request.url.deletingPathExtension().lastPathComponent
        }
    }

    private func commit() {
        let value = model.renameDraft
        dismiss()
        let sync = model.syncRenamePrefixes
        Task { await model.renameEntry(request.url, to: value, syncFilePrefixes: sync) }
    }
}

private struct NewProjectSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建项目").font(.system(size: 15, weight: .semibold))
            Text("位置:\(model.currentDirectory.path)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(TingjianTheme.secondaryInk)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("项目名称", text: $model.newProjectDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            Text("项目直接对应磁盘上的文件夹;名称不能包含 / \\ : * ? \" < > | [ ]。")
                .font(.system(size: 11))
                .foregroundStyle(TingjianTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.newProjectDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { model.newProjectDraft = "" }
    }

    private func commit() {
        let value = model.newProjectDraft
        dismiss()
        Task { await model.createProject(named: value) }
    }
}

// MARK: - 当前录音

private struct CurrentRecordingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var rec: Recorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsLiveTranscript: Bool {
        guard model.isRecordingSelection else { return false }
        switch rec.phase {
        case .starting, .recording, .paused, .finalizing: return true
        case .finished:
            if case .saved = rec.save { return false }
            return true
        case .idle: return false
        }
    }

    var body: some View {
        GeometryReader { geo in
            let usesGutter = geo.size.width >= 640
            if showsLiveTranscript {
                transcript(usesGutter: usesGutter)
            } else {
                emptyDraft(height: geo.size.height)
            }
        }
    }

    private func transcript(usesGutter: Bool) -> some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if rec.segments.isEmpty && rec.volatileText.isEmpty {
                            emptyTranscript
                        }
                        ForEach(rec.segments) { segment in
                            SegmentRow(segment: segment, usesGutter: usesGutter)
                                .id(segment.id)
                        }
                        if !rec.volatileText.isEmpty {
                            VolatileRow(text: rec.volatileText, usesGutter: usesGutter)
                                .id("volatile")
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }
                    .frame(maxWidth: 960, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 20)
                }
                .onScrollGeometryChange(for: TranscriptScrollSnapshot.self) { geometry in
                    TranscriptScrollSnapshot(
                        contentHeight: geometry.contentSize.height,
                        distanceFromBottom: geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height))
                } action: { old, new in
                    let grew = new.contentHeight > old.contentHeight + 1
                    if grew && old.distanceFromBottom <= 28 { model.atBottom = true }
                    else { model.atBottom = new.distanceFromBottom <= 28 }
                }
                .onChange(of: rec.segments.count) { _, _ in followLatest(proxy) }
                .onChange(of: rec.volatileText) { _, _ in followLatest(proxy) }

                if (!rec.segments.isEmpty || !rec.volatileText.isEmpty), !model.atBottom {
                    Button {
                        if reduceMotion { proxy.scrollTo("latest", anchor: .bottom) }
                        else { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("latest", anchor: .bottom) } }
                    } label: {
                        Label("回到最新", systemImage: "arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.trailing, 24)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func emptyDraft(height: CGFloat) -> some View {
        let outerRowHeight: CGFloat = 32
        return ScrollView {
            VStack(spacing: 26.4) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(TingjianTheme.accent)
                        .accessibilityHidden(true)
                    Text("从一节课开始")
                        .font(.system(size: 22, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                }
                .frame(height: outerRowHeight)
                if let id = model.selection.draftID, !model.isDraftLocked(id) {
                    TextField("课程名称（可选）", text: Binding(
                        get: { model.draft(id: id)?.name ?? "" },
                        set: { model.renameDraft(id: id, to: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .accessibilityLabel("课程名称")
                    .help("课程名称会用于录音文件夹和 Markdown 标题")
                }
                VStack(spacing: 7) {
                    Text("音频与文稿保存到")
                        .font(.system(size: 14))
                        .foregroundStyle(TingjianTheme.secondaryInk)
                    if let id = model.selection.draftID, let folder = model.recordingDestination(for: id) {
                        recordingFolderLink(folder)
                        if !model.isDraftLocked(id) {
                            Button("选择保存位置…") { model.chooseDraftPlacement(id) }
                                .buttonStyle(.link)
                                .font(.system(size: 12))
                        }
                        if !model.isRootDirectory(folder), !model.isDraftLocked(id) {
                            Button("改存到根目录") { model.useRoot(for: id) }
                                .buttonStyle(.link)
                                .font(.system(size: 12))
                        }
                        if model.isDraftLocked(id), model.activeDraftID != id {
                            Text("录音已中断，可恢复并保存")
                                .font(.system(size: 12))
                                .foregroundStyle(TingjianTheme.warning)
                        }
                        if let issue = model.recordingTargetIssue(for: id) {
                            Text(issue)
                                .font(.system(size: 12))
                                .foregroundStyle(TingjianTheme.warning)
                        }
                    }

                    if model.recordingBusy {
                        Text("另一份录音正在进行或等待保存")
                            .font(.system(size: 12))
                            .foregroundStyle(TingjianTheme.secondaryInk)
                    }

                    if model.nextInputUnavailable {
                        Label("所选输入设备不可用，请在底栏选择可用设备。", systemImage: "mic.slash")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TingjianTheme.warning)
                            .padding(.top, 3)
                    }
                }
                if let id = model.selection.draftID {
                    if model.isDraftLocked(id), model.activeDraftID != id {
                        Button("恢复并保存") { Task { await model.recoverDraft(id) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.recordingBusy)
                    } else {
                        Button { model.beginRecording() } label: {
                            HStack(spacing: 10) {
                                Text("开始录音").fontWeight(.semibold)
                                Text("⌘↩").font(.system(.caption, design: .monospaced))
                            }
                            .padding(.horizontal, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(TingjianTheme.record)
                        .controlSize(.large)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canStartRecording)
                        .accessibilityLabel("开始录音")
                        .accessibilityIdentifier("start")
                    }
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 600)
            .padding(.horizontal, 28)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, minHeight: height)
        }
    }

    private func recordingFolderLink(_ folder: URL) -> some View {
        Text((folder.path as NSString).abbreviatingWithTildeInPath)
            .font(.system(size: 14))
            .foregroundStyle(TingjianTheme.accent)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .gesture(
                TapGesture().modifiers(.command)
                    .onEnded { openRecordingFolder(folder) }
                    .exclusively(before: TapGesture(count: 2).onEnded { openRecordingFolder(folder) })
            )
            .help("按住 ⌘ 单击或双击，在 Finder 中打开")
            .accessibilityAddTraits(.isLink)
            .accessibilityHint("在 Finder 中打开录音保存位置")
            .accessibilityAction { openRecordingFolder(folder) }
    }

    private func openRecordingFolder(_ folder: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
           isDirectory.boolValue, NSWorkspace.shared.open(folder) {
            return
        }

        let alert = NSAlert()
        alert.messageText = "录音保存位置不可用"
        alert.informativeText = folder.path
        alert.addButton(withTitle: "好")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private var emptyTranscript: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: rec.phase == .recording ? "waveform" : "text.alignleft")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(rec.phase == .recording ? TingjianTheme.record : TingjianTheme.accent)
            Text(emptyTitle)
                .font(.system(size: 20, weight: .semibold))
            Text(emptyDetail)
                .font(.system(size: 13))
                .foregroundStyle(TingjianTheme.secondaryInk)
                .lineSpacing(4)
                .frame(maxWidth: 520, alignment: .leading)
        }
        .padding(.top, 40)
        .padding(.bottom, 20)
    }

    private var emptyTitle: String {
        switch rec.phase {
        case .starting: return "正在准备录音"
        case .recording: return "正在聆听"
        case .paused: return "录音已暂停"
        case .finalizing: return "正在收尾"
        case .finished: return "本次没有识别出文字"
        case .idle: return "从一节课开始"
        }
    }

    private var emptyDetail: String {
        switch rec.phase {
        case .starting: return "正在检查输入与本地保存目录,尚未开始采集音频。"
        case .recording: return "说话后,确认文字会沉淀在这里;静音时没有文字属于正常现象。"
        case .paused: return "暂停期间不会采集声音;继续后时间轴接着累计。"
        case .finalizing: return "正在完成音频保存与转写收尾,不会显示没有依据的进度百分比。"
        case .finished: return "音频仍然可以打开;静音或识别失败都可能没有文字。"
        case .idle: return "点击开始后,转写正文会按时间持续出现在这里。"
        }
    }

    private func followLatest(_ proxy: ScrollViewProxy) {
        guard model.atBottom else { return }
        if reduceMotion { proxy.scrollTo("latest", anchor: .bottom) }
        else { withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo("latest", anchor: .bottom) } }
    }
}

// MARK: - 文件夹

private struct DirectoryDetail: View {
    let url: URL
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var rec: Recorder

    private var entries: [LibraryEntry]? { model.childrenByDirectory[url.standardizedFileURL] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(url.lastPathComponent).font(.system(size: 22, weight: .semibold))
                        Text(model.isRootDirectory(url) ? "资料库根目录" : (model.isRecordingDirectory(url) ? "录音文件夹" : "项目文件夹"))
                            .font(.system(size: 12))
                            .foregroundStyle(TingjianTheme.secondaryInk)
                    }
                    Spacer()
                    Button {
                        model.newRecording(in: url)
                    } label: {
                        Label("在此录音", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TingjianTheme.accent)

                    Button("新建项目…") { model.newProjectRequest = true }
                        .buttonStyle(.bordered)
                }

                if let error = model.directoryErrors[url.standardizedFileURL] {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(TingjianTheme.warning)
                        .textSelection(.enabled)
                } else if let entries {
                    if entries.isEmpty {
                        Text("这个文件夹还是空的。录音或新建项目会在这里生成内容。")
                            .font(.system(size: 13))
                            .foregroundStyle(TingjianTheme.secondaryInk)
                    } else {
                        VStack(spacing: 1) {
                            ForEach(entries) { entry in
                                DirectoryRow(entry: entry)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10).fill(TingjianTheme.controlSurface))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(TingjianTheme.hairline, lineWidth: 1))
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
    }
}

private struct DirectoryRow: View {
    let entry: LibraryEntry
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var rec: Recorder

    var body: some View {
        Button {
            switch entry.kind {
            case .directory:
                model.toggleExpansion(entry.url)
                model.select(.directory(entry.url))
            case .audio: model.select(.audio(entry.url))
            case .document: model.select(.document(entry.url))
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.kind == .directory ? (model.isRecordingDirectory(entry.url) ? "waveform.badge.mic" : "folder")
                                  : (entry.kind == .audio ? "waveform" : "doc.text"))
                    .foregroundStyle(entry.kind == .audio ? TingjianTheme.accent : TingjianTheme.secondaryInk)
                    .frame(width: 16)
                let parts = entry.kind == .directory ? recordingNameParts(entry.name) : nil
                Text(parts?.course ?? entry.name).font(.system(size: 13))
                if let parts {
                    Text(parts.date).font(.system(size: 10)).foregroundStyle(TingjianTheme.secondaryInk)
                }
                if model.isRecordingDirectory(entry.url) { Text("录音").font(.system(size: 10)).foregroundStyle(TingjianTheme.record) }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(TingjianTheme.tertiaryInk)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("打开") {
                switch entry.kind {
                case .directory: model.select(.directory(entry.url))
                case .audio: model.select(.audio(entry.url))
                case .document: model.select(.document(entry.url))
                }
            }
            if entry.kind == .document {
                Button("打开关联音频") { model.openLinkedAudio(for: entry.url) }
            }
            Divider()
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Button("重命名…") { model.requestRename(entry.url) }
                .disabled(rec.isActive)
            Button("移动到…") { model.requestMove(entry.url) }
                .disabled(rec.isActive)
            Divider()
            Button("移入废纸篓…", role: .destructive) { model.requestTrash(entry.url) }
                .disabled(rec.isActive)
        }
        .onDrag { WorkspaceDragItem.file(entry.url).provider() }
    }
}

// MARK: - 文稿

private struct DocumentDetail: View {
    let url: URL
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var rec: Recorder
    @EnvironmentObject private var playback: PlaybackModel

    private var doc: OpenDocument? {
        guard let doc = model.openDocument, doc.url.standardizedFileURL == url.standardizedFileURL else { return nil }
        return doc
    }

    private var scrollPosition: Binding<ScrollPosition> {
        Binding {
            if let point = model.scrollPoint(for: url) {
                return ScrollPosition(idType: Int.self, point: point)
            }
            if let anchor = model.scrollAnchor(for: url) {
                return ScrollPosition(id: anchor, anchor: .top)
            }
            return ScrollPosition(idType: Int.self, point: .zero)
        } set: { position in
            model.setScrollPoint(position.point, for: url)
            if let anchor = position.viewID(type: Int.self) {
                model.setScrollAnchor(anchor, for: url)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let usesGutter = geo.size.width >= 640
            ScrollView {
                if let doc {
                    VStack(alignment: .leading, spacing: 0) {
                        documentHeader(doc)
                        if let error = doc.error {
                            label(error, systemImage: "exclamationmark.triangle.fill", tone: TingjianTheme.warning)
                                .padding(.top, 12)
                        }
                        if doc.lines.isEmpty {
                            Text(doc.text)
                                .font(.system(size: 16))
                                .lineSpacing(6)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 18)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(doc.lines) { line in
                                    DocumentLineRow(line: line, usesGutter: usesGutter, linkedAudio: doc.linkedAudio)
                                        .id(line.id)
                                }
                            }
                            .scrollTargetLayout()
                            .padding(.top, 12)
                            DisclosureGroup("查看原文") {
                                Text(doc.text)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(TingjianTheme.secondaryInk)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 8)
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(TingjianTheme.tertiaryInk)
                            .padding(.top, 22)
                        }
                    }
                    .frame(maxWidth: 960, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 28)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                } else if let error = model.directoryErrors[url.standardizedFileURL] {
                    Text(error).font(.system(size: 13)).foregroundStyle(TingjianTheme.warning).padding(24)
                } else {
                    ProgressView("正在读取文稿…")
                        .controlSize(.small)
                        .padding(40)
                        .frame(maxWidth: .infinity)
                }
            }
            .scrollPosition(scrollPosition, anchor: .top)
        }
    }

    private func documentHeader(_ doc: OpenDocument) -> some View {
        HStack(spacing: 12) {
            if let audio = doc.linkedAudio {
                Label(audio.lastPathComponent, systemImage: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(TingjianTheme.secondaryInk)
                    .help(audio.path)
            } else {
                Label("未找到关联音频", systemImage: "speaker.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(TingjianTheme.tertiaryInk)
            }
            correctionStatus(doc)
        }
    }

    @ViewBuilder
    private func correctionStatus(_ doc: OpenDocument) -> some View {
        switch model.correctionState(for: doc.url) {
        case .idle:
            EmptyView()
        case .running(let done, let total):
            HStack(spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 100)
                Text(total == 0 ? "正在纠正…" : "正在纠正 \(done)/\(total)")
                    .font(.system(size: 11))
                    .foregroundStyle(TingjianTheme.secondaryInk)
                Button("取消") { model.cancelCorrection() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        case .done(let file):
            VStack(alignment: .leading, spacing: 2) {
                label("已生成 \(file)", systemImage: "checkmark.circle.fill", tone: TingjianTheme.accent)
                Text(model.correctionUsage[doc.url.standardizedFileURL]?.summary ?? "服务用量未报告")
                    .font(.system(size: 9))
                    .foregroundStyle(TingjianTheme.tertiaryInk)
                    .lineLimit(2)
            }
        case .failed(let detail):
            label(detail, systemImage: "exclamationmark.triangle.fill", tone: TingjianTheme.warning)
        }
    }

    private func label(_ text: String, systemImage: String, tone: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11))
            .foregroundStyle(tone)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DocumentLineRow: View {
    let line: DocumentLine
    let usesGutter: Bool
    let linkedAudio: URL?
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var rec: Recorder
    @EnvironmentObject private var playback: PlaybackModel

    private var unavailableReason: String? {
        guard !rec.isActive else { return "录音进行中，结束后可定位回听" }
        guard let linkedAudio else { return "文稿没有可播放的关联音频" }
        guard let seconds = AppModel.parseTimecode(line.time) else { return "时间戳无法解析" }
        if playback.currentURL?.standardizedFileURL == linkedAudio.standardizedFileURL,
           playback.canSeek, seconds >= playback.duration {
            return "该时间点超出音频时长"
        }
        return nil
    }

    var body: some View {
        if usesGutter {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                timestamp.frame(width: 66, alignment: .trailing)
                text
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                timestamp
                text
            }
        }
    }

    private var timestamp: some View {
        Button {
            Task { await model.seek(toTimecode: line.time) }
        } label: {
            Text(line.time)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(unavailableReason == nil ? TingjianTheme.accent : TingjianTheme.tertiaryInk)
        }
        .buttonStyle(.plain)
        .disabled(unavailableReason != nil)
        .help(unavailableReason ?? "从 \(line.time) 定位")
        .accessibilityLabel("定位到 \(line.time)")
    }

    private var text: some View {
        Text(line.text)
            .font(.system(size: 16, weight: .regular))
            .lineSpacing(5)
            .foregroundStyle(TingjianTheme.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 音频

private struct AudioDetail: View {
    let url: URL
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlaybackModel
    @EnvironmentObject private var rec: Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(TingjianTheme.accent)
            Text(url.lastPathComponent).font(.system(size: 22, weight: .semibold))
            if let error = model.audioError ?? playback.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(TingjianTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if playback.currentURL?.standardizedFileURL == url.standardizedFileURL {
                Text("时长 \(Timecode.string(playback.duration)) · 使用下方控制带播放与拖动进度。")
                    .font(.system(size: 13))
                    .foregroundStyle(TingjianTheme.secondaryInk)
            }
            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                Button("重命名…") { model.requestRename(url) }
                    .disabled(rec.isActive)
                Button("移动到…") { model.requestMove(url) }
                    .disabled(rec.isActive)
            }
            Spacer()
        }
        .frame(maxWidth: 960, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 24)
        .padding(.top, 30)
    }
}

// MARK: - 控制带

private struct ControlBand: View {
    private var displayedPosition: Double { playback.displayedPosition }

    private var progressSlider: some View {
        Slider(value: Binding(get: { displayedPosition }, set: playback.previewSeek),
               in: 0...max(playback.duration, 0.01), onEditingChanged: playback.setScrubbing)
            .disabled(!playback.canSeek)
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var rec: Recorder
    @EnvironmentObject private var playback: PlaybackModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if rec.isActive {
                recordingControls
            } else if playback.isLoaded {
                playbackControls
            } else {
                idleControls
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 60)
        .background(TingjianTheme.windowSurface.opacity(0.7))
    }

    // 录音中
    private var recordingControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                RecordingTime(label: rec.phase == .paused ? "已暂停" : "录音中",
                              duration: rec.duration, active: rec.phase == .recording)
                LevelMeter(level: rec.level, active: rec.phase == .recording, reduceMotion: reduceMotion)
                    .frame(width: 120)
                Spacer(minLength: 8)
                pauseResumeButton
                stopButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    RecordingTime(label: rec.phase == .paused ? "已暂停" : "录音中",
                                  duration: rec.duration, active: rec.phase == .recording)
                    LevelMeter(level: rec.level, active: rec.phase == .recording, reduceMotion: reduceMotion)
                }
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    pauseResumeButton
                    stopButton
                }
            }
        }
    }

    private var pauseResumeButton: some View {
        Group {
            if rec.phase == .recording {
                Button {
                    Task { await rec.pause() }
                } label: {
                    Label("暂停", systemImage: "pause.fill")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .accessibilityIdentifier("pause")
            } else {
                Button {
                    Task { await rec.resume() }
                } label: {
                    Label("继续", systemImage: "play.fill")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .accessibilityIdentifier("resume")
            }
        }
        .buttonStyle(.bordered)
        .disabled(rec.isChangingInput || rec.phase == .finalizing || rec.phase == .starting)
    }

    private var stopButton: some View {
        Button {
            Task { await rec.stop() }
        } label: {
            Label("结束", systemImage: "stop.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(TingjianTheme.record)
        .keyboardShortcut("s", modifiers: [.command, .shift])
        .disabled(rec.phase == .finalizing)
        .help("结束并保存(⌘⇧S)")
    }

    // 播放中
    private var playbackControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                playPauseButton
                Text(Timecode.string(displayedPosition))
                    .font(.system(size: 12, design: .monospaced)).monospacedDigit()
                progressSlider
                    .frame(minWidth: 120)
                Text(Timecode.string(playback.duration))
                    .font(.system(size: 12, design: .monospaced)).monospacedDigit()
                Spacer(minLength: 8)
                closePlayerButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    playPauseButton
                    progressSlider
                    Text("\(Timecode.string(displayedPosition)) / \(Timecode.string(playback.duration))")
                        .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    closePlayerButton
                }
            }
        }
    }

    private var playPauseButton: some View {
        Button {
            playback.togglePlay()
        } label: {
            Label(playback.isPlaying ? "暂停" : "播放", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                .labelStyle(.iconOnly)
                .frame(width: 24)
        }
        .buttonStyle(.borderedProminent)
        .tint(TingjianTheme.accent)
        .disabled(!playback.canSeek)
        .accessibilityLabel(playback.isPlaying ? "暂停播放" : "播放")
    }

    private var closePlayerButton: some View {
        Button {
            playback.stop()
        } label: {
            Label("关闭音频", systemImage: "xmark.circle")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("关闭音频播放")
        .accessibilityLabel("关闭音频")
    }

    // 空闲/完成
    private var idleControls: some View {
        HStack(spacing: 12) {
            if case .pending = rec.save {
                Label("音频与文字在本地,尚未写入目标目录", systemImage: "tray.and.arrow.down")
                    .font(.system(size: 12))
                    .foregroundStyle(TingjianTheme.warning)
                Spacer()
                if model.canChangePendingSaveDestination {
                    Button("更换保存位置…") { model.choosePendingSaveDestination() }
                        .buttonStyle(.bordered)
                }
                Button {
                    Task { await rec.retrySave() }
                } label: {
                    Label("重试保存", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(TingjianTheme.warning)
            } else if case .failed = rec.save {
                Label("文字文件保存失败", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(TingjianTheme.record)
                Spacer()
                if model.canChangePendingSaveDestination {
                    Button("更换保存位置…") { model.choosePendingSaveDestination() }
                        .buttonStyle(.bordered)
                }
                Button {
                    Task { await rec.retrySave() }
                } label: {
                    Label("重试保存", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(TingjianTheme.record)
            } else if model.nextInputUnavailable {
                Label("保存的输入设备不可用", systemImage: "mic.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TingjianTheme.warning)
                Spacer()
                Text("请在底栏选择可用的输入设备")
                    .font(.system(size: 12))
                    .foregroundStyle(TingjianTheme.secondaryInk)
            } else {
                Label("准备就绪", systemImage: "waveform")
                    .font(.system(size: 12))
                    .foregroundStyle(TingjianTheme.secondaryInk)
                Spacer()
            }
        }
    }
}

// MARK: - 状态条

private struct IssueItem: Identifiable {
    enum Remedy: Equatable {
        case none, retrySave, installModel, recover
        case retryCorrection(URL)
    }
    let id: String
    let title: String
    let detail: String
    let path: String?
    let tone: TingjianTone
    let remedy: Remedy
}

private struct QuickInputMenu: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var rec: Recorder

    var body: some View {
        Menu {
            if !rec.isActive {
                Button {
                    model.useConfiguredInput()
                } label: {
                    option("使用设置中的默认设备", selected: model.isUsingConfiguredInput)
                }
            }
            Button {
                model.selectQuickInput(nil)
            } label: {
                option("系统默认", selected: !rec.isActive && !model.isUsingConfiguredInput && model.quickInputUID == nil)
            }
            .disabled(model.inputDevices.isEmpty)
            ForEach(model.inputDevices) { device in
                Button {
                    model.selectQuickInput(device.id)
                } label: {
                    option(device.name, selected: (rec.isActive || !model.isUsingConfiguredInput) && model.quickInputUID == device.id)
                }
            }
            if model.inputDevices.isEmpty {
                Text("没有可用的输入设备")
            }
        } label: {
            Label(rec.isChangingInput ? "正在切换…" : model.quickInputDescription, systemImage: "mic")
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 150)
        .disabled(!model.canSelectQuickInput || AppModel.testAudio != nil)
        .help(model.inputSwitchError ?? (rec.isActive ? "切换当前录音的输入设备" : "选择下一次录音的输入设备"))
        .accessibilityLabel("快捷切换输入设备")
        .accessibilityValue(model.quickInputDescription)
    }

    @ViewBuilder
    private func option(_ name: String, selected: Bool) -> some View {
        if selected { Label(name, systemImage: "checkmark") }
        else { Text(name) }
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var rec: Recorder
    @Binding var showIssues: Bool
    let issues: [IssueItem]

    var body: some View {
        HStack(spacing: 12) {
            if rec.isActive {
                HStack(spacing: 8) {
                    Circle().fill(TingjianTheme.record).frame(width: 6, height: 6)
                    Text("\(recordText) · \(transcribeText) · \(saveText)")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TingjianTheme.secondaryInk)
            } else if !issues.isEmpty {
                Label("\(issues.count) 个问题", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TingjianTheme.warning)
            } else {
                Label("就绪", systemImage: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(TingjianTheme.tertiaryInk)
            }
            Spacer(minLength: 8)
            QuickInputMenu()
            Button {
                showIssues = true
            } label: {
                Text("详情").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("状态详情")
            .popover(isPresented: $showIssues, arrowEdge: .bottom) {
                IssuesPopover(issues: issues, onDismiss: { showIssues = false })
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 26)
        .background(TingjianTheme.windowSurface)
    }

    private var recordText: String {
        switch rec.phase {
        case .idle: "未开始"
        case .starting: "准备中"
        case .recording: "录音中"
        case .paused: "已暂停"
        case .finalizing: "结束中"
        case .finished: "已结束"
        }
    }

    private var transcribeText: String {
        switch rec.transcribe {
        case .idle: "待命"
        case .preparing: "准备中"
        case .running: "转写中"
        case .recovering(let attempt): "恢复中(第 \(attempt) 次)"
        case .needsModel: "缺少中文模型"
        case .unsupported: "不可用"
        case .failed: "异常"
        case .finishing: "收尾中"
        case .done: "完成"
        case .incomplete: rec.finalStatus == .failed ? "识别失败" : "部分完成"
        }
    }

    private var saveText: String {
        switch rec.save {
        case .idle: rec.isActive ? "本地持续保存中" : "—"
        case .saving: "写入目标目录中"
        case .saved: "已写入目录"
        case .pending: "待保存,本地已保留"
        case .failed: "保存失败"
        }
    }
}

private struct IssuesPopover: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var rec: Recorder
    let issues: [IssueItem]
    let onDismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("状态详情").font(.system(size: 13, weight: .semibold))
                if issues.isEmpty {
                    Text("没有需要处理的问题。")
                        .font(.system(size: 12))
                        .foregroundStyle(TingjianTheme.secondaryInk)
                }
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: issue.tone == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.tone.color)
                                .font(.system(size: 11))
                            Text(issue.title).font(.system(size: 12, weight: .semibold))
                        }
                        Text(issue.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(TingjianTheme.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            remedyButton(issue.remedy)
                            if let path = issue.path {
                                Button("复制路径") { copyPath(path) }
                                    .buttonStyle(.bordered).controlSize(.small)
                                Button("打开位置") { openPath(path) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    if issue.id != issues.last?.id {
                        Rectangle().fill(TingjianTheme.hairline).frame(height: 1)
                    }
                }
                if let detail = saveDetail {
                    Rectangle().fill(TingjianTheme.hairline).frame(height: 1)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(TingjianTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("关闭") { onDismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(14)
        }
        .frame(width: 380)
        .frame(maxHeight: 460)
    }

    private var saveDetail: String? {
        switch rec.save {
        case .saved(let path): return "已写入目录:\(path)。这是本地文件写入结果,不代表云同步已完成。"
        case .pending(let path, _): return "本地恢复文件:\(path)"
        default: return nil
        }
    }

    @ViewBuilder
    private func remedyButton(_ remedy: IssueItem.Remedy) -> some View {
        switch remedy {
        case .none:
            EmptyView()
        case .retrySave:
            Button("重试保存") { Task { await rec.retrySave() } }
                .buttonStyle(.borderedProminent).controlSize(.small)
            if model.canChangePendingSaveDestination {
                Button("更换保存位置…") { model.choosePendingSaveDestination() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        case .installModel:
            if let progress = rec.modelProgress {
                ProgressView(value: progress).frame(width: 90)
                Text("\(Int((progress * 100).rounded()))%").font(.system(size: 10)).monospacedDigit()
            } else {
                Button("下载中文模型") { Task { await rec.installModel() } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        case .recover:
            Button("恢复并保存") { Task { await model.recoverFirst() } }
                .buttonStyle(.borderedProminent).controlSize(.small)
        case .retryCorrection(let url):
            Button("重试纠正") { model.startCorrection(document: url) }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!model.llmConfigured || model.isCorrecting)
        }
    }
}

// MARK: - 通用组件

private struct SegmentRow: View {
    let segment: Segment
    let usesGutter: Bool

    var body: some View {
        if usesGutter {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                timestamp.frame(width: 66, alignment: .trailing)
                content
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                timestamp
                content
            }
        }
    }

    private var timestamp: some View {
        Text(Timecode.string(segment.start))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(TingjianTheme.tertiaryInk)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var content: some View {
        if segment.incomplete {
            VStack(alignment: .leading, spacing: 6) {
                Label("此段转写不完整(\(Timecode.string(segment.start))–\(Timecode.string(segment.end)))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(TingjianTheme.warning)
                Text("音频仍已保存;这段时间没有可靠的识别文字。")
                    .font(.system(size: 12))
                    .foregroundStyle(TingjianTheme.secondaryInk)
            }
        } else {
            Text(segment.text)
                .font(.system(size: 16))
                .lineSpacing(6)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VolatileRow: View {
    let text: String
    let usesGutter: Bool

    var body: some View {
        if usesGutter {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                label.frame(width: 66, alignment: .trailing)
                textContent
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                label
                textContent
            }
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Circle().fill(TingjianTheme.accent).frame(width: 5, height: 5)
            Text("实时")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(TingjianTheme.accent)
    }

    private var textContent: some View {
        Text(text)
            .font(.system(size: 16))
            .lineSpacing(6)
            .foregroundStyle(TingjianTheme.secondaryInk)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RecordingTime: View {
    let label: String
    let duration: Double
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(active ? TingjianTheme.record : TingjianTheme.tertiaryInk.opacity(0.55))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(TingjianTheme.secondaryInk)
                Text(Timecode.string(duration))
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label),时长 \(Timecode.string(duration))")
    }
}

private struct LevelMeter: View {
    let level: Float
    let active: Bool
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                let value = active ? CGFloat(min(max(level, 0), 1)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(TingjianTheme.tertiaryInk.opacity(0.16))
                    Capsule()
                        .fill(active ? TingjianTheme.accent : TingjianTheme.tertiaryInk.opacity(0.35))
                        .frame(width: max(3, geometry.size.width * value))
                }
            }
            .frame(height: 5)
            Text(active ? "输入音量" : "无输入")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TingjianTheme.tertiaryInk)
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.12), value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("输入音量")
        .accessibilityValue(active ? "\(Int((min(max(level, 0), 1) * 100).rounded()))%" : "当前无输入")
    }
}

private func copyPath(_ path: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
}

private func openPath(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}


private struct InitialSetupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("设置听笺").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text("录音与文稿的保存位置").font(.headline)
                Text((model.saveRoot.path as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(TingjianTheme.secondaryInk)
                    .textSelection(.enabled)
                Button("选择文件夹…") { model.chooseSaveRoot() }
                if let notice = model.libraryNotice {
                    Text(notice).foregroundStyle(TingjianTheme.warning)
                }
            }
            Divider()
            SpeechModelControl()
            Divider()
            Toggle("启用文字纠正", isOn: $model.llmEnabled)
            Text("可在设置中选择网关和纠正方式。")
                .foregroundStyle(TingjianTheme.secondaryInk)
            HStack {
                Spacer()
                if model.llmEnabled {
                    Button("完成并打开设置") {
                        model.completeInitialSetup()
                        openSettings()
                    }
                }
                Button("完成设置") { model.completeInitialSetup() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 475)
    }
}
