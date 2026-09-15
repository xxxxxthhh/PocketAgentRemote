import XCTest
@testable import PocketAgentCore

/// Locks the event *sequence* the emitter produces.
///
/// This exists because of a measured failure: sending `⌃⇧M` as a single event with `flags` set was
/// silently ignored by Codex, while the same combination with a genuine Control key-down was
/// accepted. Spec §11.2 mandates the explicit modifier ordering, and these tests are what keep it
/// from being "simplified" back into a flag bitmask.
final class CGEventEmitterTests: XCTestCase {
    private final class SpyPoster: KeyboardEventPosting {
        struct Event: Equatable {
            let keyCode: CGKeyCode
            let down: Bool
            let flags: CGEventFlags
        }

        private(set) var events: [Event] = []

        func post(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
            events.append(Event(keyCode: keyCode, down: down, flags: flags))
        }

        func reset() { events.removeAll() }

        var keyCodes: [CGKeyCode] { events.map(\.keyCode) }
    }

    private func makeEmitter() -> (CGEventEmitter, SpyPoster) {
        let poster = SpyPoster()
        let emitter = CGEventEmitter(queue: DispatchQueue(label: "test"), poster: poster)
        return (emitter, poster)
    }

    func testUnmodifiedPressIsExactlyDownThenUp() {
        let (emitter, poster) = makeEmitter()
        emitter.performPress(.key(.enter))

        XCTAssertEqual(poster.events.count, 2)
        XCTAssertEqual(poster.events[0], .init(keyCode: Key.enter.keyCode, down: true, flags: []))
        XCTAssertEqual(poster.events[1], .init(keyCode: Key.enter.keyCode, down: false, flags: []))
    }

    func testModifiedPressPressesTheModifiersForReal() {
        let (emitter, poster) = makeEmitter()
        emitter.performPress(KeyStroke(.m, modifiers: [.control, .shift]))

        XCTAssertEqual(
            poster.keyCodes,
            [
                ModifierKey.control.keyCode,
                ModifierKey.shift.keyCode,
                Key.m.keyCode,
                Key.m.keyCode,
                ModifierKey.shift.keyCode,
                ModifierKey.control.keyCode,
            ],
            "modifier down → key down → key up → modifier up (spec §11.2)"
        )

        XCTAssertEqual(poster.events.map(\.down), [true, true, true, false, false, false])
    }

    func testModifierFlagsAccompanyTheKeyEvent() {
        let (emitter, poster) = makeEmitter()
        emitter.performPress(KeyStroke(.m, modifiers: [.control, .shift]))

        let keyDown = poster.events[2]
        XCTAssertTrue(keyDown.flags.contains(.maskControl))
        XCTAssertTrue(keyDown.flags.contains(.maskShift))
    }

    func testModifiersAreReleasedEvenWhenTheKeyIsNot() {
        let (emitter, poster) = makeEmitter()
        emitter.performPress(KeyStroke(.g, modifiers: [.control, .shift]))

        XCTAssertEqual(poster.events.last?.keyCode, ModifierKey.control.keyCode)
        XCTAssertEqual(poster.events.last?.down, false)
    }

    func testHeldKeyBalancesDownAndUpWithModifiers() {
        let (emitter, poster) = makeEmitter()
        emitter.performKeyDown(KeyStroke(.rightArrow, modifiers: [.option]))
        emitter.performKeyUp(KeyStroke(.rightArrow, modifiers: [.option]))

        XCTAssertEqual(
            poster.keyCodes,
            [
                ModifierKey.option.keyCode,
                Key.rightArrow.keyCode,
                Key.rightArrow.keyCode,
                ModifierKey.option.keyCode,
            ]
        )
    }

    func testReleaseAllReleasesHeldKeysAndModifiers() {
        let (emitter, poster) = makeEmitter()
        emitter.performKeyDown(KeyStroke(.upArrow, modifiers: [.command]))
        poster.reset()

        emitter.performReleaseAll()

        let ups = poster.events.filter { !$0.down }
        XCTAssertEqual(ups.count, 2, "the held key and the held modifier must both be released")
        XCTAssertTrue(poster.events.allSatisfy { !$0.down })
    }

    func testReleaseAllIsIdempotent() {
        let (emitter, poster) = makeEmitter()
        emitter.performReleaseAll()
        emitter.performReleaseAll()
        XCTAssertTrue(poster.events.isEmpty, "nothing was held, so nothing should be posted")
    }

    func testNoStuckModifierAfterAPress() {
        let (emitter, poster) = makeEmitter()
        emitter.performPress(KeyStroke(.n, modifiers: [.command]))
        // Every key that went down must come back up; otherwise the user's session inherits a
        // stuck Command key.
        for keyCode in Set(poster.keyCodes) {
            let downs = poster.events.filter { $0.keyCode == keyCode && $0.down }.count
            let ups = poster.events.filter { $0.keyCode == keyCode && !$0.down }.count
            XCTAssertEqual(downs, ups, "key \(keyCode) is unbalanced")
        }
    }
}

final class KeyStrokeDescriptionTests: XCTestCase {
    func testDescriptionReadsLikeAKeyCombo() {
        XCTAssertEqual(KeyStroke(.m, modifiers: [.control, .shift]).description, "control+shift+m")
        XCTAssertEqual(KeyStroke(.enter).description, "enter")
    }
}
