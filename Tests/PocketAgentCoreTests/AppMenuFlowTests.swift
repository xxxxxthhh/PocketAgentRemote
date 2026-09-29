import XCTest
@testable import PocketAgentCore

/// G4 「通用菜单」, driven through the real engine, recognizer and dispatcher.
///
/// The promise this suite pins is the one the feature is for: in an app that is *not* an agent,
/// `B+←` stops saying 「前台不是 agent」 and shows that app's own menu bar instead — and choosing a
/// row **presses** the item through Accessibility rather than typing its accelerator. So every case
/// below checks the emitter as well: a single keystroke reaching the app would mean the shortcut was
/// synthesised after all, which is exactly what this design refuses to do.
final class AppMenuFlowTests: XCTestCase {
    private let safari = "com.apple.Safari"
    private let codex = "com.openai.codex"

    private let unreadPath = ["显示", "下一条未读消息"]
    private let findPath = ["编辑", "查找"]
    private let minimizePath = ["窗口", "最小化"]

    private var entries: [AppMenuEntry] {
        [
            AppMenuEntry(id: 0, path: unreadPath, shortcut: "⌘⇧U"),
            AppMenuEntry(id: 1, path: findPath, shortcut: "⌘F"),
            AppMenuEntry(id: 2, path: minimizePath, shortcut: "⌘M"),
        ]
    }

    // MARK: - Opening

    func testANonAgentAppGetsItsOwnMenuBarInsteadOfARefusal() {
        let (rig, reader) = makeAppMenuRig()
        defer { rig.engine.stop() }

        openGeneralMenu(rig)

        XCTAssertEqual(rig.dispatcher.openMenu?.bundleID, safari)
        XCTAssertEqual(rig.dispatcher.openMenu?.layout, .list)
        XCTAssertEqual(rig.dispatcher.openMenu?.items.map(\.title),
                       ["下一条未读消息", "查找", "最小化"])
        XCTAssertEqual(reader.openedFor, [safari], "one session, for the app in front")
        XCTAssertTrue(
            rig.log().contains { $0.contains("MENU  opened app menu for \(safari) with 3 items") },
            "Log: \(rig.log())"
        )
        XCTAssertTrue(
            rig.log().allSatisfy { !$0.hasPrefix("SKIP") },
            "nothing was refused, so nothing may be reported. Log: \(rig.log())"
        )
        XCTAssertEqual(rig.emitter.emissions, [], "opening a menu injects nothing")
    }

    /// The allowlist gates *keystrokes*, and reading a menu bar is not one — so it must not stop the
    /// general menu from opening in a browser, which is where the feature is used.
    func testTheAllowlistDoesNotStopTheMenuFromOpening() {
        let (rig, reader) = makeAppMenuRig(configure: { $0.requireAllowedFrontmostApp = true })
        defer { rig.engine.stop() }

        openGeneralMenu(rig)

        XCTAssertEqual(rig.dispatcher.openMenu?.items.count, 3, "Log: \(rig.log())")
        XCTAssertEqual(reader.openedFor, [safari])
        XCTAssertEqual(rig.emitter.emissions, [])
    }

    func testAnAgentInFrontStillGetsItsCommandMenuAndTheReaderIsNeverAsked() {
        let (rig, reader) = makeAppMenuRig(frontmostBundleID: codex)
        defer { rig.engine.stop() }

        openGeneralMenu(rig)

        XCTAssertEqual(reader.openedFor, [],
                       "Codex has a command menu, so its menu bar is never read. Log: \(rig.log())")
        XCTAssertTrue(rig.dispatcher.openMenu?.items.contains { $0.title == "New Chat" } == true,
                      "the shipped Codex list. Log: \(rig.log())")
        XCTAssertTrue(rig.log().contains { $0.contains("MENU  opened for \(codex)") })
    }

