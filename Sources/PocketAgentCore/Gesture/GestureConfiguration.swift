import Foundation

/// Timing thresholds for the B modifier, from spec §6.2/§18.
///
/// Note on `modifierAcquireMs`: spec §6.2 also lists a 180–250 ms "modifier acquire" window, but
/// the state machine in spec §18 makes a chord legal as soon as B is down (`BPending`), so no
/// separate acquire delay is needed. It is intentionally not modelled rather than carried as dead
/// configuration.
public struct GestureConfiguration: Equatable, Sendable {
    /// A B release at or below this duration is a tap.
    public var tapMaxMs: Double
    /// B held past this duration becomes a modifier; releasing it without a chord is a hold.
    public var holdMs: Double

    public init(tapMaxMs: Double = 220, holdMs: Double = 450) {
        self.tapMaxMs = tapMaxMs
        self.holdMs = holdMs
    }

    public static let `default` = GestureConfiguration()
}

/// Cancellable handle returned by a `GestureScheduler`.
public protocol GestureSchedulerToken: AnyObject {
    func cancel()
}

/// Abstracts the hold timer so the state machine can be driven deterministically in tests.
public protocol GestureScheduler: AnyObject {
    func schedule(after delay: TimeInterval, _ body: @escaping () -> Void) -> GestureSchedulerToken
}

/// Production scheduler.
public final class DispatchGestureScheduler: GestureScheduler {
    private final class Token: GestureSchedulerToken {
        private let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func schedule(after delay: TimeInterval, _ body: @escaping () -> Void) -> GestureSchedulerToken {
        let item = DispatchWorkItem(block: body)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return Token(item)
    }
}
