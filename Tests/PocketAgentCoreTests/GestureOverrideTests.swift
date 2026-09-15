import XCTest
@testable import PocketAgentCore

/// Per-gesture keystroke overrides: the mechanism that lets a gesture send a key with no semantic
/// action at all, so the reachable command set is the whole shortcut list rather than the handful of
/// actions we happen to model.
final class GestureOverrideTests: XCTestCase {
    private let clearUnreads = KeyStroke(.escape, modifiers: [.shift])
    private let optionShift = KeyStroke(modifiers: [.option, .shift])

    private func tap(_ stroke: KeyStroke) -> GestureOverride { GestureOverride(stroke: stroke) }
    private func held(_ stroke: KeyStroke) -> GestureOverride {
        GestureOverride(stroke: stroke, isHeld: true)
    }

    // MARK: - Key bindings are taps

    func testKeyOverrideReplacesTheSemanticBinding() {
        let resolver = EventResolver(gestureOverrides: ["b.a": tap(clearUnreads)])
        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chord(modifier: .b, key: .a))),
            [.raw(clearUnreads, .press)]
        )
    }

    func testKeyOverrideIgnoresTheChordRelease() {
        let resolver = EventResolver(gestureOverrides: ["b.a": tap(clearUnreads)])
        XCTAssertEqual(resolver.triggers(for: .gesture(.chordReleased(modifier: .b, key: .a))), [])
    }

    func testBaseDirectionOverrideKeepsDownUpSemantics() {
        let resolver = EventResolver(gestureOverrides: ["up": tap(KeyStroke(.b, modifiers: [.command]))])
        let stroke = KeyStroke(.b, modifiers: [.command])
        XCTAssertEqual(resolver.triggers(for: .keyDown(.up)), [.raw(stroke, .down)])
        XCTAssertEqual(resolver.triggers(for: .keyUp(.up)), [.raw(stroke, .up)])
    }

    // MARK: - Modifier-only bindings

    /// The motivating case: Doubao's voice input is triggered by *clicking* left Option + left
    /// Shift — a tap, not a hold. Getting this backwards makes the feature do nothing.
    func testModifierOnlyOverrideIsATapByDefault() {
        let resolver = EventResolver(gestureOverrides: ["b.a": tap(optionShift)])

        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chord(modifier: .b, key: .a))),
            [.raw(optionShift, .press)]
        )
        XCTAssertEqual(resolver.triggers(for: .gesture(.chordReleased(modifier: .b, key: .a))), [])
    }

    /// The other variant Doubao offers: 长按右option.
    func testModifierOnlyCanOptIntoBeingHeld() {
        let resolver = EventResolver(gestureOverrides: ["b.a": held(optionShift)])

        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chord(modifier: .b, key: .a))),
            [.raw(optionShift, .down)]
        )
        XCTAssertEqual(
            resolver.triggers(for: .gesture(.chordReleased(modifier: .b, key: .a))),
            [.raw(optionShift, .up)]
        )
    }

    func testHeldIsIgnoredForStrokesThatHaveAKey() {
        // A held ⌘B would mean holding Command+B down, which is never what anyone means.
        let override = held(KeyStroke(.b, modifiers: [.command]))
        XCTAssertFalse(override.holdsModifiersOnly)

        let resolver = EventResolver(gestureOverrides: ["b.a": override])
        XCTAssertEqual(resolver.triggers(for: .gesture(.chord(modifier: .b, key: .a))), [.raw(KeyStroke(.b, modifiers: [.command]), .press)])
        XCTAssertEqual(resolver.triggers(for: .gesture(.chordReleased(modifier: .b, key: .a))), [])
    }

    func testModifierOnlyStrokeKnowsItHasNoKey() {
        XCTAssertTrue(optionShift.isModifiersOnly)
        XCTAssertFalse(KeyStroke(.a).isModifiersOnly)
        XCTAssertEqual(optionShift.description, "option+shift (held)")
    }

    // MARK: - Scoping

    func testTapAndHoldHaveSeparateIdentifiers() {
        let resolver = EventResolver(gestureOverrides: ["b.tap": tap(clearUnreads)])
        XCTAssertEqual(resolver.triggers(for: .gesture(.tap(.b))), [.raw(clearUnreads, .press)])
        // hold is not overridden, so it keeps its semantic meaning
        XCTAssertEqual(resolver.triggers(for: .gesture(.hold(.b))), [.press(.cancelOrInterrupt)])
    }

    func testUnrelatedGesturesAreUnaffected() {
        let resolver = EventResolver(gestureOverrides: ["b.a": tap(clearUnreads)])
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
        // Start and end of a held binding share one identifier.
        XCTAssertEqual(GestureID.of(.gesture(.chordReleased(modifier: .b, key: .left))), "b.left")
    }

    func testEveryDefaultGestureHasAnIdentifier() {
        let ids = Set(GestureID.all)
        XCTAssertTrue(ids.contains("up"))
        XCTAssertTrue(ids.contains("b.tap"))
        XCTAssertTrue(ids.contains("b.hold"))
        XCTAssertTrue(ids.contains("b.a"))
        XCTAssertFalse(ids.contains("a.left"), "a is not a modifier, so a.left must not exist")
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

    func testModifierOnlyBindingWithoutHoldDefaultsToATap() throws {
        let json = """
        {
          "gestureKeyOverrides" : {
            "b.a" : { "modifiers" : [ "option", "shift" ] },
            "not.a.real.gesture" : { "key" : "z" }
          }
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.gestureOverrides.count, 1, "unknown gesture ids must be dropped")
        let override = try XCTUnwrap(config.gestureOverrides["b.a"])
        XCTAssertEqual(override.stroke, KeyStroke(modifiers: [.option, .shift]))
        XCTAssertFalse(override.isHeld, "a bare modifier binding must be a tap by default")
        XCTAssertEqual(config.unknownGestureIDs, ["not.a.real.gesture"])
    }

    func testHoldFlagIsParsed() throws {
        let json = """
        { "gestureKeyOverrides" : { "b.a" : { "modifiers" : [ "option" ], "hold" : true } } }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.gestureOverrides["b.a"]?.isHeld ?? false)
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
            $0.gestureKeyOverrides = ["b.a": AppConfig.KeyBinding(modifiers: [.option, .shift])]
        }

        let reloaded = ConfigStore(url: url)
        reloaded.load()
        XCTAssertNil(reloaded.loadWarning)
        XCTAssertEqual(reloaded.config.gestureOverrides["b.a"]?.stroke, KeyStroke(modifiers: [.option, .shift]))
    }
}
