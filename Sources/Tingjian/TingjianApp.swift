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
                Button("下一个标签页") { AppModel.shared.activateRelativeTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                Divider()
                Button("关闭当前标签页") { AppModel.shared.closeActiveTab() }
                    .disabled(!AppModel.shared.canCloseActiveTab)
            }
            CommandMenu("资料库") {
                Button("回到当前录音") { AppModel.shared.showCurrentRecording() }
                    .disabled(!AppModel.shared.hasCurrentRecording)
                Divider()
                Button("重命名所选项…") { AppModel.shared.requestRenameSelection() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(AppModel.shared.selection.url == nil)
                Button("移动所选项…") {
                    if let url = AppModel.shared.selection.url {
                        AppModel.shared.requestMove(url)
                    }
                }
                .disabled(AppModel.shared.selection.url == nil)
                Button("移入废纸篓…") { AppModel.shared.requestTrashSelection() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(AppModel.shared.selection.url == nil || AppModel.shared.recorder.isActive)
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
            self?.mainWindow = NSApp.windows.first { window in
                !(window is NSPanel) && window.canBecomeMain
            }
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
        guard rec.isActive else { return .terminateNow }
        if isSavingBeforeTermination {
            restoreMainWindow()
            return .terminateCancel
        }
        isPresentingTerminationAlert = true
        defer { isPresentingTerminationAlert = false }

        let alert = NSAlert()
        alert.messageText = rec.phase == .finalizing ? "正在保存录音" : "仍在录音"
        alert.informativeText = rec.phase == .finalizing
            ? "录音正在保存,请等待完成后再退出。"
            : "结束并保存会先保存音频和文字再退出;继续录音会关闭此提示。"
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
            await rec.stop()
            isSavingBeforeTermination = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 关闭最后一个窗口后取消退出时,SwiftUI 不会自动把主窗口带回前台。
    private func restoreMainWindow() {
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            let window = self?.mainWindow ?? NSApp.windows.first { window in
                !(window is NSPanel) && window.canBecomeMain
            }
            window?.makeKeyAndOrderFront(nil)
            self?.mainWindow = window
        }
    }
}
