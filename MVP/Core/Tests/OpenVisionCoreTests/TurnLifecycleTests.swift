import XCTest
@testable import OpenVisionCore

final class TurnLifecycleTests: XCTestCase {
    func testCancelInvalidatesPhotoAndModelCallbacks() {
        var lifecycle = TurnLifecycle()
        let id = lifecycle.begin(photo: true)
        XCTAssertEqual(lifecycle.phase, .capturing)
        lifecycle.stop()
        XCTAssertFalse(lifecycle.isCurrent(id))
        XCTAssertFalse(lifecycle.advance(id, to: .speaking))
        XCTAssertEqual(lifecycle.phase, .idle)
    }

    func testNewTurnCannotReceivePreviousPhotoOrAnswer() {
        var lifecycle = TurnLifecycle()
        let old = lifecycle.begin(photo: true)
        let current = lifecycle.begin(photo: false)
        XCTAssertNotEqual(old, current)
        XCTAssertFalse(lifecycle.advance(old, to: .speaking))
        XCTAssertEqual(lifecycle.phase, .answering)
        XCTAssertTrue(lifecycle.advance(current, to: .speaking))
        XCTAssertEqual(lifecycle.phase, .speaking)
    }

    func testListeningInvalidatesPriorTurnAndAcceptsNextTurn() {
        var lifecycle = TurnLifecycle()
        let id = lifecycle.begin(photo: false)
        lifecycle.listen()
        XCTAssertEqual(lifecycle.phase, .listening)
        XCTAssertNil(lifecycle.turnID)
        XCTAssertFalse(lifecycle.advance(id, to: .speaking))
        let next = lifecycle.begin(photo: true)
        XCTAssertTrue(lifecycle.isCurrent(next))
        XCTAssertEqual(lifecycle.phase, .capturing)
    }
}
