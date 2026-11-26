import AppKit
import SwiftUI
import TingjianCore

struct ControlBand: View {
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
            model.requestStopRecording()
        } label: {
            Label("结束", systemImage: "stop.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(TingjianTheme.record)
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(rec.phase == .finalizing)
        .help("结束并保存（⌘⇧E）")
    }

    // 播放中
    private var playbackControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                skipBackButton
                playPauseButton
                skipForwardButton
                Text(Timecode.string(displayedPosition))
                    .font(.system(size: 12, design: .monospaced)).monospacedDigit()
                progressSlider
                    .frame(minWidth: 120)
                Text(Timecode.string(playback.duration))
                    .font(.system(size: 12, design: .monospaced)).monospacedDigit()
                playbackRateMenu
                if case .document = model.selection {
                    followScrollToggle
                }
                closePlayerButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    skipBackButton
                    playPauseButton
                    skipForwardButton
                    progressSlider
                    Text("\(Timecode.string(displayedPosition)) / \(Timecode.string(playback.duration))")
                        .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                }
                HStack(spacing: 10) {
                    playbackRateMenu
                    if case .document = model.selection {
                        followScrollToggle
                    }
                    Spacer(minLength: 0)
                    closePlayerButton
                }
            }
        }
    }

    private var skipBackButton: some View {
        Button {
            playback.skip(by: -5)
        } label: {
            Image(systemName: "gobackward.5")
                .font(.system(size: 13))
        }
        .buttonStyle(.borderless)
        .disabled(!playback.canSeek)
        .help("快退 5 秒（⌘[）")
        .accessibilityLabel("快退 5 秒")
    }

    private var skipForwardButton: some View {
        Button {
            playback.skip(by: 10)
        } label: {
            Image(systemName: "goforward.10")
                .font(.system(size: 13))
        }
        .buttonStyle(.borderless)
        .disabled(!playback.canSeek)
        .help("快进 10 秒（⌘]）")
        .accessibilityLabel("快进 10 秒")
    }

    private var playbackRateMenu: some View {
        Menu {
            ForEach(PlaybackModel.supportedRates, id: \.self) { rate in
                let label = rate == 1.0 ? "1.0x（正常）" : (rate == 1.25 ? "1.25x" : (rate == 1.5 ? "1.5x" : "2.0x"))
                Button {
                    playback.rate = rate
                } label: {
                    if abs(playback.rate - rate) < 0.01 {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            Text(playback.rateLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .frame(minWidth: 38)
        }
        .menuStyle(.borderlessButton)
        .disabled(!playback.canSeek)
        .help("播放倍速")
        .accessibilityLabel("播放倍速")
        .accessibilityValue(playback.rateLabel)
    }

    private var followScrollToggle: some View {
        Button {
            model.followPlaybackScroll.toggle()
        } label: {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 12))
                .foregroundStyle(model.followPlaybackScroll ? TingjianTheme.accent : TingjianTheme.tertiaryInk)
        }
        .buttonStyle(.borderless)
        .help(model.followPlaybackScroll ? "已开启跟随播放滚动（点击关闭）" : "跟随播放自动滚动文稿")
        .accessibilityLabel("跟随播放滚动")
        .accessibilityValue(model.followPlaybackScroll ? "已开启" : "已关闭")
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
            model.closePlayback()
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
                Label("音频与文字在本地，尚未写入目标目录", systemImage: "tray.and.arrow.down")
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

struct IssueItem: Identifiable {
    enum Remedy: Equatable {
        case none, retrySave, installModel
        case recover(URL)
        case retryCorrection(URL)
        case dismiss(String)
    }
    let id: String
    let title: String
    let detail: String
    let path: String?
    let tone: TingjianTone
    let remedy: Remedy
}

struct QuickInputMenu: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var rec: Recorder

    var body: some View {
        Menu {
            if !rec.isActive, model.audioInputUID != nil {
                Button {
                    model.useConfiguredInput()
                } label: {
                    option("默认：\(model.defaultInputDescription)", selected: model.isUsingConfiguredInput)
                }
            }
            Button {
                if !rec.isActive && model.audioInputUID == nil {
                    model.useConfiguredInput()
                } else {
                    model.selectQuickInput(nil)
                }
            } label: {
                let isSystemDefaultSelected: Bool = {
                    if rec.isActive { return false }
                    if model.audioInputUID == nil { return model.isUsingConfiguredInput || model.quickInputUID == nil }
                    return !model.isUsingConfiguredInput && model.quickInputUID == nil
                }()
                option("系统默认", selected: isSystemDefaultSelected)
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

struct StatusBar: View {
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
                Button {
                    showIssues.toggle()
                } label: {
                    Label("\(issues.count) 个问题", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TingjianTheme.warning)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看 \(issues.count) 个问题")
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
        case .recovering(let attempt): "恢复中（第 \(attempt) 次）"
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
        case .pending: "待保存，本地已保留"
        case .failed: "保存失败"
        }
    }
}

struct IssuesPopover: View {
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
        case .saved(let path): return "已写入目录：\(path)。这是本地文件写入结果，不代表云同步已完成。"
        case .pending(let path, _): return "本地恢复文件：\(path)"
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
        case .recover(let dir):
            Button("恢复并保存") { Task { await model.recoverSession(dir) } }
                .buttonStyle(.borderedProminent).controlSize(.small)
        case .retryCorrection(let url):
            Button("重试纠正") { model.startCorrection(document: url) }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!model.llmConfigured || model.isCorrecting)
        case .dismiss(let id):
            Button("知道了") { model.dismissIssue(id: id) }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }
}
