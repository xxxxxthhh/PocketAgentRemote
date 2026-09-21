import AppKit
import Foundation
import PocketAgentCore

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
        }
        debugLog.append("APP", "Input Monitoring: \(inputMonitoringState.rawValue) — only the generic C variant needs it")
        engine.start()
    }

    func stop() {
        engine.stop()
        overlay.hide()
    }

    // MARK: - Menu actions

    /// Manual smoke test for the cross-app switch: same code path the gesture uses, minus the
    /// controller. Useful because "the button did nothing" and "the app was not running" look
    /// identical from the sofa.
    @discardableResult
    func focusOtherAgentNow() -> AppActivationOutcome? {
        let config = configStore.config
        guard let target = config.focusOtherAgentTarget(
            frontmostBundleID: frontmostObserver.frontmostBundleID()
        ) else {
            debugLog.append("FOCUS", "manual: the agent pair in config is empty")
            // Same mapper as the dispatcher path, so the two entry points cannot drift apart.
            showFailure(unsupportedMessage(.focusOtherAgent, "the agent pair in config is empty"))
            return nil
        }
        let outcome = activator.activate(bundleID: target)
        lastActivationSummary = AppActivationReport.describe(outcome)
        debugLog.append("FOCUS", "manual: \(lastActivationSummary ?? "")")
        // This path calls the activator directly, so it never reaches `dispatcher.onActivation` —
        // it has to show its own failure or the menu-bar entry point would stay silent.
        if !outcome.succeeded { showFailure(activationMessage(outcome)) }
        onStatusChange?()
        return outcome
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
        let granted = AccessibilityPermission.isGranted
        if granted != isAccessibilityGranted {
            isAccessibilityGranted = granted
            debugLog.append("APP", "Accessibility → \(granted ? "granted" : "revoked")")
        }
        inputMonitoringState = InputMonitoringPermission.state
        onStatusChange?()
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

    func openConfigFile() {
        if !FileManager.default.fileExists(atPath: configStore.url.path) {
            try? configStore.save()
        }
        NSWorkspace.shared.open(configStore.url)
    }
}
