import AppKit
import SwiftUI
import TingjianCore

@main
struct TingjianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("听笺", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.recorder)
                .environmentObject(model.playback)
                .frame(minWidth: 620, minHeight: 560)
                .preferredColorScheme(model.colorScheme)
        }
        .defaultSize(width: 1100, height: 760)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建录音") { AppModel.shared.newRecording() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("新建项目…") { AppModel.shared.newProjectRequest = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(AppModel.shared.recorder.isActive)
                Button("关闭标签页") { AppModel.shared.closeActiveTab() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(!AppModel.shared.canCloseActiveTab)
            }
            CommandMenu("标签页") {
                Button("上一个标签页") { AppModel.shared.activateRelativeTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                    .disabled(AppModel.shared.openTabs.isEmpty)
                Button("下一个标签页") { AppModel.shared.activateRelativeTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                    .disabled(AppModel.shared.openTabs.isEmpty)
                Divider()
                Button("关闭当前标签页") { AppModel.shared.closeActiveTab() }
                    .disabled(!AppModel.shared.canCloseActiveTab)
            }
            CommandMenu("查找") {
                Button("在文稿中查找…") { AppModel.shared.presentDocumentSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!AppModel.shared.canSearchCurrentDocument)
                Button("查找下一个") { AppModel.shared.stepDocumentSearch(1) }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(!AppModel.shared.canStepDocumentSearch)
                Button("查找上一个") { AppModel.shared.stepDocumentSearch(-1) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!AppModel.shared.canStepDocumentSearch)
            }
            CommandMenu("播放") {
                Button(AppModel.shared.playback.isPlaying ? "暂停播放" : "开始播放") {
                    AppModel.shared.togglePlaybackIfAvailable()
                }
                .disabled(!AppModel.shared.canControlPlayback)
                Button("快退 5 秒") { AppModel.shared.skipPlayback(by: -5) }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!AppModel.shared.canControlPlayback)
                Button("快进 10 秒") { AppModel.shared.skipPlayback(by: 10) }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!AppModel.shared.canControlPlayback)
                Divider()
                ForEach(PlaybackModel.supportedRates, id: \.self) { rate in
                    let label = rate == 1.0 ? "1.0x（正常）" : (rate == 1.25 ? "1.25x" : (rate == 1.5 ? "1.5x" : "2.0x"))
                    Button((abs(AppModel.shared.playback.rate - rate) < 0.01 ? "✓ " : "") + label) {
                        AppModel.shared.playback.rate = rate
                    }
                }
            }
            CommandMenu("资料库") {
                Button("回到当前录音") { AppModel.shared.showCurrentRecording() }
                    .disabled(!AppModel.shared.hasCurrentRecording)
                Divider()
                Button("重命名所选项…") { AppModel.shared.requestRenameSelection() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!AppModel.shared.canModifyLibrarySelection || AppModel.shared.recorder.isActive)
                Button("移动所选项…") {
                    if let url = AppModel.shared.selection.url {
                        AppModel.shared.requestMove(url)
                    }
                }
                .disabled(!AppModel.shared.canModifyLibrarySelection || AppModel.shared.recorder.isActive)
                Button("移入废纸篓…") { AppModel.shared.requestTrashSelection() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!AppModel.shared.canModifyLibrarySelection || AppModel.shared.recorder.isActive)
                Button("刷新项目列表") {
                    Task { await AppModel.shared.reloadLibrary() }
                }
                .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppModel.shared.currentDirectory])
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.recorder)
                .preferredColorScheme(model.colorScheme)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var mainWindow: NSWindow?
    private var isPresentingTerminationAlert = false
    private var isSavingBeforeTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            let window = self?.findMainWindow()
            self?.mainWindow = window
            AppModel.shared.mainWindow = window
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { restoreMainWindow() }
        return true
    }

    /// 录音中退出:让用户选择“结束并保存”或“取消”。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPresentingTerminationAlert else { return .terminateCancel }

        let rec = AppModel.shared.recorder
        if rec.phase == .starting { rec.cancelStarting(); return .terminateNow }
        guard rec.isActive else {
            guard AppModel.shared.saveNeedsRetry else { return .terminateNow }
            isPresentingTerminationAlert = true
            defer { isPresentingTerminationAlert = false }

            let alert = NSAlert()
            alert.messageText = "上次录音尚未写入目标目录"
            alert.informativeText = "音频与文字仍保存在本机恢复目录，退出后下次打开听笺可继续恢复并保存。"
            alert.addButton(withTitle: "返回保存")
            alert.addButton(withTitle: "仍然退出")
            if alert.runModal() == .alertFirstButtonReturn {
                restoreMainWindow()
                return .terminateCancel
            }
            return .terminateNow
        }
        if isSavingBeforeTermination {
            restoreMainWindow()
            return .terminateCancel
        }
        isPresentingTerminationAlert = true
        defer { isPresentingTerminationAlert = false }

        let alert = NSAlert()
        alert.messageText = rec.phase == .finalizing ? "正在保存录音" : "仍在录音"
        alert.informativeText = rec.phase == .finalizing
            ? "录音正在保存，请等待完成后再退出。"
            : "结束并保存会先保存音频和文字再退出；继续录音会关闭此提示。"
        if rec.phase == .finalizing {
            alert.addButton(withTitle: "好")
            alert.runModal()
            restoreMainWindow()
            return .terminateCancel
        }
        alert.addButton(withTitle: "结束并保存")
        alert.addButton(withTitle: "继续录音")
        guard alert.runModal() == .alertFirstButtonReturn else {
            restoreMainWindow()
            return .terminateCancel
        }
        isSavingBeforeTermination = true
        Task { @MainActor in
            AppModel.shared.flushActiveCourseName()
            await rec.stop()
            isSavingBeforeTermination = false
            if case .saved = rec.save {
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                NSApp.reply(toApplicationShouldTerminate: false)
                restoreMainWindow()
            }
        }
        return .terminateLater
    }

    private func findMainWindow() -> NSWindow? {
        NSApp.windows.first { window in
            !(window is NSPanel)
                && window.canBecomeMain
                && window.identifier?.rawValue == "main"
        } ?? NSApp.windows.first { window in
            !(window is NSPanel)
                && window.canBecomeMain
                && !(window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") ?? false)
        }
    }

    /// 关闭最后一个窗口后取消退出时,SwiftUI 不会自动把主窗口带回前台。
    private func restoreMainWindow() {
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            let window = self?.mainWindow ?? self?.findMainWindow()
            window?.makeKeyAndOrderFront(nil)
            self?.mainWindow = window
            AppModel.shared.mainWindow = window
        }
    }
}
