import Foundation

/// One row of the on-screen menu.
public struct MenuItem: Equatable, Sendable {
    /// The action to run when this row is chosen.
    public var action: AgentAction
    /// What the row says. Kept separate from the action name so the menu reads like a user manual
    /// rather than a list of identifiers.
    public var title: String

    public init(action: AgentAction, title: String) {
        self.action = action
        self.title = title
    }
}

/// The on-screen menu: which rows exist, and which one is selected.
///
/// ## Why this is a model and not just a view
///
/// The controller's inputs never reach the overlay as real keyboard events — the overlay is our own
/// drawing, not a focused window, and the buttons are injected by this very process. So the menu
/// cannot use AppKit's event handling; the gesture layer has to drive it directly. Keeping the
/// selection arithmetic here (rather than in the view) is also what makes "wrap around at the ends"
/// and "what does A do" testable without rendering anything.
///
/// ## What it deliberately is not
///
/// Single-level, and only rows the active adapter can actually perform. A menu that lists commands
/// the app cannot run would be worse than no menu: the user would press A and nothing would happen,
/// with no explanation on screen.
public struct AgentMenu {
    /// The app the menu was opened for. Held so a choice can be refused when focus has moved on.
    public let bundleID: String?
    /// Display name for the header — "Codex", "Claude", or the app's own name.
    public let title: String
    public private(set) var items: [MenuItem]
    public private(set) var selection: Int

    public init(bundleID: String?, title: String, items: [MenuItem], selection: Int = 0) {
        self.bundleID = bundleID
        self.title = title
        self.items = items
        self.selection = items.isEmpty ? 0 : min(max(selection, 0), items.count - 1)
    }

    /// The row to run, or nil when the menu has nothing to offer.
    public var selectedItem: MenuItem? {
        guard items.indices.contains(selection) else { return nil }
        return items[selection]
    }

    public var isEmpty: Bool { items.isEmpty }

    /// The hint line along the bottom, so the controls never have to be remembered.
    public var hint: String { "↑↓ 选择    A 执行    B 关闭" }

    // MARK: - Navigation

    /// Moves the selection, wrapping at both ends.
    ///
    /// Wrapping rather than clamping: with three or four rows, "down from the last one" meaning
    /// "back to the top" is one gesture instead of two, and the user can see where they are.
    public mutating func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        selection = ((selection + offset) % count + count) % count
    }

    public mutating func moveUp() { moveSelection(by: -1) }
    public mutating func moveDown() { moveSelection(by: 1) }
}

/// Builds the menu for whatever is in front.
///
/// The rows come from the adapter of the profile in force, filtered to actions it can actually
/// perform *without* extra setup. That filter is the point: `toggleFastMode` exists on Claude but
/// ships no key binding on Codex, and a row that silently does nothing when chosen is worse than a
/// row that is not there.
public enum AgentMenuBuilder {
    /// The order rows appear in, most useful first, with the labels the menu shows.
    ///
    /// Kept short on purpose (first version: three rows). The B-layer direct bindings stay direct —
    /// the menu is for actions that are worth a visible confirmation, not a replacement for muscle
    /// memory.
    public static let catalog: [MenuItem] = [
        MenuItem(action: .newChat, title: "新建会话"),
        MenuItem(action: .inspectChanges, title: "查看变更"),
        MenuItem(action: .openTerminal, title: "打开终端"),
        MenuItem(action: .openModelPicker, title: "切换模型"),
        MenuItem(action: .archiveChat, title: "归档会话"),
    ]

    /// The menu for the current frontmost app, or nil when it is not one of the agents.
    ///
    /// Nil (rather than an empty menu) is the honest answer for "you are in a browser": there is no
    /// agent to act on, so there is nothing to show.
    public static func menu(
        for config: AppConfig,
        frontmostBundleID: String?,
        frontmostName: String? = nil,
        catalog: [MenuItem] = AgentMenuBuilder.catalog
    ) -> AgentMenu? {
        let profile = config.resolvedProfile(frontmostBundleID: frontmostBundleID)
        guard profile != .genericTerminal else { return nil }

        let adapter = AdapterCatalog.adapter(for: profile, overrides: config.overrides)
        let rows = catalog.filter { item in
            // An action with no recipe (and no override) cannot run; leave it out instead of
            // offering a row that does nothing.
            adapter.support(for: item.action).recipe != nil
        }
        guard !rows.isEmpty else { return nil }

        let name = config.agentPair.name(for: frontmostBundleID ?? "")
            ?? frontmostName
            ?? profile.rawValue
        return AgentMenu(bundleID: frontmostBundleID, title: name, items: rows)
    }
}

/// What happened to a controller event handed to the menu.
///
/// Returned rather than inferred so the engine and the app can react (redraw, log, dismiss) without
/// re-deriving the menu's internal state.
public enum MenuEventResult: Equatable, Sendable {
    /// No menu was open; the event was not ours.
    case ignored
    /// The menu took the event (selection moved, or a key it owns was swallowed).
    case handled
    case executed(AgentAction)
    case dismissed
    /// Refused for a reason worth telling the user, e.g. focus moved.
    case refused(String)
}
