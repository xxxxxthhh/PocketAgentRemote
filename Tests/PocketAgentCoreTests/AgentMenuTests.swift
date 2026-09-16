import XCTest
@testable import PocketAgentCore

/// The on-screen menu: what it offers, how the selection moves, and what it refuses to do.
///
/// The menu exists because the gesture set is full, so these tests are about the two promises that
/// make it worth having: it only offers rows that will really run, and it acts on the app it was
/// opened for — never on whatever happens to be in front when the user presses A.
final class AgentMenuTests: XCTestCase {
    private let codex = "com.openai.codex"
    private let claude = "com.anthropic.claudefordesktop"

    private func menu(for bundleID: String?, config: AppConfig = AppConfig()) -> AgentMenu? {
        AgentMenuBuilder.menu(for: config, frontmostBundleID: bundleID, frontmostName: nil)
    }

    // MARK: - Contents

    func testMenuOffersTheActionsTheAdapterCanActuallyRun() {
        let menu = menu(for: codex)
        XCTAssertNotNil(menu)
        XCTAssertEqual(menu?.items.first?.action, .newChat, "新建会话 is the first row")
        XCTAssertEqual(menu?.title, "Codex")

        let actions = menu?.items.map(\.action) ?? []
        XCTAssertTrue(actions.contains(.inspectChanges))
        XCTAssertTrue(actions.contains(.openTerminal))
        // Everything offered must be runnable, or pressing A on it would do nothing at all.
        let adapter = AdapterCatalog.adapter(for: .codex)
        for action in actions {
            XCTAssertNotNil(adapter.support(for: action).recipe, "\(action) is offered but unsupported")
        }
    }

    func testClaudeGetsItsOwnRowSet() {
        // The rows come from the adapter in force, so the two apps do not have to agree on what
        // exists — Codex's fast mode has no default key, Claude's does.
        let claudeMenu = menu(for: claude)
        XCTAssertEqual(claudeMenu?.title, "Claude")
        XCTAssertEqual(claudeMenu?.items.first?.action, .newChat)
        let claudeAdapter = AdapterCatalog.adapter(for: .claudeCode)
        for item in claudeMenu?.items ?? [] {
            XCTAssertNotNil(claudeAdapter.support(for: item.action).recipe)
        }
    }

    func testRowsThatCannotRunAreLeftOut() {
        // `toggleFastMode` is supported by Claude but has no key on Codex; a row that silently does
        // nothing would be worse than no row.
        var config = AppConfig()
        config.profileMode = .manual
        config.activeProfile = .codex
        let catalog = [MenuItem(action: .toggleFastMode, title: "快速模式")]
        XCTAssertNil(AgentMenuBuilder.menu(for: config, frontmostBundleID: codex, catalog: catalog),
                     "a menu with nothing runnable must not be shown at all")
    }

    func testAnOverrideMakesARowRunnable() {
        var config = AppConfig()
        config.actionKeyOverrides = ["toggleFastMode": AppConfig.KeyBinding(key: .f, modifiers: [.control, .option])]
        let catalog = [MenuItem(action: .toggleFastMode, title: "快速模式")]
        let menu = AgentMenuBuilder.menu(for: config, frontmostBundleID: codex, catalog: catalog)
        XCTAssertEqual(menu?.items.map(\.action), [.toggleFastMode])
    }

    func testNoMenuOutsideTheAgents() {
        // In a browser there is no agent to act on: nil, not an empty menu.
        XCTAssertNil(menu(for: "com.apple.Safari"))
        XCTAssertNil(menu(for: nil))
    }

    // MARK: - Selection

    func testSelectionWrapsAtBothEnds() {
        var menu = AgentMenu(bundleID: codex, title: "Codex", items: [
            MenuItem(action: .newChat, title: "a"),
            MenuItem(action: .inspectChanges, title: "b"),
            MenuItem(action: .openTerminal, title: "c"),
        ])
        XCTAssertEqual(menu.selection, 0)

        menu.moveUp()
        XCTAssertEqual(menu.selection, 2, "up from the top row wraps to the bottom")
        menu.moveDown()
        XCTAssertEqual(menu.selection, 0, "down from the bottom row wraps to the top")

        menu.moveDown()
        menu.moveDown()
        XCTAssertEqual(menu.selectedItem?.action, .openTerminal)
    }

    func testSelectionIsClampedWhenConstructed() {
        let menu = AgentMenu(bundleID: codex, title: "Codex", items: [], selection: 5)
        XCTAssertEqual(menu.selection, 0)
        XCTAssertNil(menu.selectedItem)
        XCTAssertTrue(menu.isEmpty)
        // Moving in an empty menu must not crash or invent an index.
        var mutable = menu
        mutable.moveDown()
        XCTAssertEqual(mutable.selection, 0)
    }

