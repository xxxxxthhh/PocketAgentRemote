import AppKit
import Foundation

/// How an attempt to bring an agent to the front was made.
///
/// This is data rather than an implementation detail because **which method works is a measured
/// fact about the OS, not something the code can assume** (see `AppActivator`'s note).
public enum AppActivationMethod: String, Sendable, CaseIterable {
    /// `NSRunningApplication.activate(options:)` — in-process, fastest, currently ineffective.
    case runningApplication
    /// `NSAppleScript` + `tell application "X" to activate` — the only path that works here.
    case appleScript
}

/// One attempt: what was tried, and how long it took to give up on it.
public struct AppActivationAttempt: Equatable, Sendable {
    public var method: AppActivationMethod
    public var succeeded: Bool
    public var elapsedMs: Int
    public var reason: String?

    public init(method: AppActivationMethod, succeeded: Bool, elapsedMs: Int, reason: String? = nil) {
        self.method = method
        self.succeeded = succeeded
        self.elapsedMs = elapsedMs
        self.reason = reason
    }
}

/// The result of "put this bundle ID in front", including **which** method won.
///
/// The caller (the menu bar) logs the winner, so a future macOS that changes the rules shows up as
/// a changed diagnostic line instead of a silent failure.
public struct AppActivationOutcome: Equatable, Sendable {
    public var succeeded: Bool
    public var bundleID: String
    public var method: AppActivationMethod?
    public var elapsedMs: Int
    public var attempts: [AppActivationAttempt]
    public var reason: String?

    public init(
        succeeded: Bool,
        bundleID: String,
        method: AppActivationMethod? = nil,
        elapsedMs: Int,
        attempts: [AppActivationAttempt],
        reason: String? = nil
    ) {
        self.succeeded = succeeded
        self.bundleID = bundleID
        self.method = method
        self.elapsedMs = elapsedMs
        self.attempts = attempts
        self.reason = reason
    }
}

/// Brings some other application to the front.
///
/// A protocol for the same reason `InputEmitting` is one: the dispatcher has to be testable without
/// launching or focusing a real application.
public protocol AppActivating: AnyObject {
    func activate(bundleID: String) -> AppActivationOutcome
}

/// Which app "the other agent" means, given the pair from config.
///
/// Pure, and deliberately free of any `NSWorkspace` call: deciding what is in front is the caller's
/// job (it already has to read it for the guard), so the toggle rule stays a testable function.
public enum AgentPairResolver {
    /// The side of `agentBundleIDs` opposite the one the user is on.
    ///
    /// `anchor` is the position to move away from. It is the frontmost agent when the user is in one,
    /// and the left side when the user is somewhere else entirely — a browser, a terminal — which is
    /// what makes "switch agent" predictable from outside the pair too.
    public static func otherAnchor(from anchor: String?, agentBundleIDs: [String]) -> String? {
        let agents = agentBundleIDs.filter { !$0.isEmpty }
        guard let anchor, agents.contains(anchor) else { return agents.first }
        return agents.first { $0 != anchor }
    }
}

/// Puts a desktop app in front.
///
/// ## Why this is not a keystroke
///
/// Switching the frontmost application is a **system effect**, not input to an application, so it
/// cannot be expressed as an `OutputRecipe` keystroke and must not go through the allowlist guard
/// (the whole point is that it works from anywhere — including a browser, where no agent chord is
/// allowed to fire). `ActionDispatcher` therefore handles it on its own branch.
///
/// ## Why AppleScript leads
///
/// Measured on this machine, macOS 27, from a non-bundled process **and** from a bundled, signed,
/// ad-hoc-signed probe app:
///
/// | Method | Result |
/// |---|---|
/// | `NSRunningApplication.activate(options:)` (SDK default) | ✗ no effect | <!-- SDK-DEFAULT -->
/// | `NSRunningApplication.activate(options: [.activateIgnoringOtherApps])` | ✗ no effect (deprecated, "will have no effect" in macOS 14+) |
/// | `NSRunningApplication.activate(options: [.activateAllWindows])` | ✗ no effect |
/// | AX `kAXFrontmostAttribute = true` | ✗ returns `.success`, no effect |
/// | AX raise the main window, then `kAXFrontmost` | ✗ no effect |
/// | synthesised `⌘⇥` | ✗ no effect |
/// | `NSWorkspace.openApplication(_:configuration:.activates)` | ✗ no effect |
/// | **`tell application "X" to activate`** | **✓ works, both directions, repeatedly, no TCC prompt** |
/// | `tell application id "X" to activate` (current form) | resolves by id verified from a shell (`get name`); activate-by-id from inside the app is pending the user's §L run |
///
/// The in-process calls are not *wrong* so much as unverified on the target OS, so they stay as a
/// cheap first attempt: several hundred milliseconds of latency is worth avoiding when they do
/// work. The AppleScript path is the one this feature depends on, which is why it is the default
/// (`methodOrder`) and why the provenance of the target apps is reported so it can be renamed.
///
/// `NSAppleEventsUsageDescription` in the bundle's `Info.plist` is required for the AppleScript
/// path; on this machine it never even prompted, but a denied Automation grant would surface here
/// as an AppleScript error rather than as nothing happening.
public final class AppActivator: AppActivating, @unchecked Sendable {
    /// How long to wait for the fast path before falling back to AppleScript.
    ///
    /// Measured: the working path lands well inside 500 ms, and the frontmost app is re-read after
    /// this, so a generous wait costs nothing on the path that already works.
    public static let defaultVerificationTimeout: TimeInterval = 0.5
    public static let defaultPollInterval: TimeInterval = 0.05

