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

                    SettingsSection(title: "外观", detail: "浅色、深色或跟随系统;切换立即生效并在重启后保留。") {
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

                    SettingsSection(title: "录音输入", detail: "按设备 uniqueID 固定输入,不修改系统默认设备;录音中也可以切换。") {
                        SettingsFieldRow(title: "输入设备", systemImage: "mic") {
                            inputPicker
                        }

                        SettingsDivider()

                        HStack(alignment: .top, spacing: 8) {
                            let name = model.activeInputDescription
                            Image(systemName: "waveform")
                                .foregroundStyle(TingjianTheme.secondaryInk)
                            Text(rec.isActive ? "当前实际输入:\(name)(\(rec.activeInputUID ?? "无"))" : "下次录音使用:\(name)")
                                .font(.system(size: 11))
                                .foregroundStyle(TingjianTheme.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        if model.savedInputUnavailable {
                            SettingsDivider()
                            Text("已保存的输入设备当前不可用。请重新选择设备;未改选前开始录音会明确报错,不会悄悄换成别的麦克风。")
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
                                Button("移入废纸篓") {
                                    model.trashed = model.trashSavedBackups()
                                }
                                .controlSize(.small)
                                .foregroundStyle(TingjianTheme.record)
                                .disabled(model.savedLocalBackups().isEmpty)
                            }
                        }

                        SettingsDivider()

                        SettingsFieldRow(title: "重新转写", systemImage: "waveform.badge.magnifyingglass") {
                            Button {
                                model.retranscribeFile()
                            } label: {
                                Label("选择录音…", systemImage: "waveform")
                            }
                            .controlSize(.small)
                        }

                        if let status = model.retranscribe {
                            SettingsDivider()
                            Text(status)
                                .font(.system(size: 12))
                                .foregroundStyle(status.hasPrefix("已生成") ? TingjianTheme.accent : TingjianTheme.secondaryInk)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .textSelection(.enabled)
                        }
                    }

                    SettingsSection(title: "文字纠正", detail: "结合全文主题和相邻段落修正术语，清理无意义语气词与重复；原稿始终保留。") {
                        SettingsFieldRow(title: "启用", systemImage: "text.badge.checkmark") {
                            Toggle("启用文字纠正", isOn: $model.llmEnabled)
                                .labelsHidden()
                                .accessibilityLabel("启用文字纠正")
                        }

                        SettingsDivider()

                        SettingsFieldRow(title: "网关地址", systemImage: "network") {
                            TextField("http://127.0.0.1:3425/v1", text: $model.llmURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .accessibilityLabel("网关地址")
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
                                    Label("刷新", systemImage: "arrow.clockwise")
                                }
                            }
                            .controlSize(.small)
                            .disabled(isRefreshingModels)
                            .accessibilityLabel("刷新模型清单")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        SettingsDivider()

                        SettingsFieldRow(title: "API Key", systemImage: "key") {
                            SecureField("需要时填写,本机 Magpie 通常留空", text: $model.apiKey)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { model.saveAPIKey() }
                                .accessibilityLabel("API Key")
                        }

                        Text("默认 Magpie:\(AppModel.magpieURL),模型 \(AppModel.defaultModel),推理强度 high。仅在点击“纠正文本”时发送文稿文字，不发送录音。重试会复用已验证的本地结果；网关提供 token 用量时会显示实际数据。")
                            .settingsFootnote()
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
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
        .onDisappear { model.saveAPIKey() }
        .task {
            model.refreshInputDevices()
            await model.refreshModels()
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
            set: { model.selectInput($0) }
        )) {
            Text("系统默认(开始时固定)").tag(String?.none)
            ForEach(model.inputDevices) { device in
                Text(device.name + (device.isDefault ? "(系统默认)" : "")).tag(Optional(device.id))
            }
            if model.savedInputUnavailable, let uid = model.audioInputUID {
                Text("设备不可用:\(uid)").tag(Optional(uid))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 320, alignment: .trailing)
        .disabled(rec.isChangingInput)
        .accessibilityLabel("输入设备")
        .accessibilityValue(model.activeInputDescription)
        .help("录音中切换会继续同一份录音;系统默认只在开始时解析一次")
    }

    @ViewBuilder
    private var modelControl: some View {
        if model.gatewayModels.isEmpty {
            TextField("模型名称", text: $model.llmModel)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .accessibilityLabel("模型名称")
                .accessibilityHint("网关不可用时可手动填写模型 ID")
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
            TextField("high", text: $model.llmEffort)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .accessibilityLabel("推理强度")
        } else {
            Picker("推理强度", selection: $model.llmEffort) {
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
            StatusLine(text: "尚未读取模型清单", systemImage: "circle.dotted", color: TingjianTheme.tertiaryInk)
        case .loading:
            StatusLine(text: "正在读取网关模型…", systemImage: "arrow.trianglehead.2.clockwise.rotate.90", color: TingjianTheme.accent)
        case .loaded(let count):
            StatusLine(
                text: count == 0 ? "网关没有返回模型,可手动填写模型名和强度" : "已读取 \(count) 个模型",
                systemImage: count == 0 ? "exclamationmark.triangle" : "checkmark.circle",
                color: count == 0 ? TingjianTheme.warning : TingjianTheme.accent)
        case .failed(let message):
            let detail = message.trimmingCharacters(in: CharacterSet(charactersIn: "。.！!"))
            StatusLine(text: "连接失败:\(detail)。仍可手动填写模型名和强度。",
                       systemImage: "exclamationmark.triangle.fill", color: TingjianTheme.warning)
        }
    }

    private var isRefreshingModels: Bool {
        if case .loading = model.gatewayState { return true }
        return false
    }

    private var localBackupText: String {
        if let count = model.trashed { return "已移入废纸篓 \(count) 份" }
        let count = model.savedLocalBackups().count
        return count == 0 ? "没有可清理的已保存备份" : "\(count) 份已成功交付的本地备份"
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
                    model.normalizeEffort()
                } label: {
                    Text((model.llmModel == candidate.id ? "✓ " : "")
                         + (candidate.supportsChat ? candidate.displayName : "\(candidate.displayName)(不支持纠正)"))
                }
                .disabled(!candidate.supportsChat)
                .help(candidate.id)
            }
        } label: {
            Text(model.selectedModel?.displayName ?? model.llmModel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TingjianTheme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 210, maxWidth: 320, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 340, alignment: .trailing)
        .accessibilityLabel("模型")
        .accessibilityValue(model.selectedModel?.displayName ?? model.llmModel)
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
