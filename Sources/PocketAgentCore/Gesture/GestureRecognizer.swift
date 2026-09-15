import Foundation

/// Turns raw press/release events into gestures (spec §18).
///
/// This is the most error-prone part of the whole system, so it is a pure state machine with an
/// injectable clock: no timers, no I/O, fully deterministic under test.
///
/// State machine, exactly as specified:
///
/// ```text
/// Idle
///   B down                        -> BPending, arm hold timer
///   secondary down while B is down -> ChordActive, emit chord, suppress B's own gesture
///   B held past holdMs            -> BReady (no output yet)
///   B released from BPending      -> tap if elapsed <= tapMaxMs, else hold
///   B released from BReady        -> hold, unless a chord is still active
///   all keys released             -> Idle
/// ```
///
/// Deliberate choices worth knowing:
/// - A direction pressed while B is down is *always* a chord, however quickly it follows, matching
///   spec §18's "secondary key down while BPending".
/// - Directions map to key down/up so the target app performs key repeat natively; A is a one-shot
///   down+up so it can never repeat (spec §19).
/// - Only the first secondary key of a chord counts; extra keys while a chord is active are ignored.
public final class GestureRecognizer {
    public typealias Emit = ([ResolvedEvent]) -> Void

    private enum BState: Equatable {
        case idle
        case pending(since: TimeInterval)
        case ready
    }

    /// Mutable so a config reload takes effect without relaunching the app. A change only affects
    /// the *next* press; a gesture already in flight keeps the thresholds it started with.
    public var configuration: GestureConfiguration
    public var emit: Emit?

    private let scheduler: GestureScheduler
    private var bState: BState = .idle
    private var heldDirections: Set<PhysicalButton> = []
    private var chordKey: PhysicalButton?
    private var holdToken: GestureSchedulerToken?
    /// True while the current B press has already been consumed by a chord. It stays set until B is
    /// released — clearing it when the chord *key* is released would let B's release emit Escape
    /// afterwards, which is exactly the stuck-Escape bug the tests catch.
    private var bConsumedByChord = false

    public init(
        configuration: GestureConfiguration = .default,
        scheduler: GestureScheduler = DispatchGestureScheduler()
    ) {
        self.configuration = configuration
        self.scheduler = scheduler
    }

    // MARK: - Input

    public func handle(_ event: InputEvent) {
        let output: [ResolvedEvent]
        switch event {
        case .pressed(let button, let timestamp):
            output = handlePress(button, at: timestamp)
        case .released(let button, let timestamp):
            output = handleRelease(button, at: timestamp)
        }
        deliver(output)
    }

    /// Clears all state and returns the events needed to release anything the target app still
    /// holds. Call this on device disconnect, sleep, or focus loss (spec §17, §18) — otherwise a
    /// direction that was down when the controller vanished stays down forever.
    @discardableResult
    public func reset() -> [ResolvedEvent] {
        holdToken?.cancel()
        holdToken = nil
        bState = .idle
        chordKey = nil
        bConsumedByChord = false

        var output: [ResolvedEvent] = []
        for direction in heldDirections.sorted(by: { $0.rawValue < $1.rawValue }) {
            output.append(.keyUp(direction))
        }
        heldDirections.removeAll()
        return output
    }

    /// Same as `reset()` but also notifies the emit callback.
    public func resetAndEmit() {
        deliver(reset())
    }

    // MARK: - Transitions

    private func handlePress(_ button: PhysicalButton, at timestamp: TimeInterval) -> [ResolvedEvent] {
        if button == .b {
            guard bState == .idle else { return [] }
            bState = .pending(since: timestamp)
            armHoldTimer()
            return []
        }

        // Secondary key while B is down: this is a chord, and the key's own key-down is suppressed.
        if bState != .idle {
            guard chordKey == nil else { return [] }
            chordKey = button
            bConsumedByChord = true
            holdToken?.cancel()
            holdToken = nil
            bState = .ready
            return [.gesture(.chord(modifier: .b, key: button))]
        }

        // Base layer.
        if button.isDirection {
            guard !heldDirections.contains(button) else { return [] }
            heldDirections.insert(button)
            return [.keyDown(button)]
        }

        // A must never repeat, so it is a complete press in one go.
        return [.keyDown(button), .keyUp(button)]
    }

    private func handleRelease(_ button: PhysicalButton, at timestamp: TimeInterval) -> [ResolvedEvent] {
        if button == .b {
            let consumed = bConsumedByChord
            bConsumedByChord = false

            switch bState {
            case .idle:
                return []

            case .pending(let since):
                holdToken?.cancel()
                holdToken = nil
                bState = .idle
                if consumed { return [] }
                let elapsedMs = (timestamp - since) * 1000
                return [.gesture(elapsedMs <= configuration.tapMaxMs ? .tap(.b) : .hold(.b))]

            case .ready:
                bState = .idle
                // A chord owns this B press: releasing B must never also emit Escape, whether the
                // chord key is still held or was already released.
                if consumed { return [] }
                return [.gesture(.hold(.b))]
            }
        }

        if chordKey == button {
            chordKey = nil
            return []
        }

        if heldDirections.contains(button) {
            heldDirections.remove(button)
            return [.keyUp(button)]
        }

        return []
    }

    private func armHoldTimer() {
        holdToken?.cancel()
        holdToken = scheduler.schedule(after: configuration.holdMs / 1000) { [weak self] in
            self?.holdTimerFired()
        }
    }

    private func holdTimerFired() {
        holdToken = nil
        guard case .pending = bState else { return }
        bState = .ready
        // No output: B only becomes a modifier at this point.
    }

    private func deliver(_ events: [ResolvedEvent]) {
        guard !events.isEmpty else { return }
        emit?(events)
    }
}
