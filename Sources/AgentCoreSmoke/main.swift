import AppKit
import Foundation
import PocketAgentCore

// Phase 1 hardware verification.
//
// Runs the real chain — ControllerInputCoordinator → GestureRecognizer → EventResolver — against a
// real controller and prints every layer, so the parts that unit tests cannot reach (both device
// variants, real HID reports, hot-plug) get exercised.
//
//   coresmoke                       run until Ctrl-C, log only
//   coresmoke --duration 60         run for 60 seconds
//   coresmoke --emit                ALSO synthesise keystrokes (needs Accessibility permission)
//
// `--emit` types into whatever is frontmost. It is off by default on purpose.

let start = Date()

func log(_ tag: String, _ message: String) {
    let elapsed = Date().timeIntervalSince(start)
    let stamp = String(format: "%8.3f", elapsed)
    let padded = tag.padding(toLength: 10, withPad: " ", startingAt: 0)
    print("[\(stamp)] \(padded) \(message)")
    fflush(stdout)
}

// MARK: - Options

var duration: Double?
var emitKeys = false
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--duration":
        duration = arguments.isEmpty ? nil : Double(arguments.removeFirst())
    case "--emit":
        emitKeys = true
    case "-h", "--help":
        print("""
        coresmoke — Phase 1 controller-core hardware verification

          --duration <secs>   stop after N seconds (default: run until Ctrl-C)
          --emit              also synthesise keystrokes (requires Accessibility permission)
        """)
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
        exit(2)
    }
}

// MARK: - Preview of what the Phase 3 adapter will send

/// Default Codex triggers from spec v0.3 §6.2. This is a *preview* only — the real adapter layer
/// (and its target-app guard) is Phase 3. It exists here so the smoke run shows the intended
/// keystroke next to each semantic action.
func previewStroke(for action: AgentAction) -> KeyStroke? {
    switch action {
    case .navigateUp: return .key(.upArrow)
    case .navigateDown: return .key(.downArrow)
    case .navigateLeft: return .key(.leftArrow)
    case .navigateRight: return .key(.rightArrow)
    case .submit: return .key(.enter)
    case .cancelOrInterrupt: return .key(.escape)
    case .newChat: return KeyStroke(.n, modifiers: [.command])
    case .openTerminal: return KeyStroke(.grave, modifiers: [.control])
    case .openModelPicker: return KeyStroke(.m, modifiers: [.control, .shift])
    case .queueFollowUp: return .key(.enter)
    case .inspectChanges: return KeyStroke(.b, modifiers: [.command, .option])

    case .goToRecentChat1: return KeyStroke(.digit1, modifiers: [.command, .option])
    case .goToRecentChat2: return KeyStroke(.digit2, modifiers: [.command, .option])
    case .goToRecentChat3: return KeyStroke(.digit3, modifiers: [.command, .option])
    case .goToRecentChat4: return KeyStroke(.digit4, modifiers: [.command, .option])
    case .goToRecentChat5: return KeyStroke(.digit5, modifiers: [.command, .option])
    case .goToRecentChat6: return KeyStroke(.digit6, modifiers: [.command, .option])
    case .nextChatNeedingAttention: return KeyStroke(.a, modifiers: [.command, .option])

    case .toggleFastMode, .openPermissionModeMenu, .archiveChat, .pinThread,
         .forkThread, .openSideChat:
        // Deliberately unbound in the default map: fast mode and the permission menu need a
        // one-time user key binding, and the rest would need gestures we do not have.
        return nil

    case .focusOtherAgent, .openMenu, .openAppSwitcher:
        // Not keystrokes at all — one raises the other agent's window, the others draw an overlay.
        // Shown as nil here because this tool only previews keys.
        return nil
    }
}

// MARK: - Dispatcher

final class SmokeDispatcher: ActionDispatching {
    private let emitter: InputEmitting?
    private(set) var counts: [AgentAction: Int] = [:]
    private(set) var rawCount = 0

    init(emitter: InputEmitting?) {
        self.emitter = emitter
    }

    /// Log-only tool: it holds no key state of its own, so there is nothing to forget.
    func releaseHeldStrokes() {}

