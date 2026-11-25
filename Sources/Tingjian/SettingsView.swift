import SwiftUI
import TingjianCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var rec: Recorder

    var body: some View {
        ZStack {
            TingjianPaperBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    SettingsSection(title: "外观", detail: "浅色、深色或跟随系统；切换立即生效并在重启后保留。") {
                        SettingsFieldRow(title: "主题", systemImage: "circle.lefthalf.filled") {
                            Picker("主题", selection: $model.appearance) {
                                ForEach(AppAppearance.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 300)
                            .accessibilityLabel("主题")
                        }
                    }

                    SettingsSection(title: "录音输入", detail: "为以后开始的录音设置默认设备。临时换麦可使用底栏。") {
                        SettingsFieldRow(title: "默认输入设备", systemImage: "mic") {
                            inputPicker
                        }

                        SettingsDivider()

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "waveform")
                                .foregroundStyle(TingjianTheme.secondaryInk)
                            Text("录音默认使用：\(model.defaultInputDescription)")
                                .font(.system(size: 11))
                                .foregroundStyle(TingjianTheme.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        if model.savedInputUnavailable {
                            SettingsDivider()
                            Text("已保存的输入设备当前不可用。请重新选择设备；也可在底栏为下一次录音临时选择设备。")
                                .settingsFootnote()
                                .foregroundStyle(TingjianTheme.warning)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }
                    }

                    SettingsSection(title: "保存与恢复", detail: "每次录音在目标文件夹新建独立文件夹;录制过程中先保存到本机恢复目录。") {
                        SettingsFieldRow(title: "目标文件夹", systemImage: "folder") {
                            HStack(spacing: 10) {
                                Text(model.saveRoot.path)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(TingjianTheme.secondaryInk)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Button("更改…") { model.chooseSaveRoot() }
                                    .controlSize(.small)
                                    .disabled(rec.isActive)
                                    .accessibilityHint("选择录音与转写文件的目标文件夹;录音中不可更改")
                            }
                        }

                        SettingsDivider()

                        SettingsFieldRow(title: "本地备份", systemImage: "externaldrive") {
                            HStack(spacing: 10) {
                                Text(localBackupText)
                                    .font(.system(size: 12))
                                    .foregroundStyle(TingjianTheme.secondaryInk)
                                Spacer(minLength: 8)
                                Button(model.isTrashingBackups ? "正在清理…" : "移入废纸篓") {
                                    model.trashSavedBackupsAsync()
                                }
                                .controlSize(.small)
                                .foregroundStyle(TingjianTheme.record)
                                .disabled(model.localBackupCount == 0 || model.isTrashingBackups)
                            }
                        }

                        SettingsDivider()

                        SettingsFieldRow(title: "中文识别模型", systemImage: "character.bubble") {
                            SpeechModelControl()
                        }

                        SettingsDivider()

                        SettingsFieldRow(title: "重新转写", systemImage: "waveform.badge.magnifyingglass") {
                            Button {
                                model.retranscribeFile()
                            } label: {
                                Label(model.isRetranscribing ? "正在转写…" : "选择录音…", systemImage: "waveform")
                            }
                            .controlSize(.small)
                            .disabled(model.isRetranscribing || rec.isActive)
                        }

                        if let status = model.retranscribe {
                            SettingsDivider()
                            HStack(spacing: 8) {
                                if model.isRetranscribing {
                                    ProgressView().controlSize(.small)
                                }
                                Text(status)
                                    .font(.system(size: 12))
                                    .foregroundStyle(status.hasPrefix("已生成") ? TingjianTheme.accent : TingjianTheme.secondaryInk)
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }

                    SettingsSection(title: "文字纠正", detail: "修正转写中的错字和术语，删去多余的语气词。原稿会保留。") {
                        SettingsFieldRow(title: "启用", systemImage: "text.badge.checkmark") {
                            Toggle("启用文字纠正", isOn: $model.llmEnabled)
                                .labelsHidden()
                                .accessibilityLabel("启用文字纠正")
                        }

                        if model.llmEnabled {
                            SettingsDivider()

                            SettingsFieldRow(title: "纠正方式", systemImage: "text.alignleft") {
                                VStack(alignment: .trailing, spacing: 4) {
                                    Picker("纠正方式", selection: $model.correctionStyle) {
                                        ForEach(CorrectionStyle.allCases) { style in
                                            Text(style.title).tag(style)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .accessibilityLabel("纠正方式")
                                    Text(model.correctionStyle.detail).settingsFootnote()
                                }
                            }

                            SettingsDivider()

                            SettingsFieldRow(title: "网关", systemImage: "network") {
                                Picker("网关", selection: $model.gatewayChoice) {
                                    ForEach(GatewayChoice.allCases) { choice in
                                        Text(choice.title).tag(choice)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .accessibilityLabel("网关")
                            }

                            SettingsDivider()

                            SettingsFieldRow(title: "网关地址", systemImage: "link") {
                                if model.gatewayChoice == .custom {
                                    TextField("https://example.com/v1", text: $model.customGatewayAddress)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12, design: .monospaced))
                                        .accessibilityLabel("网关地址")
                                } else {
                                    Text(model.llmURL)
                                        .font(.system(size: 12, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }

                            SettingsDivider()

                            SettingsFieldRow(title: "模型", systemImage: "cpu") {
                                modelControl
                            }

                            SettingsDivider()

                            SettingsFieldRow(title: "推理强度", systemImage: "speedometer") {
                                effortControl
                            }

                            SettingsDivider()

                            HStack(alignment: .top, spacing: 10) {
                                gatewayStatus
                                Spacer(minLength: 8)
                                Button {
                                    Task { await model.refreshModels() }
                                } label: {
                                    if isRefreshingModels {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Label("刷新模型", systemImage: "arrow.clockwise")
                                    }
                                }
                                .controlSize(.small)
                                .disabled(isRefreshingModels || model.gatewayEndpoint == nil)
                                .accessibilityLabel("刷新模型清单")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)

                            SettingsDivider()

                            SettingsFieldRow(title: "API Key", systemImage: "key") {
                                VStack(alignment: .trailing, spacing: 4) {
                                    HStack {
                                        SecureField(apiKeyPlaceholder, text: $model.apiKey)
                                            .textFieldStyle(.roundedBorder)
                                            .onSubmit { model.saveAPIKey() }
                                            .accessibilityLabel("API Key")
                                        Button("保存密钥") { model.saveAPIKey() }
                                    }
                                    if let status = model.apiKeyStatus {
                                        Text(status).settingsFootnote()
                                    }
                                }
                                .disabled(model.gatewayEndpoint == nil)
                            }

                            Text("每个网关地址单独保存密钥。要移除密钥，请清空后点「保存密钥」。点击「纠正文本」后，转写文字、项目和录音目录名、文稿名及部分文稿开头信息会发给当前网关。校正结果与上下文摘要会缓存在本机。")
                                .settingsFootnote()
                                .padding(.horizontal, 14)
                                .padding(.bottom, 12)
                        } else {
                            SettingsDivider()
                            Text("开启后可配置 DeepSeek 官方、Magpie 或自定义兼容网关，在课后对转写文稿进行连续段落校对。")
                                .settingsFootnote()
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 30)
            }
        }
        .tint(TingjianTheme.accent)
        .frame(width: 700)
        .frame(minHeight: 660)
        .task {
            model.refreshInputDevices()
            model.refreshLocalBackupsSummary()
        }
    }

    private var apiKeyPlaceholder: String {
        switch model.gatewayChoice {
        case .deepSeek: "填写 DeepSeek API Key"
        case .magpie: "本机 Magpie 通常留空"
        case .custom: "按服务要求填写，可留空"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("设置")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(TingjianTheme.ink)
            Text("外观、录音输入、保存位置与文字纠正")
                .font(.system(size: 12))
                .foregroundStyle(TingjianTheme.secondaryInk)
        }
    }

    private var inputPicker: some View {
        Picker("输入设备", selection: Binding<String?>(
            get: { model.audioInputUID },
            set: { model.audioInputUID = $0 }
        )) {
            Text("系统默认(开始时固定)").tag(String?.none)
            ForEach(model.inputDevices) { device in
                Text(device.name + (device.isDefault ? "(系统默认)" : "")).tag(Optional(device.id))
            }
            if model.savedInputUnavailable, let uid = model.audioInputUID {
                Text("\(model.savedInputDisplayName)（当前未连接）").tag(Optional(uid))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 320, alignment: .trailing)
        .accessibilityLabel("默认输入设备")
        .accessibilityValue(model.defaultInputDescription)
    }

    @ViewBuilder
    private var modelControl: some View {
        if model.gatewayModels.isEmpty || model.selectedModel == nil {
            VStack(alignment: .trailing, spacing: 3) {
                if !model.gatewayModels.isEmpty {
                    ModelMenu().environmentObject(model)
                }
                TextField("模型 ID", text: $model.llmModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .accessibilityLabel("模型 ID")
            }
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                ModelMenu()
                    .environmentObject(model)
                Text(model.selectedModel?.id ?? model.llmModel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(TingjianTheme.tertiaryInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.selectedModel?.id ?? model.llmModel)
            }
        }
    }

    @ViewBuilder
    private var effortControl: some View {
        if model.effortOptions.isEmpty {
            TextField("留空使用服务默认强度", text: $model.llmEffort)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .accessibilityLabel("推理强度")
        } else {
            Picker("推理强度", selection: $model.llmEffort) {
                Text("自动（\(model.defaultEffort)）").tag("")
                ForEach(model.effortOptions, id: \.self) { level in
                    Text(level).tag(level)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 220, alignment: .trailing)
            .accessibilityLabel("推理强度")
        }
    }

    @ViewBuilder
    private var gatewayStatus: some View {
        switch model.gatewayState {
        case .idle:
            StatusLine(text: "未刷新模型", systemImage: "circle.dotted", color: TingjianTheme.tertiaryInk)
        case .loading:
            StatusLine(text: "正在刷新…", systemImage: "arrow.trianglehead.2.clockwise.rotate.90", color: TingjianTheme.accent)
        case .loaded(let count):
            StatusLine(
                text: count == 0 ? "没有找到模型，可手动填写模型 ID" : "\(count) 个模型",
                systemImage: count == 0 ? "exclamationmark.triangle" : "checkmark.circle",
                color: count == 0 ? TingjianTheme.warning : TingjianTheme.accent)
        case .failed(let message):
            let detail = message.trimmingCharacters(in: CharacterSet(charactersIn: "。.！!"))
            StatusLine(text: "无法获取模型。\(detail)。你也可以手动填写模型 ID。",
                       systemImage: "exclamationmark.triangle.fill", color: TingjianTheme.warning)
        }
    }

    private var isRefreshingModels: Bool {
        if case .loading = model.gatewayState { return true }
        return false
    }

    private var localBackupText: String {
        if let count = model.trashed, model.localBackupCount == 0 { return "已移入废纸篓 \(count) 份" }
        let count = model.localBackupCount
        guard count > 0 else { return "没有可清理的已保存备份" }
        let size = ByteCountFormatter.string(fromByteCount: model.localBackupBytes, countStyle: .file)
        return "\(count) 份已成功交付的本地备份（共 \(size)）"
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let detail: String
    let content: Content

    init(title: String, detail: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TingjianTheme.ink)
            Text(detail)
                .settingsFootnote()

            VStack(spacing: 0) { content }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(TingjianTheme.controlSurface))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(TingjianTheme.hairline.opacity(0.72), lineWidth: 1))
        }
    }
}

private struct SettingsFieldRow<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TingjianTheme.ink)
                .frame(width: 126, alignment: .leading)

            content.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(TingjianTheme.hairline.opacity(0.62))
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

private struct ModelMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.gatewayModels) { candidate in
                Button {
                    model.llmModel = candidate.id
                } label: {
                    Text((model.llmModel == candidate.id ? "✓ " : "")
                         + (candidate.supportsChat ? candidate.displayName : "\(candidate.displayName)(不支持纠正)"))
                }
                .disabled(!candidate.supportsChat)
                .help(candidate.id)
            }
        } label: {
            Text(model.selectedModel?.displayName ?? (model.llmModel.isEmpty ? "选择模型" : model.llmModel))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TingjianTheme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 210, maxWidth: 320, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 340, alignment: .trailing)
        .accessibilityLabel("模型")
        .accessibilityValue(model.selectedModel?.displayName ?? (model.llmModel.isEmpty ? "选择模型" : model.llmModel))
        .help(model.selectedModel?.id ?? model.llmModel)
    }
}

private struct StatusLine: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

private extension View {
    func settingsFootnote() -> some View {
        font(.system(size: 11))
            .foregroundStyle(TingjianTheme.secondaryInk)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}


struct SpeechModelControl: View {
    @EnvironmentObject private var rec: Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress = rec.modelProgress {
                ProgressView("正在下载中文识别模型", value: progress)
            } else {
                switch rec.speechModelState {
                case .ready: Text("中文识别模型已就绪")
                case .unsupported: Text("本机不支持简体中文识别")
                case .needsDownload:
                    Button("下载中文识别模型") { Task { await rec.installModel() } }
                case nil: ProgressView().controlSize(.small).accessibilityLabel("正在检查中文识别模型")
                }
            }
            if let error = rec.modelDownloadError {
                Text(error).foregroundStyle(TingjianTheme.warning)
            }
        }
        .font(.system(size: 12))
        .task { await rec.refreshSpeechModelState() }
    }
}