    /// An app with no menu bar to read falls back to exactly the refusal G4 replaced — a menu that
    /// opened empty would be worse than the message.
    func testWithoutEntriesTheOldRefusalStands() {
        for available in [nil, []] as [[AppMenuEntry]?] {
            let (rig, _) = makeAppMenuRig(reader: FakeAppMenuReader(entries: available, outcome: .pressed))
            defer { rig.engine.stop() }

            rig.press(.b, at: 0)
            rig.press(.left, at: 0.05)
            rig.release(.left, at: 0.10)
            rig.release(.b, at: 0.15)

            XCTAssertFalse(rig.engine.isMenuOpen, "nothing to show. Log: \(rig.log())")
            XCTAssertTrue(
                rig.log().contains { $0.hasPrefix("SKIP") && $0.contains("no agent in front") },
                "the pre-G4 message, unchanged. Log: \(rig.log())"
            )
            XCTAssertEqual(rig.emitter.emissions, [])
        }
    }

    // MARK: - Pressing a row

    func testChoosingARowPressesThatPathAndTypesNothing() {
        let (rig, reader) = makeAppMenuRig()
        defer { rig.engine.stop() }
        openGeneralMenu(rig)

        rig.press(.a, at: 0.3)

        XCTAssertEqual(reader.pressedIDs, [0], "exactly one press, of the row's own entry. Log: \(rig.log())")
        XCTAssertEqual(reader.pressedPaths, [unreadPath])
        XCTAssertEqual(reader.sessions.first?.bundleID, safari)
        XCTAssertTrue(
            rig.log().contains { $0.contains("MENU  pressing 显示 › 下一条未读消息 in \(safari)") },
            "Log: \(rig.log())"
        )
        XCTAssertFalse(rig.engine.isMenuOpen, "running a row closes the menu")
        XCTAssertTrue(rig.log().allSatisfy { !$0.hasPrefix("SKIP") },
                      "a press that worked reports no failure. Log: \(rig.log())")

        rig.release(.a, at: 0.35)
        XCTAssertEqual(rig.emitter.emissions, [],
                       "no accelerator is synthesised, before or after the release. Log: \(rig.log())")
    }

    func testTheRowThatIsHighlightedIsTheOneThatGetsPressed() {
        let (rig, reader) = makeAppMenuRig()
        defer { rig.engine.stop() }
        openGeneralMenu(rig)

        rig.press(.down, at: 0.2)
        rig.release(.down, at: 0.25)
        XCTAssertEqual(rig.dispatcher.openMenu?.selectedItem?.title, "查找")
        rig.press(.a, at: 0.3)

        XCTAssertEqual(reader.pressedPaths, [findPath], "Log: \(rig.log())")
        XCTAssertEqual(rig.emitter.emissions, [])
    }

    /// Every outcome that is not `.pressed` has to reach the user exactly once: this is the case
    /// where the item is on screen but the app will not run it, and silence would read as a bug in
    /// the controller.
    func testEveryFailedPressIsReportedExactlyOnce() {
        let cases: [(AppMenuPressOutcome, String)] = [
            (.disabled, "app menu item is disabled right now"),
            (.notFound, "app menu item no longer exists"),
            (.appUnavailable, "app menu unavailable"),
            (.failed("AXPress returned -25205"), "app menu press failed"),
        ]

        for (outcome, expected) in cases {
            let (rig, reader) = makeAppMenuRig(outcome: outcome)
            defer { rig.engine.stop() }
            openGeneralMenu(rig)

            rig.press(.a, at: 0.3)
            rig.release(.a, at: 0.35)

            let failures = rig.log().filter { $0.hasPrefix("SKIP") }
            XCTAssertEqual(failures.count, 1,
                           "\(outcome) must be reported once, not zero or twice. Log: \(rig.log())")
            XCTAssertTrue(failures.first?.contains(expected) == true,
                          "\(outcome) → \(failures). Log: \(rig.log())")
            XCTAssertTrue(failures.first?.contains("openMenu") == true,
                          "reported as the menu's action, so the toast can name it")
            XCTAssertEqual(reader.pressedIDs.count, 1, "it was attempted, and attempted once")
            XCTAssertEqual(rig.emitter.emissions, [], "and nothing was typed instead")
            XCTAssertFalse(rig.engine.isMenuOpen)
        }
    }

