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
    /// Sends the activation request now and reports once the app is in front or the wait ran out.
    ///
    /// Asynchronous on purpose: some apps take seconds to answer the Apple event (WeChat: ~2 s
    /// measured), and blocking the caller for that froze the controller and the overlay. The
    /// completion is delivered on the main queue.
    func activate(bundleID: String, completion: @escaping (AppActivationOutcome) -> Void)
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
public final class AppActivator: AppActivating {
    /// How long the first method gets to land before the next one is tried.
    ///
    /// Generous because it costs nothing on the common path — the poll returns as soon as the app
    /// is in front, typically inside 150 ms — and because the slow apps are genuinely slow: WeChat
    /// takes about two seconds to answer `activate` and lands after that. The old 0.5 s reported
    /// those as failures and then watched them succeed.
    public static let defaultVerificationTimeout: TimeInterval = 4.0
    /// The fallback method's budget. It has never been seen to work here (see the table above), so
    /// it gets a short one.
    public static let defaultFallbackTimeout: TimeInterval = 1.0
    public static let defaultPollInterval: TimeInterval = 0.05

    /// Order in which methods are tried. AppleScript first because it is the one that works.
    public var methodOrder: [AppActivationMethod] = [.appleScript, .runningApplication]

    /// Sends one activation request and reports, on the main queue, whether the *request* failed
    /// (nil = accepted). Whether the app then actually came to the front is the poll's business.
    public typealias Requester = (AppActivationMethod, String, @escaping (String?) -> Void) -> Void

    private let frontmost: FrontmostAppProviding
    private let timeout: TimeInterval
    private let fallbackTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let scheduler: GestureScheduler
    private let clock: () -> TimeInterval
    private let isRunning: (String) -> Bool
    private let requester: Requester

    /// The production initialiser. The remaining parameters exist so a test can stand in a slow or
    /// failing target and a manual clock without touching AppleScript.
    public init(
        frontmost: FrontmostAppProviding,
        timeout: TimeInterval = AppActivator.defaultVerificationTimeout,
        fallbackTimeout: TimeInterval = AppActivator.defaultFallbackTimeout,
        pollInterval: TimeInterval = AppActivator.defaultPollInterval,
        scheduler: GestureScheduler = DispatchGestureScheduler(),
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        isRunning: ((String) -> Bool)? = nil,
        requester: Requester? = nil
    ) {
        self.frontmost = frontmost
        self.timeout = timeout
        self.fallbackTimeout = fallbackTimeout
        self.pollInterval = pollInterval
        self.scheduler = scheduler
        self.clock = clock
        self.isRunning = isRunning ?? { bundleID in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }
        self.requester = requester ?? AppActivator.send
    }

    public func activate(bundleID: String, completion: @escaping (AppActivationOutcome) -> Void) {
        let started = clock()
        let frontmostBefore = frontmost.frontmostBundleID()

        guard isRunning(bundleID) else {
            completion(AppActivationOutcome(
                succeeded: false,
                bundleID: bundleID,
                elapsedMs: milliseconds(since: started),
                attempts: methodOrder.map {
                    AppActivationAttempt(method: $0, succeeded: false, elapsedMs: 0, reason: "app is not running")
                },
                reason: "app is not running"
            ))
            return
        }

        tryMethod(at: 0, bundleID: bundleID, started: started, frontmostBefore: frontmostBefore,
                  attempts: [], completion: completion)
    }

