import XCTest
@testable import PocketAgentCore

/// The toggle rule ("which app is *the other* one") and the config surface behind it.
///
/// This is where the user-visible meaning of "hold B" lives, so it is tested as behaviour rather
/// than as a string comparison.
final class AgentPairTests: XCTestCase {
    private let codex = "com.openai.codex"
    private let claude = "com.anthropic.claudefordesktop"

    // MARK: - Pair resolution

    func testDefaultPairIsCodexAndClaude() {
        XCTAssertEqual(AppConfig.AgentPair.default.bundleIDs, [codex, claude])
        XCTAssertEqual(AppConfig.AgentPair.default.name(for: codex), "Codex")
        XCTAssertEqual(AppConfig.AgentPair.default.name(for: claude), "Claude")
    }

    func testMissingSidesFallBackToTheDefaults() {
        // A hand-written config that only sets one side must not disable the other.
        let half = AppConfig.AgentPair(rightBundleID: "com.example.other")
        XCTAssertEqual(half.bundleIDs, [codex, "com.example.other"])
        XCTAssertEqual(half.resolved.leftName, "Codex")

        let empty = AppConfig.AgentPair()
        XCTAssertEqual(empty.bundleIDs, [codex, claude])
    }

    func testBlankSidesAreDropped() {
        let single = AppConfig.AgentPair(leftBundleID: codex, rightBundleID: "")
        XCTAssertEqual(single.bundleIDs, [codex], "an empty side must not become a target")
    }

    func testTogglePicksTheOtherSideInBothDirections() {
        let pair = AppConfig.AgentPair.default
        let ids = pair.bundleIDs

        // "from" is the side the user is on; the answer is always the other side. This is the whole
        // toggle rule, and the reason one gesture works in both directions.
        XCTAssertEqual(
            AgentPairResolver.otherAnchor(from: pair.leftBundleID, agentBundleIDs: ids),
            claude)
        XCTAssertEqual(
            AgentPairResolver.otherAnchor(from: pair.rightBundleID, agentBundleIDs: ids),
            codex)
    }

    func testAnUnknownAnchorFallsBackToTheFirstAgent() {
        // Reached only if the caller passes something outside the pair; the config-based entry
        // point never does (see testConfigResolvesTheToggleTargetLive).
        let ids = AppConfig.AgentPair.default.bundleIDs
        XCTAssertEqual(AgentPairResolver.otherAnchor(from: "com.apple.Safari", agentBundleIDs: ids), codex)
        XCTAssertEqual(AgentPairResolver.otherAnchor(from: nil, agentBundleIDs: ids), codex)
    }

    func testToggleWithNoAgentsConfiguredHasNoTarget() {
        XCTAssertNil(AgentPairResolver.otherAnchor(from: nil, agentBundleIDs: []))
        XCTAssertNil(AgentPairResolver.otherAnchor(from: codex, agentBundleIDs: []))
    }

    func testConfigResolvesTheToggleTargetLive() {
        var config = AppConfig()
        XCTAssertEqual(config.focusOtherAgentTarget(frontmostBundleID: codex), claude)
        XCTAssertEqual(config.focusOtherAgentTarget(frontmostBundleID: claude), codex)
        // Anything that is not one of the pair — a terminal, a browser, or no app at all — goes to
        // the left side, identically.
        XCTAssertEqual(config.focusOtherAgentTarget(frontmostBundleID: "com.apple.Terminal"), codex)
        XCTAssertEqual(config.focusOtherAgentTarget(frontmostBundleID: nil), codex)

        config.agentPair = AppConfig.AgentPair(leftBundleID: "com.example.a", rightBundleID: "com.example.b")
        XCTAssertEqual(config.focusOtherAgentTarget(frontmostBundleID: "com.example.a"), "com.example.b")
    }

    // MARK: - Config compatibility

    func testConfigWrittenBeforeThePairExistedStillLoads() throws {
        // The decode of every field must stay tolerant, or adding this feature would reset the
        // settings of anyone upgrading (see AppConfig's decoding note).
        let legacy = """
        {
          "version": 1,
          "activeProfile": "claudeCode",
          "profileMode": "auto",
          "gestureKeyOverrides": { "b.a": { "hold": true, "modifiers": ["rightOption"] } }
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(config.agentPair.bundleIDs, [codex, claude])
        XCTAssertEqual(config.activeProfile, .claudeCode)
        XCTAssertEqual(config.gestureOverrides["b.a"]?.isHeld, true)
    }

    func testPairRoundTripsThroughJSON() throws {
        var config = AppConfig()
        config.agentPair = AppConfig.AgentPair(
            leftBundleID: "com.example.left",
            rightBundleID: "com.example.right",
            leftName: "Left",
            rightName: "Right"
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded.agentPair, config.agentPair)
    }
}

/// `AppActivator`'s fallback behaviour, with the real `NSRunningApplication` calls kept out of it by
/// using bundle IDs that are definitely not installed — the shape of the attempt list is what
/// matters here, not the OS.
final class AppActivatorTests: XCTestCase {
    private final class FixedFrontmost: FrontmostAppProviding {
        var bundleID: String?
        init(_ bundleID: String?) { self.bundleID = bundleID }
        func frontmostBundleID() -> String? { bundleID }
    }

    func testAnAppThatIsNotRunningIsReportedRatherThanPretended() {
        let frontmost = FixedFrontmost("com.openai.codex")
        let activator = AppActivator(frontmost: frontmost, timeout: 0.05, pollInterval: 0.01)

        let outcome = activator.activate(bundleID: "com.example.definitely-not-installed")

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.attempts.count, AppActivationMethod.allCases.count)
        XCTAssertTrue(outcome.attempts.allSatisfy { $0.reason == "app is not running" })
        XCTAssertTrue(AppActivationReport.describe(outcome).contains("not running"))
    }

    func testAFailedActivationNamesEveryMethodItTried() {
        // A frontmost app that never changes stands in for "the activation did not take effect".
        let frontmost = FixedFrontmost("com.openai.codex")
        let activator = AppActivator(frontmost: frontmost, timeout: 0.05, pollInterval: 0.01)
        activator.methodOrder = [.runningApplication]

        let outcome = activator.activate(bundleID: "com.example.definitely-not-installed")

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.attempts.map(\.method), [.runningApplication])
        XCTAssertNotNil(outcome.reason)
    }
}
