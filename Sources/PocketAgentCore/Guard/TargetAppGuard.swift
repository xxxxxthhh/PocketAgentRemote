import Foundation

/// The rules from spec §12/§17, as data.
public struct GuardPolicy: Equatable, Sendable {
    public var allowedBundleIDs: Set<String>
    public var requireAllowedFrontmostApp: Bool
    public var macrosEnabled: Bool

    public init(
        allowedBundleIDs: Set<String>,
        requireAllowedFrontmostApp: Bool = true,
        macrosEnabled: Bool = false
    ) {
        self.allowedBundleIDs = allowedBundleIDs
        self.requireAllowedFrontmostApp = requireAllowedFrontmostApp
        self.macrosEnabled = macrosEnabled
    }

    public static let `default` = GuardPolicy(allowedBundleIDs: Set(AppConfig.defaultAllowedBundleIDs))
}

public enum GuardDecision: Equatable, Sendable {
    case allow
    case deny(reason: String)

    public var isAllowed: Bool { self == .allow }
}

/// Decides whether a recipe may actually be sent.
///
/// The guard exists because this app injects keystrokes into *other* applications. Three rules,
/// in the order they are checked:
///
/// 1. A tool-specific recipe requires an explicit profile — the generic profile must never emit a
///    tool chord (spec §12).
/// 2. Macro recipes additionally require macros to be enabled (spec §17).
/// 3. The frontmost application must be on the allowlist (spec §12) — this is the rule that stops
///    a mis-set profile from typing `⌘N` into whatever happens to be in front.
public struct ActionGuard: Sendable {
    public let policy: GuardPolicy

    public init(policy: GuardPolicy = .default) {
        self.policy = policy
    }

    public func evaluate(
        recipe: OutputRecipe,
        profile: ToolProfile,
        frontmostBundleID: String?
    ) -> GuardDecision {
        if recipe.requiresExplicitProfile && profile == .genericTerminal {
            return .deny(reason: "tool-specific action requires an explicit profile")
        }

        if recipe.risk == .macro && !policy.macrosEnabled {
            return .deny(reason: "macros are disabled")
        }

        if policy.requireAllowedFrontmostApp {
            guard let bundleID = frontmostBundleID else {
                return .deny(reason: "cannot determine the frontmost application")
            }
            guard policy.allowedBundleIDs.contains(bundleID) else {
                return .deny(reason: "frontmost app \"\(bundleID)\" is not in the allowlist")
            }
        }

        return .allow
    }
}

/// Supplies the current frontmost application. Injectable so the guard is testable.
public protocol FrontmostAppProviding: AnyObject {
    func frontmostBundleID() -> String?
}
