import XCTest
@testable import PocketAgentCore

/// The Codex four-direction dial (G2 prototype, T1.3).
///
/// Everything runs through the real engine, recognizer and dispatcher, opened with the real `B+←`
/// chord — because most of what the dial has to promise is about *input*, not about the model:
///
/// - the chord that opened the menu must be fully consumed, so the dial opens armed with nothing;
/// - a direction arms a slot and runs nothing;
/// - A on an unarmed dial does nothing at all, and does not cost the menu;
/// - 「更多」 is a page turn, and B on that page comes back instead of closing;
/// - the action itself still goes through the adapter, the guard and the frontmost re-check.
final class DialMenuTests: XCTestCase {
    private let codex = "com.openai.codex"
    private let safari = "com.apple.Safari"

    /// Codex's real bindings — taken from the adapter, never hand-written.
    private let newChat = KeyStroke(.n, modifiers: [.command])
    private let inspectChanges = KeyStroke(.b, modifiers: [.command, .option])
    private let openTerminal = KeyStroke(.grave, modifiers: [.control])
    private let openModelPicker = KeyStroke(.m, modifiers: [.control, .shift])

    private func makeDialRig(frontmost: String? = "com.openai.codex") -> EngineRig {
        makeEngineRig(
            frontmostBundleID: frontmost,
            commandMenu: { config, bundleID in
                AgentDialBuilder.menu(for: config, frontmostBundleID: bundleID, frontmostName: "Codex")
            }
        )
    }

    private func recording(_ rig: EngineRig) -> () -> [AgentMenu?] {
        var published: [AgentMenu?] = []
        rig.engine.onMenuChanged = { published.append($0) }
        return { published }
    }

    // MARK: - The builder

    func testTheDialHasFourSlotsInDirectionOrderAndOpensUnarmed() {
        var config = AppConfig()
        config.profileMode = .auto
        guard let dial = AgentDialBuilder.menu(for: config, frontmostBundleID: codex) else {
            return XCTFail("Codex must get a dial")
        }

        XCTAssertEqual(dial.layout, .dial)
        XCTAssertFalse(dial.hasSelection, "a dial opens with nothing armed")
        XCTAssertNil(dial.selectedItem, "so there is nothing to run")
        XCTAssertEqual(dial.items.map(\.title), ["新建会话", "查看变更", "打开终端", "更多"],
                       "items are in dialSlotOrder: ↑ ← ↓ →")
        XCTAssertEqual(AgentMenu.dialSlotOrder, [.up, .left, .down, .right])
        XCTAssertEqual(dial.items.last?.submenu?.items.map(\.title), ["切换模型", "归档会话"],
                       "「更多」 carries its page, model picker first")
        XCTAssertEqual(dial.hint, "方向选择 · A 执行 · B 关闭")
    }

    func testOnlyCodexGetsADial() {
        var config = AppConfig()
        config.profileMode = .auto

        XCTAssertNil(AgentDialBuilder.menu(for: config, frontmostBundleID: "com.anthropic.claudefordesktop"),
                     "Claude keeps the list")
        XCTAssertNil(AgentDialBuilder.menu(for: config, frontmostBundleID: safari))
        XCTAssertNil(AgentDialBuilder.menu(for: config, frontmostBundleID: nil))
    }

    func testTheSubPageIsOnlyOneLevelDeep() {
        var config = AppConfig()
        config.profileMode = .auto
        let page = AgentDialBuilder.menu(for: config, frontmostBundleID: codex)?.items.last?.submenu

        XCTAssertNotNil(page)
        XCTAssertTrue(
            page?.items.allSatisfy { $0.submenu == nil } == true,
            "root plus one level, and no deeper"
        )
    }

    // MARK: - The opening chord must be fully consumed

    /// `B+←` with the direction released first. The dial must open armed with nothing: if ← reached
    /// it, the left slot (查看变更) would be armed and one press of A would run it.
    func testOpeningWithTheDirectionReleasedFirstArmsNothing() {
        let rig = makeDialRig()
        defer { rig.engine.stop() }

        rig.press(.b, at: 0)
        rig.press(.left, at: 0.05)
        rig.release(.left, at: 0.10)
        rig.release(.b, at: 0.15)

        XCTAssertTrue(rig.engine.isMenuOpen, "B+← opens the dial. Log: \(rig.log())")
        XCTAssertEqual(rig.dispatcher.openMenu?.layout, .dial)
        XCTAssertFalse(rig.dispatcher.openMenu?.hasSelection == true, "no slot may be armed")
        XCTAssertNil(rig.dispatcher.openMenu?.selectedItem)
        XCTAssertEqual(rig.emitter.emissions, [], "and nothing reached Codex")
    }

