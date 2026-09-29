import Foundation

/// Decides which of an app's own menu-bar items are worth putting on the overlay.
///
/// The reader hands us everything Accessibility exposes — for WeChat that is 105 nodes, most of
/// them either useless on a six-button controller (Undo, Paste, Minimize) or actively dangerous
/// (Quit, Close Window). A menu the user drives blind-ish with ↑↓ and one A press has to be short
/// *and* has to make a wrong press harmless, so the filtering is where most of this feature lives.
///
/// Pure functions on plain data: no Accessibility, no AppKit, so every rule below is testable
/// against a recorded menu dump.
public enum AppMenuFilter {
    /// The items to offer, in the app's own menu order.
    ///
    /// Order of the rules matters only for cost, not for the result — an entry has to pass all of
    /// them.
    ///
    /// The **Apple menu is not handled here**: `AccessibilityMenuReader` already drops it, in the
    /// read *and* in the press (`dropFirst` at both ends), so a path into it is not even
    /// addressable. A second positional rule on this side would delete whatever the reader handed
    /// over first — which is the app's own menu, About and Settings… included.
    public static func displayable(_ entries: [AppMenuEntry]) -> [AppMenuEntry] {
        // Every path that some other entry hangs below — i.e. the submenu parents. Pressing one
        // only opens a submenu, and a row that appears to do nothing is worse than no row.
        var parents: Set<[String]> = []
        for entry in entries {
            var prefix = entry.path
            while prefix.count > 1 {
                prefix.removeLast()
                parents.insert(prefix)
            }
        }

        return entries.filter { entry in
            guard entry.isEnabled else { return false }          // greyed out right now
            guard !entry.title.isEmpty else { return false }      // separators
            guard !parents.contains(entry.path) else { return false }
            guard !isNoise(entry) else { return false }
            guard !isDestructive(entry) else { return false }
            return true
        }
    }

    /// Items that work fine but have no business on a controller overlay.
    private static func isNoise(_ entry: AppMenuEntry) -> Bool {
        if entry.path.contains(where: { hiddenAnywhere.contains($0) || hiddenPrefixes.contains(where: $0.hasPrefix) }) {
            return true
        }
        if windowMenus.contains(entry.menuTitle),
           entry.path.contains(where: { component in
               windowLayout.contains(component) || windowLayoutPrefixes.contains(where: component.hasPrefix)
           }) {
            return true
        }
        if editMenus.contains(entry.menuTitle),
           entry.path.contains(where: { component in
               editNoise.contains(component) || editNoisePrefixes.contains(where: component.hasPrefix)
           }) {
            return true
        }
        return false
    }

    /// The safety rule: nothing that ends the session, throws work away, restarts or powers down
    /// something, or takes the window the user is looking at.
    ///
    /// The power words are here even though the reader never hands over the Apple menu, because an
    /// app's *own* menu has its own versions: Claude offers "Clear Cache and Restart" and "Delete
    /// Cowork VM Bundle and Restart…", and a bare "Restart Claude" would otherwise sail past a
    /// list that only knew about clear/delete.
    ///
    /// Matched as a **case-insensitive substring of every path component**, unlike the exact-match
    /// noise lists above. That deliberately over-blocks — "Block" contains "lock", "Reset Zoom"
    /// contains "reset" — because the cost of hiding a harmless row is one missing row, while the
    /// cost of showing a destructive one is the user's chat window closing under a blind A press.
    /// It is also why this check runs on favourites too: a collected favourite is still a title,
    /// and the user collecting it does not make `Quit` safe to sit under the highlight.
    private static func isDestructive(_ entry: AppMenuEntry) -> Bool {
        entry.path.contains { component in
            let lowered = component.lowercased()
            return destructive.contains { lowered.contains($0) }
        }
    }

