import Foundation
import GameController

/// Phase 0 primary probe path: Apple's GameController framework.
///
/// Records the identity of every controller macOS exposes, dumps every element in
/// the physical input profile, and logs press/release/value changes together with
/// the currently held set (so chords are observable without post-processing).
final class GameControllerProbe {
    private let log = EventLog.shared
    private let held = HeldState()
    private var attached = Set<ObjectIdentifier>()

    func start(discover: Bool) {
        // Since macOS 11.3 this defaults to NO: a non-frontmost app receives no controller
        // events at all. A menu-bar utility is never frontmost, so this is mandatory.
        GCController.shouldMonitorBackgroundEvents = true
        log.log("GC", "shouldMonitorBackgroundEvents = \(GCController.shouldMonitorBackgroundEvents)")

        let center = NotificationCenter.default
        center.addObserver(
            forName: NSNotification.Name.GCControllerDidConnect,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            self.log.log("GC-CONNECT", "controller connected")
            if let controller = note.object as? GCController { self.attach(controller) }
        }
        center.addObserver(
            forName: NSNotification.Name.GCControllerDidDisconnect,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let previous = self.held.clear()
            self.log.log("GC-DISCONNECT", "controller disconnected | cleared held state: \(previous)")
            if let controller = note.object as? GCController {
                self.attached.remove(ObjectIdentifier(controller))
            }
        }

        let known = GCController.controllers()
        log.log("GC", "GCController.controllers() count=\(known.count)")
        if known.isEmpty {
            log.log("GC", "GameController framework currently sees no controller")
        }
        for controller in known { attach(controller) }

        if discover {
            log.log("GC", "startWirelessControllerDiscovery() …")
            GCController.startWirelessControllerDiscovery { [weak self] in
                self?.log.log("GC", "wireless discovery finished")
            }
        }
    }

    // MARK: - Attach

    private func attach(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard !attached.contains(id) else { return }
        attached.insert(id)

        log.log("GC-DEVICE", """
        vendorName=\(controller.vendorName ?? "<nil>") \
        productCategory=\(controller.productCategory) \
        attachedToDevice=\(controller.isAttachedToDevice) \
        playerIndex=\(controller.playerIndex.rawValue)
        """)

        dumpElements(of: controller)
        dumpProfileIdentity(of: controller)
        bindExtendedGamepad(of: controller)
        bindMicroGamepad(of: controller)
        bindSystemButtons(of: controller)
    }

    /// `extendedGamepad` and `microGamepad` may expose the *same* underlying element objects.
    /// Handler assignment overwrites, so knowing whether they are shared decides whether a
    /// binding must be installed once or twice.
    private func dumpProfileIdentity(of controller: GCController) {
        func addr(_ object: AnyObject?) -> String {
            guard let object else { return "nil" }
            return "0x" + String(UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque()), radix: 16)
        }

        let extended = controller.extendedGamepad
        let micro = controller.microGamepad
        let elements = controller.physicalInputProfile.elements

