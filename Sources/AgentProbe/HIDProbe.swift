import Foundation
import IOKit
import IOKit.hid

/// Human-readable names for the HID usages this probe cares about.
enum HIDNames {
    static func genericDesktop(_ usage: UInt32) -> String {
        switch Int(usage) {
        case kHIDUsage_GD_Pointer: return "Pointer"
        case kHIDUsage_GD_Mouse: return "Mouse"
        case kHIDUsage_GD_Joystick: return "Joystick"
        case kHIDUsage_GD_GamePad: return "GamePad"
        case kHIDUsage_GD_Keyboard: return "Keyboard"
        case kHIDUsage_GD_Keypad: return "Keypad"
        case kHIDUsage_GD_MultiAxisController: return "MultiAxis"
        case kHIDUsage_GD_X: return "X"
        case kHIDUsage_GD_Y: return "Y"
        case kHIDUsage_GD_Z: return "Z"
        case kHIDUsage_GD_Rx: return "Rx"
        case kHIDUsage_GD_Ry: return "Ry"
        case kHIDUsage_GD_Rz: return "Rz"
        case kHIDUsage_GD_Slider: return "Slider"
        case kHIDUsage_GD_Dial: return "Dial"
        case kHIDUsage_GD_Wheel: return "Wheel"
        case kHIDUsage_GD_Hatswitch: return "HatSwitch"
        default: return "GD(0x\(String(usage, radix: 16)))"
        }
    }

    /// USB HID Usage ID (keyboard page 0x07) → readable key name.
    /// In H mode the L1162 reports as a plain keyboard, so this table is what turns
    /// raw usages into "which physical button sends which keys".
    static func keyboard(_ usage: UInt32) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        switch Int(usage) {
        case 0x04...0x1D: return String(letters[Int(usage) - 0x04])
        case 0x1E...0x26: return "\(Int(usage) - 0x1D)"
        case 0x27: return "0"
        case 0x28: return "Enter"
        case 0x29: return "Escape"
        case 0x2A: return "Backspace"
        case 0x2B: return "Tab"
        case 0x2C: return "Space"
        case 0x2D: return "Minus"
        case 0x2E: return "Equal"
        case 0x2F: return "LeftBracket"
        case 0x30: return "RightBracket"
        case 0x31: return "Backslash"
        case 0x33: return "Semicolon"
        case 0x34: return "Quote"
        case 0x35: return "Grave"
        case 0x36: return "Comma"
        case 0x37: return "Period"
        case 0x38: return "Slash"
        case 0x39: return "CapsLock"
        case 0x3A...0x45: return "F\(Int(usage) - 0x39)"
        case 0x46: return "PrintScreen"
        case 0x47: return "ScrollLock"
        case 0x48: return "Pause"
        case 0x49: return "Insert"
        case 0x4A: return "Home"
        case 0x4B: return "PageUp"
        case 0x4C: return "DeleteForward"
        case 0x4D: return "End"
        case 0x4E: return "PageDown"
        case 0x4F: return "ArrowRight"
        case 0x50: return "ArrowLeft"
        case 0x51: return "ArrowDown"
        case 0x52: return "ArrowUp"
        case 0x53: return "NumLock"
        case 0x54: return "KeypadSlash"
        case 0x55: return "KeypadStar"
        case 0x56: return "KeypadMinus"
        case 0x57: return "KeypadPlus"
        case 0x58: return "KeypadEnter"
        case 0x59...0x61: return "Keypad\(Int(usage) - 0x58)"
        case 0x62: return "Keypad0"
        case 0x63: return "KeypadPeriod"
        case 0x65: return "Application"
        case 0xE0: return "LeftControl"
        case 0xE1: return "LeftShift"
        case 0xE2: return "LeftAlt"
        case 0xE3: return "LeftGUI"
        case 0xE4: return "RightControl"
        case 0xE5: return "RightShift"
        case 0xE6: return "RightAlt"
        case 0xE7: return "RightGUI"
        default: return "Key(0x\(String(usage, radix: 16)))"
        }
    }

    static func name(page: UInt32, usage: UInt32) -> String {
        switch Int(page) {
        case kHIDPage_GenericDesktop: return genericDesktop(usage)
        case kHIDPage_Button: return "Button \(usage)"
        case kHIDPage_KeyboardOrKeypad: return keyboard(usage)
        case kHIDPage_Consumer: return "Consumer(0x\(String(usage, radix: 16)))"
        default: return "page=0x\(String(page, radix: 16)) usage=0x\(String(usage, radix: 16))"
        }
    }
}

