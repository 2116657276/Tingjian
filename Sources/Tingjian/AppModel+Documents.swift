import Foundation
import TingjianCore

extension AppModel {
    // MARK: 播放控制与文稿内查找

    var canControlPlayback: Bool {
        !recorder.isActive && playback.isLoaded && playback.canSeek
    }

    func togglePlaybackIfAvailable() {
        guard canControlPlayback else { return }
        playback.togglePlay()
    }

    func skipPlayback(by delta: Double) {
        guard canControlPlayback else { return }
        playback.skip(by: delta)
    }

    func closePlayback() {
        if let current = playback.currentURL?.standardizedFileURL {
            audioPositions[current] = playback.position
        }
        playback.stop()
        activeDocumentBlockID = nil
    }

    func playAudio(_ url: URL) async {
        guard !recorder.isActive else { return }
        let key = url.standardizedFileURL
        if playback.currentURL?.standardizedFileURL != key || !playback.isLoaded {
            await loadAudio(url, at: audioPositions[key] ?? 0)
        }
        guard !recorder.isActive,
              playback.currentURL?.standardizedFileURL == key,
              playback.isLoaded,
              playback.canSeek else { return }
        if !playback.isPlaying {
            playback.togglePlay()
        }
    }

    func updateActiveDocumentBlock(at position: Double) {
        guard let doc = openDocument,
              let linked = doc.linkedAudio?.standardizedFileURL,
              playback.currentURL?.standardizedFileURL == linked,
              playback.isLoaded,
              !doc.blocks.isEmpty else {
            if activeDocumentBlockID != nil { activeDocumentBlockID = nil }
            return
        }
        let nextID = DocumentHighlightResolver.activeBlockID(
            blocks: doc.blocks.map { (id: $0.id, isEmptyCorrectedAnchor: $0.isEmptySegment) },
            blockTimes: doc.blockTimes,
            at: position,
            showEmptyCorrectedSegments: showEmptyCorrectedSegments
        )
        if activeDocumentBlockID != nextID {
            activeDocumentBlockID = nextID
        }
    }

    var canSearchCurrentDocument: Bool {
        if case .document = selection {
            return openDocument?.blocks.isEmpty == false
        }
        return false
    }

    var canStepDocumentSearch: Bool {
        isDocumentSearchPresented && !documentSearchMatches.isEmpty
    }

    func presentDocumentSearch() {
        guard canSearchCurrentDocument else { return }
        isDocumentSearchPresented = true
        recomputeDocumentSearchMatches(resetIndex: false)
    }

    func dismissDocumentSearch() {
        isDocumentSearchPresented = false
        documentSearchQuery = ""
        documentSearchMatches = []
        documentSearchCurrentIndex = 0
    }

    func stepDocumentSearch(_ delta: Int) {
        guard !documentSearchMatches.isEmpty else { return }
        let count = documentSearchMatches.count
        documentSearchCurrentIndex = (documentSearchCurrentIndex + delta % count + count) % count
    }

    func recomputeDocumentSearchMatches(resetIndex: Bool) {
        guard isDocumentSearchPresented, let doc = openDocument, !doc.blocks.isEmpty else {
            documentSearchMatches = []
            documentSearchCurrentIndex = 0
            return
        }
        let indices = TranscriptLocator.matchingBlockIndices(query: documentSearchQuery, texts: doc.blockTexts)
        documentSearchMatches = indices.compactMap { doc.blocks.indices.contains($0) ? doc.blocks[$0].id : nil }
        if documentSearchMatches.isEmpty {
            documentSearchCurrentIndex = 0
        } else if resetIndex || !documentSearchMatches.indices.contains(documentSearchCurrentIndex) {
            documentSearchCurrentIndex = 0
        }
    }

    // MARK: 文稿与播放

