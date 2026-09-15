import AppKit
import Foundation
import GameController

// Phase 0 — Hardware Probe
//
// Usage:
//   agentprobe list                     identity snapshot only, then exit
//   agentprobe watch [options]          live raw input from GameController + HID
//
// Options:
//   --hid-only         skip GameController, use IOHIDManager only
//   --with-keyboard    also watch keyboard HID devices (needed for L1162 H mode)
//   --discover         run GCController wireless discovery (needs a bundled app)
//   --log <path>       also write JSONL to <path>
//   --duration <secs>  exit automatically after N seconds (for scripted sessions)

struct Options {
    var command = "watch"
    var hidOnly = false
    var withKeyboard = false
    var discover = false
    var logPath: String?
    var duration: Double?
    var settle: Double = 1.5

    static let usage = """
    agentprobe — IINE L1162 / GameController hardware probe (Phase 0)

      agentprobe list                           dump controller + HID device identities
      agentprobe watch [options]                log live raw input

    Options:
      --hid-only          skip GameController, use IOHIDManager only
      --with-keyboard     also watch keyboard HID devices (L1162 H mode)
      --discover          run GCController wireless discovery (bundled app only)
      --log <path>        also append JSONL records to <path>
      --duration <secs>   stop automatically after N seconds
      --settle <secs>     wait for GameController to attach before a `list` snapshot (default 1.5)
    """
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())

    if let first = args.first, !first.hasPrefix("-") {
        options.command = first
        args.removeFirst()
    }

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "list": options.command = "list"
        case "watch": options.command = "watch"
        case "--hid-only": options.hidOnly = true
        case "--with-keyboard": options.withKeyboard = true
        case "--discover": options.discover = true
        case "--log":
            options.logPath = args.isEmpty ? nil : args.removeFirst()
        case "--duration":
            options.duration = args.isEmpty ? nil : Double(args.removeFirst())
        case "--settle":
            options.settle = args.isEmpty ? 1.5 : (Double(args.removeFirst()) ?? 1.5)
        case "-h", "--help":
            print(Options.usage)
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
            print(Options.usage)
            exit(2)
        }
    }
    return options
}

let options = parseOptions()
let log = EventLog.shared
if let path = options.logPath { log.openFile(at: path) }

log.log("ENV", "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
log.log("ENV", "pid=\(getpid()) bundled=\(Bundle.main.bundleIdentifier ?? "<none>")")
log.log("ENV", "command=\(options.command) hidOnly=\(options.hidOnly) withKeyboard=\(options.withKeyboard)")
if let path = log.logPath { log.log("ENV", "jsonl log: \(path)") } else {
    log.log("ENV", "jsonl log: disabled (pass --log <path> to enable)")
}

let gameControllerProbe = GameControllerProbe()
let hidProbe = HIDProbe()

switch options.command {
case "list":
    // The GameController framework attaches to gamecontrollerd asynchronously: on a
    // cold start `GCController.controllers()` is still empty for the first ~100 ms and
    // the real device only shows up via GCControllerDidConnect. Snapshotting without
    // settling reports a false "no controller".
    gameControllerProbe.start(discover: false)
    RunLoop.main.run(until: Date().addingTimeInterval(options.settle))
    log.log("GC", "after \(options.settle)s settle: GCController.controllers() count=\(GCController.controllers().count)")
    hidProbe.listAllDevices()
    log.log("DONE", "identity snapshot complete")
    exit(0)

case "watch":
    log.log("HID-LIST", "--- identity snapshot (read-only, no device seized) ---")
    hidProbe.listAllDevices()
    log.log("WATCH", "--- live input begins; press Ctrl-C to stop ---")

    if !options.hidOnly {
        gameControllerProbe.start(discover: options.discover)
    } else {
        log.log("GC", "skipped (--hid-only)")
    }
    hidProbe.watch(includeKeyboard: options.withKeyboard)

    if let duration = options.duration {
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            log.log("EXIT", "duration \(duration)s elapsed")
            exit(0)
        }
    }

    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler {
        log.log("EXIT", "interrupted by Ctrl-C")
        exit(0)
    }
    interrupt.resume()

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
    log.log("EXIT", "run loop stopped")

default:
    FileHandle.standardError.write(Data("unknown command: \(options.command)\n".utf8))
    print(Options.usage)
    exit(2)
}
