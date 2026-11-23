import XCTest
@testable import iPlay5

final class NetworkJitterPacerTests: XCTestCase {
	func testSteadyArrivalsStayAtZeroDepth() {
		var policy = NetworkJitterPolicy()
		policy.configure(fps: 60)
		let step = 1.0 / 60.0
		var t = 10.0
		for _ in 0..<20 {
			XCTAssertNil(policy.noteArrival(at: t))
			XCTAssertEqual(policy.depth, 0)
			t += step
		}
	}

	func testUnevenArrivalsAndStallStepDepthUp() {
		var policy = NetworkJitterPolicy()
		policy.configure(fps: 60)
		let step = 1.0 / 60.0

		// 3 uneven gaps within 2 s bump depth from 0 to 1
		XCTAssertNil(policy.noteArrival(at: 1.0))
		XCTAssertNil(policy.noteArrival(at: 1.0 + step * 2.0)) // uneven #1
		XCTAssertNil(policy.noteArrival(at: 1.0 + step * 2.2)) // uneven #2 (<0.5x)
		let bump = policy.noteArrival(at: 1.0 + step * 4.0) // uneven #3
		XCTAssertEqual(bump?.depth, 1)
		XCTAssertEqual(policy.depth, 1)

		// A single big stall (> 4 frames) bumps depth from 0 to 1 immediately
		policy.reset()
		XCTAssertEqual(policy.depth, 0)
		XCTAssertNil(policy.noteArrival(at: 2.0))
		let stallBump = policy.noteArrival(at: 2.0 + step * 5.0)
		XCTAssertEqual(stallBump?.depth, 1)
		XCTAssertEqual(policy.depth, 1)
	}

	func testUnderrunsStepDepthUpToMaxAndCalmDecaysBackToZero() {
		var policy = NetworkJitterPolicy()
		policy.configure(fps: 60)
		let step = 1.0 / 60.0

		// Start holding 1 frame via a stall
		XCTAssertNil(policy.noteArrival(at: 10.0))
		XCTAssertEqual(policy.noteArrival(at: 10.1)?.depth, 1)

		// 2 underruns within 3 s raise depth to maxDepth (2)
		XCTAssertNil(policy.noteUnderrun(at: 10.5))
		XCTAssertEqual(policy.noteUnderrun(at: 11.0)?.depth, NetworkJitterPolicy.maxDepth)
		XCTAssertEqual(policy.underruns, 2)
		XCTAssertEqual(policy.depth, NetworkJitterPolicy.maxDepth)

		// Further underruns do not exceed maxDepth
		XCTAssertNil(policy.noteUnderrun(at: 11.2))
		XCTAssertNil(policy.noteUnderrun(at: 11.4))
		XCTAssertEqual(policy.depth, NetworkJitterPolicy.maxDepth)

		// Steady arrivals until >10 s after lastTrouble decay depth 2 -> 1 -> 0
		var t = 11.4 + step
		var decayedToOne = false
		var decayedToZero = false
		while t < 35.0 {
			if let change = policy.noteArrival(at: t) {
				if change.depth == 1 { decayedToOne = true }
				if change.depth == 0 { decayedToZero = true }
			}
			t += step
		}
		XCTAssertTrue(decayedToOne)
		XCTAssertTrue(decayedToZero)
		XCTAssertEqual(policy.depth, 0)

		policy.reset()
		XCTAssertEqual(policy.depth, 0)
	}
}
