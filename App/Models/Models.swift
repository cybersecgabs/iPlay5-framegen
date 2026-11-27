import CoreGraphics
import Foundation
import Observation

/// A PlayStation that has been registered (linked) with this phone.
struct Console: Codable, Identifiable, Hashable {
	var id = UUID()
	var name: String
	var host: String
	var ps5: Bool
	/// rp_regist_key: 16 bytes (ASCII hex, zero padded)
	var registKey: Data
	/// rp_key ("morning"): 16 bytes
	var rpKey: Data
	var mac: Data
}

@Observable
final class ConsoleStore {
	private(set) var consoles: [Console] = []

	@ObservationIgnored private let url: URL = {
		let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("consoles.json")
	}()

	init() {
		if let data = try? Data(contentsOf: url),
			let decoded = try? JSONDecoder().decode([Console].self, from: data)
		{
			consoles = decoded
		}
	}

	func add(_ console: Console) {
		// Re-registering the same console replaces the old keys
		consoles.removeAll { $0.mac == console.mac && !console.mac.isEmpty }
		consoles.append(console)
		save()
	}

	func update(_ console: Console) {
		guard let index = consoles.firstIndex(where: { $0.id == console.id }) else { return }
		consoles[index] = console
		save()
	}

	func remove(_ console: Console) {
		consoles.removeAll { $0.id == console.id }
		save()
	}

	private func save() {
		do {
			let data = try JSONEncoder().encode(consoles)
			try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		} catch {
			log.error("Saving consoles failed: \(error.localizedDescription, privacy: .public)")
		}
	}
}

// MARK: - Stream settings

enum StreamResolution: Int, Codable, CaseIterable, Identifiable {
	case p720 = 720
	case p1080 = 1080

	var id: Int { rawValue }
	var label: String { "\(rawValue)p" }
	var size: (width: UInt32, height: UInt32) {
		switch self {
		case .p720: (1280, 720)
		case .p1080: (1920, 1080)
		}
	}
}

enum VideoCodecChoice: String, Codable, CaseIterable, Identifiable {
	case h265
	case h264

	var id: String { rawValue }
	var label: String { self == .h265 ? "H.265 (HEVC)" : "H.264" }
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable {
	/// Whole picture visible, black bars where the screen isn't 16:9
	case fit
	/// Fill the screen, cropping whatever overflows
	case zoom

	var id: String { rawValue }
	var label: String { self == .fit ? "Fit" : "Zoom to fill" }
}

enum UpscalingMode: String, Codable, CaseIterable, Identifiable {
	case off
	case bicubic
	case metalFX
	case metalFX4K
	case vtSuperRes

	var id: String { rawValue }
	var label: String {
		switch self {
		case .off: "Off (Bilinear)"
		case .bicubic: "Catmull-Rom (Shader)"
		case .metalFX: "MetalFX Spatial (GPU)"
		case .metalFX4K: "MetalFX 4K (Supersample)"
		case .vtSuperRes: "Apple ML Super Res (iOS 26+)"
		}
	}
	var usesMetalFX: Bool { self == .metalFX || self == .metalFX4K }
}

enum FrameGenMode: String, Codable, CaseIterable, Identifiable {
	case off
	case x2

	var id: String { rawValue }
	var label: String {
		switch self {
		case .off: "Off"
		case .x2: "2x (30→60 / 60→120)"
		}
	}
}

enum RumbleTarget: String, Codable, CaseIterable, Identifiable {
	/// Use controller motors if available; otherwise fall back to the iPhone Taptic Engine.
	case auto
	/// Only use the controller's built-in rumble motors.
	case controllerOnly
	/// Always route rumble to the iPhone Taptic Engine.
	case phoneOnly

	var id: String { rawValue }
	var label: String {
		switch self {
		case .auto: "Auto (Controller / iPhone)"
		case .controllerOnly: "Controller only"
		case .phoneOnly: "iPhone Taptic Engine"
		}
	}
	var shortLabel: String {
		switch self {
		case .auto: "Auto"
		case .controllerOnly: "Controller"
		case .phoneOnly: "iPhone"
		}
	}
}

enum StatsOverlayMode: String, Codable, CaseIterable, Identifiable {
	case off
	case mini
	case full

