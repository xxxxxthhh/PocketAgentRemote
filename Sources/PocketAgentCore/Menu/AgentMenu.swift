import Foundation

/// What choosing a menu row does.
///
/// Two kinds, because the two menus do different things: the command menu runs a semantic action
/// through the normal adapter/guard pipeline, while the app switcher raises an application and
/// sends it nothing. Keeping them as one enum lets the dispatcher own a single "menu session" for
/// both, so the engine's "a menu is up, it owns the controller" rule has one state to read.
public enum MenuChoice: Equatable, Sendable {
    case run(AgentAction)
    case activateApp(bundleID: String)
    /// Turn to a second page instead of doing anything (the dial's 「更多」 slot).
    ///
    /// The page travels *inside* the row, so the builder defines the whole tree up front and the
    /// dispatcher only swaps which page is showing — no navigation stack, and no second builder
    /// call at page-turn time. Exactly one level deep: the dial builder is where that is enforced,
    /// because it is the layer that knows what a page means.
    case openSubmenu(title: String, items: [MenuItem])
    /// Press an item of the frontmost app's own menu bar through Accessibility (G4 通用菜单).
    /// `id` is the entry's id within the open `AppMenuSession` (what gets pressed); `path` is the
    /// title path, kept for display, logs and favourites only.
    case pressAppMenuItem(id: Int, path: [String])
}

/// One row of the on-screen menu.
public struct MenuItem: Equatable, Sendable {
    public var choice: MenuChoice
    /// What the row says. Kept separate from the action name so the menu reads like a user manual
    /// rather than a list of identifiers.
    public var title: String

    public init(choice: MenuChoice, title: String) {
        self.choice = choice
        self.title = title
    }

    /// A command-menu row.
    public init(action: AgentAction, title: String) {
        self.init(choice: .run(action), title: title)
    }

    /// The action this row runs; nil for an app-switcher row.
    public var action: AgentAction? {
        if case .run(let action) = choice { return action }
        return nil
    }

    /// The app this row activates; nil for a command row.
    public var appBundleID: String? {
        if case .activateApp(let bundleID) = choice { return bundleID }
        return nil
    }

