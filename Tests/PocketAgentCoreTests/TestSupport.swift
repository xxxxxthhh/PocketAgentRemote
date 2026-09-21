import XCTest
@testable import PocketAgentCore

/// Deterministic clock for the gesture engine.
final class ManualScheduler: GestureScheduler {
    private final class Token: GestureSchedulerToken {
        var due: TimeInterval
        var firedOrCancelled = false
        let body: () -> Void
        init(due: TimeInterval, body: @escaping () -> Void) {
            self.due = due
            self.body = body
        }
        func cancel() { firedOrCancelled = true }
    }

    private var tokens: [Token] = []
    private(set) var now: TimeInterval = 0

    func schedule(after delay: TimeInterval, _ body: @escaping () -> Void) -> GestureSchedulerToken {
        let token = Token(due: now + delay, body: body)
        tokens.append(token)
        return token
    }

    func advance(to time: TimeInterval) {
        precondition(time >= now, "time never moves backwards")
        now = time
        var firedAnything = true
        while firedAnything {
            firedAnything = false
            for token in tokens where !token.firedOrCancelled && token.due <= now {
                token.firedOrCancelled = true
                token.body()
                firedAnything = true
            }
            tokens.removeAll { $0.firedOrCancelled }
        }
    }
}

/// Test harness: drives the recognizer and records everything it emits.
final class Harness {
    let scheduler = ManualScheduler()
    let recognizer: GestureRecognizer
    private(set) var batches: [[ResolvedEvent]] = []

    init(configuration: GestureConfiguration = .default) {
        recognizer = GestureRecognizer(configuration: configuration, scheduler: scheduler)
        recognizer.emit = { [weak self] events in self?.batches.append(events) }
    }

    /// Every event the recognizer emitted, flattened, in order.
    var emitted: [ResolvedEvent] { batches.flatMap { $0 } }

    var gestures: [ControllerGesture] {
        emitted.compactMap { if case .gesture(let g) = $0 { return g } else { return nil } }
    }

    /// Gestures that stand on their own. `chordReleased` is excluded because it exists only to end
    /// a *held* binding (a modifier-only chord) — semantic actions are one-shot and ignore it.
    var actionGestures: [ControllerGesture] {
        gestures.filter {
            if case .chordReleased = $0 { return false }
            return true
        }
    }

    var chordReleases: [ControllerGesture] {
        gestures.filter {
            if case .chordReleased = $0 { return true }
            return false
        }
    }

    func press(_ button: PhysicalButton) {
        recognizer.handle(.pressed(button, timestamp: scheduler.now))
    }

    func release(_ button: PhysicalButton) {
        recognizer.handle(.released(button, timestamp: scheduler.now))
    }

    func advance(to time: TimeInterval) {
        scheduler.advance(to: time)
    }
}

// MARK: - Engine-level rig

/// Records what was emitted **and on which method**.
///
/// A held binding and a one-shot press produce the same kind of event through different calls
/// (`keyDown`/`keyUp` versus `press`), and several real bugs lived exactly in that distinction — so
/// the phase is part of the record rather than being flattened away.
final class RecordingEmitter: InputEmitting {
    enum Phase: Equatable { case press, down, up }
    struct Emission: Equatable {
        let phase: Phase
        let stroke: KeyStroke
    }

    private(set) var emissions: [Emission] = []
    var strokes: [KeyStroke] { emissions.map(\.stroke) }

    func press(_ stroke: KeyStroke) { emissions.append(Emission(phase: .press, stroke: stroke)) }
    func keyDown(_ stroke: KeyStroke) { emissions.append(Emission(phase: .down, stroke: stroke)) }
    func keyUp(_ stroke: KeyStroke) { emissions.append(Emission(phase: .up, stroke: stroke)) }
    func releaseAll() {}
}

/// The frontmost app, settable so a test can move focus mid-gesture.
final class MutableFrontmost: FrontmostAppProviding {
    var bundleID: String?
    init(_ bundleID: String?) { self.bundleID = bundleID }
    func frontmostBundleID() -> String? { bundleID }
}

/// An input source a test drives by hand.
final class FakeControllerSource: ControllerInputSource {
    let transport: ControllerTransport = .rawHID
    var onEvent: ((InputEvent) -> Void)?
    var onAttach: ((String) -> Void)?
    var onDetach: ((String) -> Void)?
    var onWillDetach: (() -> Void)?
    func start() {}
    func stop() {}
}

