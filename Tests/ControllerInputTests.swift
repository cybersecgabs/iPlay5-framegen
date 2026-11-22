import XCTest
@testable import iPlay5

final class ControllerInputTests: XCTestCase {
	func testSelectIsTouchpadTriggersTouchpadClickAndVirtualCenterTouch() {
		let res = ControllerInput.resolveSelectAndTouchpad(
			selectPressed: true,
			distinctSharePressed: false,
			hardwareTouchpadPressed: false,
			hasPhysicalTouchContact: false,
			selectIsTouchpad: true
		)
		XCTAssertTrue(res.touchpadButtonPressed)
		XCTAssertFalse(res.shareButtonPressed)
		XCTAssertTrue(res.needsVirtualCenterTouch)
	}

	func testDistinctShareButtonStillWorksWhenSelectIsTouchpad() {
		let res = ControllerInput.resolveSelectAndTouchpad(
			selectPressed: false,
			distinctSharePressed: true,
			hardwareTouchpadPressed: false,
			hasPhysicalTouchContact: false,
			selectIsTouchpad: true
		)
		XCTAssertFalse(res.touchpadButtonPressed)
		XCTAssertTrue(res.shareButtonPressed)
		XCTAssertFalse(res.needsVirtualCenterTouch)
	}

	func testSelectActsAsShareWhenToggleDisabled() {
		let res = ControllerInput.resolveSelectAndTouchpad(
			selectPressed: true,
			distinctSharePressed: false,
			hardwareTouchpadPressed: false,
			hasPhysicalTouchContact: false,
			selectIsTouchpad: false
		)
		XCTAssertFalse(res.touchpadButtonPressed)
		XCTAssertTrue(res.shareButtonPressed)
		XCTAssertFalse(res.needsVirtualCenterTouch)
	}

	func testHardwareTouchpadWithoutPhysicalFingerUsesVirtualCenterTouch() {
		let res = ControllerInput.resolveSelectAndTouchpad(
			selectPressed: false,
			distinctSharePressed: false,
			hardwareTouchpadPressed: true,
			hasPhysicalTouchContact: false,
			selectIsTouchpad: false
		)
		XCTAssertTrue(res.touchpadButtonPressed)
		XCTAssertFalse(res.shareButtonPressed)
		XCTAssertTrue(res.needsVirtualCenterTouch)
	}

	func testHardwareTouchpadWithPhysicalFingerSkipsVirtualCenterTouch() {
		let res = ControllerInput.resolveSelectAndTouchpad(
			selectPressed: false,
			distinctSharePressed: false,
			hardwareTouchpadPressed: true,
			hasPhysicalTouchContact: true,
			selectIsTouchpad: false
		)
		XCTAssertTrue(res.touchpadButtonPressed)
		XCTAssertFalse(res.shareButtonPressed)
		XCTAssertFalse(res.needsVirtualCenterTouch)
	}

	func testSelectAndDistinctShareSimultaneousWhenSelectIsTouchpad() {
		let res = ControllerInput.resolveSelectAndTouchpad(
			selectPressed: true,
			distinctSharePressed: true,
			hardwareTouchpadPressed: false,
			hasPhysicalTouchContact: false,
			selectIsTouchpad: true
		)
		XCTAssertTrue(res.touchpadButtonPressed)
		XCTAssertTrue(res.shareButtonPressed)
		XCTAssertTrue(res.needsVirtualCenterTouch)
	}

	func testRumbleTargetSelectionLogic() {
		// Controller with motors
		XCTAssertTrue(RumbleOutput.shouldUseControllerEngine(controllerHasHaptics: true, target: .auto))
		XCTAssertFalse(RumbleOutput.shouldUsePhoneEngine(controllerHasHaptics: true, target: .auto, deviceSupportsHaptics: true))

		XCTAssertTrue(RumbleOutput.shouldUseControllerEngine(controllerHasHaptics: true, target: .controllerOnly))
		XCTAssertFalse(RumbleOutput.shouldUsePhoneEngine(controllerHasHaptics: true, target: .controllerOnly, deviceSupportsHaptics: true))

		XCTAssertFalse(RumbleOutput.shouldUseControllerEngine(controllerHasHaptics: true, target: .phoneOnly))
		XCTAssertTrue(RumbleOutput.shouldUsePhoneEngine(controllerHasHaptics: true, target: .phoneOnly, deviceSupportsHaptics: true))

		// Controller without motors (e.g. GameSir G8 USB-C)
		XCTAssertFalse(RumbleOutput.shouldUseControllerEngine(controllerHasHaptics: false, target: .auto))
		XCTAssertTrue(RumbleOutput.shouldUsePhoneEngine(controllerHasHaptics: false, target: .auto, deviceSupportsHaptics: true))
		XCTAssertFalse(RumbleOutput.shouldUsePhoneEngine(controllerHasHaptics: false, target: .controllerOnly, deviceSupportsHaptics: true))
		XCTAssertFalse(RumbleOutput.shouldUsePhoneEngine(controllerHasHaptics: false, target: .auto, deviceSupportsHaptics: false))
	}