        log.log("GC-IDENTITY", """
        extendedGamepad=\(addr(extended)) microGamepad=\(addr(micro)) \
        ext.buttonA=\(addr(extended?.buttonA)) micro.buttonA=\(addr(micro?.buttonA)) \
        ext.buttonB=\(addr(extended?.buttonB)) \
        ext.dpad=\(addr(extended?.dpad)) micro.dpad=\(addr(micro?.dpad)) \
        ext.dpad.up=\(addr(extended?.dpad.up)) micro.dpad.up=\(addr(micro?.dpad.up)) \
        elements["Button A"]=\(addr(elements["Button A"])) \
        elements["Direction Pad Up"]=\(addr(elements["Direction Pad Up"]))
        """)
    }

    private func dumpElements(of controller: GCController) {
        let elements = controller.physicalInputProfile.elements
        log.log("GC-ELEMENTS", "physicalInputProfile.elements count=\(elements.count)")

        for key in elements.keys.sorted() {
            guard let element = elements[key] else { continue }

            var kind = "\(type(of: element))"
            var extra = ""
            if let button = element as? GCControllerButtonInput {
                kind = "button"
                extra = " analog=\(button.isAnalog) sfSymbol=\(button.sfSymbolsName ?? "-")"
            } else if element is GCControllerDirectionPad {
                kind = "dpad"
                extra = " analog=\(element.isAnalog)"
            } else if element is GCControllerAxisInput {
                kind = "axis"
                extra = " analog=\(element.isAnalog)"
            }

            log.log("GC-ELEMENT", """
            key="\(key)" kind=\(kind)\(extra) \
            localizedName=\(element.localizedName ?? "-") \
            boundToSystemGesture=\(element.isBoundToSystemGesture)
            """)

            // Generic coverage so elements without an explicit binding below are
            // still observable. Explicit bindings in bindExtendedGamepad() run
            // afterwards and overwrite these with stable names.
            bindGenerically(element, key: key)
        }
    }

    private func bindGenerically(_ element: GCControllerElement, key: String) {
        if let button = element as? GCControllerButtonInput {
            button.pressedChangedHandler = { [weak self] _, value, pressed in
                guard let self else { return }
                let heldNow = self.held.set(key, pressed: pressed)
                let chord = self.held.count >= 2 ? "   <== CHORD" : ""
                self.log.log("GC-BUTTON", """
                "\(key)" \(pressed ? "DOWN" : "up  ") value=\(String(format: "%.3f", value)) \
                | held: \(heldNow)\(chord)
                """)
            }
        } else if let axis = element as? GCControllerAxisInput {
            axis.valueChangedHandler = { [weak self] _, value in
                guard let self else { return }
                let heldNow = self.held.set(key, pressed: value > 0.5)
                self.log.log("GC-AXIS", """
                "\(key)" value=\(String(format: "%.3f", value)) | held: \(heldNow)\
                \(self.held.count >= 2 ? "   <== CHORD" : "")
                """)
            }
        } else if let dpad = element as? GCControllerDirectionPad {
            dpad.valueChangedHandler = { [weak self] _, x, y in
                self?.log.log("GC-DPAD", String(format: "\"%@\" x=%.3f y=%.3f", key, x, y))
            }
        }
    }

    /// Explicit bindings give the probe stable, human-meaningful names even when
    /// `physicalInputProfile.elements` keys differ between firmware modes.
    private func bindExtendedGamepad(of controller: GCController) {
        guard let pad = controller.extendedGamepad else {
            log.log("GC-PROFILE", "extendedGamepad = nil")
            return
        }
        log.log("GC-PROFILE", "extendedGamepad available (canonical bindings below)")

        bind(pad.buttonA, "A")
        bind(pad.buttonB, "B")
        bind(pad.buttonX, "X")
        bind(pad.buttonY, "Y")
        bind(pad.leftShoulder, "L1")
        bind(pad.rightShoulder, "R1")
        bind(pad.leftTrigger, "L2")
        bind(pad.rightTrigger, "R2")
        bind(pad.dpad.up, "Dpad.Up")
        bind(pad.dpad.down, "Dpad.Down")
        bind(pad.dpad.left, "Dpad.Left")
        bind(pad.dpad.right, "Dpad.Right")

        pad.dpad.valueChangedHandler = { [weak self] _, x, y in
            self?.log.log("GC-DPAD-AXIS", String(format: "x=%.3f y=%.3f", x, y))
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.log.log("GC-STICK-L", String(format: "x=%.3f y=%.3f", x, y))
        }
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.log.log("GC-STICK-R", String(format: "x=%.3f y=%.3f", x, y))
        }
    }

    /// `extendedGamepad` and `microGamepad` are the *same* object on this device, and their
    /// elements are shared, so installing handlers twice silently replaces the first set.
    /// Only fall back to the micro profile when there is no extended profile at all.
    private func bindMicroGamepad(of controller: GCController) {
        guard let pad = controller.microGamepad else { return }
        guard controller.extendedGamepad == nil else {
            log.log("GC-PROFILE", "microGamepad skipped: same object as extendedGamepad (handlers already bound)")
            return
        }
        log.log("GC-PROFILE", "microGamepad only (no extendedGamepad)")
        bind(pad.buttonA, "Micro.A")
        bind(pad.buttonX, "Micro.X")
        bind(pad.dpad.up, "Micro.Up")
        bind(pad.dpad.down, "Micro.Down")
        bind(pad.dpad.left, "Micro.Left")
        bind(pad.dpad.right, "Micro.Right")
    }

    private func bindSystemButtons(of controller: GCController) {
        let profile = controller.physicalInputProfile
        bind(profile.buttons[GCButtonElementName.menu.rawValue], "Menu")
        bind(profile.buttons[GCButtonElementName.options.rawValue], "Options")
        bind(profile.buttons[GCButtonElementName.home.rawValue], "Home")
    }

    private func bind(_ button: GCControllerButtonInput?, _ name: String) {
        guard let button else { return }
        button.pressedChangedHandler = { [weak self] _, value, pressed in
            guard let self else { return }
            let heldNow = self.held.set(name, pressed: pressed)
            let chord = self.held.count >= 2 ? "   <== CHORD" : ""
            self.log.log("GC-BUTTON", """
            \(name) \(pressed ? "DOWN" : "up  ") value=\(String(format: "%.3f", value)) \
            | held: \(heldNow)\(chord)
            """)
        }
    }
}