/// The real engine, recognizer and dispatcher, fed from a fake source, with a spy at the emitter.
///
/// Shared because the leaks these suites pin are made of the wiring *between* those three: stubbing
/// any of them would test the stub. The builders are wired only when a test asks for them, so a
/// suite that never opens a menu is not handed one.
struct EngineRig {
    let engine: ControllerEngine
    let dispatcher: ActionDispatcher
    let source: FakeControllerSource
    let emitter: RecordingEmitter
    let frontmost: MutableFrontmost
    /// The injected clock: an event's timestamp does **not** advance it — call `advance(to:)`.
    let scheduler: ManualScheduler
    let config: AppConfig
    let log: () -> [String]

    func press(_ button: PhysicalButton, at t: TimeInterval) {
        source.onEvent?(.pressed(button, timestamp: t))
    }
    func release(_ button: PhysicalButton, at t: TimeInterval) {
        source.onEvent?(.released(button, timestamp: t))
    }
    /// The stroke an action resolves to for the app currently in front.
    func stroke(for action: AgentAction) -> KeyStroke? {
        AdapterCatalog
            .adapter(for: config.resolvedProfile(frontmostBundleID: frontmost.bundleID),
                     overrides: config.overrides)
            .support(for: action).recipe?.primaryStroke
    }
}

/// Builds an `EngineRig`. `switcherApps` wires the app-switcher strip; `frontmostProvided: false`
/// leaves `engine.frontmost` nil, which is what the app itself did before T0.5.
func makeEngineRig(
    frontmostBundleID: String? = "com.openai.codex",
    frontmostProvided: Bool = true,
    switcherApps: [RunningApp]? = nil,
    activator: AppActivating? = nil,
    /// Which command menu `B+←` opens. Defaults to the shipped list; the G2 dial suite passes
    /// `AgentDialBuilder.menu` so the prototype is driven through the same real engine.
    commandMenu: ((AppConfig, String?) -> AgentMenu?)? = nil,
    /// The G4 general menu, wired only when a test passes them: the reader for the frontmost app's
    /// own menu bar, and the builder that turns what it found into rows. Left nil, the dispatcher
    /// behaves exactly as it did before G4 — an app with no command menu opens nothing.
    appMenuReader: AppMenuReading? = nil,
    appMenuBuilder: ((String?, [AppMenuEntry]) -> AgentMenu?)? = nil,
    configure: (inout AppConfig) -> Void = { _ in }
) -> EngineRig {
    var config = AppConfig()
    config.profileMode = .auto
    configure(&config)
    let emitter = RecordingEmitter()
    let frontmost = MutableFrontmost(frontmostBundleID)
    let scheduler = ManualScheduler()
    let dispatcher = ActionDispatcher(
        configProvider: { config },
        frontmost: frontmost,
        emitter: emitter,
        activator: activator,
        scheduler: scheduler
    )
    dispatcher.menuBuilder = { bundleID in
        if let commandMenu { return commandMenu(config, bundleID) }
        return AgentMenuBuilder.menu(for: config, frontmostBundleID: bundleID, frontmostName: "Codex")
    }
    dispatcher.appMenuReader = appMenuReader
    dispatcher.appMenuBuilder = appMenuBuilder
    if let switcherApps {
        dispatcher.switcherBuilder = { bundleID in
            AppSwitcherBuilder.menu(apps: switcherApps, frontmostBundleID: bundleID)
        }
    }
    let source = FakeControllerSource()
    let engine = ControllerEngine(
        dispatcher: dispatcher,
        gestureOverrides: config.gestureOverrides(for: config.activeProfile),
        scheduler: scheduler,
        coordinator: ControllerInputCoordinator(gameController: FakeControllerSource(), hid: source)
    )
    var diagnostics: [String] = []
    dispatcher.onDiagnostic = { diagnostics.append("DISP \($0)") }
    // The structured failure hooks, recorded in the same place and with the tag the app logs them
    // under — several failures are reported only through these, and a rig that dropped them would
    // make a silent failure look identical to no failure.
    dispatcher.onUnsupported = { diagnostics.append("SKIP  \($0.rawValue): \($1)") }
    dispatcher.onDenied = { diagnostics.append("DENY  \($0?.rawValue ?? "<raw>"): \($1)") }
    dispatcher.onActivation = { diagnostics.append("FOCUS \($0.rawValue): \(AppActivationReport.describe($1))") }
    engine.onDiagnostic = { diagnostics.append("ENG  \($0)") }
    engine.onGesture = { diagnostics.append("GESTURE \($0)") }
    if frontmostProvided { engine.frontmost = frontmost }
    engine.start()
    return EngineRig(
        engine: engine, dispatcher: dispatcher, source: source, emitter: emitter,
        frontmost: frontmost, scheduler: scheduler, config: config, log: { diagnostics }
    )
}
