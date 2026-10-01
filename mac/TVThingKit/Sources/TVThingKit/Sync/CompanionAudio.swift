import AVFoundation
import Foundation
import Observation

/// Plays the current channel's audio on the Mac, kept in step with the Car Thing's video.
///
/// Audio goes through macOS so the Mac's volume keys, output device, and AirPlay all
/// just work. Playback follows the Car Thing: it pauses when the device stops
/// reporting and resumes (and re-aligns) when it comes back.
@MainActor
@Observable
public final class CompanionAudio {
    public enum Status: Equatable, Sendable {
        case off
        case waitingForDevice
        case buffering
        case playing
        /// The stream has no program-date-time stamps, so audio plays unsynchronized.
        case unsynchronized
    }

    public static let offsetRange = -5_000...5_000

    public private(set) var status: Status = .off
    /// Latest measured difference between video and audio, in milliseconds.
    public private(set) var differenceMs: Int?

    public var isEnabled = true {
        didSet { if !isEnabled { tearDown(); status = .off } }
    }

    public var volume: Float = 0.8 {
        didSet { applyVolume() }
    }

    /// Silences audio without stopping it, so sync is kept and unmuting is instant.
    public var isMuted = false {
        didSet { player?.isMuted = isMuted }
    }

    /// Positive values delay audio relative to video.
    public var offsetMs: Int {
        get { storedOffsetMs }
        set { storedOffsetMs = min(max(newValue, Self.offsetRange.lowerBound), Self.offsetRange.upperBound) }
    }

    // Clamped through `offsetMs`. A `didSet` that reassigns an @Observable property recurses.
    private var storedOffsetMs = 0

    private static let tickInterval: Duration = .milliseconds(400)
    private static let deviceGracePeriod: TimeInterval = 4
    private static let stallTimeout: TimeInterval = 7

    private let engine: TVThingEngine
    private var streamURL: URL?
    private var player: AVPlayer?
    private var policy = SyncPolicy()
    private var loop: Task<Void, Never>?
    private var lastDeviceActivity = Date.distantPast
    private var lastAudioTime = -1.0
    private var lastAudioProgress = Date.now
    private var wasRebuffering = false
    /// The Car Thing's playback generation last aligned to.
    private var deviceGeneration: Int?
    /// Audio is silent while the Car Thing hides the picture, and fades in with it.
    private var pictureVisible = true
    /// False once the Car Thing stops reporting (unplugged, crashed); audio goes silent
    /// at once but keeps running briefly so a quick return is seamless.
    private var deviceReporting = true
    /// Reports arrive twice a second; this many seconds of silence means it's gone.
    private static let silenceAfter: TimeInterval = 1.5
    private var fade: Task<Void, Never>?
    private static let fadeInSteps = 8
    private static let fadeInStep: Duration = .milliseconds(40)

    public init(engine: TVThingEngine) {
        self.engine = engine
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        tearDown()
    }

    /// Call when the engine's stream URL changes (a new tune).
    public func setStream(_ url: URL?) {
        guard url != streamURL else { return }
        streamURL = url
        tearDown()
    }

    /// Silences audio while the Car Thing hides the picture, and fades it back in with it.
    /// Called as soon as the engine hears about a change, not on the next tick.
    public func setPictureVisible(_ visible: Bool) {
        guard visible != pictureVisible else { return }
        let wasAudible = audible
        pictureVisible = visible
        audibilityChanged(from: wasAudible)
    }

    private func setDeviceReporting(_ reporting: Bool) {
        guard reporting != deviceReporting else { return }
        let wasAudible = audible
        deviceReporting = reporting
        audibilityChanged(from: wasAudible)
    }

    private var audible: Bool { pictureVisible && deviceReporting }

    private func audibilityChanged(from wasAudible: Bool) {
        guard audible != wasAudible else { return }
        if audible { fadeIn() } else { applyVolume() }
    }

    /// Forces a fresh alignment on the next tick.
    public func resync() {
        policy.reset()
    }

    // MARK: - Loop

