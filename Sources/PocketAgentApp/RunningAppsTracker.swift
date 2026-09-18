import AppKit
import Foundation
import PocketAgentCore

/// Lists the running applications for the app switcher, most recently used first.
///
/// `NSWorkspace` exposes no recency order, so this watches activation notifications from the moment
/// the app launches and keeps its own. Apps that have not been activated since then follow, in the
/// order `NSWorkspace` lists them — which is why the strip is only ⌘⇥-accurate for apps used after
/// PocketAgentRemote started. The frontmost app is always forced to the front, because the
/// notification for it can lag the moment the user holds B.
final class RunningAppsTracker {
    /// Bundle IDs, most recent first.
    private var recent: [String] = []
    private var observer: NSObjectProtocol?
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        if let front = workspace.frontmostApplication?.bundleIdentifier {
            recent = [front]
        }
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier
            else { return }
            self?.noteActivated(bundleID)
        }
    }

    deinit {
        if let observer { workspace.notificationCenter.removeObserver(observer) }
    }

    private func noteActivated(_ bundleID: String) {
        recent.removeAll { $0 == bundleID }
        recent.insert(bundleID, at: 0)
    }

    /// Dock-visible (`.regular`) apps only, so menu bar utilities — this one included — never appear.
    func runningApps(frontmostBundleID: String?) -> [RunningApp] {
        if let frontmostBundleID { noteActivated(frontmostBundleID) }

        var seen: Set<String> = []
        var apps: [RunningApp] = []
        for app in workspace.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated {
            guard let bundleID = app.bundleIdentifier, seen.insert(bundleID).inserted else { continue }
            apps.append(RunningApp(bundleID: bundleID, name: app.localizedName ?? bundleID))
        }

        // Apps that have quit fall out of the recency list here rather than on a timer.
        recent.removeAll { id in !seen.contains(id) }
        let rank = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($1, $0) })
        return apps.enumerated()
            .sorted { lhs, rhs in
                (rank[lhs.element.bundleID] ?? Int.max, lhs.offset)
                    < (rank[rhs.element.bundleID] ?? Int.max, rhs.offset)
            }
            .map(\.element)
    }
}