	func testRumbleComputeMotorLevelsScalingAndClamping() {
		let dual = RumbleOutput.computeMotorLevels(left: 255, right: 128, motorCount: 2, intensity: 0.5, enabled: true)
		XCTAssertEqual(dual.count, 2)
		XCTAssertEqual(dual[0], 0.5, accuracy: 0.001)
		XCTAssertEqual(dual[1], (128.0 / 255.0) * 0.5, accuracy: 0.001)

		let single = RumbleOutput.computeMotorLevels(left: 64, right: 204, motorCount: 1, intensity: 0.5, enabled: true)
		XCTAssertEqual(single.count, 1)
		XCTAssertEqual(single[0], (204.0 / 255.0) * 0.5, accuracy: 0.001)

		let clamped = RumbleOutput.computeMotorLevels(left: 255, right: 255, motorCount: 2, intensity: 2.0, enabled: true)
		XCTAssertEqual(clamped[0], 1.0, accuracy: 0.0001)
		XCTAssertEqual(clamped[1], 1.0, accuracy: 0.0001)

		let disabled = RumbleOutput.computeMotorLevels(left: 255, right: 255, motorCount: 2, intensity: 1.0, enabled: false)
		XCTAssertEqual(disabled, [0.0, 0.0])

		XCTAssertTrue(RumbleOutput.computeMotorLevels(left: 255, right: 255, motorCount: 0, intensity: 1.0, enabled: true).isEmpty)
	}

	func testPhoneHapticParametersSharpnessAndNoiseFloor() {
		// Heavy (left) motor only -> low sharpness (0.20)
		let heavy = RumbleOutput.computePhoneHapticParameters(left: 255, right: 0, intensity: 0.8, enabled: true)
		XCTAssertEqual(heavy.intensity, 0.8, accuracy: 0.001)
		XCTAssertEqual(heavy.sharpness, 0.20, accuracy: 0.001)

		// Light (right) motor only -> high sharpness (0.85)
		let light = RumbleOutput.computePhoneHapticParameters(left: 0, right: 255, intensity: 0.6, enabled: true)
		XCTAssertEqual(light.intensity, 0.6, accuracy: 0.001)
		XCTAssertEqual(light.sharpness, 0.85, accuracy: 0.001)

		// Balanced -> midpoint sharpness (0.525)
		let balanced = RumbleOutput.computePhoneHapticParameters(left: 200, right: 200, intensity: 1.0, enabled: true)
		XCTAssertEqual(balanced.intensity, 200.0 / 255.0, accuracy: 0.001)
		XCTAssertEqual(balanced.sharpness, 0.525, accuracy: 0.001)

		// Noise floor zeros very quiet values
		let quiet = RumbleOutput.computePhoneHapticParameters(left: 2, right: 1, intensity: 1.0, enabled: true)
		XCTAssertEqual(quiet.intensity, 0.0, accuracy: 0.0001)
		XCTAssertEqual(quiet.sharpness, RumbleOutput.phoneBaseSharpness, accuracy: 0.0001)

		// Disabled -> zero
		let off = RumbleOutput.computePhoneHapticParameters(left: 255, right: 255, intensity: 1.0, enabled: false)
		XCTAssertEqual(off.intensity, 0.0, accuracy: 0.0001)
		XCTAssertEqual(off.sharpness, RumbleOutput.phoneBaseSharpness, accuracy: 0.0001)
	}

