import XCTest
@testable import PocketAgentCore

private final class SpyEmitter: InputEmitting {
    enum Event: Equatable {
        case press(KeyStroke)
        case down(KeyStroke)
        case up(KeyStroke)
        case releaseAll
    }

    private(set) var events: [Event] = []

    func reset() { events.removeAll() }

    func press(_ stroke: KeyStroke) { events.append(.press(stroke)) }
    func keyDown(_ stroke: KeyStroke) { events.append(.down(stroke)) }
    func keyUp(_ stroke: KeyStroke) { events.append(.up(stroke)) }
    func releaseAll() { events.append(.releaseAll) }
}

private final class StubFrontmost: FrontmostAppProviding {
    var bundleID: String?
    init(_ bundleID: String?) { self.bundleID = bundleID }
    func frontmostBundleID() -> String? { bundleID }
}

/// Records what would have been focused, and lets a test force a failure.
private final class SpyActivator: AppActivating {
    private(set) var requested: [String] = []
    var result: (String) -> AppActivationOutcome = { bundleID in
        AppActivationOutcome(
            succeeded: true,
            bundleID: bundleID,
            method: .appleScript,
            elapsedMs: 42,
            attempts: [AppActivationAttempt(method: .appleScript, succeeded: true, elapsedMs: 42)]
        )
    }

    func activate(bundleID: String) -> AppActivationOutcome {
        requested.append(bundleID)
        return result(bundleID)
    }
}

final class DispatcherTests: XCTestCase {
    private func makeDispatcher(
        profile: ToolProfile,
        frontmost: String? = "com.openai.codex",
        allowed: [String] = ["com.openai.codex"],
        overrides: [String: AppConfig.KeyBinding] = [:],
        mode: ProfileMode = .manual,
        pair: AppConfig.AgentPair = .default,
        activator: AppActivating? = nil
    ) -> (ActionDispatcher, SpyEmitter, StubFrontmost) {
        var config = AppConfig()
        config.profileMode = mode
        config.activeProfile = profile
        config.allowedBundleIDs = allowed
        config.actionKeyOverrides = overrides
        config.agentPair = pair

        let emitter = SpyEmitter()
        let frontmostProvider = StubFrontmost(frontmost)
        let dispatcher = ActionDispatcher(
            configProvider: { config },
            frontmost: frontmostProvider,
            emitter: emitter,
            activator: activator
        )
        return (dispatcher, emitter, frontmostProvider)
    }

    func testAllowedActionIsEmitted() {
        let (dispatcher, emitter, _) = makeDispatcher(profile: .codex)
        dispatcher.dispatch(.press(.newChat))
        XCTAssertEqual(emitter.events, [.press(KeyStroke(.n, modifiers: [.command]))])
    }

    func testHeldNavigationUsesDownAndUp() {
        let (dispatcher, emitter, _) = makeDispatcher(profile: .codex)
        dispatcher.dispatch(.down(.navigateUp))
        dispatcher.dispatch(.up(.navigateUp))
        XCTAssertEqual(emitter.events, [.down(.key(.upArrow)), .up(.key(.upArrow))])
    }

    func testDeniedActionEmitsNothingAndReportsWhy() {
        let (dispatcher, emitter, _) = makeDispatcher(profile: .codex, frontmost: "com.apple.mail")
        var denied: [String] = []
        dispatcher.onDenied = { _, reason in denied.append(reason) }

        dispatcher.dispatch(.press(.newChat))

        XCTAssertTrue(emitter.events.isEmpty)
        XCTAssertEqual(denied.count, 1)
        XCTAssertTrue(denied[0].contains("allowlist"))
    }

    func testUnsupportedActionEmitsNothingAndCarriesTheAdapterNote() {
        let (dispatcher, emitter, _) = makeDispatcher(profile: .codex)
        var unsupported: [(AgentAction, String)] = []
        dispatcher.onUnsupported = { unsupported.append(($0, $1)) }

        dispatcher.dispatch(.press(.openPermissionModeMenu))

        XCTAssertTrue(emitter.events.isEmpty)
        XCTAssertEqual(unsupported.count, 1)
        XCTAssertEqual(unsupported[0].0, .openPermissionModeMenu)
        XCTAssertTrue(unsupported[0].1.contains("permission-mode"))
    }

    func testGenericProfileCannotFireToolActions() {
        let (dispatcher, emitter, _) = makeDispatcher(profile: .genericTerminal, allowed: ["com.openai.codex"])
        dispatcher.dispatch(.press(.newChat))
        XCTAssertTrue(emitter.events.isEmpty)
    }

    func testNavigationStillWorksOnTheGenericProfile() {
        let (dispatcher, emitter, _) = makeDispatcher(
            profile: .genericTerminal,
            frontmost: "com.apple.Terminal",
            allowed: ["com.apple.Terminal"]
        )
        dispatcher.dispatch(.press(.submit))
        XCTAssertEqual(emitter.events, [.press(.key(.enter))])
    }