    /// 安全复审 P2 的其中一半: the app never changed, so the dispatcher's own bundle-ID check passes —
    /// only the session knows the window the user chose the row *for* is gone. Denied, once, and
    /// nothing is pressed afterwards.
    func testAContextChangeIsDeniedExactlyOnceAndPressesNothingElse() {
        let (rig, reader) = makeAppMenuRig(outcome: .contextChanged)
        defer { rig.engine.stop() }
        openGeneralMenu(rig)

        rig.press(.a, at: 0.3)
        rig.release(.a, at: 0.35)

        let denials = rig.log().filter { $0.hasPrefix("DENY") }
        XCTAssertEqual(denials.count, 1, "once, not zero and not twice. Log: \(rig.log())")
        XCTAssertTrue(denials.first?.contains("app menu context changed") == true,
                      "and with the reason the toast maps. Log: \(rig.log())")
        XCTAssertTrue(denials.first?.hasPrefix("DENY  openMenu") == true,
                      "reported as the menu's own action")
        XCTAssertTrue(rig.log().allSatisfy { !$0.hasPrefix("SKIP") },
                      "a blocked row is denied, not unsupported. Log: \(rig.log())")
        XCTAssertEqual(reader.pressedIDs, [0], "it was attempted once, and refused by the session")
        XCTAssertFalse(rig.engine.isMenuOpen, "a refused row still takes the menu down")
        XCTAssertEqual(rig.emitter.emissions, [], "and nothing was typed instead")
    }

    /// 安全复审 P4: the Window menu can list two windows with the same title, so the row that is
    /// highlighted has to be identified by the element it was read from — never by re-finding its
    /// title, which always lands on the first one.
    func testTwoRowsWithTheSamePathArePressedByIdNotByTitle() {
        let sameName = ["窗口", "项目笔记"]
        let (rig, reader) = makeAppMenuRig(
            reader: FakeAppMenuReader(
                entries: [
                    AppMenuEntry(id: 0, path: sameName),
                    AppMenuEntry(id: 1, path: sameName),
                ],
                outcome: .pressed
            )
        )
        defer { rig.engine.stop() }
        openGeneralMenu(rig)

        XCTAssertEqual(rig.dispatcher.openMenu?.items.map(\.title), ["项目笔记", "项目笔记"],
                       "both are offered; telling them apart is the id's job. Log: \(rig.log())")

        rig.press(.down, at: 0.2)
        rig.release(.down, at: 0.25)
        rig.press(.a, at: 0.3)

        XCTAssertEqual(reader.pressedIDs, [1],
                       "the second row presses the second element. Log: \(rig.log())")
        rig.release(.a, at: 0.35)
        XCTAssertEqual(rig.emitter.emissions, [])
    }

    /// One menu, one session — the sub-page included. A second `openSession` at press time would be
    /// a second read of a menu bar that may have moved under us, which is what v2 removed.
    func testTheSubPageKeepsTheSessionTheRootWasReadFrom() {
        let (rig, reader) = makeAppMenuRig(builder: pagedAppMenu)
        defer { rig.engine.stop() }
        openGeneralMenu(rig)

        rig.press(.down, at: 0.2)
        rig.release(.down, at: 0.25)
        rig.press(.a, at: 0.3)                      // into 「更多」
        rig.release(.a, at: 0.35)
        rig.press(.b, at: 0.4)                      // back to the root, still on the 「更多」 row
        rig.release(.b, at: 0.45)
        rig.press(.a, at: 0.5)                      // in again
        rig.release(.a, at: 0.55)

        XCTAssertEqual(reader.openedFor, [safari],
                       "paging back and forth must not re-read the menu bar. Log: \(rig.log())")
        XCTAssertEqual(reader.sessions.count, 1)
        XCTAssertEqual(rig.dispatcher.openMenu?.title, "More", "and the page is still navigable")

        rig.press(.a, at: 0.6)                      // a row on the page presses through that session
        XCTAssertEqual(reader.pressedIDs, [1], "Log: \(rig.log())")
        rig.release(.a, at: 0.65)
        XCTAssertEqual(rig.emitter.emissions, [])
    }