    func testHintNamesTheControls() {
        // The controls are discoverable on screen rather than remembered.
        let hint = AgentMenu(bundleID: codex, title: "Codex", items: [
            MenuItem(action: .newChat, title: "a"),
        ]).hint
        XCTAssertTrue(hint.contains("A"))
        XCTAssertTrue(hint.contains("B"))
    }
}

/// The one-time adoption of the new `B+←` meaning over a user's existing override.
final class ConfigMigrationTests: XCTestCase {
    func testStaleNewChatOverrideIsRemovedSoTheMenuCanOpen() {
        var config = AppConfig()
        config.profileGestureKeyOverrides = [
            "claudeCode": [
                // Exactly the old default this chord used to have.
                "b.left": AppConfig.KeyBinding(key: .n, modifiers: [.command]),
                "b.up": AppConfig.KeyBinding(key: .rightBracket, modifiers: [.command, .shift]),
            ],
        ]

        XCTAssertTrue(ConfigMigrations.adoptMenuChord(&config))

        XCTAssertNil(config.profileGestureKeyOverrides["claudeCode"]?["b.left"])
        XCTAssertNotNil(config.profileGestureKeyOverrides["claudeCode"]?["b.up"],
                        "only the menu chord is touched")
    }

    func testADeliberateOverrideIsLeftAlone() {
        // If the user pointed b.left at something else, that is a choice, not a stale default.
        var config = AppConfig()
        config.profileGestureKeyOverrides = [
            "codex": ["b.left": AppConfig.KeyBinding(key: .t, modifiers: [.command, .shift])],
        ]

        XCTAssertFalse(ConfigMigrations.adoptMenuChord(&config))
        XCTAssertNotNil(config.profileGestureKeyOverrides["codex"]?["b.left"])
    }

    func testAnEmptyProfileEntryIsDropped() {
        var config = AppConfig()
        config.profileGestureKeyOverrides = [
            "claudeCode": ["b.left": AppConfig.KeyBinding(key: .n, modifiers: [.command])],
        ]

        XCTAssertTrue(ConfigMigrations.adoptMenuChord(&config))
        XCTAssertNil(config.profileGestureKeyOverrides["claudeCode"])
    }

    func testRunningItTwiceChangesNothingMore() {
        var config = AppConfig()
        config.profileGestureKeyOverrides = [
            "claudeCode": ["b.left": AppConfig.KeyBinding(key: .n, modifiers: [.command])],
        ]
        XCTAssertTrue(ConfigMigrations.adoptMenuChord(&config))
        XCTAssertFalse(ConfigMigrations.adoptMenuChord(&config))
    }
}

/// What the controller's buttons do while the menu is up.
///
/// The point of these is the promise that the menu **owns** the controller while it is open: the
/// events are injected by our own process, so if they were not consumed here they would be delivered
/// to the chat window as real arrow keys, Enter and Escape.
final class MenuEventTests: XCTestCase {
    private let codex = "com.openai.codex"

    private func makeDispatcher(
        frontmost: String? = "com.openai.codex"
    ) -> (ActionDispatcher, SpyEmitterForMenu, StubFrontmostForMenu) {
        var config = AppConfig()
        config.profileMode = .auto
        let emitter = SpyEmitterForMenu()
        let front = StubFrontmostForMenu(frontmost)
        let dispatcher = ActionDispatcher(
            configProvider: { config },
            frontmost: front,
            emitter: emitter
        )
        dispatcher.menuBuilder = { bundleID in
            AgentMenuBuilder.menu(for: config, frontmostBundleID: bundleID)
        }
        return (dispatcher, emitter, front)
    }

    private func openMenu(_ dispatcher: ActionDispatcher) {
        dispatcher.dispatch(.press(.openMenu))
    }

