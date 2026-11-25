import AppKit
import SwiftUI
import TingjianCore

struct TranscriptScrollSnapshot: Equatable {
    let contentHeight: CGFloat
    let distanceFromBottom: CGFloat
}

struct CurrentRecordingView: View {
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
        VStack(spacing: 0) {
            if rec.phase == .recording || rec.phase == .paused {
                HStack(spacing: 10) {
                    Text("课程名称")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TingjianTheme.secondaryInk)
                    TextField("录音中可随时补填或修改课程名", text: Binding(
                        get: { rec.courseName },
                        set: { model.updateActiveRecordingCourseName($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 300)
                    .accessibilityLabel("当前录音课程名称")
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(TingjianTheme.windowSurface.opacity(0.6))
                Rectangle().fill(TingjianTheme.hairline).frame(height: 1)
            }
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

struct SegmentRow: View {
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

struct VolatileRow: View {
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

struct RecordingTime: View {
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

struct LevelMeter: View {
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
