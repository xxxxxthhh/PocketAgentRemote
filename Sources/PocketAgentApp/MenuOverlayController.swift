import AppKit
import Foundation
import PocketAgentCore

/// The on-screen menu, drawn as a floating panel.
///
/// ## It must never take focus
///
/// The panel is a **non-activating** panel that never becomes key or main, and it ignores mouse
/// events. That is not a detail: the whole point is that the chat window keeps the keyboard focus
/// while the menu is up. If the overlay took focus, the user's next voice-input ⌥ or the agent's own
/// shortcuts would go to the wrong place, and the guard's "frontmost app" signal would stop meaning
/// what it says.
///
/// ## The controller drives it, AppKit does not
///
/// A panel that never becomes key receives no key events, and the controller's buttons are injected
/// by this same process rather than typed on a keyboard, so AppKit's event path is not involved at
/// all. `ControllerEngine` therefore feeds the menu directly, and this class only draws the current
/// state (`render`).
public final class MenuOverlayController {
    /// Called when the menu goes away for a reason other than a choice — focus moved, controller
    /// disconnected, window closed. The engine uses it to release any menu-held state.
    public var onDismiss: (() -> Void)?

    /// How often to re-check that the app the menu was opened for is still in front.
    ///
    /// A menu that stayed up while the user switched apps would be a loaded gun: pressing A would
    /// act on whatever is in front *now*. The engine also re-checks at execution time, so this is
    /// belt and braces — it exists so the menu disappears when its subject does.
    private let frontmostCheckInterval: TimeInterval = 0.15
    private let frontmost: FrontmostAppProviding

    private var panel: NSPanel?
    private var titleLabel: NSTextField?
    private var hintLabel: NSTextField?
    private var rowLabels: [NSTextField] = []
    private var rowBackgrounds: [NSView] = []
    /// Strip layout (app switcher): one icon cell per app, and the highlighted app's name below.
    private var stripCells: [NSView] = []
    private var stripNameLabel: NSTextField?
    private var pollTimer: Timer?
    private(set) var menu: AgentMenu?

    public var isVisible: Bool { panel?.isVisible ?? false }

    public init(frontmost: FrontmostAppProviding) {
        self.frontmost = frontmost
    }

    // MARK: - Presentation

