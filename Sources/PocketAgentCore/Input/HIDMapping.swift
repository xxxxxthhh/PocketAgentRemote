import Foundation

/// Pure decoding of the L1162's HID reports.
///
/// Everything here is derived from `docs/hardware-probe.md` §6.3 and §6.8, and deliberately
/// contains no IOKit types so it can be unit tested without hardware.
///
/// The two C-mode variants report the *same usages* but differ in cookie, logical range and null
/// value — which is why cookies are never used here (Phase 0 finding #8).
public enum HIDMapping {
    // Usage pages / usages that matter.
    public static let genericDesktopPage: UInt32 = 0x01
    public static let gamePadUsage: UInt32 = 0x05
    public static let buttonPage: UInt32 = 0x09
    public static let buttonAUsage: UInt32 = 0x01
    public static let buttonBUsage: UInt32 = 0x02
    public static let hatSwitchUsage: UInt32 = 0x39

    /// The pairing key. Exposed by the hardware (page 0x9, usage 0x0d) but deliberately unmapped:
    /// it switches the device variant, and on its own it powers the controller off.
    public static let pairingKeyUsage: UInt32 = 0x0d

    /// Product strings of the two C-mode variants. `Xbox Wireless Controller` is claimed by
    /// GameController; `Wireless Controller` is HID-only (Phase 0 §6.8).
    public static let gameControllerClaimedProduct = "Xbox Wireless Controller"
    public static let hidOnlyProduct = "Wireless Controller"

    /// Vendor/product IDs are *not* sufficient to identify the controller: the generic C variant
    /// and the H-mode keyboard share `0x4353`/`0x9b09` exactly (Phase 0 §2).
    public static let hidOnlyVendorID = 0x4353
    public static let hidOnlyProductID = 0x9b09

    /// Maps a Button-page usage to a logical button, or nil for anything we must ignore.
    public static func button(forButtonUsage usage: UInt32) -> PhysicalButton? {
        switch usage {
        case buttonAUsage: return .a
        case buttonBUsage: return .b
        default: return nil
        }
    }

    /// Decodes the hat switch into a direction.
    ///
    /// One rule covers both variants: **a value outside the declared logical range means
    /// centred**, and values inside it form an 8-position ring starting at `logicalMin`.
    ///
    /// | Variant | range | centred | Up | Right | Down | Left |
    /// |---|---|---|---|---|---|---|
    /// | XInput  | `[1,8]` | `0`  | 1 | 3 | 5 | 7 |
    /// | generic | `[0,7]` | `15` | 0 | 2 | 4 | 6 |
    ///
    /// Diagonals map to nil: this hardware never produced them, and guessing a direction for an
    /// input that has never been observed would be inventing behaviour.
    public static func direction(forHatValue value: Int, logicalMin: Int, logicalMax: Int) -> PhysicalButton? {
        guard logicalMax >= logicalMin else { return nil }
        guard value >= logicalMin, value <= logicalMax else { return nil }

        let span = logicalMax - logicalMin + 1
        let index = ((value - logicalMin) % span + span) % span

        switch index {
        case 0: return .up
        case 2: return .right
        case 4: return .down
        case 6: return .left
        default: return nil
        }
    }

    /// True when a raw element value is within its declared logical range. Values outside it have
    /// been observed (a packed `21036 = 82×256 + 44` on a vendor element in H mode), so they must
    /// never be treated as input (Phase 0 §5.3).
    public static func isValueInRange(_ value: Int, logicalMin: Int, logicalMax: Int) -> Bool {
        value >= logicalMin && value <= logicalMax
    }

    /// True when this device is one of the two C-mode variants we support.
    public static func isSupportedProduct(_ product: String) -> Bool {
        product == gameControllerClaimedProduct || product == hidOnlyProduct
    }
}
