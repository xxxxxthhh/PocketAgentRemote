import AppKit
import Foundation
import PocketAgentCore
import ServiceManagement

/// Supplies the frontmost application to the guard, live.
final class FrontmostAppObserver: FrontmostAppProviding {
    func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }
}

/// Which shape the command menu takes. Development-time only (G2 prototype, T1.3).
///
/// In-process and **not persisted**: it exists so a trial can switch between the shipped list and
/// the dial between runs without a config key that would outlive the experiment. It costs no
/// controller button either — the menu bar is the only way to change it.
enum CommandMenuLayout {
    case list
    case dial
}

/// Owns the whole running system: config, controller engine, adapters, emitter.
final class AppEnvironment {
    let configStore: ConfigStore
    let debugLog = DebugLog()
    let frontmostObserver = FrontmostAppObserver()

    private(set) var engine: ControllerEngine
    private(set) var dispatcher: ActionDispatcher
    /// Raises one of the two agent apps. Also used by the menu's manual smoke action.
    let activator: AppActivator
    /// The on-screen menu the controller can drive.
    let overlay: MenuOverlayController
    /// Short messages for things that did not happen. Independent of `overlay` in every respect.
    let failureToast = FailureToastController()
    /// Which command menu to build. Changed from the menu bar, never stored. The dial only exists
    /// for Codex, so this has no effect anywhere else.
    var commandMenuLayout: CommandMenuLayout = .list {
        didSet { onStatusChange?() }
    }
    /// Running apps in recency order, for the app switcher (hold B).
    let runningApps = RunningAppsTracker()

    /// Sleep/wake observers, kept so `stop()` can take them down again.
    private var workspaceObservers: [NSObjectProtocol] = []

    /// F9. How often the Accessibility grant is re-read.
    ///
    /// There is no notification for losing it — it is revoked in System Settings, by a re-sign, or
    /// by a system update, and this process is told nothing — so polling is the only way to notice
    /// before the user does. Seven seconds is the middle of the card's 5–10 s window: the failure it
    /// catches (every keystroke silently dropped) is worth a cheap `AXIsProcessTrusted()` that often.
    private static let accessibilityPollInterval: TimeInterval = 7
    private var accessibilityTimer: Timer?

    /// The two F9 notices. Written once so the startup case and the revoke case cannot drift apart.
    private static let accessibilityLostMessage = "辅助功能权限已失效：按键会被系统丢弃，去设置重新勾选"
    private static let accessibilityRestoredMessage = "辅助功能权限已恢复"

    private(set) var connectedDevice: String?
    private(set) var isAccessibilityGranted: Bool
    private(set) var inputMonitoringState: InputMonitoringPermission.State
    /// The last "focus the other agent" result, shown in the menu so the feature is observable
    /// without opening the debug log.
    private(set) var lastActivationSummary: String?

    /// Called whenever anything the menu displays changes.
    var onStatusChange: (() -> Void)?

    init() {
        configStore = ConfigStore()
        let config = configStore.load()
        AppEnvironment.adoptMenuChordIfNeeded(store: configStore)
        AppEnvironment.adoptBackspaceChordIfNeeded(store: configStore)

        let emitter = CGEventEmitter()
        let observer = frontmostObserver
        let activator = AppActivator(frontmost: observer)
        self.activator = activator

        let overlay = MenuOverlayController(frontmost: observer)
        self.overlay = overlay

        // The dispatcher reads config live, so profile/allowlist changes take effect immediately.
        let store = configStore
        let dispatcher = ActionDispatcher(
            configProvider: { store.config },
            frontmost: observer,
            emitter: emitter,
            activator: activator
        )
        self.dispatcher = dispatcher

        engine = ControllerEngine(
            dispatcher: dispatcher,
            gestureOverrides: config.gestureOverrides(for: config.activeProfile),
            configuration: config.gestureConfiguration
        )

        isAccessibilityGranted = AccessibilityPermission.isGranted
        inputMonitoringState = InputMonitoringPermission.state

        wire()
    }

