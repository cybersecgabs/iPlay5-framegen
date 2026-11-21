import XCTest
@testable import iPlay5

final class FramePacerTests: XCTestCase {
	func testPassthroughWhenOff() {
		let pacer = FramePacer<Int>(mode: .off, nominalSourceFPS: 60)
		XCTAssertFalse(pacer.shouldInterpolate(arrivalTime: 100.0))

		// Enqueue calls while .off are ignored so buffers are never pinned in the queue
		pacer.enqueueRealFrame(1, arrivalTime: 100.0)
		XCTAssertFalse(pacer.shouldInterpolate(arrivalTime: 100.016))
		XCTAssertNil(pacer.popFrame(forDisplayTimestamp: 100.008, vsyncInterval: 1.0 / 120.0))
		XCTAssertEqual(pacer.stats.pendingCount, 0)
		XCTAssertEqual(pacer.stats.realPresented, 0)
		XCTAssertEqual(pacer.stats.generatedPresented, 0)
	}

	func test30To60PacingOn120HzDisplay() {
		let pacer = FramePacer<String>(mode: .x2, nominalSourceFPS: 30)
		let sourceInterval = 1.0 / 30.0
		let vsyncInterval = 1.0 / 120.0

		var t = 100.0
		pacer.enqueueRealFrame("R0", arrivalTime: t)

		var vsync = 100.0 + vsyncInterval
		if let first = pacer.popFrame(forDisplayTimestamp: vsync, vsyncInterval: vsyncInterval) {
			XCTAssertEqual(first.frame, "R0")
		}

		var poppedLog: [(time: Double, label: String, generated: Bool)] = []
		for i in 1...10 {
			t += sourceInterval
			let ready = t + 0.004
			XCTAssertTrue(pacer.shouldInterpolate(arrivalTime: t))
			pacer.enqueueInterpolatedPair(interpolated: "G\(i)", real: "R\(i)", sourceArrivalTime: t, readyTime: ready)

			while vsync <= t + sourceInterval + 0.004 {
				if let frame = pacer.popFrame(forDisplayTimestamp: vsync, vsyncInterval: vsyncInterval) {
					poppedLog.append((vsync, frame.frame, frame.isGenerated))
				}
				vsync += vsyncInterval
			}
		}

		let stats = pacer.stats
		XCTAssertGreaterThanOrEqual(stats.generatedPresented, 8)
		XCTAssertGreaterThanOrEqual(stats.realPresented, 9)
		XCTAssertEqual(stats.estimatedSourceFPS, 30.0, accuracy: 0.5)

		// Verify output frames alternate G -> R -> G -> R after steady state
		let tail = Array(poppedLog.suffix(8))
		for idx in 1..<tail.count {
			XCTAssertNotEqual(tail[idx].generated, tail[idx - 1].generated)
			let dt = tail[idx].time - tail[idx - 1].time
			XCTAssertEqual(dt, 1.0 / 60.0, accuracy: 0.009)
		}
	}

	func test60To120Pacing() {
		let pacer = FramePacer<String>(mode: .x2, nominalSourceFPS: 60)
		let sourceInterval = 1.0 / 60.0
		let vsyncInterval = 1.0 / 120.0

		var t = 200.0
		pacer.enqueueRealFrame("R0", arrivalTime: t)
		var vsync = 200.0 + vsyncInterval
		_ = pacer.popFrame(forDisplayTimestamp: vsync, vsyncInterval: vsyncInterval)

		for i in 1...10 {
			t += sourceInterval
			pacer.enqueueInterpolatedPair(interpolated: "G\(i)", real: "R\(i)", sourceArrivalTime: t, readyTime: t + 0.0025)
			for _ in 0..<2 {
				vsync += vsyncInterval
				_ = pacer.popFrame(forDisplayTimestamp: vsync, vsyncInterval: vsyncInterval)
			}
		}

		XCTAssertGreaterThanOrEqual(pacer.stats.generatedPresented, 8)
		XCTAssertGreaterThanOrEqual(pacer.stats.realPresented, 8)
		XCTAssertEqual(pacer.stats.estimatedSourceFPS, 60.0, accuracy: 0.5)
	}

