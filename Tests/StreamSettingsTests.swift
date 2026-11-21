import XCTest
@testable import iPlay5

final class StreamSettingsTests: XCTestCase {
	func testCodableRoundTrip() throws {
		var settings = StreamSettings()
		settings.resolution = .p720
		settings.fps = 30
		settings.bitrateMbps = 45
		settings.hdr = true
		settings.upscalingMode = .vtSuperRes
		settings.frameGenMode = .x2
		settings.deduplicateFrames = false
		settings.vtScaleFactor = 2.0

		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(StreamSettings.self, from: data)
		XCTAssertEqual(decoded, settings)
	}

	func testLegacySettingsMigration() throws {
		let legacySharpFalse = """
		{
			"resolution": 1080,
			"fps": 60,
			"bitrateMbps": 30,
			"codec": "h265",
			"hdr": false,
			"displayMode": "fit",
			"sharpUpscaling": false
		}
		""".data(using: .utf8)!

		let decodedOff = try JSONDecoder().decode(StreamSettings.self, from: legacySharpFalse)
		XCTAssertEqual(decodedOff.upscalingMode, .off)
		XCTAssertEqual(decodedOff.frameGenMode, .off)
		XCTAssertTrue(decodedOff.deduplicateFrames)
		XCTAssertEqual(decodedOff.vtScaleFactor, 1.5, accuracy: 0.001)

		let legacySharpTrue = """
		{
			"sharpUpscaling": true
		}
		""".data(using: .utf8)!

		let decodedOn = try JSONDecoder().decode(StreamSettings.self, from: legacySharpTrue)
		XCTAssertEqual(decodedOn.upscalingMode, .metalFX)
	}

	func testPresets() {
		var gta6 = StreamSettings()
		gta6.applyGTA6Preset()
		XCTAssertEqual(gta6.resolution, .p1080)
		XCTAssertEqual(gta6.fps, 30)
		XCTAssertEqual(gta6.bitrateMbps, 40)
		XCTAssertEqual(gta6.codec, .h265)
		XCTAssertEqual(gta6.frameGenMode, .x2)
		XCTAssertEqual(gta6.upscalingMode, .metalFX)
		XCTAssertTrue(gta6.deduplicateFrames)
		XCTAssertTrue(gta6.highRefreshDisplay)
		XCTAssertTrue(gta6.showStats)

		var promo = StreamSettings()
		promo.applyProMotion120Preset()
		XCTAssertEqual(promo.fps, 60)
		XCTAssertEqual(promo.frameGenMode, .x2)
		XCTAssertEqual(promo.upscalingMode, .metalFX)

		var lowLat = StreamSettings()
		lowLat.applyGTA6Preset()
		lowLat.applyLowLatencyPreset()
		XCTAssertEqual(lowLat.fps, 60)
		XCTAssertEqual(lowLat.frameGenMode, .off)
		XCTAssertEqual(lowLat.upscalingMode, .metalFX)
	}
}