    /// One-time: a per-profile `b.left` override written before 2026-09-16 still wins over the new
    /// default, which would leave that profile unable to open the menu at all. Change it once, keep a
    /// backup, and say so in the log — never silently.
    private static func adoptMenuChordIfNeeded(store: ConfigStore) {
        var probe = store.config
        guard ConfigMigrations.adoptMenuChord(&probe) else { return }
        // Back up before touching anything, so the hand-written original always exists.
        let backup = store.backUp()
        let outcome = store.update { config in
            ConfigMigrations.adoptMenuChord(&config)
        }
        let place = backup.map { "backup: \($0.lastPathComponent)" } ?? "no backup could be written"
        NSLog("PocketAgentRemote: removed a stale b.left override so B+← opens the menu (\(place), save=\(outcome))")
    }

    /// Same treatment for `b.a`: the old two-button voice grab, which every config from that week
    /// carries verbatim, would otherwise keep `B+A` from becoming backspace.
    private static func adoptBackspaceChordIfNeeded(store: ConfigStore) {
        var probe = store.config
        guard ConfigMigrations.adoptBackspaceChord(&probe) else { return }
        let backup = store.backUp()
        let outcome = store.update { config in
            ConfigMigrations.adoptBackspaceChord(&config)
        }
        let place = backup.map { "backup: \($0.lastPathComponent)" } ?? "no backup could be written"
        NSLog("PocketAgentRemote: removed the old b.a voice override so B+A is backspace (\(place), save=\(outcome))")
    }