    /// Log-only tool: it has no on-screen menu, so it never consumes an event for one.
    var openMenu: AgentMenu? { nil }
    var onMenuChanged: ((AgentMenu?) -> Void)?
    @discardableResult func openMenu(frontmostBundleID: String?) -> Bool { false }
    @discardableResult func openAppSwitcher(frontmostBundleID: String?) -> Bool { false }
    func closeMenu() {}
    func handleMenuEvent(_ event: InputEvent) -> MenuEventResult { .ignored }

    func dispatch(_ trigger: ActionTrigger) {
        let phase: String
        switch trigger.phase {
        case .press: phase = "press"
        case .down: phase = "down "
        case .up: phase = "up   "
        }

        // A gesture bound straight to a keystroke.
        if case .raw(let stroke, let phase) = trigger {
            rawCount += 1
            let label = { () -> String in
                switch phase {
                case .press: return "press"
                case .down: return "down "
                case .up: return "up   "
                }
            }()
            log("ACTION", "\(label) <gesture override>  → \(stroke)")
            guard let emitter else { return }
            switch phase {
            case .press: emitter.press(stroke)
            case .down: emitter.keyDown(stroke)
            case .up: emitter.keyUp(stroke)
            }
            return
        }

        guard let action = trigger.action else { return }
        counts[action, default: 0] += 1

        guard let stroke = previewStroke(for: action) else {
            log("ACTION", "\(phase) \(action.rawValue)  → (unbound in default map, nothing sent)")
            return
        }

        log("ACTION", "\(phase) \(action.rawValue)  → \(stroke)")

        guard let emitter else { return }
        switch trigger.phase {
        case .press: emitter.press(stroke)
        case .down: emitter.keyDown(stroke)
        case .up: emitter.keyUp(stroke)
        }
    }
}

// MARK: - Wire it up

log("ENV", "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
log("ENV", "emitKeys=\(emitKeys) duration=\(duration.map { String($0) } ?? "until Ctrl-C")")

if emitKeys {
    if AccessibilityPermission.requestIfNeeded() {
        log("PERM", "Accessibility granted — keystrokes will be synthesised")
    } else {
        log("PERM", "Accessibility NOT granted — synthesised keystrokes will be dropped by the OS")
    }
} else {
    log("PERM", "log-only mode; no keystrokes will be sent")
}

let dispatcher = SmokeDispatcher(emitter: emitKeys ? CGEventEmitter() : nil)
let engine = ControllerEngine(dispatcher: dispatcher)

engine.onDiagnostic = { log("SOURCE", $0) }
engine.onControllerAttached = { log("ATTACH", "controller usable: \($0)") }
engine.onControllerDetached = { log("DETACH", "controller gone — gesture state reset: \($0)") }

// Raw events and gestures are observed through the engine's own hooks — overriding
// `recognizer.emit` would break the engine's dispatch chain.
engine.onRawEvent = { event in
    log("RAW", "\(event.isPress ? "press  " : "release") \(event.button.rawValue)")
}
engine.onGesture = { events in
    for event in events {
        log("GESTURE", describe(event))
    }
}

func describe(_ event: ResolvedEvent) -> String {
    switch event {
    case .keyDown(let button): return "keyDown(\(button.rawValue))"
    case .keyUp(let button): return "keyUp(\(button.rawValue))"
    case .gesture(.tap(let button)): return "tap(\(button.rawValue))"
    case .gesture(.hold(let button)): return "hold(\(button.rawValue))"
    case .gesture(.chord(let modifier, let key)): return "chord(\(modifier.rawValue) + \(key.rawValue))"
    case .gesture(.chordReleased(let modifier, let key)):
        return "chordReleased(\(modifier.rawValue) + \(key.rawValue))"
    case .gesture(.holdBegan(let button)):
        return "holdBegan(\(button.rawValue))"
    case .gesture(.holdEnded(let button)):
        return "holdEnded(\(button.rawValue))"
    }
}

log("ENGINE", "starting controller core …")
engine.start()

// MARK: - Summary

func printSummary() {
    log("SUMMARY", "semantic actions fired: \(dispatcher.counts.values.reduce(0, +))")
    for action in AgentAction.allCases {
        guard let count = dispatcher.counts[action], count > 0 else { continue }
        log("SUMMARY", "  \(action.rawValue.padding(toLength: 26, withPad: " ", startingAt: 0)) \(count)")
    }
}

if let duration {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }
    engine.stop()
    printSummary()
    exit(0)
}

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    engine.stop()
    printSummary()
    exit(0)
}
interrupt.resume()

RunLoop.main.run()
