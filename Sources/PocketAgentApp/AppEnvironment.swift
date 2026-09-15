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

    private(set) var connectedDevice: String?
    private(set) var isAccessibilityGranted: Bool

    /// Called whenever anything the menu displays changes.
    var onStatusChange: (() -> Void)?

    init() {
        configStore = ConfigStore()
        let config = configStore.load()

        let emitter = CGEventEmitter()
        let observer = frontmostObserver

        // The dispatcher reads config live, so profile/allowlist changes take effect immediately.
        let store = configStore
        dispatcher = ActionDispatcher(
            configProvider: { store.config },
            frontmost: observer,
            emitter: emitter
        )

        engine = ControllerEngine(
            dispatcher: dispatcher,
            configuration: config.gestureConfiguration
        )

        isAccessibilityGranted = AccessibilityPermission.isGranted

        wire()
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
            self?.debugLog.append("DENY", "\(action.rawValue): \(reason)")
        }
    }

    private static func describe(_ event: ResolvedEvent) -> String {
        switch event {
        case .keyDown(let button): return "keyDown(\(button.rawValue))"
        case .keyUp(let button): return "keyUp(\(button.rawValue))"
        case .gesture(.tap(let button)): return "tap(\(button.rawValue))"
        case .gesture(.hold(let button)): return "hold(\(button.rawValue))"
        case .gesture(.chord(let modifier, let key)): return "chord(\(modifier.rawValue) + \(key.rawValue))"
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
        engine.start()
    }

    func stop() {
        engine.stop()
    }

    // MARK: - Menu actions

    var activeProfile: ToolProfile { configStore.config.activeProfile }

    func setProfile(_ profile: ToolProfile) {
        configStore.update { $0.activeProfile = profile }
        debugLog.append("APP", "profile → \(profile.rawValue)")
        onStatusChange?()
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
        // Pick up timing changes without a relaunch; the profile and guard are read per dispatch.
        engine.recognizer.configuration = configStore.config.gestureConfiguration
        debugLog.append("APP", "config reloaded (tapMaxMs=\(configStore.config.tapMaxMs), holdMs=\(configStore.config.holdMs))")
        onStatusChange?()
    }

    func refreshAccessibility() {
        let granted = AccessibilityPermission.isGranted
        if granted != isAccessibilityGranted {
            isAccessibilityGranted = granted
            debugLog.append("APP", "Accessibility → \(granted ? "granted" : "revoked")")
        }
        onStatusChange?()
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
