import Foundation
import GameController

/// Input source for the XInput variant, via Apple's GameController framework.
///
/// Three Phase 0 findings are encoded here and must not be "simplified" away:
///
/// 1. `GCController.shouldMonitorBackgroundEvents` defaults to **NO** since macOS 11.3, and while it
///    is NO a non-frontmost app receives nothing at all. A menu-bar utility is never frontmost, so
///    without this line the whole path is silently dead (Phase 0 §6.5).
/// 2. `GCController.controllers()` is empty for the first ~100 ms after launch even with a paired
///    controller, so attachment is driven by `GCControllerDidConnect`, never by a startup query
///    (Phase 0 §6.7).
/// 3. `extendedGamepad` and `microGamepad` are the **same object** on this device and share their
///    elements, so binding both silently overwrites the first set of handlers (Phase 0 §6.6). This
///    source therefore binds through `physicalInputProfile.elements` exactly once.
///
/// Axes are deliberately not bound at all: the six real inputs are all digital buttons, and axis
/// reports at connect time (centre values sitting on the 0.5 boundary) would otherwise be mistaken
/// for presses (Phase 0 §6.7).
public final class GameControllerInputSource: ControllerInputSource {
    public let transport: ControllerTransport = .gameController

    public var onEvent: ((InputEvent) -> Void)?
    public var onAttach: ((String) -> Void)?
    public var onDetach: ((String) -> Void)?
    /// Diagnostic sink; the menu bar's debug monitor is expected to surface these.
    public var onDiagnostic: ((String) -> Void)?

    /// Element keys verified against the hardware in Phase 0 §6.6.
    private static let bindings: [(key: String, button: PhysicalButton)] = [
        ("Direction Pad Up", .up),
        ("Direction Pad Down", .down),
        ("Direction Pad Left", .left),
        ("Direction Pad Right", .right),
        ("Button A", .a),
        ("Button B", .b),
    ]

    private var controller: GCController?
    private var observers: [NSObjectProtocol] = []
    private var running = false

    public init() {}

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true

        GCController.shouldMonitorBackgroundEvents = true
        onDiagnostic?("shouldMonitorBackgroundEvents=\(GCController.shouldMonitorBackgroundEvents)")

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSNotification.Name.GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.attach(controller)
        })
        observers.append(center.addObserver(
            forName: NSNotification.Name.GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.detach(controller)
        })

        for controller in GCController.controllers() {
            attach(controller)
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        controller = nil
    }

    // MARK: - Attachment

    private func attach(_ controller: GCController) {
        guard running, self.controller == nil else { return }
        self.controller = controller

        let name = controller.vendorName ?? "unknown controller"
        let profile = controller.physicalInputProfile

        var bound = 0
        for (key, button) in Self.bindings {
            guard let element = profile.elements[key] as? GCControllerButtonInput else {
                onDiagnostic?("missing element \"\(key)\" — this control will not work")
                continue
            }
            element.pressedChangedHandler = { [weak self] _, _, pressed in
                guard let self else { return }
                self.emit(button, pressed: pressed)
            }
            bound += 1
        }

        onDiagnostic?("attached \(name) [\(controller.productCategory)] elements=\(profile.elements.count) bound=\(bound)")
        onAttach?(name)
    }

    private func detach(_ controller: GCController) {
        guard self.controller === controller else { return }
        self.controller = nil
        let name = controller.vendorName ?? "unknown controller"
        onDiagnostic?("detached \(name)")
        onDetach?(name)
    }

    private func emit(_ button: PhysicalButton, pressed: Bool) {
        let timestamp = now
        onEvent?(pressed ? .pressed(button, timestamp: timestamp) : .released(button, timestamp: timestamp))
    }
}
