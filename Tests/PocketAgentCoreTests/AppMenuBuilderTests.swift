import XCTest
@testable import PocketAgentCore

/// 「通用菜单」 (G4) — the filter and the builder.
///
/// Everything here runs against a recorded WeChat menu bar rather than a live one, because the
/// promises being tested are about *choosing* rows, not about Accessibility: the Apple menu is
/// gone, a greyed-out row is gone, a destructive row is gone even when the user collected it, and
/// what is left is at most one page turn away.
final class AppMenuBuilderTests: XCTestCase {
    private let weChat = "com.tencent.xinWeChat"

    /// WeChat's menu bar as the reader hands it over: flattened, depth-first, submenu parents
    /// included, in menu order — and **without the Apple menu**, which `AccessibilityMenuReader`
    /// drops before we ever see it. So the first menu here is the app's own. Ids are the indices
    /// the session numbers entries with.
    private let weChatMenu: [AppMenuEntry] = [
        AppMenuEntry(id: 0, path: ["WeChat", "About WeChat"]),
        AppMenuEntry(id: 1, path: ["WeChat", "Settings…"], shortcut: "cmd+,"),
        AppMenuEntry(id: 2, path: ["WeChat", "Services"]),
        AppMenuEntry(id: 3, path: ["WeChat", "Services", "Search With Google"]),
        AppMenuEntry(id: 4, path: ["WeChat", "Hide WeChat"], shortcut: "cmd+h"),
        AppMenuEntry(id: 5, path: ["WeChat", "Hide Others"], shortcut: "cmd+option+h"),
        AppMenuEntry(id: 6, path: ["WeChat", "Quit WeChat"], shortcut: "cmd+q"),
        AppMenuEntry(id: 7, path: ["File", "New Chat"], shortcut: "cmd+n"),
        AppMenuEntry(id: 8, path: ["File", "Close Window"], shortcut: "cmd+w"),
        AppMenuEntry(id: 9, path: ["Edit", "Undo"], shortcut: "cmd+z"),
        AppMenuEntry(id: 10, path: ["Edit", "Copy"], shortcut: "cmd+c", isEnabled: false),
        AppMenuEntry(id: 11, path: ["Edit", "Select All"], shortcut: "cmd+a"),
        AppMenuEntry(id: 12, path: ["Edit", "Search"], shortcut: "cmd+f"),
        AppMenuEntry(id: 13, path: ["Edit", "Clear All Unreads"], shortcut: "cmd+shift+escape"),
        AppMenuEntry(id: 14, path: ["Show", "Show Next Unread Chat"], shortcut: "cmd+option+down"),
        AppMenuEntry(id: 15, path: ["Show", "Show Next Chat"], shortcut: "cmd+shift+]"),
        AppMenuEntry(id: 16, path: ["Show", "Show Previous Chat"], shortcut: "cmd+shift+["),
        AppMenuEntry(id: 17, path: ["Show", "Show Contacts"], isEnabled: false),
        AppMenuEntry(id: 18, path: ["Show", "Show Favorites"]),
        AppMenuEntry(id: 19, path: ["Window", "Minimize"], shortcut: "cmd+m"),
        AppMenuEntry(id: 20, path: ["Window", "Move & Resize"]),
        AppMenuEntry(id: 21, path: ["Window", "Move & Resize", "Left"]),
        AppMenuEntry(id: 22, path: ["Window", "Bring All to Front"]),
        AppMenuEntry(id: 23, path: ["Window", "WeChat"]),
        AppMenuEntry(id: 24, path: ["Help", "WeChat Help"]),
    ]

    /// The four rows that survived the real-device pass, in the order they are worth pressing.
    private let weChatFavorites = [
        "Show/Show Next Unread Chat",
        "Show/Show Next Chat",
        "Show/Show Previous Chat",
        "Edit/Search",
    ]

