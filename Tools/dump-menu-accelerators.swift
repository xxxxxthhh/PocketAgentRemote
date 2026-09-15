#!/usr/bin/env swift
//
// Dumps the *live* menu accelerators of a running application via the Accessibility API.
//
// Why this exists: the static command registry inside an app bundle is not always what the app
// actually binds at runtime. On 2026-09-16 `⌃⇧G` (from Codex's own registry) did nothing while the
// View menu clearly offered "Toggle Review Panel" — so the authoritative source is the live menu.
//
// Usage:  swift Tools/dump-menu-accelerators.swift [processName]
//         defaults to "ChatGPT"
//
// Requires the calling process to hold Accessibility permission.

import AppKit
import ApplicationServices
import Foundation

let targetName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ChatGPT"

guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == targetName }) else {
    FileHandle.standardError.write(Data("no running application named \(targetName)\n".utf8))
    exit(1)
}

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("Accessibility permission is required\n".utf8))
    exit(2)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func int(_ element: AXUIElement, _ name: String) -> Int? {
    (attribute(element, name) as? NSNumber)?.intValue
}

/// Decodes `AXMenuItemCmdModifiers` into a readable prefix.
///
/// Documented encoding: 0 means Command; bit 0 Shift, bit 1 Option, bit 2 Control,
/// bit 3 set means "no Command modifier at all".
func modifierPrefix(_ mask: Int?) -> String {
    guard let mask else { return "" }
    var parts: [String] = []
    if mask & 8 == 0 { parts.append("cmd") }
    if mask & 1 != 0 { parts.append("shift") }
    if mask & 2 != 0 { parts.append("option") }
    if mask & 4 != 0 { parts.append("control") }
    return parts.isEmpty ? "" : parts.joined(separator: "+") + "+"
}

/// Some shortcuts are drawn as glyphs (arrows, return, tab…) rather than characters.
func glyphName(_ glyph: Int?) -> String? {
    switch glyph {
    case 0x02: return "left"
    case 0x03: return "right"
    case 0x04: return "up"
    case 0x05: return "down"
    case 0x09: return "tab"
    case 0x0A: return "tab"          // ISO_Left_Tab
    case 0x0D: return "return"
    case 0x10: return "pageup"
    case 0x16: return "pagedown"
    case 0x17: return "escape"
    case 0x19: return "backtab"
    case 0x1B: return "escape"
    case 0x2B: return "comma"
    case 0x60: return "grave"
    default: return nil
    }
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)

guard let menuBar = attribute(appElement, kAXMenuBarAttribute as String) else {
    FileHandle.standardError.write(Data("could not read the menu bar\n".utf8))
    exit(3)
}

var lineCount = 0

func walk(_ element: AXUIElement, path: [String]) {
    for child in children(element) {
        let title = string(child, kAXTitleAttribute as String) ?? ""
        // A submenu is a child that itself has a menu child; recurse into it.
        let submenus = children(child).filter { string($0, kAXRoleAttribute as String) == kAXMenuRole as String }
        if let submenu = submenus.first {
            walk(submenu, path: path + [title])
            continue
        }

        guard string(child, kAXRoleAttribute as String) == kAXMenuItemRole as String else { continue }
        let enabled = (attribute(child, kAXEnabledAttribute as String) as? NSNumber)?.boolValue ?? false
        let key = string(child, kAXMenuItemCmdCharAttribute as String) ?? ""
        let glyph = int(child, kAXMenuItemCmdGlyphAttribute as String)
        let modifiers = int(child, kAXMenuItemCmdModifiersAttribute as String)

        var shortcut = ""
        if !key.isEmpty, key != "\u{0}" {
            shortcut = modifierPrefix(modifiers) + key.lowercased()
        } else if let glyphName = glyphName(glyph) {
            shortcut = modifierPrefix(modifiers) + glyphName
        }

        guard !shortcut.isEmpty else { continue }
        let menuPath = (path + [title]).joined(separator: " > ")
        let flag = enabled ? "on " : "OFF"
        print("  [\(flag)] \(menuPath.padding(toLength: 46, withPad: " ", startingAt: 0)) \(shortcut)")
        lineCount += 1
    }
}

print("live accelerators for \(targetName):")
walk(menuBar as! AXUIElement, path: [])
print("\n\(lineCount) shortcuts found")
