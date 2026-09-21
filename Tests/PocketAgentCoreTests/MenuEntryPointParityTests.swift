import XCTest
@testable import PocketAgentCore

/// The two ways a menu opens must land on the same app (D-ENTRY).
///
/// A menu built for one app and then run against another is the exact mistake the menu exists to
/// prevent, so the dispatcher refuses a row whose session `bundleID` no longer matches the frontmost
/// app. That makes *which app the menu was opened for* load-bearing — and the two entry points
/// learn it differently:
///
/// - the **gesture** path goes through `dispatcher.dispatch`, which reads the frontmost app itself;
/// - the **menu-bar** path goes through `ControllerEngine.openMenu()`, which passes down whatever
///   `engine.frontmost` supplies — nothing at all when nobody assigned it.
///
/// These tests pin that the two agree when the engine has a provider, and pin what breaks when it
/// has none, which is what the app layer did until T0.5.
final class MenuEntryPointParityTests: XCTestCase {
    private let codex = "com.openai.codex"
    private let claude = "com.anthropic.claudefordesktop"
    private let safari = "com.apple.Safari"

    private var apps: [RunningApp] {
        [RunningApp(bundleID: codex, name: "Codex"),
         RunningApp(bundleID: claude, name: "Claude"),
         RunningApp(bundleID: safari, name: "Safari")]
    }

    private final class SpyActivator: AppActivating {
        private(set) var requested: [String] = []
        func activate(bundleID: String) -> AppActivationOutcome {
            requested.append(bundleID)
            return AppActivationOutcome(
                succeeded: true, bundleID: bundleID, method: .appleScript, elapsedMs: 5,
                attempts: [AppActivationAttempt(method: .appleScript, succeeded: true, elapsedMs: 5)])
        }
    }

    /// Everything about an open menu that has to match between the two entry points.
    private struct Snapshot: Equatable, CustomStringConvertible {
        let bundleID: String?
        let title: String
        let selection: Int
        let selectedTitle: String?
        let selectedAction: AgentAction?
        let selectedApp: String?
        let itemTitles: [String]

        init?(_ menu: AgentMenu?) {
            guard let menu else { return nil }
            bundleID = menu.bundleID
            title = menu.title
            selection = menu.selection
            selectedTitle = menu.selectedItem?.title
            selectedAction = menu.selectedItem?.action
            selectedApp = menu.selectedItem?.appBundleID
            itemTitles = menu.items.map(\.title)
        }

        var description: String {
            "bundleID=\(bundleID ?? "nil") title=\(title) selection=\(selection) "
            + "selected=\(selectedTitle ?? "nil") items=\(itemTitles)"
        }
    }

    /// Hold B past `holdMs` and let go — the gesture that opens the app switcher.
    private func holdB(_ rig: EngineRig) {
        rig.press(.b, at: 0)
        rig.scheduler.advance(to: 0.5)          // past holdMs (450 ms)
        rig.release(.b, at: 0.5)
    }

    // MARK: - ② Parity between the entry points

    /// The command menu: same frontmost app, same menu, whichever way it was opened.
    func testMenuBarAndGestureOpenTheSameCommandMenu() {
        let viaMenuBar = makeEngineRig()
        defer { viaMenuBar.engine.stop() }
        XCTAssertTrue(viaMenuBar.engine.openMenu(), "the menu-bar entry point must open the menu")
        let fromMenuBar = Snapshot(viaMenuBar.dispatcher.openMenu)

        let viaGesture = makeEngineRig()
        defer { viaGesture.engine.stop() }
        viaGesture.press(.b, at: 0)
        viaGesture.press(.left, at: 0.05)       // B+←
        let fromGesture = Snapshot(viaGesture.dispatcher.openMenu)

        XCTAssertNotNil(fromMenuBar, "Log: \(viaMenuBar.log())")
        XCTAssertEqual(
            fromMenuBar, fromGesture,
            "the two entry points must build the same menu for the same app"
        )
        XCTAssertEqual(fromMenuBar?.bundleID, codex, "and it must be built for the app in front")
    }

    /// The app switcher: same strip, same starting highlight, whichever way it was opened.
    func testMenuBarAndGestureOpenTheSameAppSwitcher() {
        let viaMenuBar = makeEngineRig(switcherApps: apps)
        defer { viaMenuBar.engine.stop() }
        XCTAssertTrue(viaMenuBar.engine.openAppSwitcher(), "the menu-bar entry point must open the strip")
        let fromMenuBar = Snapshot(viaMenuBar.dispatcher.openMenu)

        let viaGesture = makeEngineRig(switcherApps: apps)
        defer { viaGesture.engine.stop() }
        holdB(viaGesture)
        let fromGesture = Snapshot(viaGesture.dispatcher.openMenu)

        XCTAssertNotNil(fromMenuBar, "Log: \(viaMenuBar.log())")
        XCTAssertEqual(fromMenuBar, fromGesture, "the two entry points must build the same strip")
        XCTAssertEqual(fromMenuBar?.bundleID, codex)
        XCTAssertEqual(fromMenuBar?.selectedApp, claude, "the highlight starts on the previous app")
    }