    private func menu(favorites: [String] = [], entries: [AppMenuEntry]? = nil) -> AgentMenu? {
        AppMenuBuilder.menu(
            entries: entries ?? weChatMenu,
            bundleID: weChat,
            appName: "微信",
            favorites: favorites
        )
    }

    /// Every row the menu draws, the 「更多」 page included.
    private func allTitles(_ menu: AgentMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            guard let page = item.submenu else { return [item.title] }
            return [item.title] + page.items.map(\.title)
        }
    }

    // MARK: - The filter

    func testTheFilterKeepsOnlyWhatIsSafeAndPressable() {
        let kept = AppMenuFilter.displayable(weChatMenu)

        XCTAssertEqual(kept.map(\.pathKey), [
            "WeChat/About WeChat",
            "WeChat/Settings…",
            "File/New Chat",
            "Edit/Search",
            "Show/Show Next Unread Chat",
            "Show/Show Next Chat",
            "Show/Show Previous Chat",
            "Show/Show Favorites",
            "Window/WeChat",
        ], "25 nodes down to the 9 a controller can usefully press, in menu order")
    }

    func testTheAppsOwnMenuIsKept() {
        // The reader drops the Apple menu at both ends (`dropFirst` in `menuEntries` and in the
        // press), so the first menu it hands over is the app's own. Filtering *that* one by
        // position — as an earlier version did — deleted About and Settings… along with it.
        let kept = AppMenuFilter.displayable(weChatMenu)
        XCTAssertEqual(kept.first?.pathKey, "WeChat/About WeChat", "nothing is dropped for being first")
        XCTAssertTrue(kept.map(\.pathKey).contains("WeChat/Settings…"),
                      "the app menu's own non-destructive rows stay reachable")
        XCTAssertEqual(kept.first?.menuTitle, "WeChat")
    }

    func testDestructiveGreyedOutAndFurnitureRowsAreAllGone() {
        let kept = AppMenuFilter.displayable(weChatMenu).map(\.title)

        for banned in ["Quit WeChat", "Close Window", "Clear All Unreads"] {
            XCTAssertFalse(kept.contains(banned), "\(banned) must never be one press away")
        }
        for greyed in ["Copy", "Show Contacts"] {
            XCTAssertFalse(kept.contains(greyed), "\(greyed) is disabled right now")
        }
        for noise in ["Undo", "Select All", "Minimize", "Bring All to Front", "WeChat Help"] {
            XCTAssertFalse(kept.contains(noise), "\(noise) is furniture, not a command")
        }
        XCTAssertFalse(kept.contains("Search With Google"), "the Services subtree is dropped whole")
        XCTAssertFalse(kept.contains("Left"), "so is everything under Move & Resize")
    }

    /// Every counter-example the 2026-09-21 security review found reachable through the *previous*
    /// blacklist. Each one is a real title from a real menu (Finder, Mail, Safari, 信箱), and each
    /// one moves, closes, clears or undoes something a blind A press must not reach.
    func testTheSecurityReviewsCounterExamplesAreAllFilteredOut() {
        let reachable = [
            AppMenuEntry(id: 0, path: ["File", "Move to Trash"]),
            AppMenuEntry(id: 1, path: ["访达", "清倒废纸篓…"]),
            AppMenuEntry(id: 2, path: ["文件", "移到废纸篓"]),
            AppMenuEntry(id: 3, path: ["Message", "Move to", "iCloud", "Trash"]),
            AppMenuEntry(id: 4, path: ["檔案", "關閉視窗"]),
            AppMenuEntry(id: 5, path: ["Safari", "結束 Safari"]),
            AppMenuEntry(id: 6, path: ["信箱", "清除垃圾郵件"]),
            AppMenuEntry(id: 7, path: ["Edit", "Undo Typing"]),
            AppMenuEntry(id: 8, path: ["Edit", "Redo Typing"]),
        ]
        for entry in reachable {
            XCTAssertEqual(AppMenuFilter.displayable([entry]), [],
                           "\(entry.pathKey) reached the overlay under the old word list")
        }
        XCTAssertEqual(AppMenuFilter.displayable(reachable), [], "and none of them survives together either")
    }

    /// Chrome's Window menu is where the 41-row 「更多」 page came from: a row per window, and above
    /// them a block of arrangement rows that the exact titles `Minimize` / `Zoom` walked past.
    func testTheWindowMenusOwnFurnitureIsFilteredOut() {
        let furniture = [
            AppMenuEntry(id: 0, path: ["Window", "Minimize All"]),
            AppMenuEntry(id: 1, path: ["Window", "Zoom All"]),
            AppMenuEntry(id: 2, path: ["Window", "Left of Screen"]),
            AppMenuEntry(id: 3, path: ["Window", "Right of Screen"]),
            AppMenuEntry(id: 4, path: ["Window", "Bring All to Front"]),
            AppMenuEntry(id: 5, path: ["窗口", "全部最小化"]),
            AppMenuEntry(id: 6, path: ["Window", "Move All to Built-in Retina Display"]),
            AppMenuEntry(id: 7, path: ["Window", "Tile Left of Screen"]),
        ]
        for entry in furniture {
            XCTAssertEqual(AppMenuFilter.displayable([entry]), [],
                           "「\(entry.title)」 arranges windows; it is not a command")
        }
        XCTAssertEqual(AppMenuFilter.displayable(furniture), [], "and the whole block goes together")

        XCTAssertEqual(AppMenuFilter.displayable([AppMenuEntry(id: 0, path: ["Window", "Gmail – Inbox"])]).map(\.title),
                       ["Gmail – Inbox"], "the windows themselves are still worth choosing")
    }

    /// `Move to …` is *not* in the window list, on purpose: `isDestructive` already blocks every
    /// component containing "move to", in every menu. `Move All to …` does not contain that
    /// substring, which is the one the window prefix exists for.
    func testMoveToIsAlreadyBlockedAsDestructiveButMoveAllToIsNot() {
        XCTAssertEqual(AppMenuFilter.displayable([AppMenuEntry(id: 0, path: ["Window", "Move to iPhone"])]), [])
        XCTAssertEqual(AppMenuFilter.displayable([AppMenuEntry(id: 0, path: ["File", "Move to Folder…"])]), [],
                       "the destructive rule runs outside the Window menu too")
        XCTAssertFalse("Move All to Built-in Retina Display".lowercased().contains("move to"),
                       "why the window prefix is needed: the destructive substring does not cover it")
    }

    func testTheRowsWorthHavingSurviveAllOfThat() {
        // The widened blacklist has to leave the reason the feature exists intact.
        let wanted = [
            AppMenuEntry(id: 0, path: ["Show", "Show Next Unread Chat"]),
            AppMenuEntry(id: 1, path: ["Edit", "Search"]),
            AppMenuEntry(id: 2, path: ["File", "New Chat"]),
            AppMenuEntry(id: 3, path: ["Window", "Chats"]),
        ]
        XCTAssertEqual(AppMenuFilter.displayable(wanted), wanted)
    }

    func testTwoRowsWithTheSamePathStillPressDifferentElements() {
        // Why v2 carries an id at all: the Window menu can list two windows with the same title,
        // and re-finding one by title would press the first of them whichever the user chose.
        let twins = [
            AppMenuEntry(id: 0, path: ["Window", "Chats"]),
            AppMenuEntry(id: 1, path: ["Window", "Chats"]),
        ]
        XCTAssertEqual(menu(entries: twins)?.items.map(\.choice), [
            .pressAppMenuItem(id: 0, path: ["Window", "Chats"]),
            .pressAppMenuItem(id: 1, path: ["Window", "Chats"]),
        ], "two rows, two elements — neither swallows the other")
    }

    func testHidingTheAppItselfIsNeverOnOffer() {
        // Not destructive, but from an overlay it is a trap: the window the user is looking at
        // disappears and a six-button controller has no ⌘⇥ to bring it back.
        let kept = AppMenuFilter.displayable(weChatMenu).map(\.title)
        XCTAssertFalse(kept.contains("Hide WeChat"), "the row carries the app's own name, so a prefix match")
        XCTAssertFalse(kept.contains("Hide Others"))

        let chinese = [
            AppMenuEntry(id: 0, path: ["微信", "隐藏微信"]),
            AppMenuEntry(id: 1, path: ["微信", "隐藏其他"]),
            AppMenuEntry(id: 2, path: ["微信", "偏好设置…"]),
        ]
        XCTAssertEqual(AppMenuFilter.displayable(chinese).map(\.title), ["偏好设置…"])
    }

    func testAnAppsOwnRestartAndPowerRowsAreDroppedToo() {
        // The Apple menu never reaches us, but an app's own menu has its own versions. The first
        // three are already caught by clear/reset/delete; "Restart Claude" is the one that needs
        // the power words, and it is the shape most likely to appear in some other app.
        let claude = [
            AppMenuEntry(id: 0, path: ["Claude", "Settings…"]),
            AppMenuEntry(id: 1, path: ["Claude", "Clear Cache and Restart"]),
            AppMenuEntry(id: 2, path: ["Claude", "Reset App Data…"]),
            AppMenuEntry(id: 3, path: ["Claude", "Delete Cowork VM Bundle and Restart…"]),
            AppMenuEntry(id: 4, path: ["Claude", "Restart Claude"]),
            AppMenuEntry(id: 5, path: ["文件", "重启并清空缓存"]),
            AppMenuEntry(id: 6, path: ["文件", "新建对话"]),
        ]
        XCTAssertEqual(AppMenuFilter.displayable(claude).map(\.pathKey), ["Claude/Settings…", "文件/新建对话"],
                       "restart / shut down / sleep join quit / close / delete on the blacklist")
    }

    func testSubmenuParentsAreDroppedBecausePressingOneDoesNothing() {
        let kept = AppMenuFilter.displayable(weChatMenu).map(\.pathKey)
        XCTAssertFalse(kept.contains("WeChat/Services"))
        XCTAssertFalse(kept.contains("Window/Move & Resize"))
    }

    func testChineseTitlesAreFilteredToo() {
        let entries = [
            AppMenuEntry(id: 0, path: ["微信", "退出微信"]),
            AppMenuEntry(id: 1, path: ["微信", "偏好设置…"]),
            AppMenuEntry(id: 2, path: ["编辑", "全选"]),
            AppMenuEntry(id: 3, path: ["编辑", "查找"]),
            AppMenuEntry(id: 4, path: ["窗口", "最小化"]),
            AppMenuEntry(id: 5, path: ["会话", "清空聊天记录"]),
        ]
        XCTAssertEqual(AppMenuFilter.displayable(entries).map(\.pathKey), ["微信/偏好设置…", "编辑/查找"])
    }

    // MARK: - Favourites

    func testFavouritesLeadInTheOrderTheyWereConfigured() {
        guard let menu = menu(favorites: weChatFavorites) else { return XCTFail("WeChat must get a menu") }

        XCTAssertEqual(menu.items.map(\.title), [
            "Show Next Unread Chat", "Show Next Chat", "Show Previous Chat", "Search", "更多",
        ], "config order wins over menu order, and everything else is one page down")
        XCTAssertEqual(
            menu.items.first?.choice,
            .pressAppMenuItem(id: 14, path: ["Show", "Show Next Unread Chat"]),
            "a row presses the element it was read from, by id — never a fresh lookup by title"
        )
        XCTAssertEqual(menu.items.last?.submenu?.items.map(\.title),
                       ["About WeChat", "Settings…", "New Chat", "Show Favorites", "WeChat"],
                       "the page keeps the app's own menu order")
    }

    func testACollectedDestructiveRowIsStillNeverShown() {
        // The user pinned Quit and Close Window by hand. The blacklist outranks them.
        let menu = menu(favorites: ["WeChat/Quit WeChat", "File/Close Window", "Edit/Search"])
        guard let menu else { return XCTFail("WeChat must get a menu") }

        let titles = allTitles(menu)
        XCTAssertFalse(titles.contains("Quit WeChat"))
        XCTAssertFalse(titles.contains("Close Window"))
        XCTAssertEqual(menu.items.map(\.title), ["Search", "更多"], "only the legal favourite is pinned")
    }

    func testFavouritesThatNoLongerMatchFallBackToTheHeadOfTheMenu() {
        // Every favourite points at a row this app does not have (renamed, or destructive). A lone
        // 「更多」 row would be the worst possible answer.
        let menu = menu(favorites: ["Show/Show Moments", "WeChat/Quit WeChat"])
        guard let menu else { return XCTFail("WeChat must get a menu") }

        XCTAssertEqual(menu.items.map(\.title), [
            "About WeChat", "Settings…", "New Chat", "Search", "Show Next Unread Chat", "Show Next Chat", "更多",
        ], "same as having configured nothing: the first six rows, then the page")
    }

    func testRepeatedAndUnknownFavouritesAreSkippedRatherThanDuplicated() {
        let menu = menu(favorites: ["Edit/Search", "Edit/Search", "Show/Nothing Like This"])
        XCTAssertEqual(menu?.items.map(\.title), ["Search", "更多"])
    }

    // MARK: - Shape

    func testWithoutFavouritesTheRootIsTheFirstSixRowsAndTheRestIsOnePageDown() {
        guard let menu = menu() else { return XCTFail("WeChat must get a menu") }

        XCTAssertEqual(menu.items.count, 7, "six rows plus 「更多」")
        XCTAssertEqual(menu.items.map(\.title).dropLast(), [
            "About WeChat", "Settings…", "New Chat", "Search", "Show Next Unread Chat", "Show Next Chat",
        ])
        XCTAssertEqual(menu.items.last?.submenu?.items.map(\.title),
                       ["Show Previous Chat", "Show Favorites", "WeChat"])
        XCTAssertEqual(AppMenuBuilder.unpinnedRootLimit, 6)
    }

    func testTheMorePageIsExactlyOneLevelDeep() {
        guard let page = menu(favorites: weChatFavorites)?.items.last?.submenu else {
            return XCTFail("there must be a 「更多」 page")
        }
        for item in page.items {
            XCTAssertNil(item.submenu, "「\(item.title)」 must be a press, not another page")
            guard case .pressAppMenuItem = item.choice else {
                return XCTFail("「\(item.title)」 must press a menu item")
            }
        }
    }

    func testNoMorePageWhenEverythingAlreadyFits() {
        let short = [
            AppMenuEntry(id: 0, path: ["Show", "Show Next Chat"]),
            AppMenuEntry(id: 1, path: ["Show", "Show Previous Chat"]),
        ]
        guard let menu = menu(entries: short) else { return XCTFail("two rows are still a menu") }
        XCTAssertEqual(menu.items.map(\.title), ["Show Next Chat", "Show Previous Chat"])
        XCTAssertNil(menu.items.last?.submenu, "no empty 「更多」")
    }

    func testCollidingTitlesOnThePageAreQualifiedByTheirMenu() {
        let entries = [
            AppMenuEntry(id: 0, path: ["File", "Export…"]),
            AppMenuEntry(id: 1, path: ["View", "Sidebar"]),
            AppMenuEntry(id: 2, path: ["Show", "Sidebar"]),
            AppMenuEntry(id: 3, path: ["Show", "Pin"]),
        ]
        guard let page = menu(favorites: ["Show/Pin"], entries: entries)?.items.last?.submenu else {
            return XCTFail("there must be a 「更多」 page")
        }
        XCTAssertEqual(page.items.map(\.title), ["Export…", "View › Sidebar", "Show › Sidebar"],
                       "only the ambiguous pair is qualified; the app's own wording stays elsewhere")
        XCTAssertEqual(page.items[1].choice, .pressAppMenuItem(id: 1, path: ["View", "Sidebar"]),
                       "a relabelled row still presses its own item")
    }

    func testTheMenuIsAListThatOpensOnItsFirstRow() {
        guard let menu = menu(favorites: weChatFavorites) else { return XCTFail("WeChat must get a menu") }
        XCTAssertEqual(menu.layout, .list)
        XCTAssertEqual(menu.selection, 0)
        XCTAssertTrue(menu.hasSelection, "a list opens on a row, so B+← then A is one gesture")
        XCTAssertEqual(menu.title, "微信", "the header is the app's own name")
        XCTAssertEqual(menu.bundleID, weChat, "held so the choice can be refused when focus moves on")
        XCTAssertEqual(menu.hint, "↑↓ 选择    A 执行    B 关闭")
    }

    func testNilWhenNothingSurvivesTheFilter() {
        XCTAssertNil(menu(entries: []), "no menu bar at all")
        XCTAssertNil(menu(entries: [
            AppMenuEntry(id: 0, path: ["WeChat", "Hide WeChat"]),
            AppMenuEntry(id: 1, path: ["WeChat", "Quit WeChat"]),
        ]), "an app menu with nothing but furniture and an exit")
        XCTAssertNil(menu(entries: [
            AppMenuEntry(id: 0, path: ["File", "Close Window"]),
            AppMenuEntry(id: 1, path: ["File", "Print…"], isEnabled: false),
        ]), "everything left is destructive or greyed out")
    }

    // MARK: - Config

    func testWeChatIsPinnedWithoutAnyConfigFile() {
        let config = AppConfig()
        XCTAssertTrue(config.appMenuFavorites.isEmpty, "nothing is written to disk")
        XCTAssertEqual(config.appMenuFavorites(for: weChat), weChatFavorites, "but the default still applies")
        XCTAssertEqual(config.appMenuFavorites(for: "com.apple.Safari"), [])
        XCTAssertEqual(config.appMenuFavorites(for: nil), [])
    }

    func testAMissingKeyDecodesToTheDefaultAndAPresentKeyReplacesIt() throws {
        let json = """
        {
          "appMenuFavorites" : {
            "com.apple.Safari" : [ "Bookmarks/Show Bookmarks" ]
          }
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.appMenuFavorites(for: "com.apple.Safari"), ["Bookmarks/Show Bookmarks"])
        XCTAssertEqual(config.appMenuFavorites(for: weChat), weChatFavorites,
                       "an app the config does not mention keeps its built-in list")
    }

    func testAnEmptyListInConfigClearsTheBuiltInFavourites() throws {
        let json = """
        { "appMenuFavorites" : { "com.tencent.xinWeChat" : [ ] } }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.appMenuFavorites(for: weChat), [],
                       "merging per bundle ID is what lets a user say 'pin nothing here'")

        // …and the builder then falls back to the head of the menu rather than to the defaults.
        let menu = menu(favorites: config.appMenuFavorites(for: weChat))
        XCTAssertEqual(menu?.items.first?.title, "About WeChat")
    }

    func testAConfigWrittenBeforeThisFieldExistedStillDecodes() throws {
        let legacy = """
        { "version" : 1, "activeProfile" : "codex", "tapMaxMs" : 220, "holdMs" : 450 }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
        XCTAssertTrue(config.appMenuFavorites.isEmpty)
        XCTAssertEqual(config.appMenuFavorites(for: weChat), weChatFavorites)
    }

    func testFavouritesSurviveARoundTrip() throws {
        var config = AppConfig()
        config.appMenuFavorites = [weChat: ["Edit/Search"]]
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded.appMenuFavorites(for: weChat), ["Edit/Search"])
    }
}
