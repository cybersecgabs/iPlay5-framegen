import Foundation

/// Pacing wrapper for a real or interpolated frame scheduled for a future vsync.
struct PacedFrame<Frame> {
	let frame: Frame
	let presentAt: Double
	let isGenerated: Bool
	let sourceArrivalTime: Double
}

enum DuplicateDecision: Equatable {
	case process
	case skipDuplicate
}

struct PacerStats: Equatable {
	var realPresented: Int = 0
	var generatedPresented: Int = 0
	var droppedStaleFrames: Int = 0
	var skippedDuplicates: Int = 0
	var estimatedSourceFPS: Double = 0
	var pendingCount: Int = 0
}

/// Cadence pacer for real and 2x-interpolated frames with bounded queue latency.
///
/// Designed as a pure generic component so pacing math, EMA source-rate tracking,
/// duplicate-frame skipping (for 30 fps games inside 60 fps streams like GTA 6),
/// and network-stall discontinuity recovery can all be exhaustively unit-tested.
final class FramePacer<Frame> {
	private let lock = NSLock()
	private var mode: FrameGenMode
	private var nominalSourceFPS: Double
	private let maxGapMultiplier: Double
	private let maxConsecutiveDuplicateSkips: Int

	private var estimatedSourceInterval: Double
	private var lastSourceArrivalTime: Double?
	private var lastPresentedTarget: Double = 0
	private var consecutiveDuplicateSkips: Int = 0
	private var queue: [PacedFrame<Frame>] = []

	private var realPresented: Int = 0
	private var generatedPresented: Int = 0
	private var droppedStaleFrames: Int = 0
	private var skippedDuplicates: Int = 0

	init(
		mode: FrameGenMode = .off,
		nominalSourceFPS: Double = 60,
		maxGapMultiplier: Double = 2.5,
		maxConsecutiveDuplicateSkips: Int = 1
	) {
		let clampedFPS = min(max(nominalSourceFPS, 15), 120)
		self.mode = mode
		self.nominalSourceFPS = clampedFPS
		self.maxGapMultiplier = max(maxGapMultiplier, 1.1)
		self.maxConsecutiveDuplicateSkips = max(maxConsecutiveDuplicateSkips, 0)
		self.estimatedSourceInterval = 1.0 / clampedFPS
	}

	func configure(mode: FrameGenMode, nominalSourceFPS: Double) {
		lock.lock()
		defer { lock.unlock() }
		let clampedFPS = min(max(nominalSourceFPS, 15), 120)
		let modeChanged = self.mode != mode
		let fpsChanged = abs(self.nominalSourceFPS - clampedFPS) > 0.5
		self.mode = mode
		self.nominalSourceFPS = clampedFPS
		if modeChanged || fpsChanged {
			estimatedSourceInterval = 1.0 / clampedFPS
			consecutiveDuplicateSkips = 0
		}
		if modeChanged {
			droppedStaleFrames += queue.count
			queue.removeAll()
			lastSourceArrivalTime = nil
			lastPresentedTarget = 0
		}
	}

	func evaluateDuplicate(diffScore: Double, threshold: Double, enabled: Bool) -> DuplicateDecision {
		lock.lock()
		defer { lock.unlock() }
		guard enabled else {
			consecutiveDuplicateSkips = 0
			return .process
		}
		if diffScore < threshold && consecutiveDuplicateSkips < maxConsecutiveDuplicateSkips {
			consecutiveDuplicateSkips += 1
			skippedDuplicates += 1
			return .skipDuplicate
		}
		consecutiveDuplicateSkips = 0
		return .process
	}

	func shouldInterpolate(arrivalTime: Double) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard mode == .x2, let lastArrival = lastSourceArrivalTime else { return false }
		let dt = arrivalTime - lastArrival
		guard dt > 0 else { return false }
		return dt <= estimatedSourceInterval * maxGapMultiplier
	}

	func enqueueRealFrame(_ frame: Frame, arrivalTime: Double) {
		lock.lock()
		defer { lock.unlock() }
		guard mode != .off else { return }
		if let lastArrival = lastSourceArrivalTime {
			let dt = arrivalTime - lastArrival
			if dt >= (1.0 / 120.0) && dt <= (1.0 / 15.0) && dt <= estimatedSourceInterval * maxGapMultiplier {
				estimatedSourceInterval = estimatedSourceInterval * 0.8 + dt * 0.2
			}
		}
		droppedStaleFrames += queue.count
		queue = [PacedFrame(frame: frame, presentAt: arrivalTime, isGenerated: false, sourceArrivalTime: arrivalTime)]
		lastSourceArrivalTime = arrivalTime
	}

	func enqueueInterpolatedPair(interpolated: Frame, real: Frame, sourceArrivalTime: Double, readyTime: Double) {
		lock.lock()
		defer { lock.unlock() }
		guard mode != .off else { return }
		if let lastArrival = lastSourceArrivalTime {
			let dt = sourceArrivalTime - lastArrival
			if dt >= (1.0 / 120.0) && dt <= (1.0 / 15.0) {
				estimatedSourceInterval = estimatedSourceInterval * 0.8 + dt * 0.2
			}
		}
		lastSourceArrivalTime = sourceArrivalTime

		let halfInterval = estimatedSourceInterval * 0.5
		let midTarget: Double
		if lastPresentedTarget > 0 {
			midTarget = min(max(readyTime, lastPresentedTarget + halfInterval), readyTime + halfInterval)
		} else {
			midTarget = readyTime
		}
		let realTarget = midTarget + halfInterval

		droppedStaleFrames += queue.count
		queue = [
			PacedFrame(frame: interpolated, presentAt: midTarget, isGenerated: true, sourceArrivalTime: sourceArrivalTime),
			PacedFrame(frame: real, presentAt: realTarget, isGenerated: false, sourceArrivalTime: sourceArrivalTime),
		]
	}

	func popFrame(forDisplayTimestamp targetTimestamp: Double, vsyncInterval: Double) -> PacedFrame<Frame>? {
		lock.lock()
		defer { lock.unlock() }
		guard let first = queue.first else { return nil }
		let leadWindow = max(vsyncInterval * 0.45, 0)
		guard first.presentAt <= targetTimestamp + leadWindow else { return nil }
		queue.removeFirst()
		lastPresentedTarget = targetTimestamp
		if first.isGenerated {
			generatedPresented += 1
		} else {
			realPresented += 1
		}
		return first
	}

	func reset(clearStats: Bool = false) {
		lock.lock()
		defer { lock.unlock() }
		droppedStaleFrames += queue.count
		queue.removeAll()
		lastSourceArrivalTime = nil
		lastPresentedTarget = 0
		consecutiveDuplicateSkips = 0
		estimatedSourceInterval = 1.0 / nominalSourceFPS
		if clearStats {
			realPresented = 0
			generatedPresented = 0
			droppedStaleFrames = 0
			skippedDuplicates = 0
		}
	}

	var stats: PacerStats {
		lock.lock()
		defer { lock.unlock() }
		return PacerStats(
			realPresented: realPresented,
			generatedPresented: generatedPresented,
			droppedStaleFrames: droppedStaleFrames,
			skippedDuplicates: skippedDuplicates,
			estimatedSourceFPS: estimatedSourceInterval > 0 ? 1.0 / estimatedSourceInterval : 0,
			pendingCount: queue.count
		)
	}
}
