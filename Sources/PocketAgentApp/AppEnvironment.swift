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
            self?.debugLog.append("SKIP", "\(action.rawValue): \(reason)")
        }
        dispatcher.onDenied = { [weak self] action, reason in
            let label = action?.rawValue ?? "<gesture override>"
            self?.debugLog.append("DENY", "\(label): \(reason)")
        }
        // Focusing an app emits no keystroke, so it gets its own line: otherwise a press that did
        // nothing would look identical to a press that was never recognised.
        dispatcher.onActivation = { [weak self] action, outcome in
            guard let self else { return }
            self.debugLog.append("FOCUS", "\(action.rawValue): \(AppActivationReport.describe(outcome))")
            self.lastActivationSummary = AppActivationReport.describe(outcome)
            self.onStatusChange?()
        }

        // The menu is built from the adapter of whatever is in front, so it only ever offers rows
        // that can actually run (and shows the matching app's name in its header).
        dispatcher.menuBuilder = { [weak self] bundleID in
            guard let self else { return nil }
            return AgentMenuBuilder.menu(
                for: self.configStore.config,
                frontmostBundleID: bundleID,
                frontmostName: self.frontmostObserver.frontmostAppName()
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
        engine.onMenuChanged = { [weak self] menu in
            guard let self else { return }
            if let menu {
                self.debugLog.append("MENU", "open for \(menu.title): \(menu.items.map(\.title).joined(separator: " / "))")
                self.overlay.show(menu)
            } else {
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
            self.engine.closeMenu()
            self.debugLog.append("MENU", "closed")
            self.onStatusChange?()
        }

        // In auto mode the profile follows the frontmost app, so the gesture table is re-resolved
        // before every event.
        engine.gestureOverridesProvider = { [weak self] in
            self?.gestureOverridesForCurrentFrontmostApp() ?? [:]
        }
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
            return nil
        }
        let outcome = activator.activate(bundleID: target)
        lastActivationSummary = AppActivationReport.describe(outcome)
        debugLog.append("FOCUS", "manual: \(lastActivationSummary ?? "")")
        onStatusChange?()
        return outcome
    }

    /// True while the on-screen menu is up.
    var isMenuVisible: Bool { overlay.isVisible }

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