    func loadDocument(_ url: URL, generation requestedGeneration: Int? = nil, force: Bool = true) async {
        let generation = requestedGeneration ?? documentGeneration
        guard generation == documentGeneration, selection == .document(url) else { return }
        let key = url.standardizedFileURL
        if let audio = playback.currentURL?.standardizedFileURL { audioPositions[audio] = playback.position }
        let cached = documentsByURL[key]
        documentRead?.cancel()
        let task = Task.detached(priority: .userInitiated) { () throws -> OpenDocument? in
            let revision = try DocumentRevision(url: key)
            if !force, let cached, cached.revision == revision { return nil }
            try Task.checkCancellation()
            let text = try String(contentsOf: key, encoding: .utf8)
            try Task.checkCancellation()
            let parsed = MarkdownDoc.parseDocument(text)
            let blocks: [DocumentBlockItem] = parsed.blocks.enumerated().map { index, block in
                switch block {
                case .segment(let time, let segmentText):
                    return DocumentBlockItem(id: index, kind: .segment(time: time, text: segmentText))
                case .gap(let start, let end, let note):
                    return DocumentBlockItem(id: index, kind: .gap(start: start, end: end, note: note))
                }
            }
            let blockTimes: [Double?] = parsed.blocks.map { block in
                switch block {
                case .segment(let time, _): return Timecode.parse(time)
                case .gap(let start, _, _): return Timecode.parse(start)
                }
            }
            let blockTexts: [String] = parsed.blocks.map { block in
                switch block {
                case .segment(_, let segmentText): return segmentText
                case .gap(let start, let end, let note): return "\(note) \(start) \(end)"
                }
            }
            var lineID = 0
            let lines: [DocumentLine] = parsed.blocks.compactMap { block in
                guard case .segment(let time, let segmentText) = block else { return nil }
                defer { lineID += 1 }
                return DocumentLine(id: lineID, time: time, text: segmentText)
            }
            let originalDocument = parsed.originalDocumentName.flatMap {
                ProjectLibrary.linkedOriginalDocument(named: $0, beside: key)
            }
            let correctedDocument = parsed.isCorrected ? nil : ProjectLibrary.latestCorrectedDocument(for: key)
            try Task.checkCancellation()
            return OpenDocument(url: url, text: text, lines: lines, blocks: blocks,
                                blockTimes: blockTimes, blockTexts: blockTexts, parsed: parsed,
                                linkedAudio: ProjectLibrary.linkedAudio(in: text, beside: key),
                                originalDocument: originalDocument,
                                correctedDocument: correctedDocument,
                                error: nil, revision: revision)
        }
        documentRead = task
        do {
            let loaded = try await task.value
            guard !task.isCancelled, generation == documentGeneration else { return }
            guard let doc = loaded ?? cached else { return }
            if let loaded {
                openDocument = loaded
                documentsByURL[key] = loaded
            }
            if doc.blocks.isEmpty && isDocumentSearchPresented {
                dismissDocumentSearch()
            } else {
                recomputeDocumentSearchMatches(resetIndex: true)
            }
            if let audio = doc.linkedAudio {
                if playback.currentURL?.standardizedFileURL != audio.standardizedFileURL || force {
                    await loadAudio(audio, at: audioPositions[audio.standardizedFileURL] ?? 0, generation: generation)
                }
                updateActiveDocumentBlock(at: playback.position)
            } else {
                playback.stop()
                audioError = nil
                activeDocumentBlockID = nil
            }
        } catch {
            guard !task.isCancelled, generation == documentGeneration else { return }
            openDocument = OpenDocument(url: url, text: "", lines: [], linkedAudio: nil,
                                        error: "无法读取文稿：" + error.localizedDescription)
            documentsByURL[key] = nil
            playback.stop()
        }
    }

    func loadAudio(_ url: URL, at position: Double = 0, generation requestedGeneration: Int? = nil) async {
        let generation = requestedGeneration ?? documentGeneration
        guard generation == documentGeneration else { return }
        audioError = nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            playback.stop()
            audioError = "文件已移动或不存在：\(url.path)。请刷新项目列表。"
            return
        }
        do {
            try await playback.load(url)
            guard generation == documentGeneration else { return }
            if position > 0 { playback.seek(to: position) }
        }
        catch {
            guard generation == documentGeneration else { return }
            audioError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func openLinkedAudio(for document: URL) {
        let generation = documentGeneration
        Task {
            let audio = await Task.detached {
                guard let text = try? String(contentsOf: document, encoding: .utf8) else { return Optional<URL>.none }
                return ProjectLibrary.linkedAudio(in: text, beside: document)
            }.value
            guard generation == documentGeneration else { return }
            guard let audio else {
                libraryNotice = "未找到可播放的关联音频：" + document.lastPathComponent
                return
            }
            select(.audio(audio))
        }
    }

    func reloadOpenContent() async {
        switch selection {
        case .document(let url): await loadDocument(url)
        case .audio(let url): await loadAudio(url, at: playback.currentURL != nil ? playback.position : (audioPositions[url.standardizedFileURL] ?? 0))
        case .directory(let url): await loadChildren(url, force: true)
        case .draft, .currentRecording:
            refreshUnfinished()
        }
    }

    func seek(toTimecode time: String, autoPlay: Bool = true) async {
        let generation = documentGeneration
        guard !recorder.isActive, let audio = openDocument?.linkedAudio,
              let seconds = Self.parseTimecode(time) else { return }
        if playback.currentURL?.standardizedFileURL != audio.standardizedFileURL {
            await loadAudio(audio, generation: generation)
        }
        guard generation == documentGeneration, !recorder.isActive else { return }
        guard playback.currentURL?.standardizedFileURL == audio.standardizedFileURL, playback.canSeek else {
            seekMessage = audioError ?? "关联音频暂时无法播放"
            return
        }
        guard seconds < playback.duration else {
            seekMessage = "该时间点超出音频时长"
            return
        }
        if autoPlay {
            playback.playFrom(seconds)
        } else {
            playback.seek(to: seconds)
        }
        seekMessage = nil
    }

    static func parseTimecode(_ text: String) -> Double? {
        Timecode.parse(text)
    }

    func linkedAudio(in text: String, nextTo url: URL) -> URL? {
        ProjectLibrary.linkedAudio(in: text, beside: url)
    }

    func originalDocumentURL(for document: URL) -> URL? {
        let key = document.standardizedFileURL
        guard let doc = openDocument, doc.url.standardizedFileURL == key,
              let original = doc.originalDocument, FileManager.default.fileExists(atPath: original.path) else {
            return nil
        }
        return original
    }

    func correctedDocumentURL(for document: URL) -> URL? {
        let key = document.standardizedFileURL
        if let output = correctionOutputByDocument[key], FileManager.default.fileExists(atPath: output.path) {
            return output
        }
        if let doc = openDocument, doc.url.standardizedFileURL == key,
           let corrected = doc.correctedDocument, FileManager.default.fileExists(atPath: corrected.path) {
            return corrected
        }
        return nil
    }
}
