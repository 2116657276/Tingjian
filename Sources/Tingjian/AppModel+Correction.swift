import AppKit
import Foundation
import TingjianCore

extension AppModel {
    // MARK: 网关与模型

    var selectedModel: GatewayModel? { gatewayModels.first { $0.id == llmModel } }
    var effortOptions: [String] {
        if let selectedModel { return selectedModel.levels }
        if let gatewayEndpoint,
           let levels = GatewayPreferences(defaults: Self.defaults).levels(for: gatewayEndpoint, model: llmModel) {
            return levels
        }
        switch (gatewayChoice, llmModel) {
        case (.magpie, GatewayChoice.magpie.defaultModel): return ["low", "high"]
        case (.deepSeek, "deepseek-flash"), (.deepSeek, "deepseek-v4-pro"): return ["low", "high", "max"]
        default: return []
        }
    }

    var defaultEffort: String { GatewayModel.minimumLevel(effortOptions) }
    var effectiveEffort: String { llmEffort.isEmpty ? defaultEffort : llmEffort }

    func invalidateModelRefresh() {
        refreshToken = UUID()
        gatewayModels = []
        gatewayState = .idle
        apiKeyStatus = nil
    }

    func activateGateway() {
        invalidateModelRefresh()
        let preferences = GatewayPreferences(defaults: Self.defaults)
        llmModel = preferences.model(for: gatewayEndpoint, choice: gatewayChoice)
        llmEffort = ""
        if isTestMode {
            apiKey = gatewayEndpoint.flatMap { isolatedKeys[$0] } ?? ""
        } else {
            apiKey = Self.readAPIKey(for: gatewayEndpoint, preferences: preferences)
        }
    }

    static func readAPIKey(for endpoint: GatewayEndpoint?, preferences: GatewayPreferences) -> String {
        guard let endpoint else { return "" }
        if let key = Keychain.read(gateway: endpoint) { return key }
        guard preferences.allowsLegacyKey(for: endpoint), let key = Keychain.read() else { return "" }
        Keychain.write(key, gateway: endpoint)
        return key
    }

    /// 从网关拉取模型清单；配置改变后，正在进行的请求失去更新资格。
    func refreshModels(session: URLSession = .shared) async {
        guard gatewayState != .loading, let endpoint = gatewayEndpoint else { return }
        let token = UUID()
        refreshToken = token
        gatewayState = .loading
        do {
            let list = try await GatewayModel.fetch(baseURL: llmURL, apiKey: apiKey, session: session)
            guard refreshToken == token else { return }
            gatewayModels = list
            gatewayState = .loaded(list.count)
            let preferences = GatewayPreferences(defaults: Self.defaults)
            for model in list {
                preferences.saveLevels(model.levels, for: endpoint, model: model.id)
            }
            if let selectedModel, !selectedModel.levels.contains(llmEffort) {
                llmEffort = ""
            }
        } catch {
            guard refreshToken == token else { return }
            gatewayModels = []
            gatewayState = .failed(error.localizedDescription)
        }
    }

    func saveAPIKey() {
        guard let gatewayEndpoint else { return }
        if isTestMode {
            isolatedKeys[gatewayEndpoint] = apiKey
            apiKeyStatus = "已保存到本次测试会话"
        } else {
            apiKeyStatus = Keychain.write(apiKey, gateway: gatewayEndpoint)
                ? (apiKey.isEmpty ? "已清空当前网关密钥" : "已保存到钥匙串")
                : "无法写入系统钥匙串"
        }
    }

    // MARK: 课后纠正

    var llmConfigured: Bool {
        gatewayEndpoint != nil && !llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (selectedModel?.supportsChat ?? true)
    }
    var gatewayHost: String { URL(string: llmURL).map { ($0.host ?? "") + ($0.port.map { ":\($0)" } ?? "") } ?? llmURL }

    func correctionState(for document: URL) -> CorrectionState {
        correctionByDocument[document.standardizedFileURL] ?? .idle
    }

    var correctionHelp: String {
        let endpoint = llmURL.isEmpty ? "尚未配置的服务" : llmURL
        let name = selectedModel?.displayName ?? llmModel
        return "会向 \(endpoint) 的 \(name) 模型发送转写文字、项目和录音目录名、文稿名及部分文稿开头信息。校正结果与上下文摘要会缓存在本机。"
    }

    func correctionWasAttempted(for document: URL) -> Bool {
        if case .idle = correctionState(for: document) { return false }
        return true
    }

    var isCorrecting: Bool { correctionRunning }

    func startCorrection(document: URL) {
        let url = document.standardizedFileURL
        guard !correctionRunning else { return }
        guard llmEnabled else {
            correctionByDocument[url] = .failed("文字纠正已关闭。可在「设置 → 文字纠正」中启用。")
            return
        }
        guard llmConfigured else {
            correctionByDocument[url] = .failed("文字纠正未配置服务地址或模型")
            return
        }
        guard !recorder.isActive else {
            correctionByDocument[url] = .failed("录音进行中不能纠正文字")
            return
        }
        let config = LLMConfig(baseURL: llmURL, model: llmModel.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: apiKey,
                               reasoningEffort: effectiveEffort, style: correctionStyle)
        let token = UUID()
        correctionToken = token
        correctionDocument = url
        correctionRunning = true
        correctionByDocument[url] = .running(0, 0)
        correctionUsage[url] = CorrectionUsage()
        correctionTask = Task { [weak self] in
            await self?.runCorrection(document: url, config: config, token: token)
        }
    }

