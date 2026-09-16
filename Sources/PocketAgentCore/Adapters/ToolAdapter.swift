import Foundation

/// What a tool can do with a semantic action, and why not when it cannot.
///
/// The `note` matters: spec §8 requires unsupported actions to be *reported*, never silently
/// substituted (turning "switch permission mode" into "approve this command" is the failure mode
/// the whole guard layer exists to prevent).
public struct ActionSupport: Equatable, Sendable {
    public var recipe: OutputRecipe?
    public var note: String?

    public init(recipe: OutputRecipe?, note: String? = nil) {
        self.recipe = recipe
        self.note = note
    }

    public static func supported(_ recipe: OutputRecipe) -> ActionSupport {
        ActionSupport(recipe: recipe)
    }

    public static func unsupported(_ reason: String) -> ActionSupport {
        ActionSupport(recipe: nil, note: reason)
    }
}

/// Translates a semantic action into keystrokes for one tool (spec §10.4).
public protocol ToolAdapter: Sendable {
    var profile: ToolProfile { get }
    func support(for action: AgentAction) -> ActionSupport
}

public extension OutputRecipe {
    /// The keystroke this recipe is about.
    ///
    /// Held dispatch (`.down` / `.up` triggers) needs a single key, and every recipe we ship is a
    /// single stroke; multi-step macros return their first stroke.
    var primaryStroke: KeyStroke? {
        for step in steps {
            switch step {
            case .keyPress(let stroke), .keyDown(let stroke), .keyUp(let stroke):
                return stroke
            case .delay, .text:
                continue
            }
        }
        return nil
    }
}

/// Recipe builders, so the adapter tables read as data rather than as construction code.
enum Recipe {
    /// A key the target app may repeat while held. Navigation only (spec §19).
    static func held(_ key: Key) -> OutputRecipe {
        OutputRecipe(
            steps: [.keyDown(.key(key)), .keyUp(.key(key))],
            risk: .navigation,
            allowsRepeat: true
        )
    }

    /// A one-shot key press. Can never repeat, however long the input is held (spec §19).
    static func press(_ key: Key, _ modifiers: Set<ModifierKey> = []) -> OutputRecipe {
        OutputRecipe(
            steps: [.keyPress(KeyStroke(key, modifiers: modifiers))],
            risk: .normal
        )
    }

    /// A tool-specific action. Requires an explicit profile and an allowed frontmost app (spec §12).
    static func tool(_ key: Key, _ modifiers: Set<ModifierKey> = []) -> OutputRecipe {
        OutputRecipe(
            steps: [.keyPress(KeyStroke(key, modifiers: modifiers))],
            risk: .sensitive,
            requiresExplicitProfile: true
        )
    }

    /// A non-keystroke system effect, valid on **every** profile.
    ///
    /// Modelled as an `OutputRecipe` so every action still yields one uniform `ActionSupport`, and
    /// so the "unsupported" path keeps its meaning: a recipe is either something to run or an
    /// explanation of why not. `ActionDispatcher` acts on `effect` before the keystroke path, so the
    /// empty `steps` are never read as a broken recipe.
    static func system(_ effect: RecipeEffect, risk: ActionRisk = .sensitive) -> OutputRecipe {
        OutputRecipe(steps: [], risk: risk, requiresExplicitProfile: false, effect: effect)
    }
}
