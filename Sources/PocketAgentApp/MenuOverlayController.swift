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
    /// Dial layout: the target app's name in the middle of the four slots.
    private var dialCenterLabel: NSTextField?
    /// List layout: the index of the first row the viewport shows.
    ///
    /// Chrome's 「更多」 page is 41 rows — every extension and every window gets one — and drawn in
    /// full it is a bar running the whole height of the screen. The panel holds
    /// `visibleRowCount(_:on:)` rows instead, and this says where in the list that window sits.
    /// Cleared by a rebuild, moved by `render` so the selection stays on screen; moving it only
    /// re-places rows that already exist, which is why the T1.1 `rebuildCount` probe stays at 1.
    private var listOffset = 0
    private var pollTimer: Timer?
    /// The app `pollTimer` is watching, so the same session does not restart it (see
    /// `startWatchingFrontmostApp`).
    private var watchedBundleID: String?
    private(set) var menu: AgentMenu?

    /// Temporary F3 probes: how much work a menu session actually costs.
    ///
    /// Both are expected to reach 1 and then stay there for the life of one menu, however many times
    /// the selection moves — that is the whole claim of F3, and it is not otherwise observable from
    /// outside. Reset by `hide()`, read by the app when the menu closes. Not configurable, and not
    /// meant to outlive the measurement. Cleared when a session *starts* (see `show`), so they are
    /// still readable when the app is told the menu closed, whichever path closed it.
    private(set) var rebuildCount = 0
    private(set) var timerCreationCount = 0

    public var isVisible: Bool { panel?.isVisible ?? false }

    public init(frontmost: FrontmostAppProviding) {
        self.frontmost = frontmost
    }

    // MARK: - Presentation

    public func show(_ menu: AgentMenu) {
        // A new session starts here, not at `hide()`: the focus-loss path hides itself from its own
        // timer, and the app only learns about it afterwards — so counters cleared in `hide()` would
        // always read 0 on exactly the path worth measuring.
        if !isVisible {
            rebuildCount = 0
            timerCreationCount = 0
        }
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
        // Long lists move their viewport before anything is painted, so the row about to be
        // highlighted is one of the rows on screen. Rows are only re-placed, never rebuilt.
        if menu.layout == .list { updateListViewport(for: menu) }
        // A dial can be showing nothing at all, so "which index is highlighted" is -1 rather than
        // `selection`. Rows and slots share these arrays, so one rule paints both layouts.
        let highlighted = menu.hasSelection ? menu.selection : -1
        for (index, background) in rowBackgrounds.enumerated() {
            background.layer?.backgroundColor = (index == highlighted
                ? NSColor.controlAccentColor.withAlphaComponent(0.85)
                : NSColor.clear).cgColor
        }
        for (index, label) in rowLabels.enumerated() {
            label.textColor = index == highlighted ? .white : .labelColor
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
        rebuildCount += 1
        content.subviews.forEach { $0.removeFromSuperview() }
        rowLabels.removeAll()
        rowBackgrounds.removeAll()
        stripCells.removeAll()
        stripNameLabel = nil
        dialCenterLabel = nil
        // New content, so the viewport goes back to the top; `render` scrolls it from there.
        listOffset = 0

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

        if menu.layout == .dial {
            // The app's name goes in the middle instead of along the top: the four slots are what
            // the eye should land on, and the header row would push them off centre.
            let centre = NSTextField(labelWithString: menu.title)
            centre.font = .systemFont(ofSize: Self.titleFontSize, weight: .semibold)
            centre.textColor = .secondaryLabelColor
            centre.alignment = .center
            content.addSubview(centre)
            dialCenterLabel = centre
            title.isHidden = true
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
            label.alignment = menu.layout == .dial ? .center : .left
            if menu.layout == .list {
                // A list row is as wide as the panel and no wider: Chrome's rows carry whole window
                // and extension names, which used to run off the right edge.
                label.lineBreakMode = .byTruncatingTail
                label.usesSingleLineMode = true
            }
            content.addSubview(label)
            rowLabels.append(label)
        }

        render(menu)
    }

    private func position(_ panel: NSPanel, for menu: AgentMenu) {
        let screen = Self.screenFrame
        if menu.layout == .strip {
            positionStrip(panel, cells: menu.items.count, on: screen)
            return
        }

        if menu.layout == .dial {
            positionDial(panel, on: screen)
            return
        }

        // The height counts the rows the viewport shows, not the rows the menu has.
        let size = Self.listPanelSize(rows: Self.visibleRowCount(menu.items.count, on: screen))

        // Lower-middle of the screen: close enough to read without a controller-holder having to
        // look up, and out of the way of the composer the agent itself puts at the bottom.
        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.minY + screen.height * 0.22
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        // Header and hint sit at the panel's edges whatever the viewport is doing; the rows in
        // between are placed by the viewport, so that one piece of arithmetic serves both the first
        // draw and every later selection move.
        titleLabel?.frame = NSRect(
            x: Self.padding,
            y: size.height - Self.padding - Self.headerHeight,
            width: size.width - Self.padding * 2,
            height: Self.headerHeight
        )
        hintLabel?.frame = NSRect(x: Self.padding, y: Self.padding, width: size.width - Self.padding * 2, height: Self.hintHeight)
        updateListViewport(for: menu)
    }

    // MARK: - List viewport

    /// Scrolls the viewport far enough that the selection is on screen, re-places the rows, and
    /// writes the position into the title.
    ///
    /// This is on the `render` path, so it may not rebuild anything — every row already exists as
    /// a view, and all this does is move frames, hide the rows outside the window, set a string.
    private func updateListViewport(for menu: AgentMenu) {
        let visible = Self.visibleRowCount(menu.items.count, on: Self.screenFrame)
        // A list always opens on a row (`AgentMenu.hasSelection`), so there is always one to keep
        // in view. One step off either edge scrolls by one row; the wrap-around at the ends jumps
        // the whole way, which is what these same two lines already do.
        let selection = menu.selection
        if selection < listOffset {
            listOffset = selection
        } else if selection >= listOffset + visible {
            listOffset = selection - visible + 1
        }
        listOffset = min(max(listOffset, 0), max(menu.items.count - visible, 0))

        layoutListRows(in: Self.listPanelSize(rows: visible), visible: visible)
        // The counter appears only when something is off screen: 41 rows of Chrome need it to say
        // where the user is, a menu that fits keeps the app's own name alone.
        titleLabel?.stringValue = visible < menu.items.count
            ? "\(menu.title) · \(selection + 1)/\(menu.items.count)"
            : menu.title
    }

    /// Places the `visible` rows starting at `listOffset` and hides every other one.
    private func layoutListRows(in size: NSSize, visible: Int) {
        let top = size.height - Self.padding - Self.headerHeight - Self.rowHeight
        for index in rowLabels.indices {
            let slot = index - listOffset
            guard slot >= 0, slot < visible else {
                rowBackgrounds[index].isHidden = true
                rowLabels[index].isHidden = true
                continue
            }
            rowBackgrounds[index].isHidden = false
            rowLabels[index].isHidden = false

            let rowFrame = NSRect(
                x: Self.padding,
                y: top - CGFloat(slot) * Self.rowHeight,
                width: size.width - Self.padding * 2,
                height: Self.rowHeight
            )
            rowBackgrounds[index].frame = rowFrame.insetBy(dx: 0, dy: 3)

            // `sizeToFit` is asked for the line height only — the width is the row's, so a title
            // longer than the panel truncates with an ellipsis instead of running off the edge.
            let label = rowLabels[index]
            label.sizeToFit()
            label.frame = NSRect(
                x: rowFrame.minX + 14,
                y: rowFrame.midY - label.frame.height / 2,
                width: rowFrame.width - 28,
                height: label.frame.height
            )
        }
    }

    /// Four slots on a 3×3 grid: ↑ top, ← left, ↓ bottom, → right, app name in the middle.
    ///
    /// Text only, deliberately: no icons, no shortcut subtitles, no animation. The slot order is
    /// `AgentMenu.dialSlotOrder`, which is also the order the builder emits items in, so index *is*
    /// position and the highlight needs no separate mapping.
    private func positionDial(_ panel: NSPanel, on screen: NSRect) {
        let side = Self.dialSide
        let size = NSSize(width: side, height: side + Self.hintHeight + Self.padding)
        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.minY + screen.height * 0.22
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        let grid = (side - Self.padding * 2) / 3
        let left = Self.padding
        let bottom = Self.hintHeight + Self.padding
        // Grid cell (column, row) per item, row 0 at the top — in `AgentMenu.dialSlotOrder`, so
        // item 0 is ↑, 1 is ←, 2 is ↓, 3 is →.
        let cells: [(column: CGFloat, row: CGFloat)] = [(1, 0), (0, 1), (1, 2), (2, 1)]
        for (index, background) in rowBackgrounds.enumerated() where index < cells.count {
            let (column, row) = cells[index]
            let frame = NSRect(
                x: left + column * grid,
                y: bottom + (2 - row) * grid,
                width: grid,
                height: grid
            )
            background.frame = frame.insetBy(dx: 4, dy: grid / 2 - Self.rowHeight / 2 + 4)
            rowLabels[index].frame = background.frame
        }

        dialCenterLabel?.frame = NSRect(
            x: left + grid,
            y: bottom + grid + grid / 2 - Self.headerHeight / 2,
            width: grid,
            height: Self.headerHeight
        )
        hintLabel?.frame = NSRect(
            x: Self.padding,
            y: Self.padding,
            width: size.width - Self.padding * 2,
            height: Self.hintHeight
        )
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
        // Already watching this app: keep the timer running. Rebuilding the panel for a structure
        // change is no reason to restart the poll, and a selection move never gets here at all. A
        // structure change that *does* name a different app falls through and re-targets.
        if let pollTimer, pollTimer.isValid, watchedBundleID == bundleID { return }
        stopWatching()
        guard let bundleID else { return }
        timerCreationCount += 1
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
        watchedBundleID = bundleID
    }

    private func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
        watchedBundleID = nil
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
    /// Dial layout: the square the 3×3 grid of slots fills.
    private static let dialSide: CGFloat = 460
    private static let stripNameHeight: CGFloat = 40
    /// List layout: the ceiling on rows drawn at once, and the share of the screen they may take.
    ///
    /// Ten is already more than anyone reads at a glance from a sofa; the fraction is what stops a
    /// 41-row menu on a short screen from becoming a full-height bar.
    private static let maxVisibleRows = 10
    private static let maxScreenFraction: CGFloat = 0.6
    /// Deliberately large: this is meant to be readable from a sofa, not from 40 cm away.
    private static let rowFontSize: CGFloat = 26
    private static let titleFontSize: CGFloat = 15
    private static let hintFontSize: CGFloat = 13

    private static var screenFrame: NSRect {
        NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// How many rows of a list the panel shows at once: the rows there are, `maxVisibleRows`, or
    /// what `maxScreenFraction` of the screen leaves once the header, the hint and the padding have
    /// taken their share — whichever is smallest. Never zero, so even an absurdly short screen
    /// still draws the row under the highlight.
    private static func visibleRowCount(_ count: Int, on screen: NSRect) -> Int {
        let furniture = headerHeight + hintHeight + padding * 2
        let fits = Int((screen.height * maxScreenFraction - furniture) / rowHeight)
        return max(1, min(count, maxVisibleRows, fits))
    }

    private static func listPanelSize(rows: Int) -> NSSize {
        NSSize(width: width, height: headerHeight + CGFloat(rows) * rowHeight + hintHeight + padding * 2)
    }
}