    func testOpenMenuPublishesAMenuAndSendsNoKeystroke() {
        let (dispatcher, emitter, _) = makeDispatcher()
        var published: [AgentMenu?] = []
        dispatcher.onMenuChanged = { published.append($0) }

        openMenu(dispatcher)

        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published[0]?.items.first?.action, .newChat)
        XCTAssertTrue(emitter.events.isEmpty, "opening a menu must not type anything")
        XCTAssertNotNil(dispatcher.openMenu)
    }

    func testArrowsMoveTheSelectionWithoutReachingTheApp() {
        let (dispatcher, emitter, _) = makeDispatcher()
        openMenu(dispatcher)

        let result = dispatcher.handleMenuEvent(.pressed(.down, timestamp: 0))
        XCTAssertEqual(result, .handled)
        XCTAssertEqual(dispatcher.openMenu?.selection, 1)
        XCTAssertTrue(emitter.events.isEmpty, "the menu's ↑↓ must not become arrow keys in the chat window")
    }

    func testAExecutesTheHighlightedRowAndClosesTheMenu() {
        let (dispatcher, emitter, _) = makeDispatcher()
        openMenu(dispatcher)

        // Move to 查看变更, then run it.
        _ = dispatcher.handleMenuEvent(.pressed(.down, timestamp: 0))
        let result = dispatcher.handleMenuEvent(.pressed(.a, timestamp: 0.1))

        XCTAssertEqual(result, .executed(.inspectChanges))
        XCTAssertNil(dispatcher.openMenu, "the menu closes on execution")
        XCTAssertEqual(emitter.events, [.press(KeyStroke(.b, modifiers: [.command, .option]))])
    }

    func testBCancelsWithoutSendingEscape() {
        let (dispatcher, emitter, _) = makeDispatcher()
        openMenu(dispatcher)

        let result = dispatcher.handleMenuEvent(.pressed(.b, timestamp: 0))

        XCTAssertEqual(result, .dismissed)
        XCTAssertNil(dispatcher.openMenu)
        XCTAssertTrue(emitter.events.isEmpty, "closing the menu must not also send Escape to the app")
    }

    func testReleasesAreSwallowedSoNoChordCanFire() {
        let (dispatcher, emitter, _) = makeDispatcher()
        openMenu(dispatcher)

        // The B release that would normally end the B+← chord.
        XCTAssertEqual(dispatcher.handleMenuEvent(.released(.b, timestamp: 0.1)), .handled)
        XCTAssertTrue(emitter.events.isEmpty)
        XCTAssertNotNil(dispatcher.openMenu, "a release must not close the menu")
    }

    func testAChoiceIsRefusedWhenFocusMovedWhileTheMenuWasUp() {
        // The guard that matters: the menu was opened for Codex, so pressing A after switching to
        // another app must not send Codex's ⌥⌘B into whatever is in front now.
        let (dispatcher, emitter, frontmost) = makeDispatcher()
        openMenu(dispatcher)
        _ = dispatcher.handleMenuEvent(.pressed(.down, timestamp: 0))
        frontmost.bundleID = "com.apple.Safari"

        let result = dispatcher.handleMenuEvent(.pressed(.a, timestamp: 0.1))

        if case .refused(let reason) = result {
            XCTAssertTrue(reason.contains("frontmost"))
        } else {
            XCTFail("expected the choice to be refused, got \(result)")
        }
        XCTAssertTrue(emitter.events.isEmpty, "nothing may be sent to the app that stole focus")
        XCTAssertNil(dispatcher.openMenu)
    }

    func testEventsAreIgnoredWhenNoMenuIsOpen() {
        let (dispatcher, _, _) = makeDispatcher()
        XCTAssertEqual(dispatcher.handleMenuEvent(.pressed(.a, timestamp: 0)), .ignored)
    }

    func testOpeningTheMenuOutsideAnAgentReportsWhy() {
        let (dispatcher, emitter, _) = makeDispatcher(frontmost: "com.apple.Safari")
        var diagnostics: [String] = []
        dispatcher.onDiagnostic = { diagnostics.append($0) }

        openMenu(dispatcher)

        XCTAssertNil(dispatcher.openMenu)
        XCTAssertTrue(emitter.events.isEmpty)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].contains("openMenu"))
    }

    func testAMenuRowCannotOpenTheMenuAgain() {
        // 新建会话 runs through the normal pipeline; if it were itself an openMenu row the menu
        // would spring straight back up.
        var config = AppConfig()
        config.profileMode = .auto
        let emitter = SpyEmitterForMenu()
        let dispatcher = ActionDispatcher(
            configProvider: { config },
            frontmost: StubFrontmostForMenu(codex),
            emitter: emitter
        )
        dispatcher.menuBuilder = { bundleID in
            AgentMenu(bundleID: bundleID, title: "Codex", items: [
                MenuItem(action: .openMenu, title: "菜单"),
            ])
        }

        // Open directly, then choose the openMenu row.
        dispatcher.dispatch(.press(.openMenu))
        let result = dispatcher.handleMenuEvent(.pressed(.a, timestamp: 0.1))

        XCTAssertEqual(result, .executed(.openMenu))
        XCTAssertNil(dispatcher.openMenu, "the row must not re-open the menu it came from")
    }
}

private final class SpyEmitterForMenu: InputEmitting {
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

private final class StubFrontmostForMenu: FrontmostAppProviding {
    var bundleID: String?
    init(_ bundleID: String?) { self.bundleID = bundleID }
    func frontmostBundleID() -> String? { bundleID }
}
