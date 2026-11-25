import AppKit
import SwiftUI
import TingjianCore

final class DocumentViewState: ObservableObject {
    @Published var showAllNotes = false
}

struct DocumentDetail: View {
    let url: URL
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var rec: Recorder
    @EnvironmentObject private var playback: PlaybackModel
    @Environment(\.openSettings) private var openSettings
    @StateObject private var viewState = DocumentViewState()

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

    private func visibleBlocks(in doc: OpenDocument) -> [DocumentBlockItem] {
        if model.showEmptyCorrectedSegments { return doc.blocks }
        return doc.blocks.filter { !$0.isEmptySegment }
    }

    var body: some View {
        GeometryReader { geo in
            let usesGutter = geo.size.width >= 640
            VStack(spacing: 0) {
                if model.isDocumentSearchPresented {
                    documentSearchBar
                    Rectangle().fill(TingjianTheme.hairline).frame(height: 1)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        if let doc {
                            let blocks = visibleBlocks(in: doc)
                            let matchSet = Set(model.documentSearchMatches)
                            let currentSearchID = model.activeSearchBlockID
                            VStack(alignment: .leading, spacing: 0) {
                                documentHeader(doc)
                                if let error = doc.error {
                                    label(error, systemImage: "exclamationmark.triangle.fill", tone: TingjianTheme.warning)
                                        .padding(.top, 12)
                                }
                                if !doc.parsed.notes.isEmpty {
                                    notesSection(doc.parsed.notes)
                                        .padding(.top, 12)
                                }
                                if doc.blocks.isEmpty {
                                    if doc.parsed.hasTranscriptMetadata {
                                        emptyTranscriptNotice(doc)
                                            .padding(.top, 16)
                                    }
                                    Text(doc.text)
                                        .font(.system(size: 16))
                                        .lineSpacing(6)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.top, 18)
                                } else {
                                    if doc.parsed.emptySegmentCount > 0 {
                                        emptySegmentToggleBar(count: doc.parsed.emptySegmentCount)
                                            .padding(.top, 12)
                                    }
                                    LazyVStack(alignment: .leading, spacing: 12) {
                                        ForEach(blocks) { block in
                                            let isActivePlayback = model.activeDocumentBlockID == block.id
                                            let isSearchMatch = matchSet.contains(block.id)
                                            let isCurrentSearch = currentSearchID == block.id
                                            switch block.kind {
                                            case .segment(let time, let text):
                                                DocumentLineRow(
                                                    line: DocumentLine(id: block.id, time: time, text: text),
                                                    usesGutter: usesGutter,
                                                    linkedAudio: doc.linkedAudio,
                                                    isActivePlayback: isActivePlayback,
                                                    isSearchMatch: isSearchMatch,
                                                    isCurrentSearchMatch: isCurrentSearch
                                                )
                                                .id(block.id)
                                            case .gap(let start, let end, let note):
                                                DocumentGapRow(
                                                    start: start,
                                                    end: end,
                                                    note: note,
                                                    usesGutter: usesGutter,
                                                    linkedAudio: doc.linkedAudio,
                                                    isActivePlayback: isActivePlayback,
                                                    isSearchMatch: isSearchMatch,
                                                    isCurrentSearchMatch: isCurrentSearch
                                                )
                                                .id(block.id)
                                            }
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
                    .onChange(of: model.activeSearchBlockID) { _, targetID in
                        guard let targetID else { return }
                        withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(targetID, anchor: .center) }
                    }
                    .onChange(of: model.activeDocumentBlockID) { _, targetID in
                        guard model.followPlaybackScroll, playback.isPlaying, let targetID else { return }
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(targetID, anchor: .center) }
                    }
                }
            }
        }
        .onChange(of: url) { _, _ in
            viewState.showAllNotes = false
        }
    }

    private var documentSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(TingjianTheme.secondaryInk)
            TextField("在当前文稿中查找…", text: $model.documentSearchQuery)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 280)
                .onSubmit { model.stepDocumentSearch(1) }
                .accessibilityLabel("在当前文稿中查找")
            if !model.documentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let total = model.documentSearchMatches.count
                Text(total == 0 ? "无匹配" : "\(model.documentSearchCurrentIndex + 1) / \(total)")
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(total == 0 ? TingjianTheme.warning : TingjianTheme.secondaryInk)
            }
            Button { model.stepDocumentSearch(-1) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canStepDocumentSearch)
            .help("上一个匹配（⌘⇧G）")
            .accessibilityLabel("查找上一个")
            Button { model.stepDocumentSearch(1) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canStepDocumentSearch)
            .help("下一个匹配（⌘G）")
            .accessibilityLabel("查找下一个")
            Spacer(minLength: 8)
            Button { model.dismissDocumentSearch() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("关闭查找")
            .accessibilityLabel("关闭查找")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(TingjianTheme.windowSurface)
    }

