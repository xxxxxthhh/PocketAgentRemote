import Foundation

/// Tool-independent semantic actions. The whole point of the design is that hardware layout and
/// gesture recognition never mention a specific tool; only the adapter layer does (spec §5).
///
/// The vocabulary was re-cut in v0.3 to match the action set Codex itself considers worth binding
/// to physical keys (the Codex Micro keycap inventory), because that set is verified to exist in
/// the desktop app rather than guessed from the command registry.
public enum AgentAction: String, Codable, CaseIterable, Sendable {
    // MARK: Navigation
    case navigateUp
    case navigateDown
    case navigateLeft
    case navigateRight

    // MARK: Composer / turn control
    //
    // `submit` doubles as **approve** and `cancelOrInterrupt` as **reject**: Codex and Claude both
    // use Enter to approve and Escape to decline, and the approval UI keeps the final say (spec
    // §17). We deliberately do NOT add separate `approve`/`reject` actions — they would be the very
    // same keystroke, and two actions competing for one key is exactly how "switch permission mode"
    // silently turns into "approve this command".
    case submit
    case cancelOrInterrupt
    case queueFollowUp

    // MARK: Threads and workspace
    case newChat
    case archiveChat
    case pinThread
    case forkThread
    case openSideChat
    case openTerminal

    // MARK: Thread switching
    //
    // Codex binds "Go to recent chat N" to ⌥⌘1…⌥⌘6 — the closest thing the desktop app has to the
    // Codex Micro's six agent keys, where each key jumps to one agent's chat. Six separate actions
    // rather than an indexed one, because `AgentAction` is a plain string enum used as a
    // configuration key.
    case goToRecentChat1
    case goToRecentChat2
    case goToRecentChat3
    case goToRecentChat4
    case goToRecentChat5
    case goToRecentChat6

    /// Jumps to the chat that wants you: waiting on approval, or holding unread output. This is the
    /// single most Micro-like command in the whole shortcut list.
    case nextChatNeedingAttention

    // MARK: Modes and panels
    case openModelPicker
    case inspectChanges
    case toggleFastMode
    /// Opens the permission-mode menu. **Not a cycle**: neither the Codex desktop app (which has no
    /// permission-mode action at all) nor Claude (menu plus a numeric choice) can cycle modes, so
    /// the v0.1 name `cyclePermissionMode` was simply wrong. Adapters must report it as
    /// unsupported on Codex rather than silently substituting an approval.
    case openPermissionModeMenu

    // MARK: Cross-app
    //
    // The one action that does **not** describe keystrokes for a tool. "Put the other agent in
    // front" is a system effect: it is what lets the user jump between Codex and Claude without
    // touching the keyboard, and it is precisely the situation where no keystroke may be sent —
    // the frontmost app is often a browser or a terminal, where every tool-specific chord is
    // (correctly) blocked by the guard while this one must still work.
    //
    // Hence: no adapter can express it as a recipe, `ActionDispatcher` handles it directly, and it
    // is exempt from the allowlist for the same reason a modifier-only stroke is (see
    // `ActionDispatcher.dispatch`).
    case focusOtherAgent

    // MARK: Menu
    //
    // Opens the on-screen menu, which is how the gesture set stops being the limit on what the
    // controller can reach: the high-frequency actions keep their direct gestures, and everything
    // that would need a new chord moves into a list the user can see. Like `focusOtherAgent` it
    // carries no keystroke of its own — pressing it draws an overlay and nothing else.
    case openMenu

    // MARK: App switcher
    //
    // Opens the controller's own ⌘⇥: a strip of every running app, ←/→ to pick, A to switch. It
    // replaced `focusOtherAgent` as the default for holding B (2026-09-18): the two-app toggle was a
    // special case of "put some other app in front", and a visible strip lets the user reach any app
    // — a browser, a terminal — not just the pair named in config. The system switcher itself is not
    // an option: a synthesised ⌘⇥ is ineffective on this machine (see `AppActivator`), and it needs
    // ⌘ held for as long as it is open, whereas this strip stays up after B is released.
    case openAppSwitcher
}

/// How risky an action is to fire (spec §10.5). Drives the guard rules in spec §12/§17.
public enum ActionRisk: String, Codable, Sendable, Comparable {
    case navigation
    case normal
    case macro
    case sensitive