    private func tryMethod(
        at index: Int,
        bundleID: String,
        started: TimeInterval,
        frontmostBefore: String?,
        attempts: [AppActivationAttempt],
        completion: @escaping (AppActivationOutcome) -> Void
    ) {
        guard index < methodOrder.count else {
            let reasons = attempts.compactMap(\.reason)
            completion(AppActivationOutcome(
                succeeded: false,
                bundleID: bundleID,
                elapsedMs: milliseconds(since: started),
                attempts: attempts,
                reason: reasons.isEmpty
                    ? "no activation method was available"
                    : "all methods failed (frontmost was \(frontmostBefore ?? "unknown")): \(reasons.joined(separator: "; "))"
            ))
            return
        }

        let method = methodOrder[index]
        let attemptStart = clock()
        let deadline = attemptStart + (index == 0 ? timeout : fallbackTimeout)
        // One outcome per attempt, whichever of the request's reply and the poll gets there first.
        var finished = false
        var pollToken: GestureSchedulerToken?

        let succeed: () -> Void = { [self] in
            finished = true
            pollToken?.cancel()
            var attempts = attempts
            attempts.append(AppActivationAttempt(
                method: method, succeeded: true, elapsedMs: milliseconds(since: attemptStart)))
            completion(AppActivationOutcome(
                succeeded: true,
                bundleID: bundleID,
                method: method,
                elapsedMs: milliseconds(since: started),
                attempts: attempts
            ))
        }
        let fail: (String) -> Void = { [self] reason in
            finished = true
            pollToken?.cancel()
            var attempts = attempts
            attempts.append(AppActivationAttempt(
                method: method, succeeded: false, elapsedMs: milliseconds(since: attemptStart), reason: reason))
            tryMethod(at: index + 1, bundleID: bundleID, started: started, frontmostBefore: frontmostBefore,
                      attempts: attempts, completion: completion)
        }

        // The poll does not wait for the request to be answered: WeChat answers late, and the
        // frontmost app is the only thing that counts anyway.
        func poll() {
            guard !finished else { return }
            if frontmost.frontmostBundleID() == bundleID {
                succeed()
            } else if clock() >= deadline {
                fail("request accepted but the frontmost app did not change within \(Int((deadline - attemptStart) * 1000)) ms")
            } else {
                pollToken = scheduler.schedule(after: pollInterval, poll)
            }
        }

        requester(method, bundleID) { [self] failure in
            guard !finished, let failure else { return }
            // The request itself was refused. One last look before moving on: an error reply can
            // arrive after the app has already come forward.
            if frontmost.frontmostBundleID() == bundleID { succeed() } else { fail(failure) }
        }
        poll()
    }

    // MARK: - Methods

    /// The real requests. The AppleScript one runs off the main queue because the target decides
    /// how long `activate` takes to answer, and that must not stall the controller; the reply is
    /// handed back on the main queue.
    private static func send(_ method: AppActivationMethod, bundleID: String, completion: @escaping (String?) -> Void) {
        switch method {
        case .runningApplication:
            guard let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first
            else { completion("app is not running"); return }
            app.activate(options: [.activateAllWindows])
            completion(nil)

        case .appleScript:
            // Addressed by bundle ID, not by name. Names are localized and need not be unique, and
            // since the app switcher any running app can be a target — `application id` is the
            // form that cannot pick the wrong one. Verified to resolve on this machine
            // (`tell application id "com.openai.codex" to get name` → ChatGPT).
            let escaped = bundleID.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let source = "tell application id \"\(escaped)\" to activate"
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&error)
                let failure: String? = error.map { error in
                    let number = error[NSAppleScript.errorNumber] ?? "?"
                    let message = error[NSAppleScript.errorMessage] ?? "unknown AppleScript error"
                    return "AppleScript error \(number): \(message)"
                }
                DispatchQueue.main.async { completion(failure) }
            }
        }
    }

    private func milliseconds(since time: TimeInterval) -> Int {
        Int(((clock() - time) * 1000).rounded())
    }
}

/// Runs an activation and reports the outcome — used by the menu's manual smoke action.
public enum AppActivationReport {
    public static func describe(_ outcome: AppActivationOutcome) -> String {
        // Per-attempt timing is in the line so a slow target is visible from the log alone.
        let tried = outcome.attempts
            .map { "\($0.method.rawValue)\($0.succeeded ? "✓" : "✗") \($0.elapsedMs) ms" }
            .joined(separator: " → ")
        if outcome.succeeded {
            let detail = outcome.attempts.count > 1 ? " (\(tried))" : ""
            return "focused \(outcome.bundleID) via \(outcome.method?.rawValue ?? "?") in \(outcome.elapsedMs) ms\(detail)"
        }
        return "could not focus \(outcome.bundleID) (\(tried)): \(outcome.reason ?? "unknown reason")"
    }
}