    private func documentHeader(_ doc: OpenDocument) -> some View {
        let parsed = doc.parsed
        let showRetranscribeProminent = doc.linkedAudio != nil
            && (parsed.status == .partial || parsed.status == .failed || parsed.gapCount > 0 || (parsed.hasTranscriptMetadata && doc.lines.isEmpty))
        let isRetranscribingThisAudio = model.isRetranscribing
            && doc.linkedAudio != nil
            && model.retranscribingAudioURL == doc.linkedAudio?.standardizedFileURL

        return VStack(alignment: .leading, spacing: 8) {
            if parsed.title != nil || parsed.hasTranscriptMetadata {
                HStack(alignment: .center, spacing: 8) {
                    if let title = parsed.title {
                        Text(title)
                            .font(.system(size: 20, weight: .semibold))
                            .lineLimit(2)
                    }
                    if parsed.isCorrected {
                        statusBadge(
                            parsed.correctedModel.map { "校正版 · \($0)" } ?? "校正版",
                            systemImage: "sparkles",
                            tone: TingjianTheme.accent
                        )
                    }
                    if parsed.status == .partial {
                        let text = parsed.gapCount > 0 ? "部分完成 · \(parsed.gapCount) 处缺口" : "部分完成"
                        statusBadge(text, systemImage: "exclamationmark.triangle.fill", tone: TingjianTheme.warning)
                    } else if parsed.status == .failed {
                        statusBadge("转写失败", systemImage: "exclamationmark.octagon.fill", tone: TingjianTheme.record)
                    }
                }
            }

            HStack(spacing: 10) {
                if let recordedAt = parsed.recordedAt {
                    Label(recordedAt, systemImage: "calendar")
                        .font(.system(size: 11))
                        .foregroundStyle(TingjianTheme.secondaryInk)
                }
                if let duration = parsed.duration {
                    Label(duration, systemImage: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(TingjianTheme.secondaryInk)
                }
                if let audio = doc.linkedAudio {
                    Label(audio.lastPathComponent, systemImage: "waveform")
                        .font(.system(size: 11))
                        .foregroundStyle(TingjianTheme.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(audio.path)
                } else {
                    Label("未找到关联音频", systemImage: "speaker.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(TingjianTheme.tertiaryInk)
                }
            }

            actionBar(doc, showRetranscribeProminent: showRetranscribeProminent, isRetranscribingThisAudio: isRetranscribingThisAudio)

            correctionStatus(doc)

            if isRetranscribingThisAudio, let status = model.retranscribe {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(TingjianTheme.secondaryInk)
                }
            }
        }
        .padding(.bottom, 8)
    }

    private func actionBar(_ doc: OpenDocument, showRetranscribeProminent: Bool, isRetranscribingThisAudio: Bool) -> some View {
        let hasSegments = !doc.lines.isEmpty
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                primaryActionButtons(doc, hasSegments: hasSegments, showRetranscribeProminent: showRetranscribeProminent, isRetranscribingThisAudio: isRetranscribingThisAudio)
                secondaryActionButtons(doc)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    primaryActionButtons(doc, hasSegments: hasSegments, showRetranscribeProminent: showRetranscribeProminent, isRetranscribingThisAudio: isRetranscribingThisAudio)
                }
                HStack(spacing: 8) {
                    secondaryActionButtons(doc)
                }
            }
        }
    }

    @ViewBuilder
    private func primaryActionButtons(_ doc: OpenDocument, hasSegments: Bool, showRetranscribeProminent: Bool, isRetranscribingThisAudio: Bool) -> some View {
        if hasSegments {
            if model.llmEnabled {
                Button {
                    model.startCorrection(document: doc.url)
                } label: {
                    Label(model.correctionWasAttempted(for: doc.url) ? "再次纠正" : "纠正文本", systemImage: "text.badge.checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.llmConfigured || model.isCorrecting || rec.isActive)
                .help(model.correctionHelp)
            } else {
                Button {
                    openSettings()
                } label: {
                    Label("启用文字纠正…", systemImage: "text.badge.checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("在设置中启用文字纠正并配置网关")
            }
        }

        if let original = model.originalDocumentURL(for: doc.url) {
            Button {
                model.select(.document(original))
            } label: {
                Label("查看原稿", systemImage: "doc.text")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(original.lastPathComponent)
        } else if let corrected = model.correctedDocumentURL(for: doc.url) {
            Button {
                model.select(.document(corrected))
            } label: {
                Label("打开校正版", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(corrected.lastPathComponent)
        }

        if let audio = doc.linkedAudio {
            retranscribeButton(
                audio: audio,
                prominent: showRetranscribeProminent,
                isRetranscribingThisAudio: isRetranscribingThisAudio
            )
        }
    }

    @ViewBuilder
    private func retranscribeButton(audio: URL, prominent: Bool, isRetranscribingThisAudio: Bool) -> some View {
        let button = Button {
            model.retranscribeAudio(audio)
        } label: {
            Label(isRetranscribingThisAudio ? "正在重转写…" : "重新转写", systemImage: "waveform.badge.magnifyingglass")
        }
        .controlSize(.small)
        .disabled(model.isRetranscribing || rec.isActive)
        .help("从关联音频重新转写并另存为 _重转写.md，不覆盖原稿")

        if prominent {
            button.buttonStyle(.borderedProminent).tint(TingjianTheme.accent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func secondaryActionButtons(_ doc: OpenDocument) -> some View {
        Button {
            model.presentDocumentSearch()
        } label: {
            Label("查找", systemImage: "magnifyingglass")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("在当前文稿中查找（⌘F）")

        Button {
            NSWorkspace.shared.open(doc.url)
        } label: {
            Label("外部打开", systemImage: "arrow.up.forward.app")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("使用系统默认应用（如 Obsidian）打开当前文稿")
    }

    private func statusBadge(_ text: String, systemImage: String, tone: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tone)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tone.opacity(0.12)))
            .lineLimit(1)
    }

    private func notesSection(_ notes: [String]) -> some View {
        let visible = viewState.showAllNotes ? notes : Array(notes.prefix(2))
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(TingjianTheme.secondaryInk)
                Text("说明")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TingjianTheme.secondaryInk)
                Spacer(minLength: 8)
                if notes.count > 2 {
                    Button(viewState.showAllNotes ? "收起" : "展开全部 \(notes.count) 条") {
                        viewState.showAllNotes.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(TingjianTheme.accent)
                }
            }
            ForEach(Array(visible.enumerated()), id: \.offset) { _, note in
                Text("• \(note)")
                    .font(.system(size: 12))
                    .foregroundStyle(TingjianTheme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(TingjianTheme.controlSurface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TingjianTheme.hairline, lineWidth: 1))
    }

    private func emptySegmentToggleBar(count: Int) -> some View {
        HStack(spacing: 8) {
            Text(model.showEmptyCorrectedSegments ? "已显示 \(count) 处校正清理后的空时间锚点" : "已隐藏 \(count) 处校正清理后的空时间锚点（原文件保留）")
                .font(.system(size: 11))
                .foregroundStyle(TingjianTheme.tertiaryInk)
            Button(model.showEmptyCorrectedSegments ? "隐藏" : "显示") {
                model.showEmptyCorrectedSegments.toggle()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(TingjianTheme.accent)
        }
    }

    private func emptyTranscriptNotice(_ doc: OpenDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(doc.parsed.status == .failed ? "本次转写失败，未产出识别文字" : "本次转写未识别出文字", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(doc.parsed.status == .failed ? TingjianTheme.record : TingjianTheme.warning)
            Text(doc.linkedAudio != nil
                 ? "原始音频仍已保存，可点击上方「重新转写」补转，或使用下方控制带直接回听。"
                 : "静音、设备无有效输入或识别异常都可能没有文字。")
                .font(.system(size: 12))
                .foregroundStyle(TingjianTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(TingjianTheme.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TingjianTheme.warning.opacity(0.25), lineWidth: 1))
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
                HStack(spacing: 8) {
                    label("已生成 \(file)", systemImage: "checkmark.circle.fill", tone: TingjianTheme.accent)
                    if let output = model.correctedDocumentURL(for: doc.url) {
                        Button("立即打开") { model.select(.document(output)) }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
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

struct DocumentGapRow: View {
    let start: String
    let end: String
    let note: String
    let usesGutter: Bool
    let linkedAudio: URL?
    var isActivePlayback: Bool = false
    var isSearchMatch: Bool = false
    var isCurrentSearchMatch: Bool = false
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var rec: Recorder
    @EnvironmentObject private var playback: PlaybackModel

    private var unavailableReason: String? {
        guard !rec.isActive else { return "录音进行中，结束后可定位回听" }
        guard let linkedAudio else { return "文稿没有可播放的关联音频" }
        guard let seconds = AppModel.parseTimecode(start) else { return "时间戳无法解析" }
        if playback.currentURL?.standardizedFileURL == linkedAudio.standardizedFileURL,
           playback.canSeek, seconds >= playback.duration {
            return "该时间点超出音频时长"
        }
        return nil
    }

    var body: some View {
        Group {
            if usesGutter {
                HStack(alignment: .top, spacing: 18) {
                    timestamp.frame(width: 66, alignment: .trailing)
                        .padding(.top, 9)
                    gapCard
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    timestamp
                    gapCard
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(rowHighlightColor))
    }

    private var rowHighlightColor: Color {
        if isCurrentSearchMatch { return TingjianTheme.warning.opacity(0.22) }
        if isSearchMatch { return TingjianTheme.warning.opacity(0.10) }
        if isActivePlayback { return TingjianTheme.accentSoft.opacity(0.75) }
        return .clear
    }

    private var timestamp: some View {
        Button {
            Task { await model.seek(toTimecode: start) }
        } label: {
            Text(start)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(unavailableReason == nil ? TingjianTheme.warning : TingjianTheme.tertiaryInk)
        }
        .buttonStyle(.plain)
        .disabled(unavailableReason != nil)
        .help(unavailableReason ?? "从 \(start) 播放缺口区间")
        .accessibilityLabel("从缺口起点 \(start) 播放")
    }

    private var gapCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(note)（\(start)–\(end)）", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TingjianTheme.warning)
            Text(linkedAudio != nil
                 ? "原始音频仍已保存，可点击时间直接回听或使用上方「重新转写」。"
                 : "这段时间没有可靠的识别文字。")
                .font(.system(size: 12))
                .foregroundStyle(TingjianTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(TingjianTheme.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TingjianTheme.warning.opacity(0.28), lineWidth: 1))
    }
}

struct DocumentLineRow: View {
    let line: DocumentLine
    let usesGutter: Bool
    let linkedAudio: URL?
    var isActivePlayback: Bool = false
    var isSearchMatch: Bool = false
    var isCurrentSearchMatch: Bool = false
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

    private var rowHighlightColor: Color {
        if isCurrentSearchMatch { return TingjianTheme.warning.opacity(0.22) }
        if isSearchMatch { return TingjianTheme.warning.opacity(0.10) }
        if isActivePlayback { return TingjianTheme.accentSoft.opacity(0.75) }
        return .clear
    }

    var body: some View {
        Group {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(rowHighlightColor))
    }

    private var timestamp: some View {
        Button {
            Task { await model.seek(toTimecode: line.time) }
        } label: {
            Text(line.time)
                .font(.system(size: 11, weight: isActivePlayback ? .semibold : .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(unavailableReason == nil ? TingjianTheme.accent : TingjianTheme.tertiaryInk)
        }
        .buttonStyle(.plain)
        .disabled(unavailableReason != nil)
        .help(unavailableReason ?? "从 \(line.time) 播放")
        .accessibilityLabel("从 \(line.time) 播放")
    }

    private var text: some View {
        let empty = line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Text(empty ? "（已清理空段）" : line.text)
            .font(.system(size: empty ? 13 : 16, weight: .regular))
            .lineSpacing(5)
            .foregroundStyle(empty ? TingjianTheme.tertiaryInk : TingjianTheme.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
