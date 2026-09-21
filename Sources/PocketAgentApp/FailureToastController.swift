import AppKit
import Foundation

/// A short-lived message for things that **did not** happen: a keystroke the guard refused, a
/// command the app in front cannot run, an app that would not come to the front.
///
/// ## Why it is its own panel
///
/// It deliberately shares nothing with `MenuOverlayController` — not the panel, not the visibility
/// state, not the menu session, not the poll timer. The menu and a failure message have unrelated
/// lifetimes: a toast raised while the menu is up must not redraw it, must not keep it alive, and
/// must not take it down when the toast expires. Reusing the menu's panel would have coupled all
/// three.
///
/// ## Why it takes no input
///
/// Same non-activating panel as the menu (never key, never main, mouse events ignored), and it is
/// wired to no controller event at all: there is no dismiss gesture, and pressing any button while a
/// toast is visible does exactly what it would with no toast on screen. A message that could swallow
/// a button press would be worse than the silence it replaces.
final class FailureToastController {
    /// How long a message stays up. The floor comes from the card: long enough to read a reason
    /// while both hands are on a controller.
    private let duration: TimeInterval = 3.0

    private var panel: NSPanel?
    private var label: NSTextField?
    private var timer: Timer?

    /// Which message is current. A timer that fires for an older one is ignored, so a replacement
    /// message cannot be cut short by the timer of the message it replaced.
    private var generation = 0

    var isVisible: Bool { panel?.isVisible ?? false }
    /// Temporary probe, same spirit as the overlay's: how many messages this session showed.
    private(set) var shownCount = 0

    /// Shows `message`, replacing whatever is up and restarting the clock.
    func show(_ message: String) {
        shownCount += 1
        generation += 1
        let mine = generation

        if panel == nil { panel = makePanel() }
        guard let panel, let label else { return }

        label.stringValue = message
        position(panel)
        // Never `makeKeyAndOrderFront`: the app in front must keep the keyboard.
        panel.orderFrontRegardless()

        timer?.invalidate()
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            guard let self, self.generation == mine else { return }
            self.hide()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: Self.fontSize, weight: .medium)
        text.textColor = .labelColor
        text.alignment = .center
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 2
        effect.addSubview(text)
        label = text
        return panel
    }

    /// Near the top of the screen, while the menu sits at 22 % from the bottom — so a toast raised
    /// while the menu is up never overlaps it, whichever order they appear in.
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(Self.width, screen.width - 80), height: Self.height)
        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.maxY - size.height - Self.topInset
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        label?.frame = NSRect(
            x: Self.padding,
            y: 0,
            width: size.width - Self.padding * 2,
            height: size.height
        )
    }

    private static let width: CGFloat = 520
    private static let height: CGFloat = 64
    private static let cornerRadius: CGFloat = 14
    private static let padding: CGFloat = 20
    private static let topInset: CGFloat = 24
    /// Readable from a sofa, like the menu, but a step down from its row text.
    private static let fontSize: CGFloat = 20
}
