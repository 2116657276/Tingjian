import AppKit
import SwiftUI
import TingjianCore

struct WorkspaceRefreshButton: View {
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

struct LibraryEntryFileMenuItems: View {
    let entry: LibraryEntry
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var rec: Recorder

    var body: some View {
        if entry.kind == .document {
            Button("打开关联音频") { model.openLinkedAudio(for: entry.url) }
            Button("在默认应用中打开") { NSWorkspace.shared.open(entry.url) }
        } else if entry.kind == .audio {
            Button("重新转写") { model.retranscribeAudio(entry.url) }
                .disabled(model.isRetranscribing || rec.isActive)
        }
    }
}

struct LibraryEntryManageMenuItems: View {
    let url: URL
    let mutationDisabled: Bool
    var separateLocationSection: Bool = true
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button("重命名…") { model.requestRename(url) }
            .disabled(mutationDisabled)
        Button("移动到…") { model.requestMove(url) }
            .disabled(mutationDisabled)
        if separateLocationSection {
            Divider()
        }
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("复制路径") { copyPath(url.path) }
        Divider()
        Button("移入废纸篓…", role: .destructive) { model.requestTrash(url) }
            .disabled(mutationDisabled)
    }
}

func copyPath(_ path: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
}

func openPath(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

final class RenameSheetState: ObservableObject {
    @Published var editFullDiskName = false
}

struct RenameSheet: View {
    let request: RenameRequest
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sheetState = RenameSheetState()

    private var isDirectory: Bool {
        var value: ObjCBool = false
        FileManager.default.fileExists(atPath: request.url.path, isDirectory: &value)
        return value.boolValue
    }

    private var datedParts: RecordingNameParts? {
        guard isDirectory else { return nil }
        return Paths.parseRecordingName(request.url.lastPathComponent)
    }

    private var canSubmit: Bool {
        let trimmed = model.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if datedParts != nil, !sheetState.editFullDiskName {
            return true // 允许清空课程名仅保留日期前缀
        }
        return !trimmed.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名").font(.system(size: 15, weight: .semibold))
            Text(request.url.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(TingjianTheme.secondaryInk)
                .lineLimit(1)
                .truncationMode(.middle)
            if let parts = datedParts, !sheetState.editFullDiskName {
                Text("将自动保留日期前缀：\(parts.prefix)")
                    .font(.system(size: 11))
                    .foregroundStyle(TingjianTheme.secondaryInk)
            }
            TextField(
                datedParts != nil && !sheetState.editFullDiskName
                    ? "课程名称（留空则仅保留日期）"
                    : (isDirectory ? "新名称" : "新名称（扩展名保持不变）"),
                text: $model.renameDraft
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit(commit)
            if isDirectory {
                Toggle("同步更换直属文件名前缀", isOn: $model.syncRenamePrefixes)
            }
            if let parts = datedParts {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("编辑完整磁盘名称", isOn: $sheetState.editFullDiskName)
                        .onChange(of: sheetState.editFullDiskName) { _, full in
                            model.renameDraft = full ? request.url.lastPathComponent : parts.course
                        }
                    Text("移除日期前缀后，该文件夹将不再按时间线排序。")
                        .font(.system(size: 10))
                        .foregroundStyle(TingjianTheme.tertiaryInk)
                }
            }
            Text(isDirectory
                 ? "仅替换直属文件名中与原项目名相同的开头，不修改子文件夹。"
                 : "同目录文稿中的音频引用与来源链接会同步更新；同名目标会被拒绝。")
                .font(.system(size: 11))
                .foregroundStyle(TingjianTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("重命名") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(18)
        .frame(width: 430)
        .onAppear {
            model.syncRenamePrefixes = false
            sheetState.editFullDiskName = false
            if let parts = datedParts {
                model.renameDraft = parts.course
            } else {
                model.renameDraft = isDirectory ? request.url.lastPathComponent : request.url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private func commit() {
        guard canSubmit else { return }
        let finalName: String
        if let parts = datedParts, !sheetState.editFullDiskName {
            finalName = parts.rebuiltName(course: model.renameDraft)
        } else {
            finalName = model.renameDraft
        }
        dismiss()
        let sync = model.syncRenamePrefixes
        Task { await model.renameEntry(request.url, to: finalName, syncFilePrefixes: sync) }
    }
}

struct NewProjectSheet: View {
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

struct InitialSetupView: View {
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