    /// Dropped wherever they appear: the whole Help menu, the Services subtree (a second, slower
    /// app switcher and nothing a controller needs), and `Hide …`.
    ///
    /// Hiding is not destructive, but from an overlay it is a trap: the app the user is looking at
    /// vanishes and a six-button controller has no ⌘⇥ to bring it back. It needs the prefix list
    /// below as well as an exact title, because the real row is "Hide WeChat" — the app's own name
    /// is part of it — and the same prefix takes "Hide Others" and the sidebar/toolbar toggles,
    /// which are furniture by the same argument as Minimize.
    private static let hiddenAnywhere: Set<String> = ["Help", "帮助", "說明", "Services", "服务", "服務", "Hide"]
    /// `"Hide WeChat"`, `"Hide Others"`, `"隐藏其他"`; `"隐藏"` also matches itself.
    private static let hiddenPrefixes = ["Hide ", "隐藏"]

    private static let windowMenus: Set<String> = ["Window", "窗口", "視窗"]
    /// macOS's own window-arrangement furniture. Matched against *any* path component so that
    /// `Move & Resize` takes its whole submenu ("Left", "Top", "Tile Left & Right") with it.
    ///
    /// The `… All` and `… of Screen` rows are exact titles in their own right: `Minimize` and
    /// `Zoom` are matched exactly, so `Minimize All` and `Zoom All` walked straight past this list
    /// — which is how Chrome's Window menu, with a row per window, got onto the 「更多」 page.
    private static let windowLayout: Set<String> = [
        "Fill", "Center", "Enter Full Screen", "Exit Full Screen", "Move & Resize",
        "Minimize", "Zoom", "Bring All to Front", "Arrange in Front",
        "Minimize All", "Zoom All", "Left of Screen", "Right of Screen",
        "填充", "居中", "进入全屏幕", "退出全屏幕", "移动与调整大小",
        "最小化", "缩放", "前置全部窗口", "全部最小化",
    ]
    /// `"Tile Left of Screen"`, `"Move All to Built-in Retina Display"`.
    ///
    /// `"Move to …"` needs nothing here: `isDestructive` already blocks every component containing
    /// `"move to"`, in any menu. `"Move All to "` is not that substring, which is why it does.
    private static let windowLayoutPrefixes = ["Tile", "Move All to "]

    private static let editMenus: Set<String> = ["Edit", "编辑", "編輯"]
    /// Clipboard and text-input items: all of them need a text selection the controller cannot
    /// make, and the ones that do work (Start Dictation) already have their own gesture.
    private static let editNoise: Set<String> = [
        "Undo", "Redo", "Cut", "Copy", "Paste", "Paste and Match Style", "Delete", "Select All",
        "Start Dictation", "Start Dictation…", "Emoji & Symbols", "Cancel",
        "撤销", "重做", "剪切", "拷贝", "复制", "粘贴", "删除", "全选",
        "开始听写", "表情与符号", "取消",
    ]
    /// macOS names the command in the row — "Undo Typing", "Redo Paste", "撤销输入" — so an exact
    /// title only ever catches the idle form. Prefix-matched instead.
    private static let editNoisePrefixes = ["Undo", "Redo", "撤销", "重做"]

    /// Lower-cased on purpose — `isDestructive` lower-cases the component before matching.
    private static let destructive: [String] = [
        "quit", "exit", "force quit", "log out", "logout", "sign out", "lock",
        "close", "delete", "remove", "clear", "reset", "erase", "empty trash",
        "restart", "shut down", "sleep",
        // Found reachable in real Finder/Mail menus by the 2026-09-21 review: "Move to Trash",
        // "Move to ▸ iCloud ▸ Trash", and the traditional-Chinese/alternative wordings that the
        // simplified-only entries above walk straight past (關閉 ≠ 关闭, 清除 ≠ 清空).
        "trash", "move to", "discard", "revert", "forget",
        "退出", "退出登录", "强制退出", "注销", "登出", "锁定",
        "关闭", "删除", "移除", "清空", "重置", "重启", "关机", "睡眠",
        "废纸篓", "廢紙簍", "關閉", "結束", "清除", "移到", "丢弃",
    ]
}

