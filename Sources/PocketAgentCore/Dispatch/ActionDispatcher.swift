import Foundation

/// Where semantic actions actually go out.
///
/// ```text
/// ActionTrigger ─▶ adapter(profile) ─▶ OutputRecipe ─▶ ActionGuard ─▶ InputEmitting
///                                            │
///                                            └─▶ diagnostics (debug monitor)
/// ```
///
/// Nothing is emitted without passing the guard, and every refusal is reported with a reason —
/// silent no-ops are impossible to debug from a menu bar (spec §17).
public final class ActionDispatcher: ActionDispatching {
    public var onDiagnostic: ((String) -> Void)?
    /// An action the active profile cannot perform, with the adapter's explanation.
    public var onUnsupported: ((AgentAction, String) -> Void)?
    /// An action the guard refused, with the reason. Nil action = a raw gesture override.
    public var onDenied: ((AgentAction?, String) -> Void)?
    /// An action that was actually sent. Nil action = a raw gesture override.
    public var onEmitted: ((AgentAction?, KeyStroke) -> Void)?

    private let configProvider: () -> AppConfig
    private let frontmost: FrontmostAppProviding
    private let emitter: InputEmitting

    public init(
        configProvider: @escaping () -> AppConfig,
        frontmost: FrontmostAppProviding,
        emitter: InputEmitting
    ) {
        self.configProvider = configProvider
        self.frontmost = frontmost
        self.emitter = emitter
    }

    public func dispatch(_ trigger: ActionTrigger) {
        let config = configProvider()
        let profile = config.activeProfile

        // A gesture bound straight to a keystroke skips the adapter, but not the guard.
        if case .raw(let stroke, let phase) = trigger {
            let recipe = OutputRecipe(
                steps: [.keyPress(stroke)],
                risk: .sensitive,
                requiresExplicitProfile: true,
                allowsRepeat: false
            )
            let frontmostBundleID = frontmost.frontmostBundleID()
            let decision = ActionGuard(policy: config.guardPolicy)
                .evaluate(recipe: recipe, profile: profile, frontmostBundleID: frontmostBundleID)
            guard decision.isAllowed else {
                if case .deny(let reason) = decision { onDenied?(nil, reason) }
                return
            }
            switch phase {
            case .press: emitter.press(stroke)
            case .down: emitter.keyDown(stroke)
            case .up: emitter.keyUp(stroke)
            }
            onEmitted?(nil, stroke)
            let label = { () -> String in
                switch phase {
                case .press: return "press"
                case .down: return "down "
                case .up: return "up   "
                }
            }()
            onDiagnostic?("SEND  \(label) <gesture override> → \(stroke.description) → \(frontmostBundleID ?? "?")")
            return
        }

        guard let action = trigger.action else { return }

        let adapter = AdapterCatalog.adapter(for: profile, overrides: config.overrides)
        let support = adapter.support(for: action)

        guard let recipe = support.recipe else {
            let reason = support.note ?? "not supported by \(profile.rawValue)"
            // Dedicated hook only — the app logs it once, from there.
            onUnsupported?(action, reason)
            return
        }

        let frontmostBundleID = frontmost.frontmostBundleID()
        let decision = ActionGuard(policy: config.guardPolicy)
            .evaluate(recipe: recipe, profile: profile, frontmostBundleID: frontmostBundleID)

        guard decision.isAllowed else {
            if case .deny(let reason) = decision {
                onDenied?(action, reason)
            }
            return
        }

        guard let stroke = recipe.primaryStroke else {
            onDiagnostic?("SKIP  \(action.rawValue): recipe has no keystroke")
            return
        }

        switch trigger {
        case .press: emitter.press(stroke)
        case .down: emitter.keyDown(stroke)
        case .up: emitter.keyUp(stroke)
        case .raw: break
        }

        let phase = { () -> String in
            switch trigger {
            case .press: return "press"
            case .down: return "down "
            case .up: return "up   "
            case .raw: return "raw  "
            }
        }()
        onEmitted?(action, stroke)
        onDiagnostic?("SEND  \(phase) \(action.rawValue) → \(stroke.description) → \(frontmostBundleID ?? "?")")
    }
}

extension KeyStroke: CustomStringConvertible {
    public var description: String {
        let prefix = modifiers.isEmpty
            ? ""
            : modifiers.map(\.rawValue).sorted().joined(separator: "+") + "+"
        return prefix + key.rawValue
    }
}