    /// The other release order, and B released last of all.
    func testOpeningWithBReleasedFirstArmsNothing() {
        let rig = makeDialRig()
        defer { rig.engine.stop() }

        rig.press(.b, at: 0)
        rig.press(.left, at: 0.05)
        rig.release(.b, at: 0.10)
        rig.release(.left, at: 0.15)

        XCTAssertTrue(rig.engine.isMenuOpen, "letting go of B leaves the dial up")
        XCTAssertFalse(rig.dispatcher.openMenu?.hasSelection == true)
        XCTAssertEqual(rig.emitter.emissions, [])
    }

    // MARK: - Arming a slot

    func testEachDirectionArmsItsOwnSlotAndRunsNothing() {
        let rig = makeDialRig()
        defer { rig.engine.stop() }
        openDial(rig)

        let expected: [(PhysicalButton, String)] = [
            (.up, "新建会话"), (.left, "查看变更"), (.down, "打开终端"), (.right, "更多"),
        ]
        var t = 0.2
        for (button, title) in expected {
            rig.press(button, at: t)
            rig.release(button, at: t + 0.05)
            XCTAssertEqual(rig.dispatcher.openMenu?.selectedItem?.title, title,
                           "\(button.rawValue) must arm \(title). Log: \(rig.log())")
            XCTAssertTrue(rig.engine.isMenuOpen, "arming a slot must not close the dial")
            XCTAssertEqual(rig.emitter.emissions, [], "arming a slot must run nothing")
            t += 0.15
        }
    }

    /// Pressing the same direction again is idempotent — it re-arms the same slot and, like every
    /// other direction press, republishes a structurally identical menu so T1.1 only repaints.
    func testRepeatedDirectionsKeepTheSameStructureSoNoRebuildIsNeeded() {
        let rig = makeDialRig()
        defer { rig.engine.stop() }
        let published = recording(rig)
        openDial(rig)
        guard let opened = published().first ?? nil else { return XCTFail("nothing published") }

        for step in 1...4 {
            rig.press(.down, at: 0.2 + Double(step) * 0.1)
            rig.release(.down, at: 0.25 + Double(step) * 0.1)
            guard let latest = published().last ?? nil else { return XCTFail("press \(step) published nothing") }
            XCTAssertTrue(opened.hasSameStructure(as: latest), "only the highlight changes")
        }
        XCTAssertEqual(rig.dispatcher.openMenu?.selectedItem?.title, "打开终端")
    }

    // MARK: - A

    /// A on an unarmed dial: nothing runs, the dial stays up, and nothing is even republished — a
    /// republish would redraw the panel and reset the recognizer for an event that changed nothing.
    func testAWithNothingArmedDoesNothingAndKeepsTheDial() {
        let rig = makeDialRig()
        defer { rig.engine.stop() }
        let published = recording(rig)
        openDial(rig)
        let publishesAfterOpen = published().count

        rig.press(.a, at: 0.3)
        rig.release(.a, at: 0.35)

        XCTAssertTrue(rig.engine.isMenuOpen, "a stray A must not cost the menu")
        XCTAssertEqual(rig.emitter.emissions, [], "and must run nothing. Log: \(rig.log())")
        XCTAssertEqual(published().count, publishesAfterOpen, "nothing changed, so nothing republished")
        XCTAssertFalse(rig.dispatcher.openMenu?.hasSelection == true)
    }

    /// A on an armed slot: exactly one recipe, exactly once, and the dial closes.
    func testAOnAnArmedSlotRunsExactlyThatRecipeOnce() {
        for (button, stroke, title) in [
            (PhysicalButton.up, newChat, "新建会话"),
            (.left, inspectChanges, "查看变更"),
            (.down, openTerminal, "打开终端"),
        ] {
            let rig = makeDialRig()
            defer { rig.engine.stop() }
            openDial(rig)

            rig.press(button, at: 0.2)
            rig.release(button, at: 0.25)
            rig.press(.a, at: 0.3)

            XCTAssertEqual(
                rig.emitter.emissions, [.init(phase: .press, stroke: stroke)],
                "\(title) must send exactly Codex's own binding. Log: \(rig.log())"
            )
            XCTAssertFalse(rig.engine.isMenuOpen, "running a slot closes the dial")
            rig.release(.a, at: 0.35)
            XCTAssertEqual(rig.emitter.emissions.count, 1, "A's release must add nothing")
        }
    }

    /// Holding A down after it ran a slot: no repeat, and the release does not become voice input.
    /// The dial is gone by then, so the release reaches an idle recognizer.
    func testHoldingAAfterRunningASlotNeitherRepeatsNorStartsVoiceInput() {
        let rig = makeDialRig()
        defer { rig.engine.stop() }
        openDial(rig)

        rig.press(.down, at: 0.2)
        rig.release(.down, at: 0.25)
        rig.press(.a, at: 0.3)                  // runs 打开终端, closes the dial
        rig.scheduler.advance(to: 1.5)          // A is still held, well past aHoldMs
        rig.release(.a, at: 1.6)

        XCTAssertEqual(
            rig.emitter.emissions, [.init(phase: .press, stroke: openTerminal)],
            "one recipe, no repeat, no ⌥ and no Enter. Log: \(rig.log())"
        )
    }