    func cancelCorrection() {
        correctionTask?.cancel()
        if let url = correctionDocument {
            correctionByDocument[url] = .failed("已取消，未生成校正版")
        }
    }

    private func runCorrection(document url: URL, config: LLMConfig, token: UUID) async {
        defer {
            if correctionToken == token {
                correctionRunning = false
                correctionDocument = nil
                correctionTask = nil
            }
        }
        do {
            let original = try String(contentsOf: url, encoding: .utf8)
            let segments = MarkdownDoc.parseSegments(original)
            guard !segments.isEmpty else { throw CorrectionError.noSegments }
            var documentConfig = config
            let metadata = original.components(separatedBy: "\n").prefix(16)
                .prefix(while: { !$0.hasPrefix("## ") }).joined(separator: "\n")
            let parentDir = url.deletingLastPathComponent()
            let recordingFolder = isRootDirectory(parentDir) ? "" : parentDir.lastPathComponent
            let grandParentDir = parentDir.deletingLastPathComponent()
            let projectFolder = (isRootDirectory(parentDir) || isRootDirectory(grandParentDir) || !ProjectLibrary.contains(saveRoot, grandParentDir))
                ? ""
                : grandParentDir.lastPathComponent
            documentConfig.course = [projectFolder, recordingFolder,
                                     url.deletingPathExtension().lastPathComponent, metadata]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            let cache = Self.testRoot?.appendingPathComponent("cache/text-correction", isDirectory: true)
                ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("com.local.tingjian/TextCorrection", isDirectory: true)
            let corrected = try await TextCorrector(config: documentConfig, cacheDirectory: cache)
                .correct(segments, progress: { [weak self] done, total in
                Task { @MainActor in
                    guard let self, self.correctionToken == token else { return }
                    self.correctionByDocument[url] = .running(done, total)
                }
            }, usage: { [weak self] update in
                Task { @MainActor in
                    guard let self, self.correctionToken == token else { return }
                    var total = self.correctionUsage[url] ?? CorrectionUsage()
                    total.add(update)
                    self.correctionUsage[url] = total
                }
            })
            try Task.checkCancellation()
            guard correctionToken == token else { return }
            // 写出前重读原稿:被外部修改则放弃,不基于旧版本生成校正版。
            let current = try String(contentsOf: url, encoding: .utf8)
            guard current == original else {
                throw CorrectionError.mismatch("原稿已更改，请重新纠正")
            }
            let base = url.deletingPathExtension().lastPathComponent
            let markdown = try TextCorrector.buildCorrectedMarkdown(
                original: original, corrected: corrected,
                originalName: url.lastPathComponent, model: config.model)
            try Task.checkCancellation()
            guard correctionToken == token else { return }
            let output = try Paths.writeUniqueMarkdown(markdown, base: base + "_校正版", in: url.deletingLastPathComponent())
            guard correctionToken == token else { return }
            let outputKey = output.standardizedFileURL
            correctionByDocument[url] = .done(output.lastPathComponent)
            correctionOutputByDocument[url] = outputKey
            documentsByURL[url]?.correctedDocument = outputKey
            if openDocument?.url.standardizedFileURL == url {
                openDocument?.correctedDocument = outputKey
            }
            await loadChildren(url.deletingLastPathComponent(), force: true)
            if selection == .document(url) { select(.document(output)) }
        } catch is CancellationError {
            correctionByDocument[url] = .failed("已取消，未生成校正版")
        } catch {
            correctionByDocument[url] = .failed("\(error.localizedDescription)。未生成校正版，原始转写不受影响")
        }
    }

    // MARK: 重新转写

    func retranscribeFile() {
        guard !isRetranscribing else { return }
        guard !recorder.isActive else {
            retranscribe = "录音进行中不能重新转写，请先结束录音。"
            return
        }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]; p.canChooseDirectories = false
        p.message = "选择要重新转写的录音（结果另存为 _重转写.md）"
        p.directoryURL = saveRoot
        guard p.runModal() == .OK, let url = p.url else { return }
        retranscribeAudio(url)
    }

    func retranscribeAudio(_ audioURL: URL) {
        guard !isRetranscribing else { return }
        guard !recorder.isActive else {
            libraryNotice = "录音进行中不能重新转写，请先结束录音。"
            return
        }
        let url = audioURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            libraryNotice = "音频文件不存在：\(url.lastPathComponent)"
            return
        }
        isRetranscribing = true
        retranscribingAudioURL = url
        retranscribe = "正在转写…"
        libraryNotice = nil
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRetranscribing = false
                self.retranscribingAudioURL = nil
            }
            do {
                let asm = try await Retranscriber.run(audio: url) { [weak self] ratio in
                    let percent = Int((min(1.0, max(0.0, ratio)) * 100).rounded())
                    Task { @MainActor [weak self] in
                        guard let self, self.isRetranscribing else { return }
                        self.retranscribe = "正在转写… \(percent)%"
                    }
                }
                let dur = (try? AVAudioFileDuration(url)) ?? 0
                let out = try Retranscriber.writeMarkdown(audio: url, assembler: asm, duration: dur)
                self.retranscribe = "已生成 \(out.lastPathComponent)"
                if ProjectLibrary.contains(self.saveRoot, out) {
                    await self.loadChildren(out.deletingLastPathComponent(), force: true)
                    self.select(.document(out))
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
            } catch {
                self.retranscribe = "重新转写失败：\(error.localizedDescription)"
                self.libraryNotice = "重新转写失败：\(error.localizedDescription)"
            }
        }
    }
}
