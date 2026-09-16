import AppKit
import Foundation
import PocketAgentCore

/// The menu bar item and its menu (spec §17).
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let environment: AppEnvironment
    private var monitor: DebugMonitorWindowController?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = Self.symbol(connected: false)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self

        environment.onStatusChange = { [weak self] in self?.refreshStatusItem() }
        refreshStatusItem()
    }

    private static func symbol(connected: Bool) -> NSImage? {
        let name = connected ? "gamecontroller.fill" : "gamecontroller"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: connected ? "Controller connected" : "Controller disconnected")
        image?.isTemplate = true
        return image
    }

    private func refreshStatusItem() {
        let connected = environment.connectedDevice != nil
        statusItem.button?.image = Self.symbol(connected: connected)
        statusItem.button?.toolTip = connected
            ? "\(environment.connectedDevice ?? "controller") — \(environment.activeProfile.rawValue)"
            : "No controller connected"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        environment.refreshAccessibility()

        // Status
        let state = environment.connectedDevice.map { "Connected: \($0)" } ?? "No controller connected"
        menu.addItem(disabled(state))
        if environment.profileMode == .auto {
            menu.addItem(disabled("Profile: \(profileTitle(environment.activeProfile))  (auto)"))
        } else {
            menu.addItem(disabled("Profile: \(profileTitle(environment.activeProfile))  (manual)"))
        }
        menu.addItem(disabled("Frontmost: \(environment.frontmostObserver.frontmostAppName() ?? "unknown")"))
        menu.addItem(.separator())

        // Profile mode — auto follows the frontmost app.
        let modeItem = NSMenuItem(title: "Profile Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for mode in ProfileMode.allCases {
            let item = NSMenuItem(title: modeTitle(mode), action: #selector(selectProfileMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == environment.profileMode ? .on : .off
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // Profile picker — only meaningful in manual mode (spec §6.4).
        let profileItem = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        let profileMenu = NSMenu()
        let autoMode = environment.profileMode == .auto
        for profile in ToolProfile.allCases {
            let item = NSMenuItem(title: profileTitle(profile), action: #selector(selectProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.rawValue
            item.state = profile == environment.activeProfile ? .on : .off
            item.isEnabled = !autoMode
            profileMenu.addItem(item)
        }
        if autoMode {
            profileMenu.addItem(.separator())
            profileMenu.addItem(disabled("Auto — switch to Manual to pick one"))
        }
        profileItem.submenu = profileMenu
        menu.addItem(profileItem)

        // Accessibility
        if environment.isAccessibilityGranted {
            menu.addItem(disabled("Accessibility: Granted"))
        } else {
            let item = NSMenuItem(title: "Accessibility: Required — open Settings", action: #selector(openAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            let prompt = NSMenuItem(title: "Request Accessibility Permission", action: #selector(requestAccessibility), keyEquivalent: "")
            prompt.target = self
            menu.addItem(prompt)
        }

        // Input Monitoring — only the generic C variant needs it, so it is reported but never nagged.
        switch environment.inputMonitoringState {
        case .granted:
            menu.addItem(disabled("Input Monitoring: Granted"))
        case .denied:
            let item = NSMenuItem(title: "Input Monitoring: Denied — open Settings", action: #selector(openInputMonitoring), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        case .unknown:
            let item = NSMenuItem(title: "Input Monitoring: not determined (needed only for the generic C variant)", action: #selector(requestInputMonitoring), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        // Safety switches
        let macros = NSMenuItem(title: "Macros", action: #selector(toggleMacros), keyEquivalent: "")
        macros.target = self
        macros.state = environment.configStore.config.macrosEnabled ? .on : .off
        menu.addItem(macros)

        let allowlist = NSMenuItem(title: "Require allowlisted frontmost app", action: #selector(toggleAllowlist), keyEquivalent: "")
        allowlist.target = self
        allowlist.state = environment.configStore.config.requireAllowedFrontmostApp ? .on : .off
        menu.addItem(allowlist)

        menu.addItem(disabled("Allowed apps: \(environment.configStore.config.allowedBundleIDs.count)"))
        menu.addItem(.separator())

        // Tools
        let monitorItem = NSMenuItem(title: "Open Input Monitor…", action: #selector(openMonitor), keyEquivalent: "d")
        monitorItem.target = self
        menu.addItem(monitorItem)

        let configItem = NSMenuItem(title: "Open Config File", action: #selector(openConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)

        let reloadItem = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit PocketAgentRemote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func profileTitle(_ profile: ToolProfile) -> String {
        switch profile {
        case .genericTerminal: return "Generic Terminal"
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        }
    }

    private func modeTitle(_ mode: ProfileMode) -> String {
        switch mode {
        case .auto: return "Auto — follow the frontmost app"
        case .manual: return "Manual — pick one below"
        }
    }

    @objc private func selectProfileMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ProfileMode(rawValue: raw) else { return }
        environment.setProfileMode(mode)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let profile = ToolProfile(rawValue: raw) else { return }
        environment.setProfile(profile)
    }

    @objc private func toggleMacros() {
        environment.setMacrosEnabled(!environment.configStore.config.macrosEnabled)
    }

    @objc private func toggleAllowlist() {
        environment.setRequireAllowedFrontmostApp(!environment.configStore.config.requireAllowedFrontmostApp)
    }

    @objc private func openAccessibility() {
        environment.openAccessibilitySettings()
    }

    @objc private func requestAccessibility() {
        environment.requestAccessibility()
    }

    @objc private func requestInputMonitoring() {
        environment.requestInputMonitoring()
    }

    @objc private func openInputMonitoring() {
        environment.openInputMonitoringSettings()
    }

    @objc private func openMonitor() {
        if monitor == nil {
            monitor = DebugMonitorWindowController(log: environment.debugLog)
        }
        monitor?.show()
    }

    @objc private func openConfig() {
        environment.openConfigFile()
    }

    @objc private func reloadConfig() {
        environment.reloadConfig()
    }
}