	var id: String { rawValue }
	var label: String {
		switch self {
		case .off: "Off"
		case .mini: "Mini (1 line)"
		case .full: "Full (Debug)"
		}
	}
	var shortLabel: String {
		switch self {
		case .off: "Off"
		case .mini: "Mini"
		case .full: "Full"
		}
	}
	func next() -> StatsOverlayMode {
		switch self {
		case .off: .mini
		case .mini: .full
		case .full: .off
		}
	}
}

/// When on-screen virtual controls are shown over the stream
enum VirtualControlsMode: String, Codable, CaseIterable, Identifiable {
	case auto
	case always
	case never

	var id: Self { self }

	var label: String {
		switch self {
		case .auto: "Auto"
		case .always: "Always show"
		case .never: "Never show"
		}
	}

	var shortLabel: String {
		switch self {
		case .auto: "Auto"
		case .always: "On"
		case .never: "Off"
		}
	}
}

/// Relative scale of the on-screen virtual controls
enum ControlsSize: String, Codable, CaseIterable, Identifiable {
	case small
	case medium
	case large

	var id: Self { self }

	var label: String {
		switch self {
		case .small: "Small"
		case .medium: "Medium"
		case .large: "Large"
		}
	}

	var scale: CGFloat {
		switch self {
		case .small: 0.85
		case .medium: 1.0
		case .large: 1.15
		}
	}
}

struct ColorAdjustments: Codable, Equatable {
	/// Additive brightness offset (-0.30 ... +0.30), 0.0 = neutral
	var brightness: Double = 0.0
	/// Contrast multiplier (0.50 ... 1.50), 1.0 = neutral
	var contrast: Double = 1.0
	/// Saturation multiplier (0.00 ... 2.00), 1.0 = neutral
	var saturation: Double = 1.0
	/// Midtone gamma multiplier (0.70 ... 1.50), 1.0 = neutral (preserves pure OLED blacks)
	var gamma: Double = 1.0
	/// Contrast Adaptive Sharpening intensity (0.00 ... 1.00), 0.0 = off
	var sharpness: Double = 0.0

	static let neutral = ColorAdjustments()
	static let vividOLED = ColorAdjustments(brightness: 0.0, contrast: 1.10, saturation: 1.20, gamma: 1.0, sharpness: 0.25)

	init(brightness: Double = 0.0, contrast: Double = 1.0, saturation: Double = 1.0, gamma: Double = 1.0, sharpness: Double = 0.0) {
		self.brightness = brightness
		self.contrast = contrast
		self.saturation = saturation
		self.gamma = gamma
		self.sharpness = sharpness
	}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = ColorAdjustments.neutral
		brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? d.brightness
		contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? d.contrast
		saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? d.saturation
		gamma = try c.decodeIfPresent(Double.self, forKey: .gamma) ?? d.gamma
		sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? d.sharpness
	}

	var hasColorGrading: Bool {
		abs(brightness) >= 0.001
			|| abs(contrast - 1.0) >= 0.001
			|| abs(saturation - 1.0) >= 0.001
			|| abs(gamma - 1.0) >= 0.001
	}

	var hasSharpness: Bool {
		sharpness >= 0.001
	}

	var isNeutral: Bool {
		!hasColorGrading && !hasSharpness
	}

	var clamped: ColorAdjustments {
		ColorAdjustments(
			brightness: min(max(brightness, -0.30), 0.30),
			contrast: min(max(contrast, 0.50), 1.50),
			saturation: min(max(saturation, 0.0), 2.00),
			gamma: min(max(gamma, 0.70), 1.50),
			sharpness: min(max(sharpness, 0.0), 1.00)
		)
	}
}

