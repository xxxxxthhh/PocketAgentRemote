import Foundation

/// Runs both input paths and presents them as one controller.
///
/// Routing rule, taken from Phase 0: the XInput variant (`Xbox Wireless Controller`) is handled by
/// GameController and the generic variant (`Wireless Controller`) by raw HID. They are distinct
/// products, so exactly one source owns whichever device is currently connected — no de-duplication
/// heuristics are needed.
///
/// The user never has to care which variant their controller is in: spec §4 requires both to work,
/// because switching variants is a fiddly, timing-sensitive hardware gesture (Phase 0 §6.8).
public final class ControllerInputCoordinator {
    public var onEvent: ((InputEvent) -> Void)?
    /// A supported controller became usable. Carries the device name.
    public var onAttach: ((String) -> Void)?
    /// The controller went away. **The host must reset gesture state** — see spec §18.
    public var onDetach: ((String) -> Void)?
    public var onDiagnostic: ((String) -> Void)?

    private let sources: [ControllerInputSource]

    /// True while a source is reporting a detach.
    ///
    /// An input event arriving in that window is cleanup from a device that is already gone, not
    /// something the user did, so it is dropped instead of becoming a gesture. The HID source no
    /// longer synthesises releases on detach, but this keeps the rule true for any source that does
    /// — the failure it prevents is a controller vanishing and switching applications by itself.
    private var isDetaching = false

    public init(
        gameController: ControllerInputSource = GameControllerInputSource(),
        hid: ControllerInputSource = HIDInputSource()
    ) {
        sources = [gameController, hid]
        for source in sources {
            source.onEvent = { [weak self] event in
                guard let self, !self.isDetaching else { return }
                self.onEvent?(event)
            }
            source.onWillDetach = { [weak self] in
                self?.isDetaching = true
            }
            source.onAttach = { [weak self] name in
                self?.onDiagnostic?("connected via \(source.transport.rawValue): \(name)")
                self?.onAttach?(name)
            }
            source.onDetach = { [weak self] name in
                guard let self else { return }
                self.isDetaching = true
                defer { self.isDetaching = false }
                self.onDiagnostic?("disconnected (\(source.transport.rawValue)): \(name)")
                self.onDetach?(name)
            }
            (source as? GameControllerInputSource)?.onDiagnostic = { [weak self] message in
                self?.onDiagnostic?(message)
            }
            (source as? HIDInputSource)?.onDiagnostic = { [weak self] message in
                self?.onDiagnostic?(message)
            }
        }
    }

    public func start() {
        for source in sources { source.start() }
    }

    public func stop() {
        for source in sources { source.stop() }
    }
}