    func testOverrideTurnsAClassCActionIntoAWorkingOne() {
        let (dispatcher, emitter, _) = makeDispatcher(
            profile: .codex,
            overrides: ["toggleFastMode": AppConfig.KeyBinding(key: .f, modifiers: [.control, .option])]
        )
        dispatcher.dispatch(.press(.toggleFastMode))
        XCTAssertEqual(emitter.events, [.press(KeyStroke(.f, modifiers: [.control, .option]))])
    }

    func testModifierOnlyOverrideFiresEvenWhenTheFrontmostAppIsNotAllowed() {
        // Deliberate exception to the allowlist rule: a modifier-only stroke carries no command into
        // any application, and the use case (an input method's voice input while typing anywhere)
        // requires it to work globally.
        let (dispatcher, emitter, _) = makeDispatcher(profile: .genericTerminal, frontmost: "com.apple.mail", allowed: [])
        let held = KeyStroke(modifiers: [.option, .shift])
        dispatcher.dispatch(.raw(held, .down))
        dispatcher.dispatch(.raw(held, .up))

        XCTAssertEqual(emitter.events, [.down(held), .up(held)])
    }

    func testKeyOverrideStillObeysTheAllowlist() {
        let (dispatcher, emitter, _) = makeDispatcher(profile: .codex, frontmost: "com.apple.mail")
        dispatcher.dispatch(.raw(KeyStroke(.b, modifiers: [.command]), .press))
        XCTAssertTrue(emitter.events.isEmpty)
    }

    func testAutoModeFollowsTheFrontmostApp() {
        // The whole point of auto mode: no menu clicking when switching between the two agents.
        let (dispatcher, emitter, frontmost) = makeDispatcher(profile: .genericTerminal, mode: .auto)

        frontmost.bundleID = "com.openai.codex"
        dispatcher.dispatch(.press(.goToRecentChat1))   // Codex action
        XCTAssertEqual(emitter.events, [.press(KeyStroke(.digit1, modifiers: [.command, .option]))])

        emitter.reset()
        frontmost.bundleID = "com.anthropic.claudefordesktop"
        dispatcher.dispatch(.press(.goToRecentChat1))
        XCTAssertTrue(emitter.events.isEmpty, "Claude cannot do this; it must not fire a Codex shortcut")

        emitter.reset()
        frontmost.bundleID = "com.apple.mail"
        dispatcher.dispatch(.press(.submit))
        XCTAssertEqual(emitter.events, [.press(.key(.enter))], "unknown apps fall back to the generic profile")
    }

    func testAutoModeDropsTheAllowlistBecauseTheProfileAlreadyEncodesIt() {
        // In manual mode an unlisted app blocks everything. In auto mode the profile is *derived*
        // from the frontmost app, so an unknown app can only ever reach the generic profile — the
        // allowlist would be a second copy of the same check.
        let (dispatcher, emitter, _) = makeDispatcher(
            profile: .genericTerminal, frontmost: "com.apple.mail", allowed: [], mode: .auto)
        dispatcher.dispatch(.press(.cancelOrInterrupt))
        XCTAssertEqual(emitter.events, [.press(.key(.escape))])
    }

    func testManualModeStillObeysTheAllowlist() {
        let (dispatcher, emitter, _) = makeDispatcher(
            profile: .codex, frontmost: "com.apple.mail", allowed: ["com.openai.codex"], mode: .manual)
        dispatcher.dispatch(.press(.newChat))
        XCTAssertTrue(emitter.events.isEmpty)
    }

    func testEveryBoundActionEmitsExactlyOnce() {
        // The whole default gesture map must be reachable end to end.
        let (dispatcher, emitter, _) = makeDispatcher(profile: .codex)
        let bound: [AgentAction] = [
            .navigateUp, .navigateDown, .navigateLeft, .navigateRight,
            .submit, .cancelOrInterrupt, .queueFollowUp,
            .newChat, .openTerminal, .openModelPicker, .inspectChanges,
        ]
        for action in bound {
            dispatcher.dispatch(.press(action))
        }
        XCTAssertEqual(emitter.events.count, bound.count)
    }

    // MARK: - Cross-app focus (hold B)

    func testFocusOtherAgentRaisesTheOtherAppAndSendsNoKeystroke() {
        let activator = SpyActivator()
        let (dispatcher, emitter, _) = makeDispatcher(profile: .codex, activator: activator)

        dispatcher.dispatch(.press(.focusOtherAgent))

        XCTAssertEqual(activator.requested, ["com.anthropic.claudefordesktop"])
        XCTAssertTrue(emitter.events.isEmpty, "focusing an app is not a keystroke")
    }

    func testFocusOtherAgentTogglesBothWays() {
        let activator = SpyActivator()
        let (dispatcher, _, frontmost) = makeDispatcher(profile: .codex, activator: activator)

        dispatcher.dispatch(.press(.focusOtherAgent))
        frontmost.bundleID = "com.anthropic.claudefordesktop"
        dispatcher.dispatch(.press(.focusOtherAgent))

        XCTAssertEqual(activator.requested, ["com.anthropic.claudefordesktop", "com.openai.codex"])
    }

