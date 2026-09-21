import Foundation

/// The safe default profile: plain arrow keys, Enter and Escape, nothing else.
///
/// This exists so that a user who has not picked a tool profile still gets predictable navigation
/// instead of nothing, and so that no tool-specific chord can fire by accident (spec §6.1, §12).
public struct GenericTerminalAdapter: ToolAdapter {
    public let profile: ToolProfile = .genericTerminal

    public init() {}

    /// No menu for an unknown app: there is no agent to act on, so there is nothing to offer.
    public var menuItems: [AdapterMenuItem] { [] }

    public func support(for action: AgentAction) -> ActionSupport {
        switch action {
        case .navigateUp: return .supported(Recipe.held(.upArrow))
        case .navigateDown: return .supported(Recipe.held(.downArrow))
        case .navigateLeft: return .supported(Recipe.held(.leftArrow))
        case .navigateRight: return .supported(Recipe.held(.rightArrow))
        case .deleteBackward: return .supported(Recipe.held(.delete))
        case .submit: return .supported(Recipe.press(.enter))
        case .cancelOrInterrupt: return .supported(Recipe.press(.escape))
        // Not keystrokes, so the "no tool chord from the generic profile" rule does not apply.
        case .focusOtherAgent: return .supported(Recipe.system(.activateAgentApp))
        case .openMenu: return .supported(Recipe.system(.openMenu, risk: .normal))
        case .openAppSwitcher: return .supported(Recipe.system(.openAppSwitcher, risk: .normal))
        default:
            return .unsupported("tool-specific action — select a profile first")
        }
    }
}

public enum AdapterCatalog {
    /// Builds the adapter for a profile, applying any per-action key overrides from config.
    public static func adapter(
        for profile: ToolProfile,
        overrides: [AgentAction: KeyStroke] = [:]
    ) -> ToolAdapter {
        switch profile {
        case .genericTerminal: return GenericTerminalAdapter()
        case .codex: return CodexDesktopAdapter(overrides: overrides)
        case .claudeCode: return ClaudeDesktopAdapter(overrides: overrides)
        }
    }
}
