import ChiakiKit
import UIKit
import XCTest
@testable import iPlay5

final class VirtualControlsTests: XCTestCase {
	private final class DummyToken {}

	func testMergePhysicalAndVirtualPadState() {
		var physical = CKPadState()
		physical.buttons = UInt32(CK_BUTTON_CROSS.rawValue)
		physical.l2 = 40
		physical.r2 = 180
		physical.left_x = 1234
		physical.left_y = -567
		physical.right_x = 8000
		physical.right_y = -4000

		// Neutral virtual state preserves physical controller state and adds extraButtons
		let neutralMerged = VirtualPadState.merge(
			physical: physical,
			virtual: VirtualPadState(),
			extraButtons: UInt32(CK_BUTTON_PS.rawValue)
		)
		XCTAssertEqual(neutralMerged.buttons, UInt32(CK_BUTTON_CROSS.rawValue | CK_BUTTON_PS.rawValue))
		XCTAssertEqual(neutralMerged.l2, 40)
		XCTAssertEqual(neutralMerged.r2, 180)
		XCTAssertEqual(neutralMerged.left_x, 1234)
		XCTAssertEqual(neutralMerged.left_y, -567)
		XCTAssertEqual(neutralMerged.right_x, 8000)
		XCTAssertEqual(neutralMerged.right_y, -4000)

		// Active virtual sticks (including occupied center 0,0) override physical axes
		let virtual = VirtualPadState(
			buttons: UInt32(CK_BUTTON_L1.rawValue),
			l2: 255,
			r2: 100,
			leftStick: SIMD2(0, 0),
			rightStick: SIMD2(-15000, 12000)
		)
		let merged = VirtualPadState.merge(physical: physical, virtual: virtual, extraButtons: 0)
		XCTAssertEqual(merged.buttons, UInt32(CK_BUTTON_CROSS.rawValue | CK_BUTTON_L1.rawValue))
		XCTAssertEqual(merged.l2, 255)
		XCTAssertEqual(merged.r2, 180)
		XCTAssertEqual(merged.left_x, 0)
		XCTAssertEqual(merged.left_y, 0)
		XCTAssertEqual(merged.right_x, -15000)
		XCTAssertEqual(merged.right_y, 12000)
	}

	func testVirtualControlsStyleClampsOpacityAndScale() {
		XCTAssertEqual(ControlsSize.small.scale, 0.85, accuracy: 0.0001)
		XCTAssertEqual(ControlsSize.medium.scale, 1.0, accuracy: 0.0001)
		XCTAssertEqual(ControlsSize.large.scale, 1.15, accuracy: 0.0001)

		var settings = StreamSettings()
		settings.controlsSize = .large
		settings.controlsOpacity = 0.05
		settings.fixedSticks = true

		let style = VirtualControlsStyle(settings)
		XCTAssertEqual(style.scale, 1.15, accuracy: 0.0001)
		XCTAssertEqual(style.opacity, 0.2, accuracy: 0.0001)
		XCTAssertTrue(style.fixedSticks)
	}

	func testOverlayButtonAndFloatingStickRouting() {
		let bounds = CGRect(x: 0, y: 0, width: 852, height: 393)
		let overlay = VirtualControlsOverlay(frame: bounds)
		overlay.setLayout(in: CGRect(x: 59, y: 0, width: 734, height: 372), systemButtonY: 346)

		// Floating stick is rejected when allowsStick == false (e.g. upper touchpad half)
		let rejected = DummyToken()
		let upperResult = overlay.begin(ObjectIdentifier(rejected), at: CGPoint(x: 300, y: 80), allowsStick: false)
		XCTAssertFalse(upperResult.handled)
		XCTAssertNil(upperResult.state)

		// Floating left stick in lower-left free space activates and publishes axis on drag
		let stickTouch = DummyToken()
		let stickID = ObjectIdentifier(stickTouch)
		let stickOrigin = CGPoint(x: 300, y: 260)
		let stickBegin = overlay.begin(stickID, at: stickOrigin, allowsStick: true)
		XCTAssertTrue(stickBegin.handled)
		XCTAssertEqual(stickBegin.state?.leftStick, SIMD2<Int16>(0, 0))

		let stickMoved = overlay.move(stickID, to: CGPoint(x: stickOrigin.x + 42, y: stickOrigin.y))
		XCTAssertEqual(stickMoved?.leftStick?.x, 32767)
		XCTAssertEqual(stickMoved?.leftStick?.y, 0)

		// Press R2 shoulder trigger while stick is held
		let r2Touch = DummyToken()
		let r2ID = ObjectIdentifier(r2Touch)
		let r2Center = CGPoint(x: 734 + 59 - 10 - 58 + 32, y: 372 - 71 - 54 - 86)
		let r2Begin = overlay.begin(r2ID, at: r2Center, allowsStick: false)
		XCTAssertTrue(r2Begin.handled)
		XCTAssertEqual(r2Begin.state?.r2, 255)
		XCTAssertEqual(r2Begin.state?.leftStick?.x, 32767)

		let stickEnded = overlay.end(stickID)
		XCTAssertNil(stickEnded?.leftStick)
		XCTAssertEqual(stickEnded?.r2, 255)

		let r2Ended = overlay.end(r2ID)
		XCTAssertEqual(r2Ended, VirtualPadState())
	}

	func testOverlayFixedSticksIgnoreFloatingSpaceAndEngageNearCenter() {
		let bounds = CGRect(x: 0, y: 0, width: 852, height: 393)
		let overlay = VirtualControlsOverlay(frame: bounds)
		var style = VirtualControlsStyle()
		style.fixedSticks = true
		overlay.style = style
		let safeArea = CGRect(x: 59, y: 0, width: 734, height: 372)
		overlay.setLayout(in: safeArea, systemButtonY: 346)

		// Empty area outside fixed stick reach does not start a stick even when allowsStick == true
		let empty = DummyToken()
		let miss = overlay.begin(ObjectIdentifier(empty), at: CGPoint(x: 426, y: 120), allowsStick: true)
		XCTAssertFalse(miss.handled)

		// Touch near left fixed stick center (x + 150, row - 20) engages left stick
		let leftCenter = CGPoint(x: safeArea.minX + 10 + 58 + 150, y: safeArea.maxY - 71 - 54 - 20)
		let fixedTouch = DummyToken()
		let hit = overlay.begin(ObjectIdentifier(fixedTouch), at: CGPoint(x: leftCenter.x + 20, y: leftCenter.y), allowsStick: true)
		XCTAssertTrue(hit.handled)
		XCTAssertNotNil(hit.state?.leftStick)
		XCTAssertGreaterThan(hit.state?.leftStick?.x ?? 0, 0)

		overlay.reset()
	}
}