    func testFocusOtherAgentWorksFromAnAppThatIsNotAllowlisted() {
        // The whole point: the user is in a browser, no agent chord may fire there, and this one
        // still must. It sends the app no input, so the allowlist has nothing to protect.
        let activator = SpyActivator()
        let (dispatcher, emitter, _) = makeDispatcher(
            profile: .genericTerminal, frontmost: "com.apple.Safari", allowed: [], activator: activator)

        dispatcher.dispatch(.press(.focusOtherAgent))

        XCTAssertEqual(activator.requested, ["com.openai.codex"])
        XCTAssertTrue(emitter.events.isEmpty)
    }

    func testFocusOtherAgentReportsFailureAndEmitsNothing() {
        let activator = SpyActivator()
        activator.result = { bundleID in
            AppActivationOutcome(
                succeeded: false,
                bundleID: bundleID,
                elapsedMs: 900,
                attempts: [AppActivationAttempt(method: .appleScript, succeeded: false, elapsedMs: 900, reason: "app is not running")],
                reason: "app is not running"
            )
        }
        let (dispatcher, emitter, _) = makeDispatcher(profile: .codex, activator: activator)
        var activations: [(AgentAction, AppActivationOutcome)] = []
        dispatcher.onActivation = { activations.append(($0, $1)) }

        dispatcher.dispatch(.press(.focusOtherAgent))

        XCTAssertTrue(emitter.events.isEmpty)
        XCTAssertEqual(activations.count, 1)
        XCTAssertFalse(activations[0].1.succeeded)
        XCTAssertTrue(AppActivationReport.describe(activations[0].1).contains("not running"))
    }

    func testFocusOtherAgentWithASingleAgentPairResolvesToThatAgent() {
        // A blank side — as opposed to a *missing* one, which falls back to its default — is how a
        // one-agent pair is written. It always resolves to that agent instead of inventing a second
        // target, and never reports "nothing to do".
        let activator = SpyActivator()
        let (dispatcher, emitter, _) = makeDispatcher(
            profile: .codex,
            pair: AppConfig.AgentPair(leftBundleID: "com.openai.codex", rightBundleID: ""),
            activator: activator
        )
        var diagnostics: [String] = []
        dispatcher.onDiagnostic = { diagnostics.append($0) }

        dispatcher.dispatch(.press(.focusOtherAgent))

        XCTAssertEqual(activator.requested, ["com.openai.codex"])
        XCTAssertTrue(emitter.events.isEmpty)
        XCTAssertTrue(diagnostics.isEmpty)
    }

    // MARK: - Releases must not be re-decided

    func testReleaseSurvivesTheFrontmostAppLeavingTheAllowlist() {
        // Found by review (2026-09-16). `keyUp` used to go through the same guard as `keyDown`, so
        // moving focus off the allowlist while an arrow was held denied the release — a key stuck
        // down in whatever app you switched to. Releases are not a new decision.
        let (dispatcher, emitter, frontmost) = makeDispatcher(
            profile: .codex, frontmost: "com.openai.codex", allowed: ["com.openai.codex"], mode: .manual)

        dispatcher.dispatch(.down(.navigateUp))
        frontmost.bundleID = "com.apple.Safari"   // focus leaves the allowlist mid-hold
        dispatcher.dispatch(.up(.navigateUp))

        XCTAssertEqual(emitter.events, [.down(.key(.upArrow)), .up(.key(.upArrow))])
    }

    func testReleaseSurvivesTheActionBecomingUnsupported() {
        // Same class of bug through the other door: the profile changed (or a config reload dropped
        // the override), so the adapter no longer resolves the action at all. The outstanding key
        // still has to come up.
        let emitter = SpyEmitter()
        let frontmost = StubFrontmost("com.openai.codex")
        var config = AppConfig(activeProfile: .codex, profileMode: .manual)
        let dispatcher = ActionDispatcher(
            configProvider: { config }, frontmost: frontmost, emitter: emitter)

        dispatcher.dispatch(.down(.navigateUp))
        config.activeProfile = .claudeCode        // Claude cannot navigate with this action
        dispatcher.dispatch(.up(.navigateUp))

        XCTAssertEqual(emitter.events, [.down(.key(.upArrow)), .up(.key(.upArrow))])
    }

    func testHeldGestureOverrideIsReleasedWithTheStrokeThatWentDown() {
        // The voice-input case: a held modifier-only override is sent down, then the override table
        // loses B+A (profile switch / config reload / frontmost app change). Nothing may re-resolve
        // the *identity* of the key that is physically still down.
        let emitter = SpyEmitter()
        let frontmost = StubFrontmost("com.apple.Safari")
        var config = AppConfig(activeProfile: .codex, profileMode: .auto)
        config.gestureKeyOverrides = ["b.a": AppConfig.KeyBinding(modifiers: [.rightOption], hold: true)]
        let dispatcher = ActionDispatcher(
            configProvider: { config }, frontmost: frontmost, emitter: emitter)

        let option = KeyStroke(modifiers: [.rightOption])
        dispatcher.dispatch(.raw(option, .down))
        config.gestureKeyOverrides = [:]          // the table changes mid-gesture
        dispatcher.dispatch(.raw(option, .up))

        XCTAssertEqual(emitter.events, [.down(option), .up(option)])
    }
}
