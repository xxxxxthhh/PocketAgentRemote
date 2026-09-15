import XCTest
@testable import PocketAgentCore

/// The adapter tables are facts about other applications, verified against their own registries.
/// These tests exist so a refactor cannot quietly change a keystroke.
final class AdapterTests: XCTestCase {
    private let codex = CodexDesktopAdapter()
    private let claude = ClaudeDesktopAdapter()
    private let generic = GenericTerminalAdapter()

    private func stroke(_ adapter: ToolAdapter, _ action: AgentAction) -> KeyStroke? {
        adapter.support(for: action).recipe?.primaryStroke
    }

    // MARK: - Navigation (shared)

    func testNavigationIsSharedAcrossProfiles() {
        for adapter in [codex as ToolAdapter, claude, generic] {
            XCTAssertEqual(stroke(adapter, .navigateUp), .key(.upArrow))
            XCTAssertEqual(stroke(adapter, .navigateDown), .key(.downArrow))
            XCTAssertEqual(stroke(adapter, .navigateLeft), .key(.leftArrow))
            XCTAssertEqual(stroke(adapter, .navigateRight), .key(.rightArrow))

            let recipe = adapter.support(for: .navigateUp).recipe
            XCTAssertEqual(recipe?.allowsRepeat, true, "navigation must repeat")
            XCTAssertEqual(recipe?.risk, .navigation)
        }
    }

    func testSubmitAndCancelAreEnterAndEscape() {
        // approval.approve = Enter, approval.decline = Escape — the same keys, which is why there
        // are no separate approve/reject actions.
        for adapter in [codex as ToolAdapter, claude, generic] {
            XCTAssertEqual(stroke(adapter, .submit), .key(.enter))
            XCTAssertEqual(stroke(adapter, .cancelOrInterrupt), .key(.escape))
        }
    }

    // MARK: - Codex

    func testCodexKeyTable() {
        XCTAssertEqual(stroke(codex, .newChat), KeyStroke(.n, modifiers: [.command]))
        XCTAssertEqual(stroke(codex, .openTerminal), KeyStroke(.grave, modifiers: [.control]))
        XCTAssertEqual(stroke(codex, .openModelPicker), KeyStroke(.m, modifiers: [.control, .shift]))
        // openReviewTab is Control+Shift+G in the registry. Using ⌘ here would be wrong.
        XCTAssertEqual(stroke(codex, .inspectChanges), KeyStroke(.g, modifiers: [.control, .shift]))
        XCTAssertEqual(stroke(codex, .archiveChat), KeyStroke(.a, modifiers: [.command, .shift]))
        XCTAssertEqual(stroke(codex, .pinThread), KeyStroke(.p, modifiers: [.command, .option]))
        XCTAssertEqual(stroke(codex, .openSideChat), KeyStroke(.s, modifiers: [.command, .option]))
        XCTAssertEqual(stroke(codex, .queueFollowUp), .key(.enter))
    }

    func testInspectChangesIsControlNotCommand() {
        // Regression guard: this was transcribed as ⌘⇧G once, and the registry says otherwise.
        let stroke = stroke(codex, .inspectChanges)
        XCTAssertTrue(stroke?.modifiers.contains(.control) ?? false)
        XCTAssertFalse(stroke?.modifiers.contains(.command) ?? true)
    }

    func testCodexUnsupportedActionsSayWhy() {
        for action in [AgentAction.openPermissionModeMenu, .toggleFastMode, .forkThread] {
            let support = codex.support(for: action)
            XCTAssertNil(support.recipe, "\(action) must not be silently mapped")
            XCTAssertFalse(support.note?.isEmpty ?? true, "\(action) needs an explanation")
        }
    }

    func testPermissionModeIsNeverSubstitutedWithAnApproval() {
        // The failure mode this guards: "switch permission mode" turning into "approve this command".
        let support = codex.support(for: .openPermissionModeMenu)
        XCTAssertNil(support.recipe)
        XCTAssertNotEqual(stroke(codex, .openPermissionModeMenu), .key(.enter))
    }

    // MARK: - Claude

    func testClaudeKeyTable() {
        XCTAssertEqual(stroke(claude, .inspectChanges), KeyStroke(.d, modifiers: [.command, .shift]))
        XCTAssertEqual(stroke(claude, .openModelPicker), KeyStroke(.i, modifiers: [.command, .shift]))
        XCTAssertEqual(stroke(claude, .toggleFastMode), KeyStroke(.f, modifiers: [.command, .option]))
        XCTAssertEqual(stroke(claude, .openPermissionModeMenu), KeyStroke(.m, modifiers: [.command, .shift]))
        XCTAssertEqual(stroke(claude, .openTerminal), KeyStroke(.j, modifiers: [.command]))
    }

    func testClaudeQueueFollowUpIsUnsupported() {
        let support = claude.support(for: .queueFollowUp)
        XCTAssertNil(support.recipe)
        XCTAssertFalse(support.note?.isEmpty ?? true)
    }

    // MARK: - Generic

    func testGenericProfileOnlyEmitsNavigationAndConfirm() {
        XCTAssertEqual(stroke(generic, .navigateUp), .key(.upArrow))
        XCTAssertEqual(stroke(generic, .submit), .key(.enter))
        XCTAssertEqual(stroke(generic, .cancelOrInterrupt), .key(.escape))

        for action in AgentAction.allCases where action != .navigateUp && action != .navigateDown
            && action != .navigateLeft && action != .navigateRight
            && action != .submit && action != .cancelOrInterrupt {
            XCTAssertNil(generic.support(for: action).recipe, "\(action) must not fire from the generic profile")
        }
    }

    // MARK: - Overrides (makes class C actions usable)

    func testOverrideMakesAnUnsupportedActionWork() {
        let bound = CodexDesktopAdapter(overrides: [.toggleFastMode: KeyStroke(.f, modifiers: [.control, .option])])
        XCTAssertEqual(stroke(bound, .toggleFastMode), KeyStroke(.f, modifiers: [.control, .option]))
        XCTAssertTrue(bound.support(for: .toggleFastMode).recipe?.requiresExplicitProfile ?? false)
    }

    func testCatalogAppliesOverrides() {
        let adapter = AdapterCatalog.adapter(
            for: .codex,
            overrides: [.forkThread: KeyStroke(.t, modifiers: [.command, .shift])]
        )
        XCTAssertEqual(stroke(adapter, .forkThread), KeyStroke(.t, modifiers: [.command, .shift]))
        XCTAssertNil(AdapterCatalog.adapter(for: .codex).support(for: .forkThread).recipe)
    }

    // MARK: - Risk classification

    func testToolActionsRequireAnExplicitProfile() {
        for action in [AgentAction.newChat, .openTerminal, .openModelPicker, .inspectChanges] {
            XCTAssertTrue(
                codex.support(for: action).recipe?.requiresExplicitProfile ?? false,
                "\(action) must not be sendable from the generic profile"
            )
        }
    }
}
