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
        // View > Toggle Review Panel — read from the live menu, not from the static registry.
        XCTAssertEqual(stroke(codex, .inspectChanges), KeyStroke(.b, modifiers: [.command, .option]))
        XCTAssertEqual(stroke(codex, .archiveChat), KeyStroke(.a, modifiers: [.command, .shift]))
        XCTAssertEqual(stroke(codex, .pinThread), KeyStroke(.p, modifiers: [.command, .option]))
        XCTAssertEqual(stroke(codex, .openSideChat), KeyStroke(.s, modifiers: [.command, .option]))
        XCTAssertEqual(stroke(codex, .queueFollowUp), .key(.enter))
    }

    func testInspectChangesMatchesTheLiveMenuNotTheRegistry() {
        // Regression guard for a real bug: the registry said `openReviewTab = Ctrl+Shift+G`, but
        // that combination did nothing in the running app while the View menu's
        // "Toggle Review Panel" (⌥⌘B) worked. Static registry ≠ live binding.
        let stroke = stroke(codex, .inspectChanges)
        XCTAssertEqual(stroke, KeyStroke(.b, modifiers: [.command, .option]))
        XCTAssertNotEqual(stroke, KeyStroke(.g, modifiers: [.control, .shift]))
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
        // `inspectChanges` (⌘⇧D) and `openTerminal` (⌘J) were confirmed against the running app's own
        // menu on 2026-09-16, cross-checking the research notes.
        XCTAssertEqual(stroke(claude, .inspectChanges), KeyStroke(.d, modifiers: [.command, .shift]))
        XCTAssertEqual(stroke(claude, .openTerminal), KeyStroke(.j, modifiers: [.command]))
        XCTAssertEqual(stroke(claude, .newChat), KeyStroke(.n, modifiers: [.command]))
        // Still 【static】 only — sendable, but not offered in the menu.
        XCTAssertEqual(stroke(claude, .toggleFastMode), KeyStroke(.f, modifiers: [.command, .option]))
        XCTAssertEqual(stroke(claude, .openPermissionModeMenu), KeyStroke(.m, modifiers: [.command, .shift]))
    }

    func testClaudeModelPickerIsNotBoundBecauseTheOldKeyWasIncognito() {
        // Regression: this adapter sent ⌘⇧I for "open model menu" (from the web build's shortcut
        // table). On the desktop app ⌘⇧I opens a **new incognito chat**, so the controller silently
        // started an anonymous conversation instead. No recipe until the real accelerator is
        // observed on the desktop app.
        let support = claude.support(for: .openModelPicker)
        XCTAssertNil(support.recipe, "⌘⇧I must not be sent for the model picker")
        XCTAssertFalse(support.note?.isEmpty ?? true, "and the reason must be recorded")
        XCTAssertNotEqual(stroke(claude, .openModelPicker), KeyStroke(.i, modifiers: [.command, .shift]))
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
        // Backspace is an editing key like the arrows: voice input lands in any app's composer.
        XCTAssertEqual(stroke(generic, .deleteBackward), .key(.delete))

        for action in AgentAction.allCases where action != .navigateUp && action != .navigateDown
            && action != .navigateLeft && action != .navigateRight
            && action != .submit && action != .cancelOrInterrupt && action != .deleteBackward
            && action != .focusOtherAgent && action != .openMenu && action != .openAppSwitcher {
            XCTAssertNil(generic.support(for: action).recipe, "\(action) must not fire from the generic profile")
        }
    }

    func testMenuAndAgentSwitchAreAvailableOnEveryProfileAndCarryNoKeystroke() {
        for adapter in [codex as ToolAdapter, claude, generic] {
            XCTAssertEqual(adapter.support(for: .openMenu).recipe?.effect, .openMenu)
            XCTAssertTrue(adapter.support(for: .openMenu).recipe?.steps.isEmpty ?? false)
            XCTAssertEqual(adapter.support(for: .openAppSwitcher).recipe?.effect, .openAppSwitcher)
            XCTAssertTrue(adapter.support(for: .openAppSwitcher).recipe?.steps.isEmpty ?? false)
        }
    }

    func testAgentSwitchIsAvailableOnEveryProfileAndCarriesNoKeystroke() {
        // The cross-app switch is the one action that must work from anywhere, including the
        // generic profile: its use case is "I am in a browser and want the agent back", which is
        // exactly when no tool profile is active. It also must never look like a keystroke, or the
        // guard's allowlist rule would apply to it — and the debug log would claim a key was sent.
        for adapter in [codex as ToolAdapter, claude, generic] {
            let support = adapter.support(for: .focusOtherAgent)
            XCTAssertEqual(support.recipe?.effect, .activateAgentApp)
            XCTAssertTrue(support.recipe?.steps.isEmpty ?? false)
            XCTAssertNil(support.recipe?.primaryStroke)
            XCTAssertFalse(support.recipe?.requiresExplicitProfile ?? true)
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