	func testShortcutTrackerTriggersOnceOnNewChordAndSuppressesShoulder() {
		var tracker = ControllerInput.ControllerShortcutTracker()

		// Select held first, then R1 pressed -> triggers toggleFrameGen once and suppresses R1
		let holdSelect = tracker.update(enabled: true, select: true, start: false, l1: false, r1: false)
		XCTAssertTrue(holdSelect.triggered.isEmpty)
		XCTAssertFalse(holdSelect.suppressR1)

		let triggerR1 = tracker.update(enabled: true, select: true, start: false, l1: false, r1: true)
		XCTAssertEqual(triggerR1.triggered, [.toggleFrameGen])
		XCTAssertTrue(triggerR1.suppressR1)
		XCTAssertFalse(triggerR1.suppressL1)

		// Repeating while held must not re-trigger and keeps suppressing R1
		let heldAgain = tracker.update(enabled: true, select: true, start: false, l1: false, r1: true)
		XCTAssertTrue(heldAgain.triggered.isEmpty)
		XCTAssertTrue(heldAgain.suppressR1)

		// Releasing R1 clears suppression and re-arms
		let releasedR1 = tracker.update(enabled: true, select: true, start: false, l1: false, r1: false)
		XCTAssertTrue(releasedR1.triggered.isEmpty)
		XCTAssertFalse(releasedR1.suppressR1)

		let retriggerR1 = tracker.update(enabled: true, select: true, start: false, l1: false, r1: true)
		XCTAssertEqual(retriggerR1.triggered, [.toggleFrameGen])
	}

	func testShortcutTrackerKeepsSuppressionIfSelectReleasedBeforeShoulder() {
		var tracker = ControllerInput.ControllerShortcutTracker()

		let triggerL1 = tracker.update(enabled: true, select: true, start: false, l1: true, r1: false)
		XCTAssertEqual(triggerL1.triggered, [.cycleHUD])
		XCTAssertTrue(triggerL1.suppressL1)

		// Select released while L1 is still held -> L1 remains suppressed until L1 is released
		let releaseSelect = tracker.update(enabled: true, select: false, start: false, l1: true, r1: false)
		XCTAssertTrue(releaseSelect.triggered.isEmpty)
		XCTAssertTrue(releaseSelect.suppressL1)

		let releaseL1 = tracker.update(enabled: true, select: false, start: false, l1: false, r1: false)
		XCTAssertFalse(releaseL1.suppressL1)
	}

	func testShortcutTrackerDoesNotMisfireWhenShoulderHeldBeforeSelectOrWithStartOrDisabled() {
		var tracker = ControllerInput.ControllerShortcutTracker()

		// Holding R1/L1 in-game before tapping Select (touchpad) must NOT trigger or suppress R1/L1
		_ = tracker.update(enabled: true, select: false, start: false, l1: true, r1: true)
		let tapSelect = tracker.update(enabled: true, select: true, start: false, l1: true, r1: true)
		XCTAssertTrue(tapSelect.triggered.isEmpty)
		XCTAssertFalse(tapSelect.suppressL1)
		XCTAssertFalse(tapSelect.suppressR1)

		// Reset and test Select + Start + R1 doesn't trigger shortcut
		tracker.reset()
		let withStart = tracker.update(enabled: true, select: true, start: true, l1: false, r1: true)
		XCTAssertTrue(withStart.triggered.isEmpty)
		XCTAssertFalse(withStart.suppressR1)

		// Disabled skips everything
		tracker.reset()
		let disabled = tracker.update(enabled: false, select: true, start: false, l1: true, r1: true)
		XCTAssertTrue(disabled.triggered.isEmpty)
		XCTAssertFalse(disabled.suppressL1)
		XCTAssertFalse(disabled.suppressR1)
	}

	func testDualSenseTouchSanitizerGuardsSpoofedRestingState() {
		var sanitizer = ControllerInput.DualSenseTouchSanitizer()

		// Real DualSense resting at (0,0) allows genuine touches and hardware clicks
		sanitizer.configureInitialState(tp0: (0, 0), tp1: (0, 0), touchpadButtonPressed: false)
		XCTAssertFalse(sanitizer.isTouching(slot: 0, x: 0, y: 0, selectIsTouchpad: false))
		XCTAssertTrue(sanitizer.isTouching(slot: 0, x: -0.25, y: 0.4, selectIsTouchpad: false))
		XCTAssertTrue(sanitizer.sanitizeHardwareTouchpadButton(rawPressed: true, selectIsTouchpad: false))

		// Spoofed DualSense (like GameSir-G8) resting at non-zero (-1, 1) with stuck touchpadButton
		sanitizer.configureInitialState(tp0: (-1, 1), tp1: (-1, 1), touchpadButtonPressed: true)
		XCTAssertFalse(sanitizer.isTouching(slot: 0, x: -1, y: 1, selectIsTouchpad: false))
		XCTAssertFalse(sanitizer.isTouching(slot: 1, x: -1, y: 1, selectIsTouchpad: false))
		XCTAssertFalse(sanitizer.sanitizeHardwareTouchpadButton(rawPressed: true, selectIsTouchpad: false))
		// Once released, genuine hardware clicks work again (when selectIsTouchpad is false)
		XCTAssertFalse(sanitizer.sanitizeHardwareTouchpadButton(rawPressed: false, selectIsTouchpad: false))
		XCTAssertTrue(sanitizer.sanitizeHardwareTouchpadButton(rawPressed: true, selectIsTouchpad: false))

		// selectIsTouchpad == true ignores both spoofed axes and hardware touchpad button
		sanitizer.configureInitialState(tp0: (0, 0), tp1: (0, 0), touchpadButtonPressed: false)
		XCTAssertFalse(sanitizer.isTouching(slot: 0, x: 0.5, y: 0.5, selectIsTouchpad: true))
		XCTAssertFalse(sanitizer.sanitizeHardwareTouchpadButton(rawPressed: true, selectIsTouchpad: true))
	}