struct StreamSettings: Codable, Equatable {
	var resolution: StreamResolution = .p1080
	var fps: Int = 60
	var bitrateMbps: Int = 30
	var codec: VideoCodecChoice = .h265
	var hdr: Bool = false
	var displayMode: DisplayMode = .fit
	/// Continuous zoom between Fit (0.0) and Zoom to fill (1.0)
	var zoomLevel: Double = 0.0
	var sharpUpscaling: Bool = true
	var upscalingMode: UpscalingMode = .metalFX
	var frameGenMode: FrameGenMode = .off
	/// Skip near-identical duplicate frames when running 2x frame gen on a 60 fps stream (for 30 fps games like GTA 6)
	var deduplicateFrames: Bool = true
	/// Preferred spatial scale factor for Apple ML Super Resolution (1.5x or 2.0x, matched dynamically to device support)
	var vtScaleFactor: Double = 1.5
	var showStats: Bool = false
	var statsOverlayMode: StatsOverlayMode = .off
	/// Controller quick shortcuts (Select + R1 toggles Frame Gen, Select + L1 cycles Stats HUD)
	var controllerShortcuts: Bool = true
	/// Live GPU picture adjustments (brightness, contrast, saturation, gamma)
	var colorAdjustments: ColorAdjustments = .neutral
	/// Phone gyro for controllers without motion sensors (e.g. GameSir G8+)
	var phoneMotion: Bool = true
	var rumble: Bool = true
	/// Where rumble is sent (Auto falls back to iPhone Taptic Engine when controller has no motors)
	var rumbleTarget: RumbleTarget = .auto
	/// Rumble strength multiplier (0.0 ... 1.0)
	var rumbleIntensity: Double = 1.0
	/// Use the controller's Select/View button as the DualSense touchpad click
	var selectIsTouchpad: Bool = false
	/// When on-screen virtual controls are shown over the stream (auto hides when a controller is paired)
	var virtualControls: VirtualControlsMode = .auto
	/// Size of the on-screen virtual controls
	var controlsSize: ControlsSize = .medium
	/// 0.2...1, multiplies the virtual controls' own transparency
	var controlsOpacity: Double = 1.0
	/// Sticks stay put in their own spots instead of starting wherever a thumb lands
	var fixedSticks: Bool = false
	/// Keep a ProMotion screen at 120 Hz while streaming, so frames wait less for the next refresh
	var highRefreshDisplay: Bool = true
	/// Optional: ride out network hitches (adaptive reorder wait 16-40 ms, decode through lost
	/// frames while waiting for IDR, and adaptive 1-2 frame jitter buffer when Frame Gen is off).
	var networkSmoothing: Bool = false
	/// Experimental: offer the PS5 the newer Takion v20 stream protocol. Off by default;
	/// the console picks, staying on v12 if declined.
	var takionV20: Bool = false

	/// HDR needs HEVC
	var effectiveCodec: VideoCodecChoice { hdr ? .h265 : codec }

	init() {}