    /// The page this row turns to; nil for every row that does something.
    public var submenu: (title: String, items: [MenuItem])? {
        if case .openSubmenu(let title, let items) = choice { return (title, items) }
        return nil
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
    /// How the rows are arranged, which also decides which buttons move the selection.
    ///
    /// The command menu is a vertical list driven by ↑↓; the app switcher is a horizontal strip of
    /// icons driven by ←→, like ⌘⇥. The other axis is swallowed in each case, so the two menus feel
    /// different in the hand as well as on screen.
    public enum Layout: Equatable, Sendable {
        case list
        case strip
        /// Four slots at the four directions (G2 prototype, Codex only). Pressing a direction
        /// *selects* its slot; nothing runs until A. Unlike the other two it opens with **no**
        /// selection, so the chord that opened the menu cannot leave a slot armed.
        case dial
    }

    /// Which direction owns which slot, in item order. One source of truth for the model and for
    /// the overlay's label placement; a dial menu's `items` must be built in exactly this order.
    public static let dialSlotOrder: [PhysicalButton] = [.up, .left, .down, .right]

    /// The app the menu was opened for. Held so a choice can be refused when focus has moved on.
    public let bundleID: String?
    /// Display name for the header — "Codex", "Claude", or the app's own name.
    public let title: String
    public let layout: Layout
    public private(set) var items: [MenuItem]
    public private(set) var selection: Int
    /// Whether `selection` means anything yet.
    ///
    /// Always true for a list or a strip — both open on a row, which is what makes "hold B, press A"
    /// a one-gesture jump. A dial opens on **nothing**: its slots are the four directions, and the
    /// `B+←` that opened the menu would otherwise read as "select the left slot". Highlight state,
    /// so it is deliberately not part of `hasSameStructure`.
    public private(set) var hasSelection: Bool

    public init(
        bundleID: String?,
        title: String,
        items: [MenuItem],
        selection: Int = 0,
        layout: Layout = .list,
        hasSelection: Bool = true
    ) {
        self.bundleID = bundleID
        self.title = title
        self.layout = layout
        self.items = items
        self.selection = items.isEmpty ? 0 : min(max(selection, 0), items.count - 1)
        self.hasSelection = hasSelection
    }

    /// The row to run, or nil when nothing is selected (a dial before any direction is pressed) or
    /// the menu has nothing to offer.
    public var selectedItem: MenuItem? {
        guard hasSelection, items.indices.contains(selection) else { return nil }
        return items[selection]
    }

    public var isEmpty: Bool { items.isEmpty }

    /// The hint line along the bottom, so the controls never have to be remembered.
    public var hint: String {
        switch layout {
        case .list: return "↑↓ Select    A Run    B Close"
        case .strip: return "←→ Select    A Switch    B Close"
        case .dial: return "Arrows Select · A Run · B Close"
        }
    }

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

    /// Disarms the dial, so only a direction press since it last appeared can arm it.
    ///
    /// Used when coming back from the 「更多」 page: the dial then has exactly one safety rule —
    /// "armed only by a direction you just pressed" — instead of one rule for a fresh open and
    /// another for a return, which is the sort of difference a misfire hides in.
    public mutating func clearSelection() {
        guard layout == .dial else { return }
        hasSelection = false
        selection = 0
    }

    /// Selects the slot a direction owns. Returns false when this is not a dial, or that direction
    /// owns no slot — the caller then swallows the press rather than passing it on.
    ///
    /// Absolute, not relative: a dial is four fixed positions, so ↑ always means the top slot
    /// however the highlight got where it is.
    @discardableResult
    public mutating func selectSlot(_ button: PhysicalButton) -> Bool {
        guard layout == .dial,
              let index = Self.dialSlotOrder.firstIndex(of: button),
              items.indices.contains(index)
        else { return false }
        selection = index
        hasSelection = true
        return true
    }

    // MARK: - Structural identity

    /// Whether `other` draws the same menu, ignoring which row is highlighted.
    ///
    /// The overlay rebuilds its views from the menu's *contents*; only the highlight depends on the
    /// selection. So a caller that can tell "same structure, new selection" apart from "a different
    /// menu" can repaint the highlight instead of rebuilding every row — which is what makes moving
    /// through a 17-app strip free instead of 17 view rebuilds per press.
    ///
    /// The key is everything the drawing depends on: the app it was built for, the header, the
    /// layout, and the rows **in order**. `MenuItem` is `Equatable` on exactly `(choice, title)`, so
    /// comparing `items` already compares each row's action/target *and* its label — a menu with the
    /// same number of rows but a different action or a different title is correctly a different
    /// structure, and needs a rebuild. `selection` is deliberately excluded: it is the one thing that
    /// changes without changing what is drawn.
    public func hasSameStructure(as other: AgentMenu) -> Bool {
        bundleID == other.bundleID
            && title == other.title
            && layout == other.layout
            && items == other.items
    }
}

/// Builds the menu for whatever is in front.
///
/// The rows come from the adapter of the profile in force, filtered to actions it can actually
/// perform *without* extra setup. That filter is the point: `toggleFastMode` exists on Claude but
/// ships no key binding on Codex, and a row that silently does nothing when chosen is worse than a
/// row that is not there.
public enum AgentMenuBuilder {
    /// The menu for the current frontmost app, or nil when it is not one of the agents.
    ///
    /// Rows come from the **adapter**, which is the only layer that knows whether a binding was
    /// actually verified for that app. A fixed catalogue here (as an earlier version had) offered
    /// Claude a `切换模型` row backed by an unverified `⌘⇧I`, which on the desktop app is *new
    /// incognito chat* — so the row silently did the wrong thing.
    ///
    /// Nil (rather than an empty menu) is the honest answer for "you are in a browser" or for an app
    /// the adapter offers nothing for: there is nothing to show.
    public static func menu(
        for config: AppConfig,
        frontmostBundleID: String?,
        frontmostName: String? = nil,
        menuItems: ((ToolAdapter) -> [AdapterMenuItem])? = nil
    ) -> AgentMenu? {
        let profile = config.resolvedProfile(frontmostBundleID: frontmostBundleID)
        guard profile != .genericTerminal else { return nil }

        let adapter = AdapterCatalog.adapter(for: profile, overrides: config.overrides)
        let offered = (menuItems ?? { $0.menuItems })(adapter)
        let rows = offered
            // Defence in depth: even a listed row has to be runnable by this adapter right now.
            .filter { adapter.support(for: $0.action).recipe != nil }
            .map { MenuItem(action: $0.action, title: $0.title) }
        guard !rows.isEmpty else { return nil }

        let name = config.agentPair.name(for: frontmostBundleID ?? "")
            ?? frontmostName
            ?? profile.rawValue
        return AgentMenu(bundleID: frontmostBundleID, title: name, items: rows)
    }
}

/// Builds the Codex four-direction dial (G2 prototype).
///
/// Deliberately not a general mechanism: one profile, four fixed slots, one sub-page. The titles
/// come from `CodexDesktopAdapter.menuItems` so the dial and the list call the same action the same
/// thing, and every slot is checked against the adapter before the dial is offered at all.
public enum AgentDialBuilder {
    /// ↑ New Chat · ← Changes · ↓ Terminal · → More (Switch Model / Archive Chat).
    ///
    /// Nil for anything but Codex — that is what keeps Claude on the list — and nil when any one
    /// slot's action is unrunnable. A dial with a hole in it would break the promise that a
    /// direction always means the same thing, and the caller falls back to the list, which can drop
    /// a row without moving the others.
    public static func menu(
        for config: AppConfig,
        frontmostBundleID: String?,
        frontmostName: String? = nil
    ) -> AgentMenu? {
        guard config.resolvedProfile(frontmostBundleID: frontmostBundleID) == .codex else { return nil }
        let adapter = AdapterCatalog.adapter(for: .codex, overrides: config.overrides)

        func row(_ action: AgentAction) -> MenuItem? {
            guard adapter.support(for: action).recipe != nil,
                  let title = adapter.menuItems.first(where: { $0.action == action })?.title
            else { return nil }
            return MenuItem(action: action, title: title)
        }

        guard let newChat = row(.newChat),
              let changes = row(.inspectChanges),
              let terminal = row(.openTerminal),
              let model = row(.openModelPicker),
              let archive = row(.archiveChat)
        else { return nil }

        // One level only: the page's own rows are plain actions, never another page.
        let more = MenuItem(
            choice: .openSubmenu(title: AppMenuBuilder.morePageTitle, items: [model, archive]),
            title: AppMenuBuilder.morePageTitle
        )
        let name = config.agentPair.name(for: frontmostBundleID ?? "")
            ?? frontmostName
            ?? ToolProfile.codex.rawValue
        // Item order is `AgentMenu.dialSlotOrder`: up, left, down, right.
        return AgentMenu(
            bundleID: frontmostBundleID,
            title: name,
            items: [newChat, changes, terminal, more],
            layout: .dial,
            hasSelection: false
        )
    }
}

/// A running application, as the app switcher sees it. Plain data so Core needs no AppKit.
public struct RunningApp: Equatable, Sendable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Builds the app-switcher strip.
public enum AppSwitcherBuilder {
    /// The strip for `apps`, which must be in most-recently-used order with the frontmost app first.
    ///
    /// The highlight starts on the **second** app — the one used before this — so "hold B, press A"
    /// is a one-gesture jump back, exactly like a quick ⌘⇥. That is what keeps the old two-agent
    /// toggle working as a special case of the switcher.
    ///
    /// Nil with fewer than two apps: a strip with one icon offers nowhere to go, and showing it
    /// would only make the user wonder why → does nothing. The dispatcher reports the skip.
    public static func menu(apps: [RunningApp], frontmostBundleID: String?) -> AgentMenu? {
        guard apps.count >= 2 else { return nil }
        let rows = apps.map { MenuItem(choice: .activateApp(bundleID: $0.bundleID), title: $0.name) }
        return AgentMenu(bundleID: frontmostBundleID, title: "Switch App", items: rows, selection: 1, layout: .strip)
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
    /// An app-switcher row was chosen; the activation itself is reported through `onActivation`.
    case activated(bundleID: String)
    case dismissed
    /// Refused for a reason worth telling the user, e.g. focus moved.
    case refused(String)
}
