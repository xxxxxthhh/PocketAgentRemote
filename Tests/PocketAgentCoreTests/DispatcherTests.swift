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

final class DispatcherTests: XCTestCase {
    private func makeDispatcher(
        profile: ToolProfile,
        frontmost: String? = "com.openai.codex",
        allowed: [String] = ["com.openai.codex"],
        overrides: [String: AppConfig.KeyBinding] = [:]
    ) -> (ActionDispatcher, SpyEmitter, StubFrontmost) {
        var config = AppConfig()
        config.activeProfile = profile
        config.allowedBundleIDs = allowed
        config.actionKeyOverrides = overrides

        let emitter = SpyEmitter()
        let frontmostProvider = StubFrontmost(frontmost)
        let dispatcher = ActionDispatcher(
            configProvider: { config },
            frontmost: frontmostProvider,
            emitter: emitter
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
}
