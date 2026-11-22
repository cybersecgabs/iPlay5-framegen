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
}
