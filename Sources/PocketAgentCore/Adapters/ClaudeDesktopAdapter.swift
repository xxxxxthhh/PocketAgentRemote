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

    /// **Only what has been verified for Claude.**
    ///
    /// Every row here has its binding confirmed twice — the running app's own menu (via
    /// `Tools/dump-menu-accelerators.swift`) and the shortcut table inside Claude's bundle. Actions
    /// whose binding comes from the web build only stay out, because offering a row on an unverified
    /// key already went wrong once (see `openModelPicker` below).
    ///
    /// Two of these three are **context-dependent**: `Show Changes` and `Show Terminal` are `[OFF]`
    /// in Claude's own menu while a plain chat is open, because they belong to a Code session.
    /// Sending them there is harmless — Claude ignores it — but it will look like "nothing
    /// happened", so the app logs the injected keys to make that distinguishable from a failure on
    /// our side.
    public var menuItems: [AdapterMenuItem] {
        [
            // Labels are Claude's own wording, so the menu reads like Claude's menu.
            // Evidence for each binding is recorded in `docs/research-claude-commands-verified.md`.
            AdapterMenuItem(action: .newChat, title: "新建对话"),          // File > New Chat   ⌘N
            AdapterMenuItem(action: .inspectChanges, title: "显示变更"),   // View > Show Changes ⌘⇧D
            AdapterMenuItem(action: .openTerminal, title: "显示终端"),     // View > Show Terminal ⌘J
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
        case .deleteBackward: return .supported(Recipe.held(.delete))

        // `enter` submit is confirmed in the chat surface but **not** verified in the Code surface
        // (research §6 caveat 2). Kept as the default, with the caveat recorded in spec v0.3 U-series.
        case .submit: return .supported(Recipe.press(.enter))
        case .cancelOrInterrupt: return .supported(Recipe.press(.escape))

        // Verified against the running app's menu on 2026-09-16: `View > Show Changes` is ⌘⇧D and
        // `View > Show Terminal` is ⌘J (both currently [OFF] in a plain chat, by the app's own rule).
        case .inspectChanges: return .supported(Recipe.tool(.d, [.command, .shift]))   // toggleDiff
        case .openTerminal: return .supported(Recipe.tool(.j, [.command]))             // Show Terminal

        // `openModelPicker` is **deliberately unsupported**: Claude's bundle table says
        // `openModelMenu = ⌘⇧I`, a user reported that choosing "切换模型" opened an *anonymous
        // conversation*, and my own attempt to reproduce it saw no effect at all. The conflict is
        // unresolved in both directions, so the row is withheld — an unverified key that might
        // silently create an incognito chat is not worth the feature. Full write-up:
        // `docs/research-claude-commands-verified.md` §3. Switching models in Claude goes through
        // the `⌘K` command palette (`b.right`) instead.
        case .openModelPicker:
            return .unsupported("⌘⇧I conflicts with incognito chat and could not be reproduced; use the ⌘K palette instead")

        case .toggleFastMode: return .supported(Recipe.tool(.f, [.command, .option]))  // toggleFastMode
        case .openPermissionModeMenu: return .supported(Recipe.tool(.m, [.command, .shift]))  // openModeMenu

        // Verified against the *live* menu on 2026-09-16 with `Tools/dump-menu-accelerators.swift`:
        // `File > New Chat` is ⌘N. The earlier note that this surface was unverified was simply
        // stale, and it mattered: the menu's first row is 新建会话, so without this mapping the
        // menu built for Claude silently lost its most useful row.
        case .newChat: return .supported(Recipe.tool(.n, [.command]))

        case .queueFollowUp:
            return .unsupported("Claude desktop has no queue action; ⌘⌥Enter forks a session instead")

        // Cross-app: sends nothing to Claude, so it works on every profile (see CodexDesktopAdapter).
        case .focusOtherAgent: return .supported(Recipe.system(.activateAgentApp))
        case .openMenu: return .supported(Recipe.system(.openMenu, risk: .normal))
        case .openAppSwitcher: return .supported(Recipe.system(.openAppSwitcher, risk: .normal))

        case .archiveChat, .pinThread, .forkThread, .openSideChat,
             .goToRecentChat1, .goToRecentChat2, .goToRecentChat3,
             .goToRecentChat4, .goToRecentChat5, .goToRecentChat6,
             .nextChatNeedingAttention:
            return .unsupported("not part of the researched Claude desktop surface — bind a key and set actionKeyOverrides")
        }
    }
}