    private func tick() async {
        guard isEnabled, let streamURL else {
            tearDown()
            if isEnabled { status = .waitingForDevice }
            return
        }

        let timeline = await engine.deviceTimeline()
        if let timeline, timeline.generation != deviceGeneration {
            // The Car Thing restarted playback: align straight away, without waiting
            // out the cooldown that guards automatic re-alignment.
            if deviceGeneration != nil { policy.reset() }
            deviceGeneration = timeline.generation
        }
        setDeviceReporting(timeline.map { Date.now.timeIntervalSince($0.receivedAt) < Self.silenceAfter } ?? false)
        if let timeline, timeline.playing, Date.now.timeIntervalSince(timeline.receivedAt) < 3 {
            lastDeviceActivity = .now
        }
        guard let timeline, Date.now.timeIntervalSince(lastDeviceActivity) < Self.deviceGracePeriod else {
            player?.pause()
            status = .waitingForDevice
            differenceMs = nil
            return
        }

        let player = player ?? makePlayer(for: streamURL)
        if player.timeControlStatus == .paused { player.play() }
        guard let item = player.currentItem, item.status == .readyToPlay else {
            status = .buffering
            return
        }
        disableVideo(in: item)

        guard let devicePosition = timeline.positionMs, let audioDate = item.currentDate() else {
            status = timeline.positionMs == nil && item.currentDate() == nil ? .unsynchronized : .buffering
            differenceMs = nil
            checkForStall(item)
            return
        }

        let elapsed = Date.now.timeIntervalSince(timeline.receivedAt) * 1_000
        let targetMs = devicePosition + elapsed - Double(offsetMs)
        let difference = (targetMs - audioDate.timeIntervalSince1970 * 1_000) / 1_000
        differenceMs = Int((difference * 1_000).rounded())
        // While the picture is hidden and the audio silent, keep following the Car Thing
        // closely, so the sound is already aligned when the picture returns.
        if !audible { policy.reset() }

        if case .seek(let delta, let reason) = policy.evaluate(difference: difference, offsetMs: offsetMs) {
            let current = item.currentTime().seconds
            if current.isFinite {
                let target = CMTime(seconds: max(0, current + delta), preferredTimescale: 600)
                await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                // Silent re-alignments (while the picture is hidden) happen constantly; only
                // audible ones are worth recording.
                if audible {
                    let label = switch reason {
                    case .initial: "start"
                    case .offsetChanged: "delay changed"
                    case .transition: "stream transition"
                    case .drift: "drift"
                    }
                    await engine.log.record("Audio re-aligned by \(Int((delta * 1_000).rounded())) ms (\(label))", source: .mac)
                }
            }
        }
        status = .playing
        noteRebuffering(player)
        checkForStall(item)
    }

    /// Records when the Mac's audio player runs dry and pauses to refill mid-playback.
    private func noteRebuffering(_ player: AVPlayer) {
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if waiting, !wasRebuffering, audible {
            let reason = player.reasonForWaitingToPlay.map { $0.rawValue } ?? "unknown"
            Task { await engine.log.record("Audio rebuffering (\(reason))", source: .mac) }
        }
        wasRebuffering = waiting
    }

    private func makePlayer(for url: URL) -> AVPlayer {
        let item = AVPlayerItem(url: url)
        // Every rendition carries the same audio; the smallest wastes the least bandwidth.
        item.preferredPeakBitRate = 1
        let player = AVPlayer(playerItem: item)
        // Play whatever is buffered instead of pausing to build a safety margin: TV Thing
        // keeps the audio aligned itself, and with streams converted live there's little
        // buffered ahead, so waiting caused a stall, re-align, stall loop.
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = isMuted
        self.player = player
        applyVolume()
        policy.reset()
        lastAudioTime = -1
        lastAudioProgress = .now
        status = .buffering
        return player
    }

    /// The Mac never shows the picture, so don't spend energy decoding it.
    private func disableVideo(in item: AVPlayerItem) {
        for track in item.tracks where track.isEnabled && track.assetTrack?.mediaType == .video {
            track.isEnabled = false
        }
    }

    /// Rebuilds the player if audio stops advancing while the Car Thing keeps playing.
    private func checkForStall(_ item: AVPlayerItem) {
        let time = item.currentTime().seconds
        if time.isFinite, time > lastAudioTime + 0.04 {
            lastAudioTime = time
            lastAudioProgress = .now
        } else if Date.now.timeIntervalSince(lastAudioProgress) > Self.stallTimeout {
            Task { await engine.log.record("Audio stalled; reconnecting", source: .mac) }
            tearDown()
        }
    }

    private func applyVolume() {
        fade?.cancel()
        player?.volume = audible ? volume : 0
    }

    private func fadeIn() {
        fade?.cancel()
        fade = Task { [weak self] in
            for step in 1...Self.fadeInSteps {
                guard let self, !Task.isCancelled else { return }
                self.player?.volume = self.volume * Float(step) / Float(Self.fadeInSteps)
                try? await Task.sleep(for: Self.fadeInStep)
            }
        }
    }

    private func tearDown() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        differenceMs = nil
    }
}