	func testDuplicateSkippingNeverFreezesStaticScreens() {
		let pacer = FramePacer<Int>(mode: .x2, nominalSourceFPS: 60, maxConsecutiveDuplicateSkips: 1)

		// First near-identical frame is skipped, second consecutive identical frame must be processed
		XCTAssertEqual(pacer.evaluateDuplicate(diffScore: 0.0004, threshold: 0.0028, enabled: true), .skipDuplicate)
		XCTAssertEqual(pacer.evaluateDuplicate(diffScore: 0.0004, threshold: 0.0028, enabled: true), .process)
		XCTAssertEqual(pacer.evaluateDuplicate(diffScore: 0.0004, threshold: 0.0028, enabled: true), .skipDuplicate)
		XCTAssertEqual(pacer.evaluateDuplicate(diffScore: 0.05, threshold: 0.0028, enabled: true), .process)
		XCTAssertEqual(pacer.evaluateDuplicate(diffScore: 0.0001, threshold: 0.0028, enabled: false), .process)
		XCTAssertEqual(pacer.stats.skippedDuplicates, 2)
	}

	func testDiscontinuityGuardOnNetworkStall() {
		let pacer = FramePacer<Int>(mode: .x2, nominalSourceFPS: 30, maxGapMultiplier: 2.5)
		pacer.enqueueRealFrame(1, arrivalTime: 50.0)
		XCTAssertTrue(pacer.shouldInterpolate(arrivalTime: 50.033))
		XCTAssertFalse(pacer.shouldInterpolate(arrivalTime: 50.25))

		pacer.reset()
		XCTAssertFalse(pacer.shouldInterpolate(arrivalTime: 50.283))
	}

	func testBurstBackpressureCapsQueueAtTwo() {
		let pacer = FramePacer<Int>(mode: .x2, nominalSourceFPS: 30)
		pacer.enqueueRealFrame(0, arrivalTime: 10.0)
		pacer.enqueueInterpolatedPair(interpolated: 1, real: 2, sourceArrivalTime: 10.033, readyTime: 10.036)
		XCTAssertEqual(pacer.stats.pendingCount, 2)

		// Second pair arrives before consumer popped previous pair -> stale pair dropped
		pacer.enqueueInterpolatedPair(interpolated: 3, real: 4, sourceArrivalTime: 10.066, readyTime: 10.069)
		XCTAssertEqual(pacer.stats.pendingCount, 2)
		XCTAssertEqual(pacer.stats.droppedStaleFrames, 3) // 1 real + 2 from first pair
	}

	func testSwitchingToOffClearsPendingQueue() {
		let pacer = FramePacer<Int>(mode: .x2, nominalSourceFPS: 30)
		pacer.enqueueRealFrame(0, arrivalTime: 10.0)
		pacer.enqueueInterpolatedPair(interpolated: 1, real: 2, sourceArrivalTime: 10.033, readyTime: 10.036)
		XCTAssertEqual(pacer.stats.pendingCount, 2)

		pacer.configure(mode: .off, nominalSourceFPS: 30)
		XCTAssertEqual(pacer.stats.pendingCount, 0)
		XCTAssertEqual(pacer.stats.droppedStaleFrames, 3)

		// In-flight enqueue arriving right after live toggle to .off must not repopulate queue
		pacer.enqueueInterpolatedPair(interpolated: 5, real: 6, sourceArrivalTime: 10.066, readyTime: 10.069)
		XCTAssertEqual(pacer.stats.pendingCount, 0)

		// Switching back to .x2 starts with clean continuity
		pacer.configure(mode: .x2, nominalSourceFPS: 30)
		XCTAssertFalse(pacer.shouldInterpolate(arrivalTime: 10.1))
	}
}