    // MARK: - 「更多」 and back

    func testRightThenAOpensTheMorePageAndBComesBackWithoutEscape() {
        let rig = makeDialRig()
        defer { rig.engine.stop() }
        openDial(rig)

        rig.press(.right, at: 0.2)
        rig.release(.right, at: 0.25)
        rig.press(.a, at: 0.3)                  // turn the page

        XCTAssertTrue(rig.engine.isMenuOpen, "a page turn is not a choice")
        XCTAssertEqual(rig.dispatcher.openMenu?.layout, .list, "the page is the ordinary list")
        XCTAssertEqual(rig.dispatcher.openMenu?.items.map(\.title), ["切换模型", "归档会话"])
        XCTAssertEqual(rig.dispatcher.openMenu?.selectedItem?.title, "切换模型", "a list opens on a row")
        XCTAssertEqual(rig.emitter.emissions, [], "turning a page runs nothing")

        rig.release(.a, at: 0.35)
        rig.press(.b, at: 0.4)                  // back to the dial

        XCTAssertTrue(rig.engine.isMenuOpen, "B on the page goes back, it does not close")
        XCTAssertEqual(rig.dispatcher.openMenu?.layout, .dial)
        XCTAssertFalse(rig.dispatcher.openMenu?.hasSelection == true, "and comes back unarmed")
        rig.release(.b, at: 0.45)
        XCTAssertEqual(rig.emitter.emissions, [], "no Escape anywhere in the round trip. Log: \(rig.log())")
    }

    func testARowOnTheMorePageRunsThroughTheNormalPipeline() {
        let rig = makeDialRig()
        defer { rig.engine.stop() }
        openDial(rig)

        rig.press(.right, at: 0.2)
        rig.release(.right, at: 0.25)
        rig.press(.a, at: 0.3)                  // page
        rig.release(.a, at: 0.35)
        rig.press(.a, at: 0.4)                  // run 切换模型

        XCTAssertEqual(rig.emitter.emissions, [.init(phase: .press, stroke: openModelPicker)],
                       "⌃⇧M, Codex's own binding. Log: \(rig.log())")
        XCTAssertFalse(rig.engine.isMenuOpen)
    }

    func testBOnTheDialRootClosesIt() {
        let rig = makeDialRig()
        defer { rig.engine.stop() }
        openDial(rig)

        rig.press(.b, at: 0.3)
        XCTAssertFalse(rig.engine.isMenuOpen, "B on the root closes. Log: \(rig.log())")
        rig.release(.b, at: 0.35)
        XCTAssertEqual(rig.emitter.emissions, [], "and sends no Escape")
    }

    // MARK: - The guard still applies

    func testFocusMovingAwayRefusesASlotAndInjectsNothing() {
        let rig = makeDialRig()
        defer { rig.engine.stop() }
        openDial(rig)

        rig.press(.up, at: 0.2)
        rig.release(.up, at: 0.25)
        rig.frontmost.bundleID = safari
        rig.press(.a, at: 0.3)

        XCTAssertFalse(rig.engine.isMenuOpen, "a refused slot still takes the dial down")
        XCTAssertEqual(rig.emitter.emissions, [], "nothing may reach the app that is in front now")
        XCTAssertTrue(rig.log().contains { $0.contains("menu item refused") }, "Log: \(rig.log())")
    }

    /// Switching app closes the whole tree, sub-page included — there is no page left behind to
    /// come back to.
    func testClosingFromTheSubPageLeavesNoPageBehind() {
        let rig = makeDialRig()
        defer { rig.engine.stop() }
        openDial(rig)

        rig.press(.right, at: 0.2)
        rig.release(.right, at: 0.25)
        rig.press(.a, at: 0.3)
        rig.release(.a, at: 0.35)
        XCTAssertEqual(rig.dispatcher.openMenu?.layout, .list, "on the page")

        rig.engine.closeMenu()                  // what a frontmost change does
        XCTAssertFalse(rig.engine.isMenuOpen)

        rig.engine.openMenu()
        XCTAssertEqual(rig.dispatcher.openMenu?.layout, .dial, "reopening starts at the root")
        XCTAssertFalse(rig.dispatcher.openMenu?.hasSelection == true)
    }

    // MARK: - Helpers

    /// Opens the dial with the real chord and asserts the preconditions every case below relies on.
    private func openDial(_ rig: EngineRig, file: StaticString = #filePath, line: UInt = #line) {
        rig.press(.b, at: 0)
        rig.press(.left, at: 0.05)
        rig.release(.left, at: 0.10)
        rig.release(.b, at: 0.15)
        XCTAssertEqual(rig.dispatcher.openMenu?.layout, .dial, file: file, line: line)
        XCTAssertFalse(rig.dispatcher.openMenu?.hasSelection == true, file: file, line: line)
        XCTAssertEqual(rig.emitter.emissions, [], file: file, line: line)
    }
}
