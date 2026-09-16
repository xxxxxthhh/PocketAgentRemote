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
    /// The menu should be drawn (non-nil) or taken down (nil).
    public var onMenuChanged: ((AgentMenu?) -> Void)?
    /// Builds the menu for a bundle ID. Injected by the app so Core stays free of AppKit.
    public var menuBuilder: ((String?) -> AgentMenu?)?

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

    /// The open menu, if any. While this is set the controller belongs to the menu (see
    /// `handleMenuEvent`).
    private var menuSession: MenuSession?
    /// True only while a menu row is being run, so the run itself cannot open another menu.
    private var isExecutingMenuItem = false

    private struct MenuSession {
        var menu: AgentMenu
        /// The app the menu was built for. A choice is refused if focus has moved on since.
        let bundleID: String?
    }

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

    // MARK: - On-screen menu

    /// The menu currently on screen, if any.
    ///
    /// **This is the single source of truth for "is a menu open".** The engine and the app read it
    /// rather than keeping their own flag: a second flag disagreed with this one once, and the
    /// failure was subtle and bad — the engine thought a menu was up (so it stopped feeding the
    /// recognizer) while this side had already dropped it, and the event was then passed on as a
    /// normal keystroke, so ↑ moved the caret instead of the selection.
    public var openMenu: AgentMenu? { menuSession?.menu }

    /// Takes one raw controller event for the menu while it is open.
    ///
    /// This is deliberately *not* routed through the recognizer: the buttons are injected by this
    /// process, so the overlay cannot receive them as key events, and letting the recognizer see them
    /// would mean the ↑↓/A/B that drive the list also became arrow keys and Enter inside the chat
    /// window behind it.
    public func handleMenuEvent(_ event: InputEvent) -> MenuEventResult {
        guard var session = menuSession else { return .ignored }
        guard event.isPress else { return .handled }   // releases are ours, not the app's

        switch event.button {
        case .up:
            session.menu.moveUp()
        case .down:
            session.menu.moveDown()
        case .a:
            menuSession = session
            return executeSelectedMenuItem(config: configProvider())
        case .b:
            menuSession = nil
            onMenuChanged?(nil)
            onDiagnostic?("MENU  closed by B")
            return .dismissed
        default:
            // ←/→ have no meaning inside the menu; swallow them rather than let them fall through.
            menuSession = session
            return .handled
        }

        menuSession = session
        onMenuChanged?(session.menu)
        return .handled
    }

    /// Runs the highlighted row and closes the menu.
    private func executeSelectedMenuItem(config: AppConfig) -> MenuEventResult {
        guard let session = menuSession else { return .ignored }
        guard let item = session.menu.selectedItem else {
            menuSession = nil
            onMenuChanged?(nil)
            return .dismissed
        }

        // The menu was built for one app. If focus moved while it was up, running the row would send
        // a keystroke to whatever is in front now — the exact mistake the menu exists to make
        // visible, so refuse instead.
        let currentBundleID = frontmost.frontmostBundleID()
        guard currentBundleID == session.bundleID else {
            menuSession = nil
            onMenuChanged?(nil)
            let reason = "frontmost app changed (\(session.bundleID ?? "unknown") → \(currentBundleID ?? "unknown")); menu item refused"
            onDiagnostic?("DENY  \(item.action.rawValue): \(reason)")
            return .refused(reason)
        }

        menuSession = nil
        onMenuChanged?(nil)

        // Log the exact keys about to be injected alongside the row that was chosen. Two of Claude's
        // rows are context-dependent (its own menu shows them greyed out in a plain chat), so "the
        // menu item did nothing" is normally Claude declining the keystroke — and without the key in
        // the log there is no way to tell that apart from us failing to send anything.
        let stroke = AdapterCatalog.adapter(for: config.resolvedProfile(frontmostBundleID: currentBundleID),
                                            overrides: config.overrides)
            .support(for: item.action).recipe?.primaryStroke
        onDiagnostic?("MENU  running \(item.action.rawValue) (\(item.title)) → \(stroke?.description ?? "no keystroke")")

        // Run it with the menu out of the way, but through the normal pipeline so the guard still
        // applies. `isExecutingMenuItem` stops a row from opening the menu again.
        isExecutingMenuItem = true
        dispatch(.press(item.action))
        isExecutingMenuItem = false
        return .executed(item.action)
    }

    public func releaseHeldStrokes() {
        heldByAction.removeAll()
        heldRawStrokes.removeAll()
    }

    /// Opens the menu for the app in front. Returns false when there is nothing to show.
    ///
    /// The app calls this for the menu-bar entry point; the controller reaches it through the
    /// `openMenu` action, which both routes end up in.
    @discardableResult
    public func openMenu(frontmostBundleID: String?) -> Bool {
        guard menuSession == nil else {
            onDiagnostic?("MENU  open ignored: a menu is already open")
            return true
        }
        guard let menu = menuBuilder?(frontmostBundleID) else { return false }
        menuSession = MenuSession(menu: menu, bundleID: frontmostBundleID)
        onMenuChanged?(menu)
        onDiagnostic?("MENU  opened for \(frontmostBundleID ?? "?") with \(menu.items.count) items")
        return true
    }

    /// Takes the menu down without running anything.
    ///
    /// Called by the app when the overlay goes away for its own reasons (focus moved, controller
    /// unplugged). It deliberately does **not** notify back: the overlay is already gone, and the
    /// callback exists to keep the overlay in step with this state, not the other way round.
    public func closeMenu() {
        guard menuSession != nil else { return }
        menuSession = nil
        onMenuChanged?(nil)
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

        // Opening the menu is likewise a system effect, and it is global for the same reason: the
        // menu is useful from wherever the user is, and it decides for itself whether there is an
        // agent in front to act on. A row run from the menu must not re-open the menu it came from.
        if action.recipeEffect == .openMenu {
            guard !isExecutingMenuItem else { return }
            guard openMenu(frontmostBundleID: frontmostBundleID) else {
                onDiagnostic?("SKIP  openMenu: no agent in front (or no commands available for it)")
                return
            }
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