    private func wire() {
        engine.onDiagnostic = { [weak self] message in self?.debugLog.append("SOURCE", message) }
        engine.onControllerAttached = { [weak self] name in
            self?.connectedDevice = name
            self?.debugLog.append("DEVICE", "connected: \(name)")
            self?.onStatusChange?()
        }
        engine.onControllerDetached = { [weak self] name in
            self?.connectedDevice = nil
            self?.debugLog.append("DEVICE", "disconnected: \(name) — gesture state reset")
            self?.onStatusChange?()
        }
        engine.onRawEvent = { [weak self] event in
            self?.debugLog.append("RAW", "\(event.isPress ? "press  " : "release") \(event.button.rawValue)")
        }
        engine.onGesture = { [weak self] events in
            for event in events { self?.debugLog.append("GESTURE", Self.describe(event)) }
        }

        dispatcher.onDiagnostic = { [weak self] message in self?.debugLog.append("OUTPUT", message) }
        dispatcher.onUnsupported = { [weak self] action, reason in
            guard let self else { return }
            self.debugLog.append("SKIP", "\(action.rawValue): \(reason)")
            self.showFailure(self.unsupportedMessage(action, reason))
        }
        dispatcher.onDenied = { [weak self] action, reason in
            guard let self else { return }
            let label = action?.rawValue ?? "<gesture override>"
            self.debugLog.append("DENY", "\(label): \(reason)")
            self.showFailure(self.deniedMessage(action, reason))
        }
        // Focusing an app emits no keystroke, so it gets its own line: otherwise a press that did
        // nothing would look identical to a press that was never recognised.
        dispatcher.onActivation = { [weak self] action, outcome in
            guard let self else { return }
            guard !self.isSuppressingLateActivation(action.rawValue, outcome) else { return }
            self.debugLog.append("FOCUS", "\(action.rawValue): \(AppActivationReport.describe(outcome))")
            self.lastActivationSummary = AppActivationReport.describe(outcome)
            // Only failures are shown. A successful switch is self-evident — the other app is now in
            // front — and this batch deliberately adds no success feedback.
            if !outcome.succeeded { self.showFailure(self.activationMessage(outcome)) }
            self.onStatusChange?()
        }

        // The menu is built from the adapter of whatever is in front, so it only ever offers rows
        // that can actually run (and shows the matching app's name in its header).
        dispatcher.menuBuilder = { [weak self] bundleID in
            guard let self else { return nil }
            let config = self.configStore.config
            let name = self.frontmostObserver.frontmostAppName()
            // The dial is the experiment; the list is what ships. `AgentDialBuilder` returns nil for
            // anything but Codex, so Claude keeps the list whatever this is set to — the fallback is
            // the same call the list mode makes, not a second code path.
            if self.commandMenuLayout == .dial,
               let dial = AgentDialBuilder.menu(
                   for: config, frontmostBundleID: bundleID, frontmostName: name) {
                return dial
            }
            return AgentMenuBuilder.menu(
                for: config,
                frontmostBundleID: bundleID,
                frontmostName: name
            )
        }
        // The app switcher lists whatever is running, regardless of profile: it is the one menu
        // that must work from a browser or a terminal, because getting back to an agent from there
        // is its whole point.
        dispatcher.switcherBuilder = { [weak self] bundleID in
            guard let self else { return nil }
            let pair = self.configStore.config.agentPair
            // The two agents keep the names config gives them ("Codex", not "ChatGPT"), as the
            // command menu's header already does; everything else shows its own localized name.
            let apps = self.runningApps.runningApps(frontmostBundleID: bundleID).map { app in
                RunningApp(bundleID: app.bundleID, name: pair.name(for: app.bundleID) ?? app.name)
            }
            return AppSwitcherBuilder.menu(apps: apps, frontmostBundleID: bundleID)
        }
        // G4: when the app in front is not an agent there is no command menu, and the dispatcher
        // falls back to that app's own menu bar — read live through Accessibility, filtered by the
        // builder, pressed through Accessibility too. Nothing here synthesises a shortcut.
        dispatcher.appMenuReader = AccessibilityMenuReader()
        dispatcher.appMenuBuilder = { [weak self] bundleID, entries in
            guard let self else { return nil }
            return AppMenuBuilder.menu(
                entries: entries,
                bundleID: bundleID,
                // The app's own localized name, which is what its menu bar says — the bundle ID is
                // only a header of last resort.
                appName: self.frontmostObserver.frontmostAppName() ?? bundleID ?? "前台程序",
                favorites: self.configStore.config.appMenuFavorites(for: bundleID)
            )
        }
        // F3: a selection move republishes the *same* menu with a new highlight, and rebuilding the
        // whole panel for that made moving through a 17-app strip cost 17 view rebuilds, a fresh
        // frontmost-poll timer and a log line per press. So the contents decide which way to go:
        // structurally identical and already on screen → repaint the highlight only.
        //
        // No log line here any more. This closure runs on every press, so anything written here is
        // per-*draw* noise; the menu's lifecycle (opened / running / switching / closed by B /
        // closed / refused) is reported by the dispatcher, which is the layer that knows which of
        // those actually happened.
        engine.onMenuChanged = { [weak self] menu in
            guard let self else { return }
            if let menu {
                if self.overlay.isVisible, self.overlay.menu?.hasSameStructure(as: menu) == true {
                    self.overlay.render(menu)
                } else {
                    self.overlay.show(menu)
                }
            } else {
                // Read the F3 probes before `hide()` clears them. Deliberately its own tag: it is a
                // temporary measurement, and it must not spend the menu's log budget.
                self.debugLog.append(
                    "OVERLAY",
                    "session ended: rebuild=\(self.overlay.rebuildCount) timer=\(self.overlay.timerCreationCount)"
                )
                self.overlay.hide()
            }
            self.onStatusChange?()
        }
        // The overlay can go away on its own (focus moved, controller gone). Tell the engine, which
        // owns the gesture side of the menu: it closes the dispatcher's session *and* resets the
        // recognizer. Doing only the first half once left the two disagreeing, and an ↑ then went
        // through as a real arrow key instead of moving the selection.
        overlay.onDismiss = { [weak self] in
            guard let self else { return }
            guard self.engine.isMenuOpen else { return }
            self.engine.closeMenu()   // logs `MENU  closed` from the dispatcher
            self.onStatusChange?()
        }

        // In auto mode the profile follows the frontmost app, so the gesture table is re-resolved
        // before every event.
        engine.gestureOverridesProvider = { [weak self] in
            self?.gestureOverridesForCurrentFrontmostApp() ?? [:]
        }
        // The menu-bar entry points (`showControllerMenu` / `showAppSwitcher`) go through the engine,
        // which passes *this* down as the app the menu is built for. Unassigned it passed nil, and a
        // session built for nobody is refused at execution time by the "same app still in front"
        // check — so the menu bar could open a strip but never switch with it. The gesture path was
        // unaffected because the dispatcher reads the frontmost app itself.
        engine.frontmost = frontmostObserver
    }