/// Builds the 「通用菜单」 for whatever app is in front (G4).
///
/// The shape is the same promise as every other menu here: a short list the user can walk with ↑↓
/// and commit with A, plus at most one page turn. What is different is that the rows are not a
/// catalogue we wrote — they are read live out of the app's own menu bar, so the builder's whole
/// job is choosing *which* of them, and in which order.
///
/// Favourites are what make the list usable in practice: WeChat's filtered menu is still a dozen
/// rows, and the three the user actually wants (next unread chat, next chat, search) are scattered
/// across two menus. Pinning them by `pathKey` puts them under the highlight the moment the menu
/// opens, and everything else keeps its original menu order one page down.
public enum AppMenuBuilder {
    /// The 「更多」 row's label, and its page's title.
    public static let morePageTitle = "More"
    /// How many rows the root gets when the user has pinned nothing — enough to be worth looking
    /// at, short enough to read at a glance.
    public static let unpinnedRootLimit = 6

    /// The menu for `entries`, or nil when nothing survives the filter.
    ///
    /// Nil rather than an empty menu, for the same reason `AgentMenuBuilder` returns nil: "this app
    /// offers nothing we can safely press" is a thing to report, not a blank overlay to dismiss.
    ///
    /// `favorites` is a list of `AppMenuEntry.pathKey`s in the order the user wants them. Entries
    /// that no longer exist, or that the filter removed (including anything destructive), are
    /// skipped silently — the menu bar is read live, so a favourite pointing at a row the app has
    /// since moved must degrade to "not pinned", never to a broken row.
    public static func menu(
        entries: [AppMenuEntry],
        bundleID: String?,
        appName: String,
        favorites: [String] = []
    ) -> AgentMenu? {
        let shown = AppMenuFilter.displayable(entries)
        guard !shown.isEmpty else { return nil }

        // Indices rather than paths: the Window menu can list two windows with identical titles and
        // identical-looking paths, and neither must swallow the other.
        var rootIndices: [Int] = []
        for key in favorites {
            guard let index = shown.firstIndex(where: { $0.pathKey == key }),
                  !rootIndices.contains(index)
            else { continue }
            rootIndices.append(index)
        }
        // Nothing pinned — or nothing pinned that still exists — falls back to the head of the
        // menu, so the user always gets rows rather than a lone 「更多」.
        if rootIndices.isEmpty {
            rootIndices = Array(shown.indices.prefix(unpinnedRootLimit))
        }

        let pinned = Set(rootIndices)
        let rest = shown.indices.filter { !pinned.contains($0) }.map { shown[$0] }

        var rows = rootIndices.map { row(shown[$0], title: shown[$0].title) }
        if !rest.isEmpty {
            // Exactly one level deep, like the dial's 「更多」: the page's rows are all presses.
            rows.append(MenuItem(
                choice: .openSubmenu(title: morePageTitle, items: page(rest)),
                title: morePageTitle
            ))
        }
        return AgentMenu(bundleID: bundleID, title: appName, items: rows)
    }

    /// The 「更多」 page.
    ///
    /// Titles are qualified as `"菜单 › 标题"` only where they would otherwise collide: the page can
    /// hold a dozen rows drawn from every menu in the bar, and two rows both reading "Search" with
    /// nothing to tell them apart is a coin flip under the highlight. Unqualified everywhere else,
    /// because the app's own wording is what the user recognises.
    private static func page(_ entries: [AppMenuEntry]) -> [MenuItem] {
        var counts: [String: Int] = [:]
        for entry in entries { counts[entry.title, default: 0] += 1 }
        return entries.map { entry in
            let ambiguous = (counts[entry.title] ?? 0) > 1
            return row(entry, title: ambiguous ? "\(entry.menuTitle) › \(entry.title)" : entry.title)
        }
    }

    /// `id` is what the press uses — the element the user was actually looking at. `path` rides
    /// along for the log line and for matching favourites, and is deliberately *not* what gets
    /// looked up again: two windows can share a path, and re-finding one by title would press the
    /// first of them whichever the user chose.
    private static func row(_ entry: AppMenuEntry, title: String) -> MenuItem {
        MenuItem(choice: .pressAppMenuItem(id: entry.id, path: entry.path), title: title)
    }
}
