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
///   B held past holdMs            -> BReady (no output yet; a later chord still wins)
///   chord key down while B is down-> BReady(occupiedByChord), chord emitted
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
        /// B is down but the hold timer has not fired.
        case pending(since: TimeInterval)
        /// The hold timer fired and/or a chord key made B a modifier.
        ///
        /// Both flags are needed to decide what releasing B means:
        /// - `holdFired` separates a real hold (switch agent) from a press that merely outlived the
        ///   old `tapMaxMs` threshold, which stays a tap;
        /// - `occupiedByChord` suppresses B's own gesture once a chord has taken the press, so
        ///   finishing push-to-talk cannot also fire a stray Escape.
        case ready(holdFired: Bool, occupiedByChord: Bool)
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
    /// True while A is physically down. B pressed during that is ignored: A is never a layer key, so
    /// a B that arrives after it cannot start a chord or a hold.
    private var aIsDown = false
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

    /// True when nothing is physically down as far as this recognizer knows.
    ///
    /// Used to decide whether a *release* still means something: with no press outstanding there is
    /// nothing that release could be ending, which is the signature of cleanup invented by a source
    /// (a device that vanished) rather than input from a user.
    public var hasNothingInFlight: Bool {
        bState == .idle && heldDirections.isEmpty && chordKey == nil
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
        bConsumedByChord = false
        aIsDown = false

        var output: [ResolvedEvent] = []
        // A held (modifier-only) chord must be released too, or the user's session inherits a stuck
        // Option+Shift when the controller disconnects mid-chord.
        if let key = chordKey {
            output.append(.gesture(.chordReleased(modifier: .b, key: key)))
        }
        chordKey = nil
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
            // A already being held means this is not a B press the user intends as a gesture: A is
            // never a layer key, so a B arriving after it must not start a chord or a hold. Letting
            // it do so is how releasing A during push-to-talk turned the tail of a voice input into
            // an app switch.
            if aIsDown || bState != .idle { return [] }
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
            // The chord takes the press away from B: whatever the hold timer did in the meantime,
            // B is now a modifier for as long as the user keeps holding it. This is what makes
            // "hold B, then press A" (push-to-talk) work at any hold duration — without it, holding
            // B for longer than `holdMs` fired the hold action before the chord even started, which
            // is exactly backwards: the user is still holding B precisely *because* they are using
            // it as a modifier.
            bState = .ready(holdFired: false, occupiedByChord: true)
            return [.gesture(.chord(modifier: .b, key: button))]
        }

        // Base layer.
        if button.isDirection {
            guard !heldDirections.contains(button) else { return [] }
            heldDirections.insert(button)
            return [.keyDown(button)]
        }

        // A must never repeat, so it is a complete press in one go.
        aIsDown = true
        return [.keyDown(button), .keyUp(button)]
    }

    private func handleRelease(_ button: PhysicalButton, at timestamp: TimeInterval) -> [ResolvedEvent] {
        if button == .a {
            aIsDown = false
        }

        if button == .b {
            let consumed = bConsumedByChord
            bConsumedByChord = false

            switch bState {
            case .idle:
                return []

            case .pending:
                holdToken?.cancel()
                holdToken = nil
                bState = .idle
                if consumed { return [] }
                // `tapMaxMs` alone used to decide this, which made `holdMs` decorative: a 300 ms
                // press was announced as a *hold* even though the documented hold threshold is
                // 450 ms. That was harmless while a hold meant "the same as a tap" (Escape), but a
                // hold now switches applications, and guessing wrong there is destructive — so a
                // hold is only reported once the hold timer has actually fired, and anything
                // shorter is a (deliberately late) tap.
                return [.gesture(.tap(.b))]

            case .ready(let holdFired, let occupiedByChord):
                bState = .idle
                // A chord owns this B press: releasing B must never also emit Escape or switch apps,
                // whether the chord key is still held or was already released.
                if consumed || occupiedByChord { return [] }
                return [.gesture(holdFired ? .hold(.b) : .tap(.b))]
            }
        }

        if chordKey == button {
            chordKey = nil
            return [.gesture(.chordReleased(modifier: .b, key: button))]
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
        bState = .ready(holdFired: true, occupiedByChord: false)
        // Still no output: becoming a modifier emits nothing on its own. The hold action fires when
        // B is released, which is also what keeps `holdMs` — not `tapMaxMs` — the deciding threshold.
    }

    private func deliver(_ events: [ResolvedEvent]) {
        guard !events.isEmpty else { return }
        emit?(events)
    }
}
