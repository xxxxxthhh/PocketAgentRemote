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

    func testAKeypressDoesNotReleaseAModifierAnotherGestureIsHolding() {
        // Found by review (2026-09-16). While push-to-talk holds ⌥, an unrelated one-shot key must
        // not treat that ⌥ as a leftover and cancel the voice input.
        let (emitter, poster) = makeEmitter()
        emitter.performKeyDown(KeyStroke(modifiers: [.rightOption]))   // voice input starts
        poster.reset()

        emitter.performPress(.key(.escape))                            // B tap during the hold

        XCTAssertFalse(
            poster.keyCodes.contains(ModifierKey.rightOption.keyCode),
            "the deliberately held ⌥ must survive an unrelated press"
        )
    }

    func testOnlyTheKeypressesOwnModifiersAreReleasedWithIt() {
        // The held ⌥ belongs to another gesture, so releasing this key must not pop it either.
        let (emitter, poster) = makeEmitter()
        emitter.performKeyDown(KeyStroke(modifiers: [.rightOption]))
        emitter.performKeyDown(KeyStroke(.rightArrow, modifiers: [.command]))
        poster.reset()

        emitter.performKeyUp(KeyStroke(.rightArrow, modifiers: [.command]))

        XCTAssertEqual(
            poster.keyCodes,
            [Key.rightArrow.keyCode, ModifierKey.command.keyCode],
            "only this key's own ⌘ may be released"
        )
        XCTAssertFalse(poster.keyCodes.contains(ModifierKey.rightOption.keyCode))
    }

    func testRightSideModifiersUseTheirOwnKeyCodes() {
        // Doubao distinguishes 长按右option from its left-hand shortcuts, so the two sides must not
        // collapse into one key code.
        XCTAssertEqual(ModifierKey.option.keyCode, 58)
        XCTAssertEqual(ModifierKey.rightOption.keyCode, 61)
        XCTAssertEqual(ModifierKey.shift.keyCode, 56)
        XCTAssertEqual(ModifierKey.rightShift.keyCode, 60)
        // …but they carry the same flag.
        XCTAssertEqual(ModifierKey.option.eventFlag, ModifierKey.rightOption.eventFlag)
    }

    func testHoldingRightOptionSendsExactlyOneBalancedPair() {
        let (emitter, poster) = makeEmitter()
        let stroke = KeyStroke(modifiers: [.rightOption])
        emitter.performKeyDown(stroke)
        emitter.performKeyUp(stroke)

        XCTAssertEqual(poster.events, [
            // The down event carries the flag it is setting; the up event clears it.
            .init(keyCode: 61, down: true, flags: [.maskAlternate]),
            .init(keyCode: 61, down: false, flags: []),
        ])
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
