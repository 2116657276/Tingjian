import AppKit
import SwiftUI
import TingjianCore

struct DirectoryDetail: View {
    let url: URL
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var rec: Recorder

    private var entries: [LibraryEntry]? { model.childrenByDirectory[url.standardizedFileURL] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    let parts = model.isRootDirectory(url) ? nil : Paths.parseRecordingName(url.lastPathComponent)
                    let kindLabel = model.isRootDirectory(url) ? "资料库根目录" : (model.isRecordingDirectory(url) ? "录音文件夹" : "项目文件夹")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(parts?.displayTitle ?? (model.isRootDirectory(url) ? "资料库根目录" : url.lastPathComponent))
                            .font(.system(size: 22, weight: .semibold))
                            .help(url.lastPathComponent)
                        Text(parts.map { "\($0.fullDate) · \(kindLabel)" } ?? kindLabel)
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
                        .disabled(rec.isActive)
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

struct DirectoryRow: View {
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
                let parts = entry.kind == .directory ? Paths.parseRecordingName(entry.name) : nil
                Text(parts?.displayTitle ?? entry.name).font(.system(size: 13))
                if let parts {
                    Text(parts.fullDate).font(.system(size: 10)).foregroundStyle(TingjianTheme.secondaryInk)
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
            LibraryEntryFileMenuItems(entry: entry)
            Divider()
            LibraryEntryManageMenuItems(url: entry.url, mutationDisabled: rec.isActive)
        }
        .onDrag { WorkspaceDragItem.file(entry.url).provider() }
    }
}

struct AudioDetail: View {
    let url: URL
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlaybackModel
    @EnvironmentObject private var rec: Recorder

    private var isRetranscribingThis: Bool {
        model.isRetranscribing && model.retranscribingAudioURL == url.standardizedFileURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let audioParts = Paths.parseRecordingName(url.deletingPathExtension().lastPathComponent)
            Image(systemName: "waveform")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(TingjianTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(audioParts?.displayTitle ?? url.lastPathComponent)
                    .font(.system(size: 22, weight: .semibold))
                if let audioParts {
                    Text("\(audioParts.fullDate) · \(url.lastPathComponent)")
                        .font(.system(size: 12))
                        .foregroundStyle(TingjianTheme.secondaryInk)
                        .textSelection(.enabled)
                }
            }
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
                    model.retranscribeAudio(url)
                } label: {
                    Label(isRetranscribingThis ? "正在转写…" : "重新转写", systemImage: "waveform.badge.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .tint(TingjianTheme.accent)
                .disabled(model.isRetranscribing || rec.isActive)
                .help("从当前音频重新转写并另存为 _重转写.md，不覆盖原稿")

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
            if isRetranscribingThis, let status = model.retranscribe {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(TingjianTheme.secondaryInk)
                }
            }
            Spacer()
        }
        .frame(maxWidth: 960, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 24)
        .padding(.top, 30)
    }
}
