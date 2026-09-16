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
    /// A cross-app focus ran (successfully or not), with a human-readable outcome.
    ///
    /// Separate from `onEmitted` on purpose: focusing an app emits no keystroke, and reporting it as
    /// a keystroke would make the debug log claim something happened in the target app that did not.
    public var onActivation: ((AgentAction, AppActivationOutcome) -> Void)?

    private let configProvider: () -> AppConfig
    private let frontmost: FrontmostAppProviding
    private let emitter: InputEmitting
    private let activator: AppActivating?

    /// What each currently-held key was actually emitted as.
    ///
    /// A key that is still down must be released with **the stroke that went down**, not with
    /// whatever the current profile/guard/override table would produce now. Two real failures came
    /// from re-deciding at release time:
    ///
    /// - the guard re-checked the *current* frontmost app, so releasing an arrow key after focus
    ///   moved off the allowlist was denied and the key stayed down;
    /// - a held gesture override (B+A voice input) whose override disappeared mid-chord — profile
    ///   switch, config reload, frontmost app change — resolved to nothing at all, so the release
    ///   was never sent and the modifier stayed down.
    ///
    /// Keyed by action and, separately, by stroke for gesture overrides (which have no action).
    private var heldByAction: [AgentAction: KeyStroke] = [:]
    private var heldRawStrokes: Set<KeyStroke> = []

    public init(
        configProvider: @escaping () -> AppConfig,
        frontmost: FrontmostAppProviding,
        emitter: InputEmitting,
        activator: AppActivating? = nil
    ) {
        self.configProvider = configProvider
        self.frontmost = frontmost
        self.emitter = emitter
        self.activator = activator
    }

    public func releaseHeldStrokes() {
        heldByAction.removeAll()
        heldRawStrokes.removeAll()
    }

    /// Handles `focusOtherAgent`: resolve the target from the configured pair and raise it.
    ///
    /// Every exit is reported — an app that is not running, a missing pair, a failed AppleScript —
    /// because this action produces no keystroke, so nothing else in the log would show that the
    /// user's button press did nothing.
    private func performFocus(
        _ action: AgentAction,
        frontmostBundleID: String?,
        config: AppConfig
    ) {
        guard let target = config.focusOtherAgentTarget(frontmostBundleID: frontmostBundleID) else {
            onDiagnostic?("SKIP  \(action.rawValue): the agent pair in config is empty")
            return
        }

        guard let activator else {
            onDiagnostic?("SKIP  \(action.rawValue): app activation is not wired up in this build")
            return
        }

        let outcome = activator.activate(bundleID: target)
        // Reported through the dedicated hook, not `onDiagnostic`: one line per activation attempt,
        // written by the app under its own tag.
        onActivation?(action, outcome)
    }

    private func emitRaw(_ stroke: KeyStroke, phase: KeyPhase, frontmostBundleID: String?) {
        switch phase {
        case .press: emitter.press(stroke)
        case .down:
            emitter.keyDown(stroke)
            heldRawStrokes.insert(stroke)
        case .up:
            emitter.keyUp(stroke)
            heldRawStrokes.remove(stroke)
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
    }

    /// A key-down that is still outstanding, with the stroke it must eventually be released with.
    private func heldStroke(for action: AgentAction) -> KeyStroke? {
        heldByAction[action]
    }

    private func remember(_ stroke: KeyStroke, for action: AgentAction) {
        heldByAction[action] = stroke
    }

    private func forget(_ action: AgentAction) {
        heldByAction.removeValue(forKey: action)
    }

    public func dispatch(_ trigger: ActionTrigger) {
        let config = configProvider()
        let frontmostBundleID = frontmost.frontmostBundleID()
        // The profile may be derived from the frontmost app (config.profileMode == .auto), so it has
        // to be resolved here rather than read once at startup.
        let profile = config.resolvedProfile(frontmostBundleID: frontmostBundleID)
        let policy = config.effectiveGuardPolicy

        // A gesture bound straight to a keystroke skips the adapter, but not the guard.
        if case .raw(let stroke, let phase) = trigger {
            if stroke.isHoldOnly {
                // Modifier-only strokes are treated as **global**. They carry no command into any
                // application — nothing is typed, only ⌥/⇧/⌃/⌘ are held — and the motivating use
                // case (holding ⌥⇧ to trigger an input method's voice input) only works if it fires
                // while the user is typing in *any* app. Requiring an allowlisted frontmost app
                // would make it useless.
                emitRaw(stroke, phase: phase, frontmostBundleID: frontmostBundleID)
                return
            }

            // Releasing something we already sent needs no authorisation: the decision was made when
            // the key went down, and refusing the release here is exactly how a key gets stuck.
            if phase == .up, heldRawStrokes.contains(stroke) {
                emitRaw(stroke, phase: .up, frontmostBundleID: frontmostBundleID)
                return
            }

            let recipe = OutputRecipe(
                steps: [.keyPress(stroke)],
                risk: .sensitive,
                requiresExplicitProfile: true,
                allowsRepeat: false
            )
            let decision = ActionGuard(policy: policy)
                .evaluate(recipe: recipe, profile: profile, frontmostBundleID: frontmostBundleID)
            guard decision.isAllowed else {
                if case .deny(let reason) = decision { onDenied?(nil, reason) }
                return
            }
            emitRaw(stroke, phase: phase, frontmostBundleID: frontmostBundleID)
            return
        }

        guard let action = trigger.action else { return }

        // Cross-app focus is a system effect, not a keystroke, so it takes this branch before any
        // adapter or guard runs. It is deliberately **global** (any frontmost app, any profile):
        // its motivating use case is being in a browser and wanting the agent back, which is exactly
        // when no allowlisted app is in front and every tool chord is — correctly — blocked. It also
        // cannot misfire into the wrong app: the activator only ever raises one of the two agents
        // the config names, and it sends them no input.
        if action.recipeEffect == .activateAgentApp {
            performFocus(action, frontmostBundleID: frontmostBundleID, config: config)
            return
        }

        let adapter = AdapterCatalog.adapter(for: profile, overrides: config.overrides)
        let support = adapter.support(for: action)

        // A release never re-decides. If this action has a key outstanding, send exactly the stroke
        // that went down — even when the profile changed, the config was reloaded, or the frontmost
        // app left the allowlist in the meantime. Those are precisely the cases where re-resolving
        // (or re-authorising) would strand a held key in the target application.
        if case .up = trigger, let held = heldStroke(for: action) {
            emitter.keyUp(held)
            forget(action)
            onEmitted?(action, held)
            onDiagnostic?("SEND  up    \(action.rawValue) → \(held.description) → \(frontmostBundleID ?? "?")")
            return
        }

        guard let recipe = support.recipe else {
            let reason = support.note ?? "not supported by \(profile.rawValue)"
            // Dedicated hook only — the app logs it once, from there.
            onUnsupported?(action, reason)
            return
        }

        let decision = ActionGuard(policy: policy)
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
        case .down:
            emitter.keyDown(stroke)
            remember(stroke, for: action)
        case .up:
            emitter.keyUp(stroke)
            forget(action)
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
        let prefix = modifiers.map(\.rawValue).sorted().joined(separator: "+")
        guard let key else {
            // Modifier-only: nothing is typed, only the modifier keys move.
            return prefix.isEmpty ? "<empty>" : prefix + " (modifiers only)"
        }
        return prefix.isEmpty ? key.rawValue : prefix + "+" + key.rawValue
    }
}