	func testVirtualTouchpadStateMachineShortPulseAndHold() {
		var vm = ControllerInput.VirtualTouchpadStateMachine()

		// 1. Ultra-short pulse (pressed at t=0, released at t=0.005) completes full touch -> 90ms click -> touch up
		let down = vm.setPhysicalPressed(true, now: 0.0)
		XCTAssertTrue(down.touchDown)
		XCTAssertFalse(down.isClickActive)
		XCTAssertEqual(down.nextTimerDelay ?? -1, 0.02, accuracy: 0.0001)

		let earlyRelease = vm.setPhysicalPressed(false, now: 0.005)
		XCTAssertFalse(earlyRelease.touchUp)
		XCTAssertFalse(earlyRelease.clickChanged)
		XCTAssertEqual(earlyRelease.nextTimerDelay ?? -1, 0.015, accuracy: 0.0001)

		let leadTick = vm.tick(now: 0.020)
		XCTAssertTrue(leadTick.clickChanged)
		XCTAssertTrue(leadTick.isClickActive)
		XCTAssertEqual(leadTick.nextTimerDelay ?? -1, 0.09, accuracy: 0.0001)

		let clickUpTick = vm.tick(now: 0.110)
		XCTAssertTrue(clickUpTick.clickChanged)
		XCTAssertFalse(clickUpTick.isClickActive)
		XCTAssertFalse(clickUpTick.touchUp)
		XCTAssertEqual(clickUpTick.nextTimerDelay ?? -1, 0.02, accuracy: 0.0001)

		let tailTick = vm.tick(now: 0.130)
		XCTAssertTrue(tailTick.touchUp)
		XCTAssertNil(tailTick.nextTimerDelay)
		XCTAssertEqual(vm.phase, .idle)

		// 2. Normal tap released mid-click (t=0.050) extends remaining hold to 0.060s
		_ = vm.setPhysicalPressed(true, now: 1.000)
		_ = vm.tick(now: 1.020)
		let midRelease = vm.setPhysicalPressed(false, now: 1.050)
		XCTAssertTrue(midRelease.isClickActive)
		XCTAssertFalse(midRelease.clickChanged)
		XCTAssertEqual(midRelease.nextTimerDelay ?? -1, 0.060, accuracy: 0.0001)
		_ = vm.tick(now: 1.110)
		let endTail = vm.tick(now: 1.130)
		XCTAssertTrue(endTail.touchUp)

		// 3. Long hold (t=2.000 to t=3.200) holds continuously and releases immediately on release
		_ = vm.setPhysicalPressed(true, now: 2.000)
		let longLead = vm.tick(now: 2.020)
		XCTAssertNil(longLead.nextTimerDelay)
		XCTAssertTrue(vm.isClickActive)
		let longRelease = vm.setPhysicalPressed(false, now: 3.200)
		XCTAssertTrue(longRelease.clickChanged)
		XCTAssertFalse(longRelease.isClickActive)
		XCTAssertEqual(longRelease.nextTimerDelay ?? -1, 0.02, accuracy: 0.0001)
		_ = vm.tick(now: 3.220)

		// 4. Cancel pending before click (for Select+Start / Select+R1 chords) & reset
		_ = vm.setPhysicalPressed(true, now: 4.000)
		let cancelled = vm.cancelIfPendingBeforeClick()
		XCTAssertTrue(cancelled.touchUp)
		XCTAssertFalse(vm.isClickActive)
		XCTAssertEqual(vm.phase, .idle)

		_ = vm.setPhysicalPressed(true, now: 5.000)
		_ = vm.tick(now: 5.020)
		let resetResult = vm.reset()
		XCTAssertTrue(resetResult.clickChanged)
		XCTAssertFalse(resetResult.isClickActive)
		XCTAssertTrue(resetResult.touchUp)
		XCTAssertEqual(vm.phase, .idle)
	}
}