    /// Order in which methods are tried. AppleScript first because it is the one that works.
    public var methodOrder: [AppActivationMethod] = [.appleScript, .runningApplication]

    private let frontmost: FrontmostAppProviding
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval

    public init(
        frontmost: FrontmostAppProviding,
        timeout: TimeInterval = AppActivator.defaultVerificationTimeout,
        pollInterval: TimeInterval = AppActivator.defaultPollInterval
    ) {
        self.frontmost = frontmost
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    public func activate(bundleID: String) -> AppActivationOutcome {
        let started = Date()
        let frontmostBefore = frontmost.frontmostBundleID()

        var attempts: [AppActivationAttempt] = []

        for method in methodOrder {
            let attemptStart = Date()
            let failure = perform(method, bundleID: bundleID)

            if let failure {
                attempts.append(AppActivationAttempt(
                    method: method,
                    succeeded: false,
                    elapsedMs: milliseconds(since: attemptStart),
                    reason: failure
                ))
                continue
            }

            if waitUntilFocused(bundleID) {
                attempts.append(AppActivationAttempt(
                    method: method,
                    succeeded: true,
                    elapsedMs: milliseconds(since: attemptStart)
                ))
                return AppActivationOutcome(
                    succeeded: true,
                    bundleID: bundleID,
                    method: method,
                    elapsedMs: milliseconds(since: started),
                    attempts: attempts
                )
            }

            attempts.append(AppActivationAttempt(
                method: method,
                succeeded: false,
                elapsedMs: milliseconds(since: attemptStart),
                reason: "request accepted but the frontmost app did not change"
            ))
        }

        let reasons = attempts.compactMap(\.reason)
        return AppActivationOutcome(
            succeeded: false,
            bundleID: bundleID,
            elapsedMs: milliseconds(since: started),
            attempts: attempts,
            reason: reasons.isEmpty
                ? "no activation method was available"
                : "all methods failed (frontmost was \(frontmostBefore ?? "unknown")): \(reasons.joined(separator: "; "))"
        )
    }

    // MARK: - Methods

    /// Returns a reason when the method could not even be attempted.
    private func perform(_ method: AppActivationMethod, bundleID: String) -> String? {
        switch method {
        case .runningApplication:
            guard let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first
            else { return "app is not running" }
            app.activate(options: [.activateAllWindows])
            return nil

        case .appleScript:
            guard NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first != nil
            else { return "app is not running" }
            // Addressed by bundle ID, not by name. Names are localized and need not be unique, and
            // since the app switcher any running app can be a target — `application id` is the
            // form that cannot pick the wrong one. Verified to resolve on this machine
            // (`tell application id "com.openai.codex" to get name` → ChatGPT).
            let escaped = bundleID.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            var error: NSDictionary?
            NSAppleScript(source: "tell application id \"\(escaped)\" to activate")?
                .executeAndReturnError(&error)
            if let error {
                let number = error[NSAppleScript.errorNumber] ?? "?"
                let message = error[NSAppleScript.errorMessage] ?? "unknown AppleScript error"
                return "AppleScript error \(number): \(message)"
            }
            return nil
        }
    }

    private func waitUntilFocused(_ bundleID: String) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if frontmost.frontmostBundleID() == bundleID { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return frontmost.frontmostBundleID() == bundleID
    }

    private func milliseconds(since date: Date) -> Int {
        Int((Date().timeIntervalSince(date) * 1000).rounded())
    }
}

/// Runs an activation and reports the outcome — used by the menu's manual smoke action.
public enum AppActivationReport {
    public static func describe(_ outcome: AppActivationOutcome) -> String {
        let tried = outcome.attempts
            .map { "\($0.method.rawValue)\($0.succeeded ? "✓" : "✗")" }
            .joined(separator: " → ")
        if outcome.succeeded {
            return "focused \(outcome.bundleID) via \(outcome.method?.rawValue ?? "?") in \(outcome.elapsedMs) ms"
        }
        return "could not focus \(outcome.bundleID) (\(tried)): \(outcome.reason ?? "unknown reason")"
    }
}
