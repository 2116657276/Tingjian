import AVFoundation
import Foundation

extension Recorder {
    // MARK: 恢复

    public static func unfinishedSessions(in root: URL) -> [URL] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter {
            guard let i = SessionStore.readInfo(dir: $0) else { return FileManager.default.fileExists(atPath: $0.appendingPathComponent(SessionFiles.audio).path) }
            return i.state == .recording || i.state == .finalizing || i.state == .pendingSave
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 从本地会话目录恢复并保存(进程异常退出或保存未完成)。
    public func recover(dir: URL) async {
        guard phase == .idle || phase == .finished else { return }
        switch save {
        case .pending, .failed:
            guard localDir?.standardizedFileURL == dir.standardizedFileURL else {
                message = "上次录音尚未保存，请先重试保存。"
                return
            }
            await retrySave()
            return
        default:
            break
        }
        resetForNewSession()
        let original = SessionStore.readInfo(dir: dir)
        sessionSaveRoot = original?.sessionDestination ?? original?.deliveryRoot ?? saveRoot
        sessionDraftID = original?.draftID
        sessionPlacement = original?.recordingPlacement
        let date = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        var info = original ?? SessionInfo(baseName: dir.lastPathComponent, course: "", startedAt: date, state: .finalizing)
        phase = .finalizing; localDir = dir; courseName = info.course
        let store = SessionStore(dir: dir, info: info)
        self.store = store
        if let id = info.deliveryID, let root = info.deliveryRoot {
            do {
                if let existing = try await existingPublication(for: info, placement: sessionPlacement, in: root, id: id) {
                    duration = info.durationSeconds
                    finalStatus = info.status
                    transcribe = info.status == .completed ? .done : .incomplete
                    acknowledgeDelivery(existing, store: store)
                    phase = .finished
                    return
                }
            } catch {
                // Keep the attempted destination so retry checks the same publication.
                sessionSaveRoot = root
            }
        }
        let loaded = SessionStore.loadEvents(dir: dir)
        let volatileLoaded = SessionStore.loadVolatile(dir: dir)
        assembler = TranscriptAssembler(events: loaded.events)
        notes = info.notes + loaded.issues
        if let issue = volatileLoaded.issue { notes.append(issue) }
        if original == nil { notes.append("会话信息缺失或损坏，课程、原录制日期及转写状态未知；显示日期取工作目录创建时间，仅作恢复标识。") }
        var dur = info.durationSeconds
        if let f = try? AVAudioFile(forReading: store.audioURL) {
            dur = Double(f.length) / f.processingFormat.sampleRate
            info.sampleRate = f.processingFormat.sampleRate; info.savedSamples = f.length
        }
        store.info = info; duration = dur
        let uncertain = original == nil || info.state != .pendingSave || !loaded.issues.isEmpty
        var recoveredVolatileDraft = false
        if uncertain, let snap = volatileLoaded.snapshot {
            let trimmed = snap.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, snap.start.isFinite {
                let effectiveText: String?
                if snap.start + Self.timelineEpsilon < assembler.lastEnd {
                    effectiveText = assembler.resolveOverlappingVolatile(text: trimmed, start: snap.start)
                } else {
                    effectiveText = trimmed
                }
                if let effectiveText, !effectiveText.isEmpty {
                    let start = max(max(0, snap.start), assembler.lastEnd)
                    let end = max(start, dur)
                    record(assembler.commit(start: start, end: end, text: effectiveText))
                    recoveredVolatileDraft = true
                }
            }
        }
        if uncertain {
            notes.append("录音或文字曾被意外中断或损坏，已保留完整记录；转写可能不完整。")
            if recoveredVolatileDraft {
                notes.append("末段文字来自意外中断前的实时草稿（未经最终确认），原始音频已完整保留，可使用上方「重新转写」获取完整文稿。")
            }
            if dur > assembler.lastEnd { record(assembler.markGap(start: assembler.lastEnd, end: dur)) }
        }
        store.clearVolatile()
        publishAssembler()
        let m4a = await exportAudio(store: store)
        let hasText = assembler.events.contains { $0.kind == .text }
        var status = info.status ?? (hasText ? .partial : .failed)
        if uncertain || assembler.segments.contains(where: \.incomplete) {
            status = info.status == .failed || !hasText ? .failed : .partial
        }
        transcribe = status == .completed ? .done : .incomplete
        await finishSession(store: store, m4a: m4a, duration: dur, status: status)
    }

    // MARK: 保存

    func exportAudio(store: SessionStore) async -> URL? {
        let m4a = store.dir.appendingPathComponent(store.info.baseName + ".m4a")
        do {
            _ = try await AudioExporter.exportM4A(from: store.audioURL, to: m4a)
            return m4a
        } catch {
            notes.append("M4A 转换失败(\(error.localizedDescription)),原始录音保留为 audio.caf。")
            if FileManager.default.fileExists(atPath: m4a.path) { try? FileManager.default.trashItem(at: m4a, resultingItemURL: nil) }
            return nil
        }
    }

    func finishSession(store: SessionStore, m4a: URL?, duration: Double, status: TranscriptStatus) async {
        attemptPersistence(forceJournal: true)
        let status = journalError != nil && status == .completed ? TranscriptStatus.partial : status
        finalStatus = status
        transcribe = status == .completed ? .done : .incomplete
        if hadPersistenceFailure {
            let note = persistenceIssue == nil ? "录制期间曾有文本或恢复信息保存异常，结束时已重新保存。" : "本地文本或恢复信息仍未完整保存:\(persistenceIssue!)"
            if !notes.contains(note) { notes.append(note) }
        }
        if assembler.segments.contains(where: \.incomplete) && !notes.contains(where: { $0.contains("不完整") }) {
            notes.append("部分时间段的转写不完整,已在正文中标注。")
        }
        let engineName = engine?.name ?? SpeechEngine().name
        let lang = engine?.languageTag ?? "zh-CN"
        let title = store.info.course.isEmpty ? "课堂录音" : store.info.course
        let audioName = (m4a ?? store.audioURL).lastPathComponent
        let doc = MarkdownDoc(title: title, date: store.info.startedAt, duration: duration, audioName: audioName,
                              engine: engineName, language: lang, status: status, notes: notes,
                              segments: assembler.segments)
        let md = store.dir.appendingPathComponent(store.info.baseName + ".md")
        do { try doc.render().write(to: md, atomically: true, encoding: .utf8) }
        catch { save = .failed("无法写入 Markdown:\(error.localizedDescription)。本地文件:\(store.dir.path)"); phase = .finished; return }
        store.info.status = status; store.info.notes = notes
        pendingFiles = (store.info.baseName, m4a ?? store.audioURL, md)
        await deliver(store: store)
        phase = .finished
    }

    public func retrySave(in newParent: URL? = nil) async {
        guard let store, phase == .finished else { return }
        switch save { case .pending, .failed: break; default: return }
        phase = .finalizing
        if let newParent {
            let oldInfo = store.info
            let oldPlacement = sessionPlacement
            if let id = oldInfo.deliveryID, let root = oldInfo.deliveryRoot {
                do {
                    if let previous = try await existingPublication(for: oldInfo, placement: oldPlacement, in: root, id: id) {
                        acknowledgeDelivery(previous, store: store)
                        phase = .finished
                        return
                    }
                } catch {
                    // A missing/replaced or incomplete target can be left behind after explicit reselection.
                }
            }
            store.info.sessionDestination = newParent
            store.info.recordingPlacement = nil
            store.info.deliveryID = nil
            store.info.deliveryRoot = nil
            do { try store.save() }
            catch {
                store.info = oldInfo
                save = .pending(store.dir.path, error.localizedDescription)
                phase = .finished
                return
            }
            sessionSaveRoot = newParent
            sessionPlacement = nil
        }
        if pendingFiles == nil {
            let audio = store.dir.appendingPathComponent(store.info.baseName + ".m4a")
            await finishSession(store: store, m4a: FileManager.default.fileExists(atPath: audio.path) ? audio : nil,
                                duration: duration, status: finalStatus ?? .partial)
        } else {
            attemptPersistence(forceJournal: true)
            await deliver(store: store)
            phase = .finished
        }
    }

    private func existingPublication(for info: SessionInfo, placement: RecordingPlacement?, in root: URL, id: UUID) async throws -> DeliveryResult? {
        try await Task.detached {
            if let placement {
                return try Deliverer.placementPublication(placement, audioName: info.deliveryAudioName,
                                                          markdownName: info.baseName + ".md", id: id)
            }
            return try Deliverer.published(base: info.baseName, audioName: info.deliveryAudioName,
                                           markdownName: info.baseName + ".md", in: root, id: id)
        }.value
    }

    private func deliver(store: SessionStore) async {
        guard let f = pendingFiles else { return }
        save = .saving
        let destination = sessionDestination
        let operation = deliverFiles
        let placement = sessionPlacement
        do {
            let id = store.info.deliveryID ?? UUID()
            store.info.deliveryID = id
            store.info.deliveryRoot = destination
            store.info.deliveryAudioName = f.m4a?.lastPathComponent
            store.info.state = .pendingSave
            try store.save()
            let result = try await Task.detached {
                if let placement {
                    return try Deliverer.fill(placement, audio: f.m4a, markdown: f.md, id: id)
                }
                return try operation(f.base, f.m4a, f.md, destination, id)
            }.value
            acknowledgeDelivery(result, store: store)
        } catch {
            store.info.state = .pendingSave
            persistMetadata()
            save = .pending(store.dir.path, error.localizedDescription)
        }
    }

    private func acknowledgeDelivery(_ result: DeliveryResult, store: SessionStore) {
        deliveredFiles = result
        deliveredDir = result.directory
        store.info.destination = result.directory.path
        store.info.state = .saved
        persistMetadata()
        save = .saved(result.directory.path)
        onDelivery?(result, sessionDraftID)
    }
}