    public func show(_ menu: AgentMenu) {
        self.menu = menu
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }
        rebuildContent(for: menu)
        position(panel, for: menu)

        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: never take focus.
        panel.orderFrontRegardless()
        startWatchingFrontmostApp(menu.bundleID)
    }

    public func render(_ menu: AgentMenu) {
        self.menu = menu
        if menu.layout == .strip {
            for (index, cell) in stripCells.enumerated() {
                cell.layer?.backgroundColor = (index == menu.selection
                    ? NSColor.controlAccentColor.withAlphaComponent(0.85)
                    : NSColor.clear).cgColor
            }
            stripNameLabel?.stringValue = menu.selectedItem?.title ?? ""
            return
        }
        for (index, background) in rowBackgrounds.enumerated() {
            background.layer?.backgroundColor = (index == menu.selection
                ? NSColor.controlAccentColor.withAlphaComponent(0.85)
                : NSColor.clear).cgColor
        }
        for (index, label) in rowLabels.enumerated() {
            label.textColor = index == menu.selection ? .white : .labelColor
        }
    }

    public func hide(notify: Bool = false) {
        stopWatching()
        panel?.orderOut(nil)
        menu = nil
        if notify { onDismiss?() }
    }

    // MARK: - Panel construction

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
            // `.nonactivatingPanel` is what keeps the currently focused app focused.
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
        return panel
    }

    private func rebuildContent(for menu: AgentMenu) {
        guard let panel, let content = panel.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        rowLabels.removeAll()
        rowBackgrounds.removeAll()
        stripCells.removeAll()
        stripNameLabel = nil

        let title = NSTextField(labelWithString: menu.title)
        title.font = .systemFont(ofSize: Self.titleFontSize, weight: .semibold)
        title.textColor = .secondaryLabelColor
        content.addSubview(title)
        titleLabel = title

        let hint = NSTextField(labelWithString: menu.hint)
        hint.font = .systemFont(ofSize: Self.hintFontSize, weight: .regular)
        hint.textColor = .tertiaryLabelColor
        content.addSubview(hint)
        hintLabel = hint

        if menu.layout == .strip {
            for item in menu.items {
                let cell = NSView()
                cell.wantsLayer = true
                cell.layer?.cornerRadius = 14
                content.addSubview(cell)
                stripCells.append(cell)

                let icon = NSImageView()
                icon.imageScaling = .scaleProportionallyUpOrDown
                // The icon comes from the running app itself, looked up here so Core never needs
                // AppKit for a menu row.
                icon.image = item.appBundleID.flatMap {
                    NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.icon
                } ?? NSImage(named: NSImage.applicationIconName)
                cell.addSubview(icon)
            }
            let name = NSTextField(labelWithString: menu.selectedItem?.title ?? "")
            name.font = .systemFont(ofSize: Self.rowFontSize, weight: .medium)
            name.textColor = .labelColor
            name.alignment = .center
            name.lineBreakMode = .byTruncatingTail
            content.addSubview(name)
            stripNameLabel = name
            render(menu)
            return
        }

        for item in menu.items {
            let background = NSView()
            background.wantsLayer = true
            background.layer?.cornerRadius = 8
            content.addSubview(background)
            rowBackgrounds.append(background)

            let label = NSTextField(labelWithString: item.title)
            label.font = .systemFont(ofSize: Self.rowFontSize, weight: .medium)
            label.textColor = .labelColor
            content.addSubview(label)
            rowLabels.append(label)
        }

        render(menu)
    }

    private func position(_ panel: NSPanel, for menu: AgentMenu) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if menu.layout == .strip {
            positionStrip(panel, cells: menu.items.count, on: screen)
            return
        }

        let rows = menu.items.count
        let height = Self.headerHeight + CGFloat(rows) * Self.rowHeight + Self.hintHeight + Self.padding * 2
        let size = NSSize(width: Self.width, height: height)

        // Lower-middle of the screen: close enough to read without a controller-holder having to
        // look up, and out of the way of the composer the agent itself puts at the bottom.
        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.minY + screen.height * 0.22
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        // Lay the rows out after the frame is known.
        guard let content = panel.contentView else { return }
        var y = size.height - Self.padding - Self.headerHeight
        titleLabel?.frame = NSRect(x: Self.padding, y: y, width: size.width - Self.padding * 2, height: Self.headerHeight)
        y -= Self.rowHeight

        for index in rowLabels.indices {
            let label = rowLabels[index]
            let rowFrame = NSRect(x: Self.padding, y: y, width: size.width - Self.padding * 2, height: Self.rowHeight)
            rowBackgrounds[index].frame = rowFrame.insetBy(dx: 0, dy: 3)
            label.frame = rowFrame.offsetBy(dx: 12, dy: 0)
            label.sizeToFit()
            label.frame = NSRect(
                x: rowFrame.minX + 14,
                y: rowFrame.midY - label.frame.height / 2,
                width: label.frame.width,
                height: label.frame.height
            )
            y -= Self.rowHeight
        }

        hintLabel?.frame = NSRect(x: Self.padding, y: Self.padding, width: size.width - Self.padding * 2, height: Self.hintHeight)
        _ = content
    }

    /// Horizontal strip, ⌘⇥-style: icons in a row, the highlighted app's name underneath.
    ///
    /// Cells shrink when there are too many apps for the screen rather than letting the panel run
    /// off the edge; the icon inside scales with the cell.
    private func positionStrip(_ panel: NSPanel, cells count: Int, on screen: NSRect) {
        let available = screen.width - 40 - Self.padding * 2
        let cell = min(Self.stripCell, available / CGFloat(max(count, 1)))
        let width = max(Self.width, Self.padding * 2 + cell * CGFloat(count))
        let height = Self.padding + Self.headerHeight + cell + Self.stripNameHeight + Self.hintHeight + Self.padding
        let size = NSSize(width: width, height: height)

        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.minY + screen.height * 0.22
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        var y = size.height - Self.padding - Self.headerHeight
        titleLabel?.frame = NSRect(x: Self.padding, y: y, width: size.width - Self.padding * 2, height: Self.headerHeight)
        y -= cell

        let stripWidth = cell * CGFloat(count)
        var x = (size.width - stripWidth) / 2
        let inset = cell * 0.12
        for cellView in stripCells {
            cellView.frame = NSRect(x: x, y: y, width: cell, height: cell).insetBy(dx: 4, dy: 4)
            cellView.subviews.first?.frame = cellView.bounds.insetBy(dx: inset, dy: inset)
            x += cell
        }
        y -= Self.stripNameHeight
        stripNameLabel?.frame = NSRect(x: Self.padding, y: y, width: size.width - Self.padding * 2, height: Self.stripNameHeight)

        hintLabel?.frame = NSRect(x: Self.padding, y: Self.padding, width: size.width - Self.padding * 2, height: Self.hintHeight)
    }

    // MARK: - Focus watching

    private func startWatchingFrontmostApp(_ bundleID: String?) {
        stopWatching()
        guard let bundleID else { return }
        let timer = Timer(timeInterval: frontmostCheckInterval, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            guard self.frontmost.frontmostBundleID() != bundleID else { return }
            // The app the menu was built for is no longer in front: drop the menu rather than let it
            // act on a different window.
            self.hide(notify: true)
        }
        // `.common` so it keeps firing while the user interacts with menus or the panel.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Metrics

    private static let width: CGFloat = 420
    private static let cornerRadius: CGFloat = 16
    private static let padding: CGFloat = 18
    private static let rowHeight: CGFloat = 54
    private static let headerHeight: CGFloat = 30
    private static let hintHeight: CGFloat = 26
    /// Strip layout: the square each app icon sits in, and the name line under the strip.
    private static let stripCell: CGFloat = 88
    private static let stripNameHeight: CGFloat = 40
    /// Deliberately large: this is meant to be readable from a sofa, not from 40 cm away.
    private static let rowFontSize: CGFloat = 26
    private static let titleFontSize: CGFloat = 15
    private static let hintFontSize: CGFloat = 13
}