    /// The re-check that makes the whole thing safe: the menu belongs to the app it was built for,
    /// and pressing a row after focus moved would act on whatever is in front now.
    func testFocusMovingAwayRefusesTheRowAndNeverReachesTheReader() {
        let (rig, reader) = makeAppMenuRig()
        defer { rig.engine.stop() }
        openGeneralMenu(rig)

        rig.frontmost.bundleID = codex
        rig.press(.a, at: 0.3)

        XCTAssertEqual(reader.pressedIDs, [], "the session must not even be asked. Log: \(rig.log())")
        XCTAssertFalse(rig.engine.isMenuOpen, "a refused row still takes the menu down")
        XCTAssertTrue(
            rig.log().contains { $0.hasPrefix("DENY  openMenu") && $0.contains("menu item refused") },
            "refused, and named as the menu's own action. Log: \(rig.log())"
        )
        XCTAssertEqual(rig.emitter.emissions, [])
    }

    // MARK: - 「更多」 on a list

    func testTheMorePageOpensOnAListAndBWalksBackOutWithoutEscape() {
        let (rig, _) = makeAppMenuRig(builder: pagedAppMenu)
        defer { rig.engine.stop() }
        openGeneralMenu(rig)

        XCTAssertEqual(rig.dispatcher.openMenu?.items.map(\.title), ["下一条未读消息", "More"])

        rig.press(.down, at: 0.2)
        rig.release(.down, at: 0.25)
        rig.press(.a, at: 0.3)                      // turn the page

        XCTAssertTrue(rig.engine.isMenuOpen, "a page turn is not a choice. Log: \(rig.log())")
        XCTAssertEqual(rig.dispatcher.openMenu?.title, "More")
        XCTAssertEqual(rig.dispatcher.openMenu?.layout, .list, "a page of a list is still a list")
        XCTAssertEqual(rig.dispatcher.openMenu?.items.map(\.title), ["查找", "最小化"])
        XCTAssertEqual(rig.dispatcher.openMenu?.selectedItem?.title, "查找", "a list opens on a row")
        XCTAssertTrue(rig.log().contains { $0.contains("MENU  More page opened with 2 items") },
                      "Log: \(rig.log())")

        rig.release(.a, at: 0.35)
        rig.press(.b, at: 0.4)                      // back to the root page

        XCTAssertTrue(rig.engine.isMenuOpen, "B on a page goes back, it does not close")
        XCTAssertEqual(rig.dispatcher.openMenu?.items.map(\.title), ["下一条未读消息", "More"])
        XCTAssertEqual(rig.dispatcher.openMenu?.selectedItem?.title, "More",
                       "and lands back on the row that opened the page")

        rig.release(.b, at: 0.45)
        rig.press(.b, at: 0.5)                      // the root's B closes

        XCTAssertFalse(rig.engine.isMenuOpen, "Log: \(rig.log())")
        rig.release(.b, at: 0.55)
        XCTAssertEqual(rig.emitter.emissions, [],
                       "no Escape anywhere in the round trip. Log: \(rig.log())")
    }

