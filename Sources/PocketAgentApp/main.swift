import AppKit
import Foundation

/// Entry point for the menu bar app.
///
/// Launch is intentionally boring: an accessory (no Dock icon) AppKit app whose only UI is the
/// status item. Anything that needs Accessibility or the codex/claude apps is handled inside
/// `AppEnvironment`, so this file stays trivial.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment()
        self.environment = environment

        let menuBar = MenuBarController(environment: environment)
        self.menuBar = menuBar

        environment.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave a modifier or arrow key held in someone else's app.
        environment?.stop()
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let delegate = AppDelegate()
application.delegate = delegate
application.run()
