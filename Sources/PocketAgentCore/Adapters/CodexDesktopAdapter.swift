import Foundation

/// Codex desktop app (`com.openai.codex`).
///
/// Every key below was verified against the app's own command registry rather than assumed —
/// see `docs/research-codex-micro-mapping.md` §2 and `docs/spec-v0.3.md` §6.2 — **except where the
/// live menu disagreed**, which happened once and is worth remembering:
///
/// `inspectChanges` is `⌥⌘B` (`View > Toggle Review Panel`, read from the running app with
/// `Tools/dump-menu-accelerators.swift`), **not** `⌃⇧G`. The registry entry `openReviewTab` does
/// carry `Ctrl+Shift+G`, but that command had no visible effect in the running app while the menu
/// item works. A static registry is not the same thing as a live binding.
///
/// Two entries are deliberately **unsupported**, and the notes say why:
/// - `openPermissionModeMenu`: the Codex desktop app has no permission-mode action at all (its
///   registry only has `approval.approve` / `approval.decline`). Substituting an approval here
///   would turn "switch mode" into "approve this command".
/// - `toggleFastMode`: the command exists but ships **no default accelerator**, and it is not in
///   the ⌘K command palette either. It needs a one-time user key binding, which the config can
///   supply through `actionKeyOverrides`.
public struct CodexDesktopAdapter: ToolAdapter {
    public let profile: ToolProfile = .codex

    /// Keys the user has bound manually in Codex's own Settings → Keyboard Shortcuts.
    private let overrides: [AgentAction: KeyStroke]

    public init(overrides: [AgentAction: KeyStroke] = [:]) {
        self.overrides = overrides
    }

    /// Verified against the live menu / command registry (see `docs/codex-shortcuts.md`).
    public var menuItems: [AdapterMenuItem] {
        [
            AdapterMenuItem(action: .newChat, title: "新建会话"),
            AdapterMenuItem(action: .inspectChanges, title: "查看变更"),
            AdapterMenuItem(action: .openTerminal, title: "打开终端"),
            AdapterMenuItem(action: .openModelPicker, title: "切换模型"),
            AdapterMenuItem(action: .archiveChat, title: "归档会话"),
        ]
    }

    public func support(for action: AgentAction) -> ActionSupport {
        if let stroke = overrides[action] {
            return .supported(OutputRecipe(
                steps: [.keyPress(stroke)],
                risk: action.risk,
                requiresExplicitProfile: action.risk >= .sensitive,
                allowsRepeat: action.allowsRepeat
            ))
        }

        switch action {
        case .navigateUp: return .supported(Recipe.held(.upArrow))
        case .navigateDown: return .supported(Recipe.held(.downArrow))
        case .navigateLeft: return .supported(Recipe.held(.leftArrow))
        case .navigateRight: return .supported(Recipe.held(.rightArrow))

        // approval.approve = Enter, approval.decline = Escape (registry)
        case .submit: return .supported(Recipe.press(.enter))
        case .cancelOrInterrupt: return .supported(Recipe.press(.escape))

        // Reached through the same Enter path while a turn is running, gated by the app's own
        // `followUpQueueMode` setting. `composer.queue` is a real command but has no default key.
        case .queueFollowUp: return .supported(Recipe.press(.enter))

        case .newChat: return .supported(Recipe.tool(.n, [.command]))
        case .openTerminal: return .supported(Recipe.tool(.grave, [.control]))
        case .openModelPicker: return .supported(Recipe.tool(.m, [.control, .shift]))
        case .inspectChanges: return .supported(Recipe.tool(.b, [.command, .option]))
        case .archiveChat: return .supported(Recipe.tool(.a, [.command, .shift]))
        case .pinThread: return .supported(Recipe.tool(.p, [.command, .option]))
        case .openSideChat: return .supported(Recipe.tool(.s, [.command, .option]))

        // "Go to recent chat N" — the desktop app's answer to the Codex Micro's six agent keys.
        case .goToRecentChat1: return .supported(Recipe.tool(.digit1, [.command, .option]))
        case .goToRecentChat2: return .supported(Recipe.tool(.digit2, [.command, .option]))
        case .goToRecentChat3: return .supported(Recipe.tool(.digit3, [.command, .option]))
        case .goToRecentChat4: return .supported(Recipe.tool(.digit4, [.command, .option]))
        case .goToRecentChat5: return .supported(Recipe.tool(.digit5, [.command, .option]))
        case .goToRecentChat6: return .supported(Recipe.tool(.digit6, [.command, .option]))
        case .nextChatNeedingAttention: return .supported(Recipe.tool(.a, [.command, .option]))

        // Cross-app: sends nothing to Codex. Supported here so a profile is never the reason the
        // user's "switch agent" button did nothing.
        case .focusOtherAgent: return .supported(Recipe.system(.activateAgentApp))
        case .openMenu: return .supported(Recipe.system(.openMenu, risk: .normal))
        case .openAppSwitcher: return .supported(Recipe.system(.openAppSwitcher, risk: .normal))

        case .openPermissionModeMenu:
            return .unsupported("Codex desktop has no permission-mode action (only approve/decline)")

        case .toggleFastMode:
            return .unsupported("no default accelerator and not in the command palette — bind a key in Codex, then set actionKeyOverrides")

        case .forkThread:
            return .unsupported("no default accelerator for split/fork — bind a key in Codex, then set actionKeyOverrides")
        }
    }
}
