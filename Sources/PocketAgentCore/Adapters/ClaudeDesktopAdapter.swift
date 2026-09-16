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
    /// Deliberately short. The other actions this adapter can name — terminal, changes, model picker,
    /// permission mode — are marked 【静态】 in `docs/research-claude-desktop.md`, i.e. read out of
    /// the web build's shortcut table rather than observed on the desktop app, and one of them was
    /// positively wrong: `⌘⇧I` is **incognito chat**, not the model menu (that is `⌘⇧.`). Offering a
    /// row on an unverified binding sent the wrong command, so an unverified action stays out of the
    /// menu until someone watches it work.
    public var menuItems: [AdapterMenuItem] {
        [
            // File > New Chat = ⌘N, read from the running app's menu on 2026-09-16.
            AdapterMenuItem(action: .newChat, title: "新建对话"),
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

        // `enter` submit is confirmed in the chat surface but **not** verified in the Code surface
        // (research §6 caveat 2). Kept as the default, with the caveat recorded in spec v0.3 U-series.
        case .submit: return .supported(Recipe.press(.enter))
        case .cancelOrInterrupt: return .supported(Recipe.press(.escape))

        // Verified against the running app's menu on 2026-09-16: `View > Show Changes` is ⌘⇧D and
        // `View > Show Terminal` is ⌘J (both currently [OFF] in a plain chat, by the app's own rule).
        case .inspectChanges: return .supported(Recipe.tool(.d, [.command, .shift]))   // toggleDiff
        case .openTerminal: return .supported(Recipe.tool(.j, [.command]))             // Show Terminal

        // `openModelPicker` is **deliberately unsupported**, and unsupported for a reason worth
        // recording: this adapter used to send ⌘⇧I, taken from the web build's shortcut table. On the
        // desktop app ⌘⇧I is *new incognito chat* — so "切换模型" silently opened an anonymous
        // conversation. The model menu's real accelerator is not in the app's menu at all
        // (`model_selector` = ⌘⇧. in the web build), so it needs to be observed on the desktop app
        // before this can be mapped. Until then: no recipe, no menu row.
        case .openModelPicker:
            return .unsupported("⌘⇧I turned out to be new incognito chat; the desktop model menu needs verifying first")

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

        case .archiveChat, .pinThread, .forkThread, .openSideChat,
             .goToRecentChat1, .goToRecentChat2, .goToRecentChat3,
             .goToRecentChat4, .goToRecentChat5, .goToRecentChat6,
             .nextChatNeedingAttention:
            return .unsupported("not part of the researched Claude desktop surface — bind a key and set actionKeyOverrides")
        }
    }
}
