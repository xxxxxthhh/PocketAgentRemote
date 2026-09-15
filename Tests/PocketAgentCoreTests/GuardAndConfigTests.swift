import XCTest
@testable import PocketAgentCore

final class GuardTests: XCTestCase {
    private let codexBundle = "com.openai.codex"
    private let policy = GuardPolicy(allowedBundleIDs: ["com.openai.codex", "com.apple.Terminal"])

    private var toolRecipe: OutputRecipe { Recipe.tool(.n, [.command]) }
    private var navigationRecipe: OutputRecipe { Recipe.held(.upArrow) }

    func testToolActionIsAllowedWhenProfileAndAppMatchInsideAllowlist() {
        let guardrail = ActionGuard(policy: policy)
        XCTAssertEqual(
            guardrail.evaluate(recipe: toolRecipe, profile: .codex, frontmostBundleID: codexBundle),
            .allow
        )
    }

    func testToolActionIsDeniedFromTheGenericProfile() {
        let guardrail = ActionGuard(policy: policy)
        let decision = guardrail.evaluate(recipe: toolRecipe, profile: .genericTerminal, frontmostBundleID: codexBundle)
        XCTAssertFalse(decision.isAllowed)
        if case .deny(let reason) = decision {
            XCTAssertTrue(reason.contains("explicit profile"))
        }
    }

    func testToolActionIsDeniedWhenFrontmostAppIsNotAllowed() {
        let guardrail = ActionGuard(policy: policy)
        let decision = guardrail.evaluate(recipe: toolRecipe, profile: .codex, frontmostBundleID: "com.apple.mail")
        XCTAssertFalse(decision.isAllowed)
        if case .deny(let reason) = decision {
            XCTAssertTrue(reason.contains("allowlist"))
        }
    }

    func testNavigationFollowsTheSameAllowlistRule() {
        let guardrail = ActionGuard(policy: policy)
        XCTAssertEqual(
            guardrail.evaluate(recipe: navigationRecipe, profile: .genericTerminal, frontmostBundleID: "com.apple.Terminal"),
            .allow
        )
        XCTAssertFalse(
            guardrail.evaluate(recipe: navigationRecipe, profile: .genericTerminal, frontmostBundleID: "com.apple.mail").isAllowed
        )
    }

    func testUnknownFrontmostAppIsDeniedRatherThanAssumedSafe() {
        let guardrail = ActionGuard(policy: policy)
        let decision = guardrail.evaluate(recipe: toolRecipe, profile: .codex, frontmostBundleID: nil)
        XCTAssertFalse(decision.isAllowed, "an unreadable frontmost app must fail closed")
    }

    func testAllowlistCanBeTurnedOffEntirely() {
        let permissive = GuardPolicy(
            allowedBundleIDs: [],
            requireAllowedFrontmostApp: false,
            macrosEnabled: false
        )
        let guardrail = ActionGuard(policy: permissive)
        XCTAssertEqual(
            guardrail.evaluate(recipe: toolRecipe, profile: .codex, frontmostBundleID: "com.apple.mail"),
            .allow
        )
        // …but the explicit-profile rule still holds.
        XCTAssertFalse(
            guardrail.evaluate(recipe: toolRecipe, profile: .genericTerminal, frontmostBundleID: nil).isAllowed
        )
    }

    func testMacrosAreGatedSeparately() {
        let macro = OutputRecipe(steps: [.text("/diff")], risk: .macro, requiresExplicitProfile: true)
        let off = ActionGuard(policy: GuardPolicy(allowedBundleIDs: [codexBundle], macrosEnabled: false))
        XCTAssertFalse(off.evaluate(recipe: macro, profile: .codex, frontmostBundleID: codexBundle).isAllowed)

        let on = ActionGuard(policy: GuardPolicy(allowedBundleIDs: [codexBundle], macrosEnabled: true))
        XCTAssertEqual(on.evaluate(recipe: macro, profile: .codex, frontmostBundleID: codexBundle), .allow)
    }
}

final class ConfigTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pocketagent-config-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func storeURL() -> URL { directory.appendingPathComponent("config.json") }

    func testDefaultsAreSafe() {
        let config = AppConfig()
        XCTAssertEqual(config.activeProfile, .genericTerminal, "must not start in a tool profile")
        XCTAssertFalse(config.macrosEnabled, "macros off by default")
        XCTAssertTrue(config.requireAllowedFrontmostApp)
        XCTAssertTrue(config.allowedBundleIDs.contains("com.openai.codex"))
        XCTAssertTrue(config.allowedBundleIDs.contains("com.anthropic.claudefordesktop"))
        XCTAssertEqual(config.tapMaxMs, 220)
        XCTAssertEqual(config.holdMs, 450)
    }

    func testFirstLoadWritesDefaultsSoTheFileCanBeEdited() {
        let store = ConfigStore(url: storeURL())
        store.load()
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL().path))
    }

    func testRoundTrip() throws {
        let store = ConfigStore(url: storeURL())
        store.load()
        store.update {
            $0.activeProfile = .codex
            $0.macrosEnabled = true
            $0.allowedBundleIDs = ["com.openai.codex"]
            $0.actionKeyOverrides = ["toggleFastMode": AppConfig.KeyBinding(key: .f, modifiers: [.control, .option])]
        }

        let reloaded = ConfigStore(url: storeURL())
        reloaded.load()
        XCTAssertEqual(reloaded.config.activeProfile, .codex)
        XCTAssertTrue(reloaded.config.macrosEnabled)
        XCTAssertEqual(reloaded.config.allowedBundleIDs, ["com.openai.codex"])
        XCTAssertEqual(reloaded.config.overrides[.toggleFastMode], KeyStroke(.f, modifiers: [.control, .option]))
    }

    func testCorruptFileIsNotOverwritten() throws {
        let broken = "{ this is not json"
        try broken.write(to: storeURL(), atomically: true, encoding: .utf8)

        let store = ConfigStore(url: storeURL())
        store.load()

        XCTAssertNotNil(store.loadWarning)
        XCTAssertEqual(store.config.activeProfile, .genericTerminal)
        let after = try String(contentsOf: storeURL(), encoding: .utf8)
        XCTAssertEqual(after, broken, "a hand-edited config with a typo must survive")
    }

    func testOverridesIgnoreUnknownActionNames() {
        var config = AppConfig()
        config.actionKeyOverrides = [
            "toggleFastMode": AppConfig.KeyBinding(key: .f),
            "notARealAction": AppConfig.KeyBinding(key: .z),
        ]
        XCTAssertEqual(config.overrides.count, 1)
        XCTAssertNotNil(config.overrides[.toggleFastMode])
    }

    func testGestureConfigurationComesFromConfig() {
        var config = AppConfig()
        config.tapMaxMs = 180
        config.holdMs = 400
        XCTAssertEqual(config.gestureConfiguration, GestureConfiguration(tapMaxMs: 180, holdMs: 400))
    }
}
