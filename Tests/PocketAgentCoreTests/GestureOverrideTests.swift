import XCTest
@testable import PocketAgentCore

/// Per-gesture keystroke overrides: the mechanism that lets a gesture send a key with no semantic
/// action at all, so the reachable command set is the whole Codex shortcut list rather than the
/// handful of actions we happen to model.
final class GestureOverrideTests: XCTestCase {
    private let clearUnreads = KeyStroke(.escape, modifiers: [.shift])

    func testOverrideReplacesTheSemanticBinding() {
        let resolver = EventResolver(gestureOverrides: ["b.a": clearUnreads])
        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chord(modifier: .b, key: .a))),
            [.raw(clearUnreads, .press)]
        )
    }

    func testBaseDirectionOverrideKeepsDownUpSemantics() {
        let resolver = EventResolver(gestureOverrides: ["up": KeyStroke(.b, modifiers: [.command])])
        XCTAssertEqual(resolver.triggers(for: .keyDown(.up)), [.raw(KeyStroke(.b, modifiers: [.command]), .down)])
        XCTAssertEqual(resolver.triggers(for: .keyUp(.up)), [.raw(KeyStroke(.b, modifiers: [.command]), .up)])
    }

    func testTapAndHoldHaveSeparateIdentifiers() {
        let resolver = EventResolver(gestureOverrides: ["b.tap": clearUnreads])
        XCTAssertEqual(resolver.triggers(for: .gesture(.tap(.b))), [.raw(clearUnreads, .press)])
        // hold is not overridden, so it keeps its semantic meaning
        XCTAssertEqual(resolver.triggers(for: .gesture(.hold(.b))), [.press(.cancelOrInterrupt)])
    }

    func testModifierOnlyOverrideIsHeldForTheWholeChord() {
        // The motivating case: holding ⌥⇧ to trigger an input method's voice input. A bare tap of
        // ⌥⇧ with no key is invisible to almost everything, so it has to be held.
        let held = KeyStroke(modifiers: [.option, .shift])
        let resolver = EventResolver(gestureOverrides: ["b.a": held])

        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chord(modifier: .b, key: .a))),
            [.raw(held, .down)]
        )
        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chordReleased(modifier: .b, key: .a))),
            [.raw(held, .up)]
        )
    }

    func testKeyOverrideStaysATapAndIgnoresTheRelease() {
        let tap = KeyStroke(.b, modifiers: [.command])
        let resolver = EventResolver(gestureOverrides: ["b.a": tap])

        XCTAssertEqual(resolver.triggers(for: .gesture(.chord(modifier: .b, key: .a))), [.raw(tap, .press)])
        XCTAssertEqual(resolver.triggers(for: .gesture(.chordReleased(modifier: .b, key: .a))), [])
    }

    func testUnrelatedGesturesAreUnaffected() {
        let resolver = EventResolver(gestureOverrides: ["b.a": clearUnreads])
        XCTAssertEqual(resolver.triggers(for: .gesture(.chord(modifier: .b, key: .up))), [.press(.goToRecentChat1)])
        XCTAssertEqual(resolver.triggers(for: .keyDown(.left)), [.down(.navigateLeft)])
    }

    func testGestureIDNamingIsStable() {
        // These strings are configuration keys; renaming one silently breaks every user's config.
        XCTAssertEqual(GestureID.of(.keyDown(.up)), "up")
        XCTAssertEqual(GestureID.of(.keyUp(.a)), "a")
        XCTAssertEqual(GestureID.of(.gesture(.tap(.b))), "b.tap")
        XCTAssertEqual(GestureID.of(.gesture(.hold(.b))), "b.hold")
        XCTAssertEqual(GestureID.of(.gesture(.chord(modifier: .b, key: .left))), "b.left")
    }

    func testEveryDefaultGestureHasAnIdentifier() {
        let ids = Set(GestureID.all)
        XCTAssertTrue(ids.contains("up"))
        XCTAssertTrue(ids.contains("b.tap"))
        XCTAssertTrue(ids.contains("b.hold"))
        XCTAssertTrue(ids.contains("b.a"))
        XCTAssertTrue(ids.contains("a.left") == false, "a is not a modifier, so a.left must not exist")
    }
}

final class ConfigCompatibilityTests: XCTestCase {
    func testConfigWrittenByAnOlderBuildStillLoads() throws {
        // The exact shape written before gestureKeyOverrides existed. Missing keys must fall back to
        // defaults rather than failing the whole decode and silently resetting the user's settings.
        let legacy = """
        {
          "actionKeyOverrides" : { },
          "activeProfile" : "codex",
          "allowedBundleIDs" : [ "com.openai.codex" ],
          "holdMs" : 450,
          "macrosEnabled" : true,
          "requireAllowedFrontmostApp" : true,
          "tapMaxMs" : 220,
          "version" : 1
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(config.activeProfile, .codex)
        XCTAssertTrue(config.macrosEnabled)
        XCTAssertEqual(config.allowedBundleIDs, ["com.openai.codex"])
        XCTAssertTrue(config.gestureKeyOverrides.isEmpty)
    }

    func testGestureOverridesAreParsedAndValidated() throws {
        let json = """
        {
          "gestureKeyOverrides" : {
            "b.a" : { "key" : "escape", "modifiers" : [ "shift" ] },
            "not.a.real.gesture" : { "key" : "z" }
          }
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.gestureOverrides.count, 1, "unknown gesture ids must be dropped")
        XCTAssertEqual(config.gestureOverrides["b.a"], KeyStroke(.escape, modifiers: [.shift]))
        XCTAssertEqual(config.unknownGestureIDs, ["not.a.real.gesture"])
    }

    func testRoundTripThroughDiskKeepsGestureOverrides() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pocketagent-gesture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")

        let store = ConfigStore(url: url)
        store.load()
        store.update {
            $0.gestureKeyOverrides = ["b.a": AppConfig.KeyBinding(key: .escape, modifiers: [.shift])]
        }

        let reloaded = ConfigStore(url: url)
        reloaded.load()
        XCTAssertNil(reloaded.loadWarning)
        XCTAssertEqual(reloaded.config.gestureOverrides["b.a"], KeyStroke(.escape, modifiers: [.shift]))
    }
}