    /// Running a row is guarded by "is the same app still in front": that guard has to reach the
    /// same verdict, and inject the same keystroke, from both entry points.
    func testARowRunsIdenticallyFromBothEntryPoints() {
        let viaMenuBar = makeEngineRig()
        defer { viaMenuBar.engine.stop() }
        viaMenuBar.engine.openMenu()
        let action = viaMenuBar.dispatcher.openMenu?.selectedItem?.action
        viaMenuBar.press(.a, at: 0.10)

        let viaGesture = makeEngineRig()
        defer { viaGesture.engine.stop() }
        viaGesture.press(.b, at: 0)
        viaGesture.press(.left, at: 0.05)
        viaGesture.press(.a, at: 0.10)

        guard let action, let stroke = viaMenuBar.stroke(for: action) else {
            return XCTFail("the first row must be a runnable command. Log: \(viaMenuBar.log())")
        }
        XCTAssertEqual(
            viaMenuBar.emitter.emissions, [.init(phase: .press, stroke: stroke)],
            "the menu-bar path must pass the guard and inject the row's recipe. Log: \(viaMenuBar.log())"
        )
        XCTAssertEqual(
            viaMenuBar.emitter.emissions, viaGesture.emitter.emissions,
            "both entry points must inject the same thing"
        )
        XCTAssertFalse(viaMenuBar.engine.isMenuOpen)
        XCTAssertFalse(viaGesture.engine.isMenuOpen)
    }

    /// Choosing an app from the strip: same activation from both entry points, and no keystroke.
    func testAStripChoiceActivatesTheSameAppFromBothEntryPoints() {
        let menuBarActivator = SpyActivator()
        let viaMenuBar = makeEngineRig(switcherApps: apps, activator: menuBarActivator)
        defer { viaMenuBar.engine.stop() }
        viaMenuBar.engine.openAppSwitcher()
        viaMenuBar.press(.a, at: 0.10)

        let gestureActivator = SpyActivator()
        let viaGesture = makeEngineRig(switcherApps: apps, activator: gestureActivator)
        defer { viaGesture.engine.stop() }
        holdB(viaGesture)
        viaGesture.press(.a, at: 0.60)

        XCTAssertEqual(
            menuBarActivator.requested, [claude],
            "the strip's A must not be refused for a nil session bundleID. Log: \(viaMenuBar.log())"
        )
        XCTAssertEqual(menuBarActivator.requested, gestureActivator.requested)
        XCTAssertEqual(viaMenuBar.emitter.emissions, [], "switching apps types nothing")
    }

    // MARK: - ① The shape of the bug this card fixes

    /// With no frontmost provider on the engine, the menu-bar path hands `nil` down. In auto mode
    /// that resolves to the fallback profile, which offers no rows — so the menu simply never opens,
    /// and the log says why.
    func testWithoutAFrontmostProviderTheMenuBarPathCannotOpenTheMenu() {
        let rig = makeEngineRig(frontmostProvided: false)
        defer { rig.engine.stop() }

        XCTAssertFalse(rig.engine.openMenu(), "nil frontmost cannot build a menu in auto mode")
        XCTAssertFalse(rig.engine.isMenuOpen)
        XCTAssertFalse(
            rig.log().contains { $0.contains("MENU  opened for") },
            "nothing was opened, so nothing may be logged as opened. Log: \(rig.log())"
        )

        // The gesture path is unaffected: the dispatcher reads the frontmost app itself.
        rig.press(.b, at: 0)
        rig.press(.left, at: 0.05)
        XCTAssertTrue(rig.engine.isMenuOpen, "B+← still opens it. Log: \(rig.log())")
        XCTAssertEqual(rig.dispatcher.openMenu?.bundleID, codex)
    }

    /// Manual profile mode is where it gets worse: the menu *does* open, for `nil`, so it is logged
    /// as `opened for ?` and every row is then refused because the real frontmost app does not match
    /// the session it was built for.
    func testWithoutAFrontmostProviderAManualModeMenuOpensForNobodyAndRefusesEveryRow() {
        let rig = makeEngineRig(frontmostProvided: false) { config in
            config.profileMode = .manual
            config.activeProfile = .codex
        }
        defer { rig.engine.stop() }

        XCTAssertTrue(rig.engine.openMenu(), "manual mode builds a menu regardless of the app")
        XCTAssertNil(rig.dispatcher.openMenu?.bundleID, "but it belongs to no app")
        XCTAssertTrue(
            rig.log().contains { $0.contains("MENU  opened for ?") },
            "this is the log line the acceptance criteria call out. Log: \(rig.log())"
        )

        rig.press(.a, at: 0.10)
        XCTAssertEqual(rig.emitter.emissions, [], "every row is refused, so nothing is injected")
        XCTAssertTrue(
            rig.log().contains { $0.contains("menu item refused") },
            "refused because nil != the real frontmost app. Log: \(rig.log())"
        )
    }

    /// And the strip has the same problem: it opens, but choosing an app is refused, so the
    /// menu-bar app switcher cannot switch to anything.
    func testWithoutAFrontmostProviderTheStripRefusesEveryChoice() {
        let activator = SpyActivator()
        let rig = makeEngineRig(frontmostProvided: false, switcherApps: apps, activator: activator)
        defer { rig.engine.stop() }

        XCTAssertTrue(rig.engine.openAppSwitcher(), "the strip does not care about the profile")
        XCTAssertNil(rig.dispatcher.openMenu?.bundleID)

        rig.press(.a, at: 0.10)
        XCTAssertEqual(
            activator.requested, [],
            "nothing was activated: the choice was refused. Log: \(rig.log())"
        )
    }

    /// With a provider, the non-nil frontmost app is what actually reaches the session — the Core
    /// half of the acceptance criteria.
    func testTheProvidedFrontmostAppIsHandedToTheMenuSession() {
        let rig = makeEngineRig(frontmostBundleID: claude)
        defer { rig.engine.stop() }

        XCTAssertTrue(rig.engine.openMenu())
        XCTAssertEqual(rig.dispatcher.openMenu?.bundleID, claude, "Log: \(rig.log())")
        XCTAssertTrue(
            rig.log().contains { $0.contains("MENU  opened for \(claude)") },
            "and the log names it instead of '?'. Log: \(rig.log())"
        )
    }
}
