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

    /// A target app under test: how long it takes to answer the request, how long until it is
    /// actually in front, and whether the request errors. Drives the activator through the manual
    /// clock, so "two seconds" costs nothing.
    private struct Target {
        var replyAfter: TimeInterval = 0.02
        var frontAfter: TimeInterval? = 0.05
        var replyError: String? = nil
    }

    private func run(
        _ target: Target,
        frontmostBefore: String = "com.openai.codex",
        bundleID: String = "com.tencent.xinWeChat",
        methodOrder: [AppActivationMethod] = [.appleScript, .runningApplication],
        running: Bool = true
    ) -> (result: Result, scheduler: ManualScheduler, frontmost: FixedFrontmost) {
        let scheduler = ManualScheduler()
        let frontmost = FixedFrontmost(frontmostBefore)
        var requests: [AppActivationMethod] = []
        let activator = AppActivator(
            frontmost: frontmost,
            scheduler: scheduler,
            clock: { scheduler.now },
            isRunning: { _ in running },
            requester: { method, _, completion in
                requests.append(method)
                _ = scheduler.schedule(after: target.replyAfter) { completion(target.replyError) }
                if let frontAfter = target.frontAfter, requests.count == 1 {
                    _ = scheduler.schedule(after: frontAfter) { frontmost.bundleID = bundleID }
                }
            }
        )
        activator.methodOrder = methodOrder
        let result = Result()
        activator.activate(bundleID: bundleID) { result.outcome = $0 }
        return (result, scheduler, frontmost)
    }

    /// The completion lands later, on the manual clock, so the test reads through a box.
    private final class Result {
        var outcome: AppActivationOutcome?
    }

    /// Moves the clock the way a real timer would: in poll-sized steps, so each poll is scheduled
    /// from the time it actually fired at, not from wherever a single jump landed.
    private func step(_ scheduler: ManualScheduler, to time: TimeInterval) {
        var t = scheduler.now
        while t < time {
            t = min(t + AppActivator.defaultPollInterval, time)
            scheduler.advance(to: t)
        }
    }

    func testAnAppThatIsNotRunningIsReportedRatherThanPretended() {
        let (result, _, _) = run(Target(), running: false)
        XCTAssertEqual(result.outcome?.succeeded, false)
        XCTAssertEqual(result.outcome?.attempts.count, AppActivationMethod.allCases.count)
        XCTAssertTrue(result.outcome?.attempts.allSatisfy { $0.reason == "app is not running" } ?? false)
        XCTAssertTrue(AppActivationReport.describe(result.outcome!).contains("not running"))
    }

    func testAFastAppSucceedsAsSoonAsItIsInFront() {
        let (result, scheduler, _) = run(Target(replyAfter: 0.02, frontAfter: 0.05))
        XCTAssertNil(result.outcome, "nothing is decided at request time")
        scheduler.advance(to: 0.04); XCTAssertNil(result.outcome)
        scheduler.advance(to: 0.10)
        XCTAssertEqual(result.outcome?.succeeded, true)
        XCTAssertEqual(result.outcome?.method, .appleScript)
        XCTAssertEqual(result.outcome?.attempts.count, 1)
        XCTAssertLessThanOrEqual(result.outcome!.elapsedMs, 100)
    }

    func testASlowAppIsNotReportedAsAFailureWhileItIsStillComing() {
        // WeChat: answers the Apple event after ~2 s and lands after that. The old 0.5 s wait called
        // this a failure and then watched it succeed.
        let (result, scheduler, _) = run(Target(replyAfter: 2.1, frontAfter: 3.0))
        scheduler.advance(to: 2.5)
        XCTAssertNil(result.outcome, "the reply alone proves nothing; keep waiting")
        scheduler.advance(to: 3.05)
        XCTAssertEqual(result.outcome?.succeeded, true)
        XCTAssertEqual(result.outcome?.method, .appleScript)
        XCTAssertGreaterThanOrEqual(result.outcome!.elapsedMs, 3000)
        XCTAssertTrue(AppActivationReport.describe(result.outcome!).contains("via appleScript in 3"), AppActivationReport.describe(result.outcome!))
    }

    func testAnAppThatNeverComesForwardFailsAfterBothBudgets() {
        let (result, scheduler, _) = run(Target(replyAfter: 0.02, frontAfter: nil))
        step(scheduler, to: AppActivator.defaultVerificationTimeout - 0.01)
        XCTAssertNil(result.outcome)
        step(scheduler, to: AppActivator.defaultVerificationTimeout + AppActivator.defaultFallbackTimeout + 0.1)
        XCTAssertEqual(result.outcome?.succeeded, false)
        XCTAssertEqual(result.outcome?.attempts.map(\.method), [.appleScript, .runningApplication])
        XCTAssertEqual(result.outcome?.attempts.map(\.succeeded), [false, false])
        // Within one poll of the budget: the deadline is noticed on the next tick after it passes.
        XCTAssertEqual(Double(result.outcome!.attempts[0].elapsedMs), 4000, accuracy: 100)
        XCTAssertEqual(Double(result.outcome!.attempts[1].elapsedMs), 1000, accuracy: 100)
        let line = AppActivationReport.describe(result.outcome!)
        XCTAssertTrue(line.contains("could not focus"), line)
        XCTAssertNotNil(line.range(of: #"appleScript✗ 4\d{3} ms → runningApplication✗ 1\d{3} ms"#, options: .regularExpression), line)
        XCTAssertTrue(line.contains("frontmost was com.openai.codex"), line)
    }

    func testARefusedRequestFallsThroughToTheNextMethodAtOnce() {
        let (result, scheduler, _) = run(Target(replyAfter: 0.02, frontAfter: nil, replyError: "AppleScript error -600: not running"))
        step(scheduler, to: 0.03)
        XCTAssertNil(result.outcome, "the fallback is now in flight")
        step(scheduler, to: 0.03 + AppActivator.defaultFallbackTimeout + 0.1)
        XCTAssertEqual(result.outcome?.succeeded, false)
        XCTAssertEqual(result.outcome?.attempts.first?.reason, "AppleScript error -600: not running")
        XCTAssertLessThan(result.outcome!.attempts[0].elapsedMs, 100, "no 4 s wait on a request that was refused")
    }

    func testAFailedActivationNamesEveryMethodItTried() {
        let (result, scheduler, _) = run(Target(replyAfter: 0.02, frontAfter: nil), methodOrder: [.runningApplication])
        step(scheduler, to: AppActivator.defaultVerificationTimeout + 0.1)
        XCTAssertEqual(result.outcome?.succeeded, false)
        XCTAssertEqual(result.outcome?.attempts.map(\.method), [.runningApplication])
        XCTAssertNotNil(result.outcome?.reason)
    }
}
