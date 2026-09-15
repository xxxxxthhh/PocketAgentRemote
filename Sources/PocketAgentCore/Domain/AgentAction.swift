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

    public init(
        steps: [OutputStep],
        risk: ActionRisk,
        requiresExplicitProfile: Bool = false,
        allowsRepeat: Bool = false
    ) {
        self.steps = steps
        self.risk = risk
        self.requiresExplicitProfile = requiresExplicitProfile
        self.allowsRepeat = allowsRepeat
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
        }
    }
}
