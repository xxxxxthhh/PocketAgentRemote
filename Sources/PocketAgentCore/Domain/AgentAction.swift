import Foundation

/// Tool-independent semantic actions. The whole point of the design is that hardware layout and
/// gesture recognition never mention a specific tool; only the adapter layer does (spec §5).
public enum AgentAction: String, Codable, CaseIterable, Sendable {
    case navigateUp
    case navigateDown
    case navigateLeft
    case navigateRight

    case submit
    case cancelOrInterrupt

    case queueFollowUp
    case cyclePermissionMode
    case toggleFastMode
    case openModelPicker
    case inspectChanges
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
        case .queueFollowUp, .cyclePermissionMode, .toggleFastMode,
             .openModelPicker, .inspectChanges: return .sensitive
        }
    }
}
