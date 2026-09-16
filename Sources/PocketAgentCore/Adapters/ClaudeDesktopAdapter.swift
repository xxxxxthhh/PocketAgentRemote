import Foundation

/// Claude desktop app (`com.anthropic.claudefordesktop`).
///
/// Keys come from `docs/research-claude-desktop.md` §6 (the app's own `ion-dist` shortcut table
/// plus its menu). Where that research could not confirm something, this adapter says so instead of
/// guessing — the Claude side was not re-verified in the Codex Micro pass, so most of the
/// thread/workspace actions are simply absent rather than invented.
public struct ClaudeDesktopAdapter: ToolAdapter {
    public let profile: ToolProfile = .claudeCode

    private let overrides: [AgentAction: KeyStroke]

    public init(overrides: [AgentAction: KeyStroke] = [:]) {
        self.overrides = overrides
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

        // `enter` submit is confirmed in the chat surface but **not** verified in the Code surface
        // (research §6 caveat 2). Kept as the default, with the caveat recorded in spec v0.3 U-series.
        case .submit: return .supported(Recipe.press(.enter))
        case .cancelOrInterrupt: return .supported(Recipe.press(.escape))

        case .inspectChanges: return .supported(Recipe.tool(.d, [.command, .shift]))   // toggleDiff
        case .openModelPicker: return .supported(Recipe.tool(.i, [.command, .shift]))  // openModelMenu
        case .toggleFastMode: return .supported(Recipe.tool(.f, [.command, .option]))  // toggleFastMode
        case .openPermissionModeMenu: return .supported(Recipe.tool(.m, [.command, .shift]))  // openModeMenu
        case .openTerminal: return .supported(Recipe.tool(.j, [.command]))             // Show Terminal

        case .queueFollowUp:
            return .unsupported("Claude desktop has no queue action; ⌘⌥Enter forks a session instead")

        // Cross-app: sends nothing to Claude, so it works on every profile (see CodexDesktopAdapter).
        case .focusOtherAgent: return .supported(Recipe.system(.activateAgentApp))

        case .newChat, .archiveChat, .pinThread, .forkThread, .openSideChat,
             .goToRecentChat1, .goToRecentChat2, .goToRecentChat3,
             .goToRecentChat4, .goToRecentChat5, .goToRecentChat6,
             .nextChatNeedingAttention:
            return .unsupported("not part of the researched Claude desktop surface — bind a key and set actionKeyOverrides")
        }
    }
}