    private static func describe(_ event: ResolvedEvent) -> String {
        switch event {
        case .keyDown(let button): return "keyDown(\(button.rawValue))"
        case .keyUp(let button): return "keyUp(\(button.rawValue))"
        case .gesture(.tap(let button)): return "tap(\(button.rawValue))"
        case .gesture(.hold(let button)): return "hold(\(button.rawValue))"
        case .gesture(.chord(let modifier, let key)): return "chord(\(modifier.rawValue) + \(key.rawValue))"
        case .gesture(.chordReleased(let modifier, let key)):
            return "chordReleased(\(modifier.rawValue) + \(key.rawValue))"
        case .gesture(.holdBegan(let button)):
            return "holdBegan(\(button.rawValue))"
        case .gesture(.holdEnded(let button)):
            return "holdEnded(\(button.rawValue))"
        }
    }

    func start() {
        debugLog.append("APP", "starting — config: \(configStore.url.path)")
        if let warning = configStore.loadWarning {
            debugLog.append("APP", "config warning: \(warning)")
        }
        if !isAccessibilityGranted {
            debugLog.append("APP", "Accessibility is NOT granted — keystrokes will be dropped by the OS")
            // Launching without it is the same fact as losing it, so it says the same thing. The
            // menu bar badge below says it again, permanently, for after the toast has gone.
            showFailure(Self.accessibilityLostMessage)
        }
        debugLog.append("APP", "Input Monitoring: \(inputMonitoringState.rawValue) — only the generic C variant needs it")
        engine.start()
        observeSleepWake()
        startAccessibilityPolling()
    }

