import Foundation

// G4 「通用菜单」的接口契约（v2，2026-09-21 安全复审后）。三条实现线都只依赖这个文件，只由 lead 改。
//
// v2 与 v1 的区别，以及为什么：
// - 执行按 **元素引用** 而不是按标题路径重新定位。两个同名窗口、菜单在读与按之间重排，按路径都会按错；
//   用户看到并选中的是某一个元素，就按那一个。所以条目带 `id`，读取器持有 id → AXUIElement 的映射。
// - 读取与执行绑定成一个 **会话**：会话记住目标进程 pid 和打开菜单时聚焦的窗口。bundle ID 相同不等于
//   还是用户选菜单时的上下文（Finder 窗口 A 选好文件，切到窗口 B 再按 A，「移到废纸篓」就作用在 B 上）。
//   执行前重检 pid 仍在、聚焦窗口仍是同一个，否则 `.contextChanged`，不执行。
// - 读取有 **整次截止时间**：目标 App 无响应时，每条 AX 消息 0.5 s 超时 × 数百条消息仍会卡住主线程；
//   读取器必须在首次超时或总耗时超过 `AppMenuReadBudget` 时中止并返回 nil，而不是继续遍历。

/// One item of the frontmost app's own menu bar, as read live through Accessibility.
///
/// `id` is the entry's index within its session and is what `AppMenuSession.press(id:)` takes.
/// `path` is the full title path from the menu bar down, e.g. `["Show", "Show Next Unread Chat"]`;
/// `title` is its last component. `shortcut` is display-only (may be nil); nothing is ever
/// synthesised from it.
public struct AppMenuEntry: Equatable, Sendable {
    public var id: Int
    public var path: [String]
    public var shortcut: String?
    public var isEnabled: Bool

    public init(id: Int, path: [String], shortcut: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.path = path
        self.shortcut = shortcut
        self.isEnabled = isEnabled
    }

    public var title: String { path.last ?? "" }
    /// The top-level menu this lives under ("File", "Show", …); "" for a malformed path.
    public var menuTitle: String { path.first ?? "" }
    /// `"Show/Show Next Unread Chat"` — the form favourites are written in config. Compare with
    /// `==` against live entries; never split it on "/" (titles such as `Pin/Unpin` contain one).
    public var pathKey: String { path.joined(separator: "/") }
}

/// What happened when an entry was pressed.
public enum AppMenuPressOutcome: Equatable, Sendable {
    case pressed
    /// The app is no longer running as the process the session was opened against, or
    /// Accessibility gives no menu bar for it any more.
    case appUnavailable
    /// The window that was focused when the menu opened is no longer the focused one (or the
    /// process changed). The user chose the row for a different context; nothing was pressed.
    case contextChanged
    /// The element behind `id` no longer exists in the live menu (unknown id, or the app rebuilt
    /// its menu since the session was opened).
    case notFound
    /// The item exists but the app has it greyed out right now.
    case disabled
    case failed(String)
}

/// Limits on one read. The reader must stop and return nil rather than exceed them.
public enum AppMenuReadBudget {
    /// Wall-clock deadline for one `openSession` call: once it has passed, the reader sends no
    /// further Accessibility message and returns nil. It is checked between messages, so a single
    /// message already in flight can still run to `messagingTimeout` — the true worst case for
    /// one call is therefore `maxDuration + messagingTimeout` (about 1.0 s). 0.5 s rather than 0.3 s because a busy but
    /// healthy Chrome was measured at 244 ms; an unresponsive app still aborts at its first timeout.
    public static let maxDuration: TimeInterval = 0.5
    /// Per-message Accessibility timeout the reader applies (`AXUIElementSetMessagingTimeout`).
    public static let messagingTimeout: TimeInterval = 0.5
}

/// One opened menu: the entries the user is looking at, bound to the process and the focused
/// window they were read from.
public protocol AppMenuSession: AnyObject {
    var bundleID: String { get }
    /// Flattened, depth-first, in menu order; leaves only; the Apple menu excluded.
    var entries: [AppMenuEntry] { get }
    /// Presses the entry with `id` — the very element that was read, not a fresh lookup by title —
    /// after re-checking that the same process is running and the same window is still focused.
    func press(id: Int) -> AppMenuPressOutcome
}

/// Reads an application's menu bar through Accessibility and hands back a session.
///
/// Synchronous by design for now (it runs on the gesture path), which is exactly why
/// `AppMenuReadBudget` exists. `nil` when the app is not running, exposes no menu bar, or the
/// read had to be aborted (first Accessibility timeout, or `maxDuration` exceeded) — an aborted
/// read never returns a partial menu, because a partial menu silently loses favourites.
public protocol AppMenuReading: AnyObject {
    func openSession(bundleID: String) -> AppMenuSession?
}
