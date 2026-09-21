import XCTest
@testable import PocketAgentCore

/// The Core half of F3: what the app layer is allowed to assume when it decides between repainting
/// the highlight and rebuilding the panel.
///
/// `AppEnvironment` takes that decision in one line — `overlay.isVisible && overlay.menu?
/// .hasSameStructure(as: menu) == true → render, else show` — and the app has no test target, so the
/// premises it rests on are pinned here instead, against the **real** dispatcher output rather than
/// a hand-written menu:
///
/// - a selection move really does republish a structurally identical menu (otherwise the render
///   branch would never be taken, and F3 would be a no-op);
/// - a reopen republishes a structurally *identical* menu too, which is exactly why `isVisible` has
///   to be part of the condition and structure alone is not enough;
/// - navigation writes no `MENU` log line, so the lifecycle log stays readable.
final class MenuRedrawContractTests: XCTestCase {
    private let codex = "com.openai.codex"
    private let claude = "com.anthropic.claudefordesktop"
    private let safari = "com.apple.Safari"

    private var apps: [RunningApp] {
        [RunningApp(bundleID: codex, name: "Codex"),
         RunningApp(bundleID: claude, name: "Claude"),
         RunningApp(bundleID: safari, name: "Safari")]
    }

    /// Everything `engine.onMenuChanged` hands the app, in order. This is the app's input.
    private func recording(_ rig: EngineRig) -> () -> [AgentMenu?] {
        var published: [AgentMenu?] = []
        rig.engine.onMenuChanged = { published.append($0) }
        return { published }
    }

    private func menuLines(_ rig: EngineRig) -> [String] {
        rig.log().filter { $0.contains("MENU") }
    }

    // MARK: - ② The render branch is reachable

    /// Five presses of → on the strip: one menu published per press, all structurally identical to
    /// the one the open produced, every one with a different highlight.
    func testNavigatingRepublishesTheSameStructureWithANewSelection() {
        let rig = makeEngineRig(switcherApps: apps)
        defer { rig.engine.stop() }
        let published = recording(rig)

        XCTAssertTrue(rig.engine.openAppSwitcher())
        guard let opened = published().first ?? nil else {
            return XCTFail("opening must publish a menu. Log: \(rig.log())")
        }

        var selections: [Int] = [opened.selection]
        for step in 1...5 {
            rig.press(.right, at: Double(step) * 0.1)
            rig.release(.right, at: Double(step) * 0.1 + 0.05)
            guard let latest = published().last ?? nil else {
                return XCTFail("press #\(step) published nothing. Log: \(rig.log())")
            }
            XCTAssertTrue(
                opened.hasSameStructure(as: latest),
                "press #\(step) must be a highlight change, not a new menu. Log: \(rig.log())"
            )
            selections.append(latest.selection)
        }

        XCTAssertEqual(published().count, 6, "one publish for the open, one per press")
        XCTAssertEqual(
            selections, [1, 2, 0, 1, 2, 0],
            "the highlight really moved (and wrapped) across three apps"
        )
    }

    /// The same for the command list's ↑↓.
    func testNavigatingTheCommandListAlsoRepublishesTheSameStructure() {
        let rig = makeEngineRig()
        defer { rig.engine.stop() }
        let published = recording(rig)

        rig.press(.b, at: 0)
        rig.press(.left, at: 0.05)              // B+←
        guard let opened = published().first ?? nil else {
            return XCTFail("B+← must publish a menu. Log: \(rig.log())")
        }

        for step in 1...3 {
            rig.press(.down, at: 0.2 + Double(step) * 0.1)
            rig.release(.down, at: 0.25 + Double(step) * 0.1)
            guard let latest = published().last ?? nil else {
                return XCTFail("press #\(step) published nothing")
            }
            XCTAssertTrue(opened.hasSameStructure(as: latest), "press #\(step) must only move the highlight")
            XCTAssertNotEqual(latest.selection, opened.selection)
        }
    }

    /// A reopen publishes a menu that is structurally identical to the closed one — so structure
    /// alone would wrongly take the render branch onto a hidden panel. This is why the app also
    /// checks `overlay.isVisible`.
    func testAReopenPublishesTheSameStructureWhichIsWhyVisibilityIsAlsoChecked() {
        let rig = makeEngineRig(switcherApps: apps)
        defer { rig.engine.stop() }
        let published = recording(rig)

        rig.engine.openAppSwitcher()
        let first = published().first ?? nil
        rig.press(.b, at: 0.2)                  // B closes it
        XCTAssertFalse(rig.engine.isMenuOpen)
        XCTAssertNil(published().last ?? nil, "closing publishes nil")

        rig.engine.openAppSwitcher()
        let second = published().last ?? nil

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertTrue(
            first?.hasSameStructure(as: second!) == true,
            "the same apps in the same order: identical structure, but the panel is hidden"
        )
    }