/// Phase 0 fallback path: raw IOHIDManager enumeration and input reporting.
///
/// `listAllDevices()` never seizes or opens a device for input — it only reads
/// device properties, so it is safe to run while typing. `watch()` registers
/// input callbacks for gamepad-ish devices only, unless keyboards are requested.
final class HIDProbe {
    private let log = EventLog.shared
    private var managers: [IOHIDManager] = []

    // MARK: - Identity enumeration

    func listAllDevices() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        log.log("HID-LIST", "IOHIDManagerOpen(all devices) IOReturn=\(describe(openResult))")

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            log.log("HID-LIST", "IOHIDManagerCopyDevices returned nothing")
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return
        }

        log.log("HID-LIST", "HID device count=\(devices.count)")
        for device in devices.sorted(by: { describe($0) < describe($1) }) {
            log.log("HID-DEVICE", describe(device))
        }

        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func describe(_ device: IOHIDDevice) -> String {
        let vendor = prop(device, kIOHIDVendorIDKey)
        let product = prop(device, kIOHIDProductIDKey)
        let primaryPage = prop(device, kIOHIDPrimaryUsagePageKey)
        let primaryUsage = prop(device, kIOHIDPrimaryUsageKey)
        let pair = "\(primaryPage)/\(primaryUsage)"
        return """
        product="\(prop(device, kIOHIDProductKey))" \
        manufacturer="\(prop(device, kIOHIDManufacturerKey))" \
        vid=\(vendor) pid=\(product) \
        transport=\(prop(device, kIOHIDTransportKey)) \
        primaryUsagePage/Usage=\(pair) \
        serial=\(prop(device, kIOHIDSerialNumberKey)) \
        location=\(prop(device, kIOHIDLocationIDKey)) \
        version=\(prop(device, kIOHIDVersionNumberKey))
        """
    }

    private func prop(_ device: IOHIDDevice, _ key: String) -> String {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return "-" }
        return "\(value)"
    }

    // MARK: - Live input

    func watch(includeKeyboard: Bool) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        var matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
        ]
        if includeKeyboard {
            matches.append([
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
            ])
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        log.log("HID", "watching usages: gamepad/joystick/multi-axis\(includeKeyboard ? " + keyboard" : "")")

        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let probe = Unmanaged<HIDProbe>.fromOpaque(context).takeUnretainedValue()
            probe.log.log("HID-MATCH", probe.describe(device))
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let probe = Unmanaged<HIDProbe>.fromOpaque(context).takeUnretainedValue()
            let identity = probe.prop(device, kIOHIDProductKey)
            // Without this the held set keeps stale buttons from the previous connection:
            // the controller disconnects without sending a release for whatever was held.
            let previous = probe.held.clear()
            probe.log.log("HID-REMOVE", """
            product="\(identity)" cleared held state: \(previous) (reconnect will fire a new MATCH)
            """)
        }, context)

        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard let context, result == kIOReturnSuccess else { return }
            let probe = Unmanaged<HIDProbe>.fromOpaque(context).takeUnretainedValue()
            probe.report(value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        log.log("HID", "IOHIDManagerOpen IOReturn=\(describe(openResult))")
        if openResult != kIOReturnSuccess {
            log.log("HID", "open failed — likely missing Input Monitoring permission for this binary")
        }
        managers.append(manager)
    }

    private func report(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)
        let device = IOHIDElementGetDevice(element)
        let product = prop(device, kIOHIDProductKey)

        let pressed = intValue != 0
        let label = "\(HIDNames.name(page: page, usage: usage))@\(IOHIDElementGetCookie(element))"
        let heldNow = held.set(label, pressed: pressed)

        log.log("HID-VALUE", """
        product="\(product)" \(HIDNames.name(page: page, usage: usage)) \
        page=0x\(String(page, radix: 16)) usage=0x\(String(usage, radix: 16)) \
        cookie=\(IOHIDElementGetCookie(element)) \
        value=\(intValue) logical=[\(IOHIDElementGetLogicalMin(element)),\(IOHIDElementGetLogicalMax(element))] \
        | held: \(heldNow)\(held.count >= 2 ? "   <== CHORD" : "")
        """)
    }

    private func describe(_ result: IOReturn) -> String {
        if result == kIOReturnSuccess { return "success" }
        return "0x\(String(UInt32(bitPattern: result), radix: 16))"
    }

    private let held = HeldState()
}
