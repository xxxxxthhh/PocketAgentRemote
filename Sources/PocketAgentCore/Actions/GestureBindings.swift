import Foundation

/// Maps gestures to semantic actions (spec §6.1/§6.2/§13).
public struct GestureBindings: Equatable, Sendable {
    /// Base layer: directions and A behave normally when B is not down.
    public var base: [PhysicalButton: AgentAction]
    /// B layer: the key that, pressed while B is held, produces this action.
    public var bLayer: [PhysicalButton: AgentAction]

    public init(base: [PhysicalButton: AgentAction], bLayer: [PhysicalButton: AgentAction]) {
        self.base = base
        self.bLayer = bLayer
    }

    public static let `default` = GestureBindings(
        base: [
            .up: .navigateUp,
            .down: .navigateDown,
            .left: .navigateLeft,
            .right: .navigateRight,
            .a: .submit,
            .b: .cancelOrInterrupt,
        ],
        bLayer: [
            .up: .cyclePermissionMode,
            .down: .toggleFastMode,
            .left: .openModelPicker,
            .right: .queueFollowUp,
            .a: .inspectChanges,
        ]
    )
}

/// The phase of an action, which the output layer needs in order to decide between a key press
/// (one-shot) and a held key down/up pair (repeatable).
public enum ActionTrigger: Equatable, Sendable {
    case press(AgentAction)
    case down(AgentAction)
    case up(AgentAction)

    public var action: AgentAction {
        switch self {
        case .press(let action), .down(let action), .up(let action): return action
        }
    }
}

public struct EventResolver: Sendable {
    public let bindings: GestureBindings

    public init(bindings: GestureBindings = .default) {
        self.bindings = bindings
    }

    public func triggers(for event: ResolvedEvent) -> [ActionTrigger] {
        switch event {
        case .keyDown(let button):
            guard let action = bindings.base[button] else { return [] }
            return [.down(action)]

        case .keyUp(let button):
            guard let action = bindings.base[button] else { return [] }
            return [.up(action)]

        case .gesture(.tap(let button)), .gesture(.hold(let button)):
            guard let action = bindings.base[button] else { return [] }
            return [.press(action)]

        case .gesture(.chord(_, let key)):
            guard let action = bindings.bLayer[key] else { return [] }
            return [.press(action)]
        }
    }

    public func triggers(for events: [ResolvedEvent]) -> [ActionTrigger] {
        events.flatMap { triggers(for: $0) }
    }
}