    func stop() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        engine.stop()
        overlay.hide()
    }

    // MARK: - Sleep / wake

    /// F10. These are `NSWorkspace`'s notifications, not `NotificationCenter.default`'s — the
    /// distributed ones are the only place `willSleep` / `didWake` are posted.
    ///
    /// Cleaning up on the way *in* is the point: a direction that is down when the lid closes stays
    /// down in the target application for the whole sleep, and waiting for the wake to notice is
    /// exactly the failure this is for.
    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleWillSleep() })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleDidWake() })
    }

    private func handleWillSleep() {
        engine.suspend()
        // `suspend()` already took the menu down through `onMenuChanged`; these two cover the
        // screen-side leftovers that have no menu session behind them — a toast counting down, and
        // an overlay that outlived its session.
        overlay.hide()
        failureToast.hide()
        debugLog.append("SLEEP", "suspended — keys released, gesture and menu state cleared")
    }

    private func handleDidWake() {
        engine.resume()
        // Accessibility and Input Monitoring survive a sleep, but a system update installed during
        // one does not: re-reading is what makes a revoked grant visible without a relaunch.
        refreshAccessibility()
        debugLog.append("WAKE", "resumed — gesture state clean, permissions re-read")
        debugLog.append("WAKE", "controller: \(connectedDevice ?? "none connected")")
    }

    /// The longest an activation can honestly take: `AppActivator` gives the first method
    /// `defaultVerificationTimeout` and the fallback `defaultFallbackTimeout`, both measured on a
    /// wall clock, and this app builds its activator with exactly those defaults. The multiplier is
    /// slack for a busy main queue — the answer this is separating out is minutes late, not seconds.
    private static let activationSanityBudgetMs = Int(
        (AppActivator.defaultVerificationTimeout + AppActivator.defaultFallbackTimeout) * 3 * 1000
    )

    /// True when an activation answer belongs to a request the machine slept through.
    ///
    /// Two ways to tell, and both are needed. The obvious one is that we are still asleep. The one
    /// that actually fires is the second: `AppActivator` measures its timeouts on a **wall** clock
    /// and schedules its poll on a **mach** one (which does not tick during sleep), so a switch that
    /// was in flight when the lid closed does not answer during the sleep at all — it answers about
    /// a second *after* the wake, having failed the first method on "the frontmost app did not
    /// change within 4000 ms" and then run the fallback's full budget. By then `resume()` has
    /// already cleared `isSuspended`. What gives it away is `elapsedMs`: it is wall-clock, and the
    /// activator cannot legitimately produce one past its own budget.
    ///
    /// Either way it is logged — a swallowed answer with no trace is worse — but it raises no toast
    /// and moves no state the menu shows, success or failure: it is about a moment the user is no
    /// longer in.
    ///
    /// Blind spot, deliberately left: a sleep shorter than the budget is indistinguishable from a
    /// slow switch, so it still reports. That is the right way round — a five-second nap and a slow
    /// WeChat look the same to the user too.
    private func isSuppressingLateActivation(_ label: String, _ outcome: AppActivationOutcome) -> Bool {
        let reason: String
        if engine.isSuspended {
            reason = "answered while asleep"
        } else if outcome.elapsedMs > Self.activationSanityBudgetMs {
            reason = "took \(outcome.elapsedMs) ms — a sleep happened in the middle"
        } else {
            return false
        }
        debugLog.append("FOCUS", "\(label): \(reason), ignored — \(AppActivationReport.describe(outcome))")
        return true
    }

    // MARK: - Menu actions

    /// Manual smoke test for the cross-app switch: same code path the gesture uses, minus the
    /// controller. Useful because "the button did nothing" and "the app was not running" look
    /// identical from the sofa.
    func focusOtherAgentNow() {
        let config = configStore.config
        guard let target = config.focusOtherAgentTarget(
            frontmostBundleID: frontmostObserver.frontmostBundleID()
        ) else {
            debugLog.append("FOCUS", "manual: the agent pair in config is empty")
            // Same mapper as the dispatcher path, so the two entry points cannot drift apart.
            showFailure(unsupportedMessage(.focusOtherAgent, "the agent pair in config is empty"))
            return
        }
        activator.activate(bundleID: target) { [weak self] outcome in
            guard let self else { return }
            guard !self.isSuppressingLateActivation("manual", outcome) else { return }
            self.lastActivationSummary = AppActivationReport.describe(outcome)
            self.debugLog.append("FOCUS", "manual: \(self.lastActivationSummary ?? "")")
            // This path calls the activator directly, so it never reaches `dispatcher.onActivation`
            // — it has to show its own failure or the menu-bar entry point would stay silent.
            if !outcome.succeeded { self.showFailure(self.activationMessage(outcome)) }
            self.onStatusChange?()
        }
    }

    /// True while the on-screen menu is up.
    var isMenuVisible: Bool { overlay.isVisible }

    // MARK: - Failure messages

    /// Shows one short Chinese message. The single display path, so every failure looks the same
    /// wherever it came from.
    private func showFailure(_ message: String) {
        failureToast.show(message)
        debugLog.append("TOAST", message)
    }

    /// "已拦截：…" — the guard refused, or a menu row was refused because focus moved.
    ///
    /// The reason arrives as the English text `ActionGuard` (or the menu refusal) built, so this
    /// matches on it. That is a coupling to those strings and they live in this same repo; if a
    /// third reason is ever added the fallback shows it verbatim rather than lying.
    private func deniedMessage(_ action: AgentAction?, _ reason: String) -> String {
        if reason.contains("menu item refused") {
            return "已拦截：前台已切换，菜单项未执行"
        }
        // G4 v2: the app never changed, the window did — and 「前台已切换」 would be a lie the user
        // could check against their own screen.
        if reason.contains("app menu context changed") {
            return "已拦截：窗口已切换，菜单项未执行"
        }
        if reason.contains("requires an explicit profile") {
            return "已拦截：当前是通用模式，工具专属动作不发送"
        }
        if reason.contains("macros are disabled") {
            return "已拦截：宏未启用"
        }
        if reason.contains("cannot determine the frontmost") {
            return "已拦截：读不到前台程序"
        }
        if reason.contains("not in the allowlist") {
            return "已拦截：前台不是 agent（不在白名单）"
        }
        return "已拦截：\(actionLabel(action))（\(reason)）"
    }

    /// "<工具> 不支持：…" for an adapter gap, and a plain reason for the environmental refusals
    /// that now arrive on the same hook.
    private func unsupportedMessage(_ action: AgentAction, _ reason: String) -> String {
        // G4: the row was shown, so the user is owed the reason it did not run. The item's own state
        // and the app's are told apart, because "greyed out" is normal and "no answer" is not.
        if action == .openMenu {
            if reason.contains("app menu item is disabled") {
                return "菜单项已不可用"
            }
            if reason.contains("app menu item no longer exists") {
                return "找不到该菜单项"
            }
            if reason.contains("app menu unavailable") || reason.contains("app menu press failed") {
                return "App 未响应"
            }
            if reason.contains("app menu reader unavailable") {
                return "打不开菜单：本次构建未接入通用菜单"
            }
            if reason.contains("the frontmost app is unknown") {
                return "打不开菜单：读不到前台程序"
            }
        }
        if reason.contains("no agent in front") {
            return "打不开菜单：前台不是 agent"
        }
        if reason.contains("fewer than two apps") {
            return "打不开切换器：可切换的程序不足两个"
        }
        if reason.contains("not wired up") {
            return "切换失败：本次构建未接入程序激活"
        }
        if reason.contains("agent pair in config is empty") {
            return "切换失败：配置里没有设置两个 agent"
        }
        return "\(profileLabel()) 不支持：\(actionLabel(action))"
    }

    /// "切换失败：<程序>（<原因>）" — the reason comes from the activator, not from a string match.
    private func activationMessage(_ outcome: AppActivationOutcome) -> String {
        let name = configStore.config.agentPair.name(for: outcome.bundleID)
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: outcome.bundleID)
                .first?.localizedName
            ?? outcome.bundleID
        return "切换失败：\(name)（\(outcome.reason ?? "未知原因")）"
    }

    /// The Chinese label a menu already uses for this action, so the toast and the menu agree.
    ///
    /// The menus are the primary source — a row and a toast naming the same action differently would
    /// be worse than either. Gesture-only actions appear in no menu, so they get the short names
    /// below; anything still unnamed shows its identifier rather than a guess.
    private func actionLabel(_ action: AgentAction?) -> String {
        guard let action else { return "该手势" }
        let overrides = configStore.config.overrides
        for profile in ToolProfile.allCases {
            if let title = AdapterCatalog.adapter(for: profile, overrides: overrides)
                .menuItems.first(where: { $0.action == action })?.title {
                return title
            }
        }
        switch action {
        case .goToRecentChat1: return "最近会话 1"
        case .goToRecentChat2: return "最近会话 2"
        case .nextChatNeedingAttention: return "待处理会话"
        case .focusOtherAgent: return "切到另一个 agent"
        case .openMenu: return "手柄菜单"
        case .openAppSwitcher: return "程序切换器"
        case .submit: return "提交"
        case .cancelOrInterrupt: return "取消"
        case .navigateUp, .navigateDown, .navigateLeft, .navigateRight: return "方向键"
        default: return action.rawValue
        }
    }

    private func profileLabel() -> String {
        switch configStore.config.resolvedProfile(
            frontmostBundleID: frontmostObserver.frontmostBundleID()
        ) {
        case .codex: return "Codex"
        case .claudeCode: return "Claude"
        case .genericTerminal: return "通用模式"
        }
    }

    /// Opens the controller's menu from the menu bar — the same code path as `B+←`, for when the
    /// controller is not in hand.
    func showControllerMenu() {
        engine.openMenu()
    }

    /// Opens the app switcher from the menu bar — the same code path as holding B.
    func showAppSwitcher() {
        if !engine.openAppSwitcher() {
            debugLog.append("MENU", "app switcher: fewer than two apps to switch between")
        }
    }

    /// The profile in force right now — in auto mode this follows the frontmost application.
    var activeProfile: ToolProfile {
        configStore.config.resolvedProfile(frontmostBundleID: frontmostObserver.frontmostBundleID())
    }

    var profileMode: ProfileMode { configStore.config.profileMode }

    func setProfileMode(_ mode: ProfileMode) {
        configStore.update { $0.profileMode = mode }
        applyGestureOverrides()
        debugLog.append("APP", "profile mode → \(mode.rawValue)")
        onStatusChange?()
    }

    func setProfile(_ profile: ToolProfile) {
        // Picking a profile by hand only makes sense in manual mode.
        configStore.update {
            $0.activeProfile = profile
            $0.profileMode = .manual
        }
        applyGestureOverrides()
        debugLog.append("APP", "profile → \(profile.rawValue) (manual)")
        onStatusChange?()
    }

    /// Gesture bindings can differ per profile (Codex and Claude share almost no shortcuts), so this
    /// has to run on a profile switch, a mode switch and a config reload.
    private func applyGestureOverrides() {
        let config = configStore.config
        let profile = config.resolvedProfile(frontmostBundleID: frontmostObserver.frontmostBundleID())
        let overrides = config.gestureOverrides(for: profile)
        engine.gestureOverrides = overrides

        let unknownGestures = config.unknownGestureIDs(for: profile)
        if !unknownGestures.isEmpty {
            debugLog.append("APP", "unrecognised gesture ids (ignored): \(unknownGestures.joined(separator: ", "))")
        }
        let unknownProfiles = config.unknownProfileNames
        if !unknownProfiles.isEmpty {
            debugLog.append("APP", "unrecognised profile names (ignored): \(unknownProfiles.joined(separator: ", "))")
        }
        debugLog.append("APP", "gesture overrides for \(profile.rawValue) [\(config.profileMode.rawValue)]: \(overrides.count)")
    }

    /// Auto mode follows the frontmost app, so the override table has to be re-resolved per event.
    private func gestureOverridesForCurrentFrontmostApp() -> [String: GestureOverride] {
        let config = configStore.config
        let profile = config.resolvedProfile(frontmostBundleID: frontmostObserver.frontmostBundleID())
        return config.gestureOverrides(for: profile)
    }

    func setMacrosEnabled(_ enabled: Bool) {
        configStore.update { $0.macrosEnabled = enabled }
        debugLog.append("APP", "macros → \(enabled ? "on" : "off")")
        onStatusChange?()
    }

    func setRequireAllowedFrontmostApp(_ required: Bool) {
        configStore.update { $0.requireAllowedFrontmostApp = required }
        debugLog.append("APP", "require allowlisted frontmost app → \(required)")
        onStatusChange?()
    }

    func reloadConfig() {
        configStore.load()
        // Pick up timing and binding changes without a relaunch; the profile and guard are read
        // per dispatch.
        engine.recognizer.configuration = configStore.config.gestureConfiguration
        applyGestureOverrides()
        let config = configStore.config
        debugLog.append("APP", "config reloaded (tapMaxMs=\(config.tapMaxMs), holdMs=\(config.holdMs))")
        onStatusChange?()
    }

    func refreshAccessibility() {
        noteAccessibilityChange()
        inputMonitoringState = InputMonitoringPermission.state
        onStatusChange?()
    }

    /// F9. Re-reads the grant and announces a **transition**, once. Returns whether it moved.
    ///
    /// Only the two edges do anything: granted → revoked raises the notice and badges the menu bar,
    /// revoked → granted takes both back. Staying revoked says nothing further — the badge is the
    /// standing reminder, and a toast every seven seconds would be the nagging the card rules out.
    ///
    /// Every entry point shares this: the poll, the menu opening, and the wake. Which one noticed
    /// does not change what the user is told.
    @discardableResult
    private func noteAccessibilityChange() -> Bool {
        let granted = AccessibilityPermission.isGranted
        guard granted != isAccessibilityGranted else { return false }
        isAccessibilityGranted = granted
        debugLog.append("APP", "Accessibility → \(granted ? "granted" : "revoked")")
        // Deliberately the same display path as a refused keystroke: one toast, one place, so a
        // permission notice cannot end up looking like a different kind of message.
        showFailure(granted ? Self.accessibilityRestoredMessage : Self.accessibilityLostMessage)
        return true
    }

    /// F9's timer. Deliberately narrower than `refreshAccessibility()`: it reads **only** the
    /// Accessibility grant.
    ///
    /// Input Monitoring is left out because it is not a required permission — only the generic C
    /// controller variant needs it, so the menu reports it and nothing chases it. And nothing is
    /// published when nothing changed: the status item would otherwise be rebuilt every seven
    /// seconds for a picture that is already correct.
    private func startAccessibilityPolling() {
        let timer = Timer(timeInterval: Self.accessibilityPollInterval, repeats: true) { [weak self] _ in
            guard let self, self.noteAccessibilityChange() else { return }
            self.onStatusChange?()
        }
        // `.common`, not the default mode: a timer in the default mode stops while a menu is open
        // or a window is being dragged, which is exactly when the user is looking at the thing this
        // keeps up to date.
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTimer = timer
    }

    func requestInputMonitoring() {
        inputMonitoringState = InputMonitoringPermission.request()
        debugLog.append("APP", "Input Monitoring → \(inputMonitoringState.rawValue)")
        onStatusChange?()
    }

    func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    func requestAccessibility() {
        let granted = AccessibilityPermission.requestIfNeeded()
        isAccessibilityGranted = granted
        debugLog.append("APP", "Accessibility request shown (currently \(granted ? "granted" : "not granted"))")
        onStatusChange?()
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Launch at login (F8)

    /// The login-item registration, read straight from the system every time.
    ///
    /// Deliberately not mirrored into config or into a stored flag: the user can turn this off in
    /// System Settings without telling us, and a cached checkbox would then be lying. It is also
    /// the reason `.requiresApproval` is a state the menu has to draw — `register()` can succeed
    /// and still leave the item switched off on the other side.
    var launchAtLoginStatus: SMAppService.Status { SMAppService.mainApp.status }

    /// Registers or unregisters **the bundle this process is running from**.
    ///
    /// So it only means anything inside a real `.app` bundle; a `swift run` process has no bundle
    /// to register and `register()` throws. Note `.notFound` is *also* what a never-registered
    /// bundle reports on macOS 27 (measured 2026-09-21), so it is not a reliable "no bundle" signal.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            // The resulting status, not the requested one: registering while the item is switched
            // off in System Settings succeeds and stays `requiresApproval`, and that line is the
            // only thing that explains why the checkbox did not come on.
            debugLog.append(
                "APP",
                "Launch at Login → \(enabled ? "registered" : "unregistered") (status: \(Self.describe(launchAtLoginStatus)))"
            )
        } catch {
            debugLog.append(
                "APP",
                "Launch at Login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)"
            )
            showFailure("开机自启\(enabled ? "打开" : "关闭")失败（\(error.localizedDescription)）")
        }
        onStatusChange?()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    func openConfigFile() {
        if !FileManager.default.fileExists(atPath: configStore.url.path) {
            try? configStore.save()
        }
        NSWorkspace.shared.open(configStore.url)
    }
}
