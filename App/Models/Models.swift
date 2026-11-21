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
	case vtSuperRes

	var id: String { rawValue }
	var label: String {
		switch self {
		case .off: "Off (Bilinear)"
		case .bicubic: "Catmull-Rom (Shader)"
		case .metalFX: "MetalFX Spatial (GPU)"
		case .vtSuperRes: "Apple ML Super Res (iOS 26+)"
		}
	}
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

struct StreamSettings: Codable, Equatable {
	var resolution: StreamResolution = .p1080
	var fps: Int = 60
	var bitrateMbps: Int = 30
	var codec: VideoCodecChoice = .h265
	var hdr: Bool = false
	var displayMode: DisplayMode = .fit
	var sharpUpscaling: Bool = true
	var upscalingMode: UpscalingMode = .metalFX
	var frameGenMode: FrameGenMode = .off
	/// Skip near-identical duplicate frames when running 2x frame gen on a 60 fps stream (for 30 fps games like GTA 6)
	var deduplicateFrames: Bool = true
	/// Preferred spatial scale factor for Apple ML Super Resolution (1.5x or 2.0x, matched dynamically to device support)
	var vtScaleFactor: Double = 1.5
	var showStats: Bool = false
	/// Phone gyro for controllers without motion sensors (e.g. GameSir G8+)
	var phoneMotion: Bool = true
	var rumble: Bool = true
	/// Use the controller's Select/View button as the DualSense touchpad click
	var selectIsTouchpad: Bool = false
	/// Keep a ProMotion screen at 120 Hz while streaming, so frames wait less for the next refresh
	var highRefreshDisplay: Bool = true

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
		phoneMotion = try c.decodeIfPresent(Bool.self, forKey: .phoneMotion) ?? d.phoneMotion
		rumble = try c.decodeIfPresent(Bool.self, forKey: .rumble) ?? d.rumble
		selectIsTouchpad = try c.decodeIfPresent(Bool.self, forKey: .selectIsTouchpad) ?? d.selectIsTouchpad
		highRefreshDisplay = try c.decodeIfPresent(Bool.self, forKey: .highRefreshDisplay) ?? d.highRefreshDisplay
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
		showStats = true
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