    /// A menu for a different app must not be mistaken for a highlight change.
    func testADifferentAppsMenuIsAStructureChange() {
        let rig = makeEngineRig(frontmostBundleID: codex)
        defer { rig.engine.stop() }
        let published = recording(rig)

        rig.engine.openMenu()
        let forCodex = published().last ?? nil
        rig.press(.b, at: 0.2)

        rig.frontmost.bundleID = claude
        rig.engine.openMenu()
        let forClaude = published().last ?? nil

        XCTAssertNotNil(forCodex)
        XCTAssertNotNil(forClaude)
        XCTAssertFalse(
            forCodex?.hasSameStructure(as: forClaude!) == true,
            "a different app means a rebuild. Log: \(rig.log())"
        )
    }

    // MARK: - ④ The log says what happened, once

    /// Moving the selection is not a lifecycle event: it must write no `MENU` line at all, so the
    /// per-draw `open for …` noise cannot come back in another form.
    func testNavigatingWritesNoMenuLogLine() {
        let rig = makeEngineRig(switcherApps: apps)
        defer { rig.engine.stop() }

        rig.engine.openAppSwitcher()
        let afterOpen = menuLines(rig)
        XCTAssertEqual(afterOpen.count, 1, "the open itself is one line: \(afterOpen)")

        for step in 1...5 {
            rig.press(.right, at: Double(step) * 0.1)
            rig.release(.right, at: Double(step) * 0.1 + 0.05)
        }

        XCTAssertEqual(
            menuLines(rig), afterOpen,
            "five presses must add nothing to the MENU log. Added: \(menuLines(rig).dropFirst(afterOpen.count))"
        )
    }

    /// One complete switch — open, five moves, choose — and the exact `MENU` lines it writes.
    ///
    /// Pinned as an exact list rather than a count: this is the log the report quotes, and it is
    /// also where a reviewer checks that the per-draw `open for …` noise is really gone. Eight apps
    /// so five presses land on a different app instead of wrapping back to the one in front.
    func testACompleteSwitchWritesExactlyTwoMenuLines() {
        final class Spy: AppActivating {
            func activate(bundleID: String, completion: @escaping (AppActivationOutcome) -> Void) {
                completion(AppActivationOutcome(
                    succeeded: true, bundleID: bundleID, method: .appleScript, elapsedMs: 5,
                    attempts: [AppActivationAttempt(method: .appleScript, succeeded: true, elapsedMs: 5)]))
            }
        }
        let many = (0..<7).map { RunningApp(bundleID: "app.\($0)", name: "App \($0)") }
        let rig = makeEngineRig(
            switcherApps: [RunningApp(bundleID: codex, name: "Codex")] + many,
            activator: Spy()
        )
        defer { rig.engine.stop() }

        rig.engine.openAppSwitcher()
        for step in 1...5 {
            rig.press(.right, at: Double(step) * 0.1)
            rig.release(.right, at: Double(step) * 0.1 + 0.05)
        }
        rig.press(.a, at: 1.0)

        XCTAssertEqual(
            menuLines(rig),
            ["DISP MENU  app switcher opened with 8 apps",
             "DISP MENU  switching to app.5 (App 5)"],
            "one open, one switch, and nothing per press"
        )
    }

    /// An externally closed menu (focus moved, controller unplugged) used to leave no trace at all.
    func testAnExternalCloseIsReported() {
        let rig = makeEngineRig()
        defer { rig.engine.stop() }

        rig.engine.openMenu()
        rig.engine.closeMenu()

        XCTAssertTrue(
            rig.log().contains { $0.contains("MENU  closed") },
            "closing without running anything is a lifecycle event. Log: \(rig.log())"
        )
    }

    /// And a detach-close is reported too — that path never reaches the app's overlay callback, so
    /// the dispatcher is the only layer that can report it.
    func testADetachCloseIsReported() {
        let rig = makeEngineRig()
        defer { rig.engine.stop() }

        rig.engine.openMenu()
        rig.source.onDetach?("Wireless Controller")

        XCTAssertFalse(rig.engine.isMenuOpen)
        XCTAssertTrue(
            rig.log().contains { $0.contains("MENU  closed") },
            "a disconnect used to close the menu silently. Log: \(rig.log())"
        )
    }
}