	/// Missing keys keep their defaults, so adding a setting doesn't reset the others
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let d = StreamSettings()
		resolution = try c.decodeIfPresent(StreamResolution.self, forKey: .resolution) ?? d.resolution
		fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
		bitrateMbps = try c.decodeIfPresent(Int.self, forKey: .bitrateMbps) ?? d.bitrateMbps
		codec = try c.decodeIfPresent(VideoCodecChoice.self, forKey: .codec) ?? d.codec
		hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? d.hdr
		displayMode = try c.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? d.displayMode
		if let decodedZoom = try c.decodeIfPresent(Double.self, forKey: .zoomLevel) {
			zoomLevel = min(max(decodedZoom, 0.0), 1.0)
		} else {
			zoomLevel = displayMode == .zoom ? 1.0 : 0.0
		}
		sharpUpscaling = try c.decodeIfPresent(Bool.self, forKey: .sharpUpscaling) ?? d.sharpUpscaling
		if let decodedUpscaling = try c.decodeIfPresent(UpscalingMode.self, forKey: .upscalingMode) {
			upscalingMode = decodedUpscaling
		} else {
			upscalingMode = sharpUpscaling ? d.upscalingMode : .off
		}
		frameGenMode = try c.decodeIfPresent(FrameGenMode.self, forKey: .frameGenMode) ?? d.frameGenMode
		deduplicateFrames = try c.decodeIfPresent(Bool.self, forKey: .deduplicateFrames) ?? d.deduplicateFrames
		vtScaleFactor = try c.decodeIfPresent(Double.self, forKey: .vtScaleFactor) ?? d.vtScaleFactor
		showStats = try c.decodeIfPresent(Bool.self, forKey: .showStats) ?? d.showStats
		if let decodedStatsMode = try c.decodeIfPresent(StatsOverlayMode.self, forKey: .statsOverlayMode) {
			statsOverlayMode = decodedStatsMode
			showStats = decodedStatsMode != .off
		} else {
			statsOverlayMode = showStats ? .full : .off
		}
		controllerShortcuts = try c.decodeIfPresent(Bool.self, forKey: .controllerShortcuts) ?? d.controllerShortcuts
		colorAdjustments = (try c.decodeIfPresent(ColorAdjustments.self, forKey: .colorAdjustments))?.clamped ?? d.colorAdjustments
		phoneMotion = try c.decodeIfPresent(Bool.self, forKey: .phoneMotion) ?? d.phoneMotion
		rumble = try c.decodeIfPresent(Bool.self, forKey: .rumble) ?? d.rumble
		rumbleTarget = try c.decodeIfPresent(RumbleTarget.self, forKey: .rumbleTarget) ?? d.rumbleTarget
		if let decodedIntensity = try c.decodeIfPresent(Double.self, forKey: .rumbleIntensity) {
			rumbleIntensity = min(max(decodedIntensity, 0.0), 1.0)
		} else {
			rumbleIntensity = d.rumbleIntensity
		}
		selectIsTouchpad = try c.decodeIfPresent(Bool.self, forKey: .selectIsTouchpad) ?? d.selectIsTouchpad
		virtualControls = (try? c.decodeIfPresent(VirtualControlsMode.self, forKey: .virtualControls)) ?? d.virtualControls
		controlsSize = (try? c.decodeIfPresent(ControlsSize.self, forKey: .controlsSize)) ?? d.controlsSize
		controlsOpacity = min(1.0, max(0.2, try c.decodeIfPresent(Double.self, forKey: .controlsOpacity) ?? d.controlsOpacity))
		fixedSticks = try c.decodeIfPresent(Bool.self, forKey: .fixedSticks) ?? d.fixedSticks
		highRefreshDisplay = try c.decodeIfPresent(Bool.self, forKey: .highRefreshDisplay) ?? d.highRefreshDisplay
		networkSmoothing = try c.decodeIfPresent(Bool.self, forKey: .networkSmoothing) ?? d.networkSmoothing
		takionV20 = try c.decodeIfPresent(Bool.self, forKey: .takionV20) ?? d.takionV20
	}

	mutating func applyGTA6Preset() {
		resolution = .p1080
		fps = 30
		bitrateMbps = 40
		codec = .h265
		frameGenMode = .x2
		upscalingMode = .metalFX
		sharpUpscaling = true
		deduplicateFrames = true
		highRefreshDisplay = true
	}

	mutating func applyProMotion120Preset() {
		resolution = .p1080
		fps = 60
		bitrateMbps = 40
		codec = .h265
		frameGenMode = .x2
		upscalingMode = .metalFX
		sharpUpscaling = true
		deduplicateFrames = true
		highRefreshDisplay = true
	}

	mutating func applyLowLatencyPreset() {
		resolution = .p1080
		fps = 60
		bitrateMbps = 30
		codec = .h265
		frameGenMode = .off
		upscalingMode = .metalFX
		sharpUpscaling = true
		highRefreshDisplay = true
	}
}

@Observable
final class SettingsStore {
	var settings: StreamSettings {
		didSet { save() }
	}

	@ObservationIgnored private let key = "streamSettings"

	init() {
		if let data = UserDefaults.standard.data(forKey: key),
			let decoded = try? JSONDecoder().decode(StreamSettings.self, from: data)
		{
			settings = decoded
		} else {
			settings = StreamSettings()
		}
	}

	private func save() {
		if let data = try? JSONEncoder().encode(settings) {
			UserDefaults.standard.set(data, forKey: key)
		}
	}
}
