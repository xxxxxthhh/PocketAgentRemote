import XCTest
@testable import PocketAgentCore

/// Deterministic clock for the gesture engine.
final class ManualScheduler: GestureScheduler {
    private final class Token: GestureSchedulerToken {
        var due: TimeInterval
        var firedOrCancelled = false
        let body: () -> Void
        init(due: TimeInterval, body: @escaping () -> Void) {
            self.due = due
            self.body = body
        }
        func cancel() { firedOrCancelled = true }
    }

    private var tokens: [Token] = []
    private(set) var now: TimeInterval = 0

    func schedule(after delay: TimeInterval, _ body: @escaping () -> Void) -> GestureSchedulerToken {
        let token = Token(due: now + delay, body: body)
        tokens.append(token)
        return token
    }

    func advance(to time: TimeInterval) {
        precondition(time >= now, "time never moves backwards")
        now = time
        var firedAnything = true
        while firedAnything {
            firedAnything = false
            for token in tokens where !token.firedOrCancelled && token.due <= now {
                token.firedOrCancelled = true
                token.body()
                firedAnything = true
            }
            tokens.removeAll { $0.firedOrCancelled }
        }
    }
}

/// Test harness: drives the recognizer and records everything it emits.
final class Harness {
    let scheduler = ManualScheduler()
    let recognizer: GestureRecognizer
    private(set) var batches: [[ResolvedEvent]] = []

    init(configuration: GestureConfiguration = .default) {
        recognizer = GestureRecognizer(configuration: configuration, scheduler: scheduler)
        recognizer.emit = { [weak self] events in self?.batches.append(events) }
    }

    /// Every event the recognizer emitted, flattened, in order.
    var emitted: [ResolvedEvent] { batches.flatMap { $0 } }

    var gestures: [ControllerGesture] {
        emitted.compactMap { if case .gesture(let g) = $0 { return g } else { return nil } }
    }

    /// Gestures that stand on their own. `chordReleased` is excluded because it exists only to end
    /// a *held* binding (a modifier-only chord) — semantic actions are one-shot and ignore it.
    var actionGestures: [ControllerGesture] {
        gestures.filter {
            if case .chordReleased = $0 { return false }
            return true
        }
    }

    var chordReleases: [ControllerGesture] {
        gestures.filter {
            if case .chordReleased = $0 { return true }
            return false
        }
    }

    func press(_ button: PhysicalButton) {
        recognizer.handle(.pressed(button, timestamp: scheduler.now))
    }

    func release(_ button: PhysicalButton) {
        recognizer.handle(.released(button, timestamp: scheduler.now))
    }

    func advance(to time: TimeInterval) {
        scheduler.advance(to: time)
    }
}
