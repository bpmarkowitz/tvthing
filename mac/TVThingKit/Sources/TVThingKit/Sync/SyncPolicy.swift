import Foundation

/// Decides when to nudge the Mac's audio to match the Car Thing's video.
///
/// Both players stamp their position with the stream's program-date-time, so their
/// difference is directly comparable. Position reports travel over USB through
/// Bridgething and jitter by a few hundred milliseconds, so constantly chasing them
/// sounds worse than a small steady offset. The policy therefore:
/// - aligns once when a stream starts (or the user changes the offset), then locks;
/// - re-aligns when the difference jumps by a lot for consecutive samples, which is
///   what an ad break joining or leaving a stitched stream looks like;
/// - re-aligns when a moderate drift persists for several seconds.
public struct SyncPolicy: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// Seek the audio forward (positive) or back (negative) by this many seconds.
        case seek(by: TimeInterval, reason: Reason)
    }

    public enum Reason: Equatable, Sendable {
        case initial
        case offsetChanged
        case transition
        case drift
    }

    static let tolerance: TimeInterval = 0.08
    static let transitionThreshold: TimeInterval = 0.6
    static let transitionSamples = 2
    static let transitionCooldown: TimeInterval = 5
    static let driftThreshold: TimeInterval = 0.25
    static let driftSamples = 12

    private var locked = false
    private var lockedOffset: Int?
    private var transitionCount = 0
    private var driftCount = 0
    private var lastTransitionAt = Date.distantPast

    public init() {}

    public mutating func reset() {
        self = SyncPolicy()
    }

    /// - Parameters:
    ///   - difference: device position minus audio position, in seconds (positive: audio is behind).
    ///   - offsetMs: the user's manual offset, used to detect changes.
    public mutating func evaluate(difference: TimeInterval, offsetMs: Int, now: Date = .now) -> Action {
        let magnitude = abs(difference)
        transitionCount = locked && magnitude >= Self.transitionThreshold ? transitionCount + 1 : 0
        driftCount = locked && magnitude >= Self.driftThreshold && magnitude < Self.transitionThreshold ? driftCount + 1 : 0

        let reason: Reason? =
            if !locked { .initial }
            else if lockedOffset != offsetMs { .offsetChanged }
            else if transitionCount >= Self.transitionSamples, now.timeIntervalSince(lastTransitionAt) >= Self.transitionCooldown { .transition }
            else if driftCount >= Self.driftSamples { .drift }
            else { nil }

        guard let reason else { return .none }
        locked = true
        lockedOffset = offsetMs
        transitionCount = 0
        driftCount = 0
        if reason == .transition { lastTransitionAt = now }
        return magnitude > Self.tolerance ? .seek(by: difference, reason: reason) : .none
    }
}
