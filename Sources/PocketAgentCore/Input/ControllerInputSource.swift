import Foundation

/// Where a controller's input is coming from.
///
/// Phase 0 showed why there are two: GameController only ever attaches to the XInput variant
/// (`Xbox Wireless Controller`); the generic variant (`Wireless Controller`) is invisible to it and
/// only exists at the HID layer. Both are supported, so both paths are first-class.
public enum ControllerTransport: String, Sendable {
    case gameController
    case rawHID
}

/// Anything that can produce `InputEvent`s from the controller.
public protocol ControllerInputSource: AnyObject {
    var transport: ControllerTransport { get }
    var onEvent: ((InputEvent) -> Void)? { get set }
    /// Fires with a human-readable device name when a supported controller becomes usable.
    var onAttach: ((String) -> Void)? { get set }
    /// Fires when that controller goes away. Callers must reset gesture state here (spec §17/§18).
    var onDetach: ((String) -> Void)? { get set }
    /// The source is about to tear a device down and may emit cleanup events before `onDetach`.
    ///
    /// A source that synthesises releases for whatever it believed was held announces it here first,
    /// so the coordinator can mark the whole window as "not user input" from the start instead of
    /// depending on the order in which the releases and the detach happen to arrive.
    var onWillDetach: (() -> Void)? { get set }

    func start()
    func stop()
}

public extension ControllerInputSource {
    /// Monotonic clock, so gesture timing is unaffected by wall-clock changes.
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
