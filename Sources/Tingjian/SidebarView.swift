import AppKit
import SwiftUI
import TingjianCore

enum WorkspaceDragItem: Codable {
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

final class DropHighlight: ObservableObject {
    @Published var targeted = false
}

struct SidebarPanel: View {
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
                .disabled(rec.isActive)
                .help("在当前文件夹新建项目")
                .accessibilityLabel("新建项目")

                Menu {
                    ForEach(LibrarySortOrder.allCases) { order in
                        Button {
                            model.librarySortOrder = order
                        } label: {
                            if model.librarySortOrder == order {
                                Label(order.title, systemImage: "checkmark")
                            } else {
                                Text(order.title)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20, height: 16)
                .help("排序：\(model.librarySortOrder.title)")
                .accessibilityLabel("项目排序")

                WorkspaceRefreshButton(title: "刷新项目列表", refreshing: model.refreshingLibrary) {
                    await model.refreshLibrary()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    RootDirectoryRow()

                    if !model.drafts.isEmpty {
                        Text("暂存")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(TingjianTheme.tertiaryInk)
                            .padding(.horizontal, 12)
                            .padding(.top, 5.3)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(model.drafts) { draft in
                            RecordingDraftRow(draft: draft)
                        }
                    }

                    if let entries = model.childrenByDirectory[model.saveRoot.standardizedFileURL] {
                        if entries.isEmpty {
                            Text("还没有项目。录音会自动生成文件夹，也可以用加号新建。")
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
                .disabled(rec.isActive)
                Menu("排序方式") {
                    ForEach(LibrarySortOrder.allCases) { order in
                        Button {
                            model.librarySortOrder = order
                        } label: {
                            if model.librarySortOrder == order {
                                Label(order.title, systemImage: "checkmark")
                            } else {
                                Text(order.title)
                            }
                        }
                    }
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

struct RecordingDraftRow: View {
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

struct RootDirectoryRow: View {
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

struct SidebarRow: View {
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

    private var nameParts: RecordingNameParts? {
        guard entry.kind == .directory else { return nil }
        return Paths.parseRecordingName(entry.name)
    }

    private var displayName: String {
        nameParts?.displayTitle ?? entry.name
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
                HStack(alignment: nameParts == nil ? .center : .top, spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(iconColor)
                        .frame(width: 14)
                        .padding(.top, nameParts == nil ? 0 : 2)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(displayName)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(nameParts == nil ? .middle : .tail)
                            Spacer(minLength: 4)
                            if model.isRecordingDirectory(entry.url), entry.kind == .directory {
                                Circle().fill(TingjianTheme.record).frame(width: 4, height: 4)
                            }
                        }
                        if let parts = nameParts {
                            Text(parts.compactDate)
                                .font(.system(size: 9.5, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(TingjianTheme.tertiaryInk)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
                .padding(.trailing, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected || dropHighlight.targeted ? TingjianTheme.accentSoft : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.kind == .directory ? "文件夹" : "文件") \(displayName)\(nameParts.map { "，\($0.fullDate)" } ?? "")")
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
            LibraryEntryFileMenuItems(entry: entry)
        }
        Divider()
        LibraryEntryManageMenuItems(url: entry.url, mutationDisabled: model.recorder.isActive)
    }
}
