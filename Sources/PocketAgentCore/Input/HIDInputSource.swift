import Foundation
import IOKit
import IOKit.hid

/// Input source for the generic C variant (`Wireless Controller`), which GameController cannot see
/// at all (Phase 0 §6.8).
///
/// The rules encoded here come straight from the probe findings:
/// - Devices are matched by **product name**, never by VID/PID alone and never by `location`:
///   the generic variant shares `0x4353`/`0x9b09` with the H-mode keyboard, and `location` changes
///   across reconnects (Phase 0 §2, §6.7).
/// - H mode (keyboard/mouse) is not matched at all. It leaks every input into the frontmost app and
///   is out of scope (Phase 0 §5.4).
/// - Cookies and logical ranges are read per device, never hardcoded: the two variants disagree on
///   both (Phase 0 §6.8).
/// - Values outside the element's declared logical range are discarded, and elements with an
///   invalid usage are ignored outright — H mode produced a packed `21036` on a logical `[0,255]`
///   element (Phase 0 §5.3).
public final class HIDInputSource: ControllerInputSource {
    public let transport: ControllerTransport = .rawHID

    public var onEvent: ((InputEvent) -> Void)?
    public var onAttach: ((String) -> Void)?
    public var onDetach: ((String) -> Void)?
    public var onDiagnostic: ((String) -> Void)?

    public struct Configuration: Sendable {
        /// Products this source is responsible for. The XInput product is deliberately absent: it
        /// is handled by `GameControllerInputSource`, and listening to both would double every event.
        public var handledProducts: Set<String>
        /// Optional escape hatch if GameController ever fails to attach to the XInput variant.
        public var includeGameControllerClaimedProduct: Bool

        public init(
            handledProducts: Set<String> = [HIDMapping.hidOnlyProduct],
            includeGameControllerClaimedProduct: Bool = false
        ) {
            self.handledProducts = handledProducts
            self.includeGameControllerClaimedProduct = includeGameControllerClaimedProduct
        }
    }

    private let configuration: Configuration
    private var manager: IOHIDManager?
    private var attachedProduct: String?
    private var pressedButtons: Set<PhysicalButton> = []
    private var heldDirection: PhysicalButton?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    private var effectiveProducts: Set<String> {
        var products = configuration.handledProducts
        if configuration.includeGameControllerClaimedProduct {
            products.insert(HIDMapping.gameControllerClaimedProduct)
        }
        return products
    }

    // MARK: - Lifecycle

    public func start() {
        guard manager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [[
            kIOHIDDeviceUsagePageKey: HIDMapping.genericDesktopPage,
            kIOHIDDeviceUsageKey: HIDMapping.gamePadUsage,
        ]]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDInputSource>.fromOpaque(context).takeUnretainedValue().deviceArrived(device)
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDInputSource>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, context)

        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<HIDInputSource>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            onDiagnostic?("IOHIDManagerOpen failed (0x\(String(UInt32(bitPattern: openResult), radix: 16))) — Input Monitoring permission may be missing")
        }
        self.manager = manager
    }

    public func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        attachedProduct = nil
        pressedButtons.removeAll()
        heldDirection = nil
    }

    // MARK: - Device callbacks

    private func deviceArrived(_ device: IOHIDDevice) {
        let product = stringProperty(device, kIOHIDProductKey)
        guard effectiveProducts.contains(product) else {
            // Usually the XInput variant, which GameControllerInputSource owns — not an error, and
            // saying "unsupported" here would be misleading during a debug session.
            onDiagnostic?("skipping gamepad \"\(product)\" (handled by another source)")
            return
        }
        attachedProduct = product
        onDiagnostic?("attached \(product) (raw HID)")
        onAttach?(product)
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        let product = stringProperty(device, kIOHIDProductKey)
        guard product == attachedProduct else { return }
        attachedProduct = nil
        // The device disappears without releasing whatever was held, so release it here or the
        // target app keeps the key down forever (Phase 0 §6.8, spec §17).
        releaseEverything()
        onDiagnostic?("detached \(product) (raw HID)")
        onDetach?(product)
    }

    private func releaseEverything() {
        let timestamp = now
        for button in pressedButtons {
            onEvent?(.released(button, timestamp: timestamp))
        }
        pressedButtons.removeAll()
        if let direction = heldDirection {
            heldDirection = nil
            onEvent?(.released(direction, timestamp: timestamp))
        }
    }

    // MARK: - Input

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard let attachedProduct, stringProperty(device, kIOHIDProductKey) == attachedProduct else { return }

        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let raw = IOHIDValueGetIntegerValue(value)
        let logicalMin = Int(IOHIDElementGetLogicalMin(element))
        let logicalMax = Int(IOHIDElementGetLogicalMax(element))

        // Elements with an invalid usage (0xFFFFFFFF) are vendor noise, not input.
        guard page != 0xFFFF_FFFF, usage != 0xFFFF_FFFF else { return }

        if page == HIDMapping.buttonPage, let button = HIDMapping.button(forButtonUsage: usage) {
            guard HIDMapping.isValueInRange(raw, logicalMin: logicalMin, logicalMax: logicalMax) else { return }
            let pressed = raw != 0
            guard pressed != pressedButtons.contains(button) else { return }
            if pressed { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
            let timestamp = now
            onEvent?(pressed ? .pressed(button, timestamp: timestamp) : .released(button, timestamp: timestamp))
            return
        }

        if page == HIDMapping.genericDesktopPage, usage == HIDMapping.hatSwitchUsage {
            handleHat(raw, logicalMin: logicalMin, logicalMax: logicalMax)
        }
    }

    /// The hat reports one direction at a time, with any value outside the declared range meaning
    /// centred. One implementation therefore covers both variants, whose ranges and null values
    /// differ (Phase 0 §6.3, §6.8).
    private func handleHat(_ value: Int, logicalMin: Int, logicalMax: Int) {
        let direction = HIDMapping.direction(forHatValue: value, logicalMin: logicalMin, logicalMax: logicalMax)
        guard direction != heldDirection else { return }

        let timestamp = now
        if let previous = heldDirection {
            heldDirection = nil
            onEvent?(.released(previous, timestamp: timestamp))
        }
        if let direction {
            heldDirection = direction
            onEvent?(.pressed(direction, timestamp: timestamp))
        }
    }

    private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String {
        (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? ""
    }
}
