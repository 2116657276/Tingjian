import Observation
import AVFoundation
import Foundation
import TingjianCore

enum PlaybackError: Error, LocalizedError {
    case noAudioTrack
    case invalidDuration
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "这个文件没有可播放的音轨"
        case .invalidDuration: return "音频时长无效,文件可能已损坏"
        case .failed(let message): return "无法播放:\(message)"
        }
    }
}

@MainActor
@Observable
private final class PlaybackProgress {
    var position: Double = 0
    var preview: Double?
    var isScrubbing = false
}

/// 应用内唯一播放器:切换资源时移除旧观察者,结束时归为暂停。
@MainActor
final class PlaybackModel: ObservableObject {
    static let supportedRates: [Float] = [1.0, 1.25, 1.5, 2.0]

    @Published private(set) var currentURL: URL?
    private let progress = PlaybackProgress()
    private(set) var position: Double {
        get { progress.position }
        set { progress.position = newValue }
    }
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published var rate: Float {
        didSet {
            let normalized = Self.normalizeRate(rate)
            if normalized != rate {
                rate = normalized
                return
            }
            defaults.set(Double(normalized), forKey: "playbackRate")
            if isPlaying { player.rate = normalized }
        }
    }
    @Published private(set) var error: String?
    var onTimeChanged: ((Double) -> Void)?

    private let defaults: UserDefaults
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = Float(defaults.double(forKey: "playbackRate"))
        self.rate = stored > 0 ? Self.normalizeRate(stored) : 1.0
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.tick(time) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.isPlaying = false
                self.position = self.duration
                self.onTimeChanged?(self.position)
            }
        }
    }

    static func normalizeRate(_ candidate: Float) -> Float {
        guard candidate.isFinite else { return 1.0 }
        return supportedRates.min(by: { abs($0 - candidate) < abs($1 - candidate) }) ?? 1.0
    }

    var rateLabel: String {
        if abs(rate - Float(Int(rate))) < 0.01 { return "\(Int(rate)).0x" }
        let hundredths = Int((rate * 100).rounded())
        if hundredths % 10 == 0 { return String(format: "%.1fx", rate) }
        return String(format: "%.2fx", rate)
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    var isLoaded: Bool { currentURL != nil }
    var canSeek: Bool { duration > 0.05 }

    /// 加载音频并校验音轨;失败时保留错误且不留下旧播放器状态。
    func load(_ url: URL) async throws {
        loadGeneration += 1
        let generation = loadGeneration
        teardown()
        error = nil
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { throw PlaybackError.noAudioTrack }
            let seconds = try await asset.load(.duration).seconds
            guard seconds.isFinite, seconds > 0.05 else { throw PlaybackError.invalidDuration }
            guard generation == loadGeneration else { return }
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .timeDomain
            player.replaceCurrentItem(with: item)
            currentURL = url
            duration = seconds
            position = 0
            isPlaying = false
            onTimeChanged?(0)
            for _ in 0..<60 {
                try Task.checkCancellation()
                if generation != loadGeneration { return }
                if item.status == .readyToPlay { return }
                if item.status == .failed {
                    throw PlaybackError.failed(item.error?.localizedDescription ?? "音频加载失败")
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            throw PlaybackError.failed("音频加载超时")
        } catch {
            if generation == loadGeneration {
                teardown()
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            throw error
        }
    }

    func play() {
        guard currentURL != nil, player.currentItem?.status == .readyToPlay else { return }
        if duration > 0, position >= duration - 0.05 { seek(to: 0) }
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func skip(by delta: Double) {
        guard currentURL != nil, canSeek, delta.isFinite else { return }
        seek(to: position + delta)
    }

    func playFrom(_ seconds: Double) {
        guard currentURL != nil, canSeek else { return }
        seek(to: seconds)
        if player.currentItem?.status == .readyToPlay {
            player.playImmediately(atRate: rate)
            isPlaying = true
        }
    }

    var displayedPosition: Double { progress.preview ?? position }

    func previewSeek(_ seconds: Double) {
        if progress.isScrubbing { progress.preview = seconds }
        else { seek(to: seconds) }
    }

    func setScrubbing(_ editing: Bool) {
        progress.isScrubbing = editing
        if !editing, let target = progress.preview {
            progress.preview = nil
            seek(to: target)
        }
    }

    func seek(to seconds: Double) {
        guard currentURL != nil, canSeek else { return }
        let target = min(max(0, seconds), max(0, duration - 0.02))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        position = target
        onTimeChanged?(target)
    }

    /// 释放播放器与资源;不清除 error,由调用方决定是否展示。
    func stop() {
        loadGeneration += 1
        teardown()
        error = nil
    }

    private func teardown() {
        progress.isScrubbing = false
        progress.preview = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
        duration = 0
        position = 0
        isPlaying = false
        onTimeChanged?(0)
    }

    private func tick(_ time: CMTime) {
        guard player.currentItem != nil else { return }
        let seconds = time.seconds
        if seconds.isFinite {
            position = max(0, min(seconds, max(duration, seconds)))
            onTimeChanged?(position)
        }
        let playing = player.rate > 0
        if isPlaying != playing { isPlaying = playing }
        if player.currentItem?.status == .failed {
            error = player.currentItem?.error?.localizedDescription ?? "播放中断"
            isPlaying = false
        }
    }
}