    func testARowOnTheMorePagePressesThroughTheSameCheck() {
        let (rig, reader) = makeAppMenuRig(builder: pagedAppMenu)
        defer { rig.engine.stop() }
        openGeneralMenu(rig)

        rig.press(.down, at: 0.2)
        rig.release(.down, at: 0.25)
        rig.press(.a, at: 0.3)                      // page
        rig.release(.a, at: 0.35)
        rig.press(.down, at: 0.4)
        rig.release(.down, at: 0.45)
        rig.press(.a, at: 0.5)                      // 最小化

        XCTAssertEqual(reader.pressedPaths, [minimizePath], "Log: \(rig.log())")
        XCTAssertEqual(reader.sessions.count, 1,
                       "the sub-page presses through the session the root was read from")
        XCTAssertFalse(rig.engine.isMenuOpen)
        rig.release(.a, at: 0.55)
        XCTAssertEqual(rig.emitter.emissions, [])
    }

    // MARK: - The seam with the real builder

    /// Everything above builds its rows locally, so it pins the dispatcher and nothing else. This
    /// one case runs the **shipped** builder through the same path, because the two halves only have
    /// to agree in one place — the rows it produces must be rows this dispatcher can press, and its
    /// 「更多」 must be a page this dispatcher can turn.
    func testTheShippedBuilderProducesRowsThisDispatcherCanPressAndPage() {
        // More entries than the root holds, whatever that limit is, so a 「更多」 row must appear.
        // No Apple-menu stand-in: the reader (G4-B) drops that menu before anything downstream sees
        // it, so what arrives here is already only the app's own menus.
        let offered = (0..<(AppMenuBuilder.unpinnedRootLimit + 3)).map {
            AppMenuEntry(id: $0, path: ["显示", "会话 \($0)"])
        }
        let (rig, reader) = makeAppMenuRig(
            reader: FakeAppMenuReader(entries: offered, outcome: .pressed),
            builder: { AppMenuBuilder.menu(entries: $1, bundleID: $0, appName: "微信") }
        )
        defer { rig.engine.stop() }
        openGeneralMenu(rig)

        XCTAssertEqual(rig.dispatcher.openMenu?.title, "微信")
        XCTAssertEqual(rig.dispatcher.openMenu?.items.last?.title, AppMenuBuilder.morePageTitle,
                       "a long menu bar has to page. Log: \(rig.log())")

        // The last row is the page turn, so walk up one from the top to reach it.
        rig.press(.up, at: 0.2)
        rig.release(.up, at: 0.25)
        rig.press(.a, at: 0.3)
        XCTAssertTrue(rig.engine.isMenuOpen, "turning a page is not a choice. Log: \(rig.log())")
        XCTAssertEqual(rig.dispatcher.openMenu?.title, AppMenuBuilder.morePageTitle)
        rig.release(.a, at: 0.35)

        rig.press(.b, at: 0.4)                      // back out of the page
        rig.release(.b, at: 0.45)
        XCTAssertEqual(rig.dispatcher.openMenu?.items.last?.title, AppMenuBuilder.morePageTitle,
                       "B on a page goes back to the root. Log: \(rig.log())")

        rig.press(.down, at: 0.5)                   // wrap to the first row
        rig.release(.down, at: 0.55)
        rig.press(.a, at: 0.6)

        XCTAssertEqual(reader.pressedPaths, [offered[0].path],
                       "its rows carry the entry's own path. Log: \(rig.log())")
        rig.release(.a, at: 0.65)
        XCTAssertEqual(rig.emitter.emissions, [], "and none of it types anything")
    }

    // MARK: - Helpers

    /// A reader that answers from a script and records everything it was asked.
    private final class FakeAppMenuReader: AppMenuReading {
        var entries: [AppMenuEntry]?
        var outcome: AppMenuPressOutcome
        private(set) var openedFor: [String] = []
        /// Every session handed out, so a test can assert that one menu means **one** session —
        /// re-opening one at press time is the re-lookup v2 exists to remove.
        private(set) var sessions: [FakeAppMenuSession] = []