    private var order: Int {
        switch self {
        case .navigation: return 0
        case .normal: return 1
        case .macro: return 2
        case .sensitive: return 3
        }
    }

    public static func < (lhs: ActionRisk, rhs: ActionRisk) -> Bool { lhs.order < rhs.order }
}

/// Which tool profile is active. Explicit in the MVP — never inferred (spec §6.4, §23.7).
public enum ToolProfile: String, Codable, CaseIterable, Sendable {
    case genericTerminal
    case codex
    case claudeCode
}

/// One step of an output recipe.
public enum OutputStep: Equatable, Sendable {
    case keyDown(KeyStroke)
    case keyUp(KeyStroke)
    case keyPress(KeyStroke)
    case delay(milliseconds: Int)
    case text(String)
}

/// What running a recipe actually does.
///
/// Almost everything a recipe describes is a keystroke. `activateAgentApp` is the exception, and it
/// is a separate case rather than "a recipe with no steps" because those two things must not be
/// confused: an empty keystroke recipe is a bug, while focusing an app is a deliberate system effect
/// that carries no keystroke at all. `ActionDispatcher` branches on this before the keystroke path.
public enum RecipeEffect: Equatable, Sendable {
    case keystroke
    /// Bring the other configured agent (Codex ⇄ Claude) to the front. No keystroke is emitted.
    case activateAgentApp
    /// Draw the on-screen menu for the app in front. No keystroke is emitted.
    case openMenu
    /// Draw the strip of running apps. No keystroke is emitted; choosing a row activates an app.
    case openAppSwitcher
}

/// A complete, pre-validated recipe for one semantic action (spec §10.5, extended with the
/// key-repeat policy from spec §19).
public struct OutputRecipe: Equatable, Sendable {
    public var steps: [OutputStep]
    public var risk: ActionRisk
    /// True when the recipe may only run while an explicit tool profile — not `genericTerminal` —
    /// is selected (spec §12).
    public var requiresExplicitProfile: Bool
    /// True when holding the input may repeat this recipe. Navigation only.
    public var allowsRepeat: Bool
    /// What the recipe does. Keystrokes for everything except the cross-app focus action.
    public var effect: RecipeEffect

    public init(
        steps: [OutputStep],
        risk: ActionRisk,
        requiresExplicitProfile: Bool = false,
        allowsRepeat: Bool = false,
        effect: RecipeEffect = .keystroke
    ) {
        self.steps = steps
        self.risk = risk
        self.requiresExplicitProfile = requiresExplicitProfile
        self.allowsRepeat = allowsRepeat
        self.effect = effect
    }
}

public extension AgentAction {
    /// Spec §19: only the four navigation actions may repeat while the input is held.
    var allowsRepeat: Bool {
        switch self {
        case .navigateUp, .navigateDown, .navigateLeft, .navigateRight: return true
        default: return false
        }
    }

    /// The effect this action has when it runs, independent of any tool profile.
    ///
    /// Only `focusOtherAgent` is a system effect; everything else is a keystroke aimed at the
    /// frontmost application.
    var recipeEffect: RecipeEffect {
        switch self {
        case .focusOtherAgent: return .activateAgentApp
        case .openMenu: return .openMenu
        case .openAppSwitcher: return .openAppSwitcher
        default: return .keystroke
        }
    }

    var risk: ActionRisk {
        switch self {
        case .navigateUp, .navigateDown, .navigateLeft, .navigateRight: return .navigation
        case .submit, .cancelOrInterrupt: return .normal
        case .queueFollowUp, .openModelPicker, .inspectChanges, .toggleFastMode,
             .openPermissionModeMenu, .newChat, .archiveChat, .pinThread,
             .forkThread, .openSideChat, .openTerminal,
             .goToRecentChat1, .goToRecentChat2, .goToRecentChat3,
             .goToRecentChat4, .goToRecentChat5, .goToRecentChat6,
             .nextChatNeedingAttention:
            return .sensitive
        case .focusOtherAgent: return .sensitive
        // Opening a menu touches no application: it only draws our own overlay.
        case .openMenu, .openAppSwitcher: return .normal
        }
    }
}
