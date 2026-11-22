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
		XCTAssertFalse(gta6.showStats)

		// Applying GTA 6 preset preserves user's debug overlay and color preferences
		gta6.showStats = true
		gta6.colorAdjustments = .vividOLED
		gta6.applyGTA6Preset()
		XCTAssertTrue(gta6.showStats)
		XCTAssertEqual(gta6.colorAdjustments, .vividOLED)

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

	func testColorAdjustmentsNeutralClampingAndCodable() throws {
		XCTAssertTrue(ColorAdjustments.neutral.isNeutral)
		XCTAssertFalse(ColorAdjustments.neutral.hasColorGrading)
		XCTAssertFalse(ColorAdjustments.neutral.hasSharpness)
		XCTAssertFalse(ColorAdjustments.vividOLED.isNeutral)
		XCTAssertTrue(ColorAdjustments.vividOLED.hasColorGrading)
		XCTAssertTrue(ColorAdjustments.vividOLED.hasSharpness)

		let sharpOnly = ColorAdjustments(sharpness: 0.35)
		XCTAssertFalse(sharpOnly.hasColorGrading)
		XCTAssertTrue(sharpOnly.hasSharpness)
		XCTAssertFalse(sharpOnly.isNeutral)

		let tooHigh = ColorAdjustments(brightness: 1.0, contrast: 3.0, saturation: 5.0, gamma: 3.0, sharpness: 2.0).clamped
		XCTAssertEqual(tooHigh.brightness, 0.30, accuracy: 0.0001)
		XCTAssertEqual(tooHigh.contrast, 1.50, accuracy: 0.0001)
		XCTAssertEqual(tooHigh.saturation, 2.00, accuracy: 0.0001)
		XCTAssertEqual(tooHigh.gamma, 1.50, accuracy: 0.0001)
		XCTAssertEqual(tooHigh.sharpness, 1.00, accuracy: 0.0001)

		let tooLow = ColorAdjustments(brightness: -1.0, contrast: 0.1, saturation: -0.5, gamma: 0.2, sharpness: -0.5).clamped
		XCTAssertEqual(tooLow.brightness, -0.30, accuracy: 0.0001)
		XCTAssertEqual(tooLow.contrast, 0.50, accuracy: 0.0001)
		XCTAssertEqual(tooLow.saturation, 0.0, accuracy: 0.0001)
		XCTAssertEqual(tooLow.gamma, 0.70, accuracy: 0.0001)
		XCTAssertEqual(tooLow.sharpness, 0.0, accuracy: 0.0001)

		var settings = StreamSettings()
		settings.colorAdjustments = ColorAdjustments(brightness: 0.08, contrast: 1.15, saturation: 1.25, gamma: 1.05, sharpness: 0.40)
		settings.zoomLevel = 0.45
		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(StreamSettings.self, from: data)
		XCTAssertEqual(decoded.colorAdjustments, settings.colorAdjustments)
		XCTAssertEqual(decoded.zoomLevel, 0.45, accuracy: 0.0001)

		let legacyData = #"{"fps":60,"showStats":false}"#.data(using: .utf8)!
		let legacyDecoded = try JSONDecoder().decode(StreamSettings.self, from: legacyData)
		XCTAssertEqual(legacyDecoded.colorAdjustments, .neutral)
		XCTAssertTrue(legacyDecoded.colorAdjustments.isNeutral)
		XCTAssertEqual(legacyDecoded.zoomLevel, 0.0, accuracy: 0.0001)
	}

	func testLegacyZoomLevelMigration() throws {
		let legacyZoom = #"{"displayMode":"zoom"}"#.data(using: .utf8)!
		let decodedZoom = try JSONDecoder().decode(StreamSettings.self, from: legacyZoom)
		XCTAssertEqual(decodedZoom.zoomLevel, 1.0, accuracy: 0.0001)

		let legacyFit = #"{"displayMode":"fit"}"#.data(using: .utf8)!
		let decodedFit = try JSONDecoder().decode(StreamSettings.self, from: legacyFit)
		XCTAssertEqual(decodedFit.zoomLevel, 0.0, accuracy: 0.0001)

		let explicitZoom = #"{"displayMode":"fit","zoomLevel":0.45}"#.data(using: .utf8)!
		let decodedExplicit = try JSONDecoder().decode(StreamSettings.self, from: explicitZoom)
		XCTAssertEqual(decodedExplicit.zoomLevel, 0.45, accuracy: 0.0001)
	}

	func testRumbleSettingsCodableAndClamping() throws {
		var settings = StreamSettings()
		XCTAssertEqual(settings.rumbleTarget, .auto)
		XCTAssertEqual(settings.rumbleIntensity, 1.0, accuracy: 0.0001)

		settings.rumbleTarget = .phoneOnly
		settings.rumbleIntensity = 0.65
		let encoded = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(StreamSettings.self, from: encoded)
		XCTAssertEqual(decoded.rumbleTarget, .phoneOnly)
		XCTAssertEqual(decoded.rumbleIntensity, 0.65, accuracy: 0.0001)

		let tooHigh = try JSONDecoder().decode(StreamSettings.self, from: #"{"rumbleIntensity":2.5}"#.data(using: .utf8)!)
		XCTAssertEqual(tooHigh.rumbleIntensity, 1.0, accuracy: 0.0001)

		let tooLow = try JSONDecoder().decode(StreamSettings.self, from: #"{"rumbleIntensity":-0.5}"#.data(using: .utf8)!)
		XCTAssertEqual(tooLow.rumbleIntensity, 0.0, accuracy: 0.0001)

		let legacy = try JSONDecoder().decode(StreamSettings.self, from: #"{"rumble":false}"#.data(using: .utf8)!)
		XCTAssertFalse(legacy.rumble)
		XCTAssertEqual(legacy.rumbleTarget, .auto)
		XCTAssertEqual(legacy.rumbleIntensity, 1.0, accuracy: 0.0001)
	}

	func testStatsOverlayModeCycleMigrationAndShortcuts() throws {
		XCTAssertEqual(StatsOverlayMode.off.next(), .mini)
		XCTAssertEqual(StatsOverlayMode.mini.next(), .full)
		XCTAssertEqual(StatsOverlayMode.full.next(), .off)

		var settings = StreamSettings()
		XCTAssertEqual(settings.statsOverlayMode, .off)
		XCTAssertFalse(settings.showStats)
		XCTAssertTrue(settings.controllerShortcuts)

		settings.statsOverlayMode = .mini
		settings.showStats = true
		settings.controllerShortcuts = false
		let encoded = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(StreamSettings.self, from: encoded)
		XCTAssertEqual(decoded.statsOverlayMode, .mini)
		XCTAssertTrue(decoded.showStats)
		XCTAssertFalse(decoded.controllerShortcuts)

		// Legacy migration from showStats boolean
		let legacyTrue = try JSONDecoder().decode(StreamSettings.self, from: #"{"showStats":true}"#.data(using: .utf8)!)
		XCTAssertEqual(legacyTrue.statsOverlayMode, .full)
		XCTAssertTrue(legacyTrue.showStats)
		XCTAssertTrue(legacyTrue.controllerShortcuts)

		let legacyFalse = try JSONDecoder().decode(StreamSettings.self, from: #"{"showStats":false}"#.data(using: .utf8)!)
		XCTAssertEqual(legacyFalse.statsOverlayMode, .off)
		XCTAssertFalse(legacyFalse.showStats)

		// Explicit statsOverlayMode syncs showStats
		let explicitMini = try JSONDecoder().decode(StreamSettings.self, from: #"{"showStats":false,"statsOverlayMode":"mini"}"#.data(using: .utf8)!)
		XCTAssertEqual(explicitMini.statsOverlayMode, .mini)
		XCTAssertTrue(explicitMini.showStats)

		// GTA 6 preset preserves Mini HUD choice
		var gta6 = StreamSettings()
		gta6.statsOverlayMode = .mini
		gta6.showStats = true
		gta6.applyGTA6Preset()
		XCTAssertEqual(gta6.statsOverlayMode, .mini)
		XCTAssertTrue(gta6.showStats)
	}
}