        init(entries: [AppMenuEntry]?, outcome: AppMenuPressOutcome) {
            self.entries = entries
            self.outcome = outcome
        }

        func openSession(bundleID: String) -> AppMenuSession? {
            openedFor.append(bundleID)
            guard let entries else { return nil }
            let session = FakeAppMenuSession(bundleID: bundleID, entries: entries, outcome: outcome)
            sessions.append(session)
            return session
        }

        /// What was pressed, across every session — normally one.
        var pressedIDs: [Int] { sessions.flatMap(\.pressedIDs) }
        /// The same presses as paths, for the cases where the path is what the assertion is about.
        var pressedPaths: [[String]] {
            sessions.flatMap { session in
                session.pressedIDs.compactMap { id in session.entries.first { $0.id == id }?.path }
            }
        }
    }

    /// One opened menu: fixed entries, a scripted outcome, and a record of the ids pressed.
    private final class FakeAppMenuSession: AppMenuSession {
        let bundleID: String
        let entries: [AppMenuEntry]
        var outcome: AppMenuPressOutcome
        private(set) var pressedIDs: [Int] = []

        init(bundleID: String, entries: [AppMenuEntry], outcome: AppMenuPressOutcome) {
            self.bundleID = bundleID
            self.entries = entries
            self.outcome = outcome
        }

        func press(id: Int) -> AppMenuPressOutcome {
            pressedIDs.append(id)
            return outcome
        }
    }

    /// The flat menu G4-A's builder is expected to produce: one row per entry, each pressing its own
    /// path. Written here rather than called from `AppMenuBuilder` so this suite pins the
    /// *dispatcher's* half of the contract and nothing else.
    private func flatAppMenu(_ bundleID: String?, _ entries: [AppMenuEntry]) -> AgentMenu? {
        let rows = entries.map {
            MenuItem(choice: .pressAppMenuItem(id: $0.id, path: $0.path), title: $0.title)
        }
        guard !rows.isEmpty else { return nil }
        return AgentMenu(bundleID: bundleID, title: "Safari", items: rows)
    }

    /// The same rows, with everything past the first behind a 「更多」 page — the shape a long menu
    /// bar has to take on a six-button controller.
    private func pagedAppMenu(_ bundleID: String?, _ entries: [AppMenuEntry]) -> AgentMenu? {
        guard let flat = flatAppMenu(bundleID, entries), flat.items.count > 1 else { return nil }
        let more = MenuItem(
            choice: .openSubmenu(title: "More", items: Array(flat.items.dropFirst())),
            title: "More"
        )
        return AgentMenu(bundleID: bundleID, title: flat.title, items: [flat.items[0], more])
    }

    private func makeAppMenuRig(
        frontmostBundleID: String? = "com.apple.Safari",
        reader: FakeAppMenuReader? = nil,
        outcome: AppMenuPressOutcome = .pressed,
        builder: ((String?, [AppMenuEntry]) -> AgentMenu?)? = nil,
        configure: (inout AppConfig) -> Void = { _ in }
    ) -> (EngineRig, FakeAppMenuReader) {
        let reader = reader ?? FakeAppMenuReader(entries: entries, outcome: outcome)
        let build = builder ?? flatAppMenu
        let rig = makeEngineRig(
            frontmostBundleID: frontmostBundleID,
            appMenuReader: reader,
            appMenuBuilder: { build($0, $1) },
            configure: configure
        )
        return (rig, reader)
    }

    /// Opens the menu with the real `B+←`, the only entry point there is.
    private func openGeneralMenu(_ rig: EngineRig, file: StaticString = #filePath, line: UInt = #line) {
        rig.press(.b, at: 0)
        rig.press(.left, at: 0.05)
        rig.release(.left, at: 0.10)
        rig.release(.b, at: 0.15)
        XCTAssertTrue(rig.engine.isMenuOpen, "B+← must open a menu. Log: \(rig.log())",
                      file: file, line: line)
    }
}
