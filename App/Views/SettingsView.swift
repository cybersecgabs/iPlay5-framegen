import SwiftUI

/// Stream settings, shared by the main settings sheet and the in-stream menu.
struct StreamSettingsForm: View {
	@Binding var settings: StreamSettings

	var body: some View {
		Section {
			Button {
				settings.applyGTA6Preset()
			} label: {
				Label("GTA 6 (30→60 fps + MetalFX)", systemImage: "sparkles.tv")
			}
			Button {
				settings.applyProMotion120Preset()
			} label: {
				Label("ProMotion (60→120 fps + MetalFX)", systemImage: "gauge.with.dots.needle.100percent")
			}
			Button {
				settings.applyLowLatencyPreset()
			} label: {
				Label("Low Latency (60 fps + MetalFX)", systemImage: "bolt.fill")
			}
		} header: {
			Text("Presets")
		} footer: {
			Text("GTA 6 preset streams 1080p30 HEVC at 40 Mbps and enables 2x VideoToolbox Frame Gen to output smooth 60 fps with MetalFX Spatial upscaling.")
		}

		Section {
			Picker("Frame Generation", selection: $settings.frameGenMode) {
				ForEach(FrameGenMode.allCases) { Text($0.label).tag($0) }
			}
			if settings.frameGenMode == .x2 && settings.fps >= 60 {
				Toggle("Skip duplicate frames (30 fps games)", isOn: $settings.deduplicateFrames)
			}
			Picker("Upscaling", selection: $settings.upscalingMode) {
				ForEach(UpscalingMode.allCases) { Text($0.label).tag($0) }
			}
			.onChange(of: settings.upscalingMode) { _, new in
				settings.sharpUpscaling = new != .off
			}
			if settings.upscalingMode == .vtSuperRes {
				Picker("ML Scale Factor", selection: $settings.vtScaleFactor) {
					Text("1.5x").tag(1.5)
					Text("2.0x").tag(2.0)
				}
			}
		} header: {
			Text("Frame Gen & Upscaling")
		} footer: {
			Text("Applies live without reconnecting. \(EnhancerCapabilities.current.shortStatus)")
		}

		Section {
			Picker("Resolution", selection: $settings.resolution) {
				ForEach(StreamResolution.allCases) { Text($0.label).tag($0) }
			}
			Picker("Frame rate", selection: $settings.fps) {
				Text("60 fps").tag(60)
				Text("30 fps").tag(30)
			}
			VStack(alignment: .leading) {
				HStack {
					Text("Bitrate")
					Spacer()
					Text("\(settings.bitrateMbps) Mbps").foregroundStyle(.secondary).monospacedDigit()
				}
				Slider(value: Binding(get: { Double(settings.bitrateMbps) }, set: { settings.bitrateMbps = Int($0) }), in: 5...100, step: 5)
			}
			Picker("Codec", selection: $settings.codec) {
				ForEach(VideoCodecChoice.allCases) { Text($0.label).tag($0) }
			}
			.disabled(settings.hdr)
			Toggle("HDR", isOn: $settings.hdr)
		} header: {
			Text("Video")
		} footer: {
			Text("PS5 Remote Play tops out at 1080p60. The PS5 may cap the bitrate below what you ask for, so watch the stats overlay. HDR needs H.265 and HDR turned on in the PS5's video output settings. Changing these reconnects the stream.")
		}

		Section {
			Picker("Picture", selection: $settings.displayMode) {
				ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
			}
			if UIScreen.main.maximumFramesPerSecond > 60 {
				Toggle("120 Hz screen", isOn: $settings.highRefreshDisplay)
			}
			Toggle("Show stats overlay", isOn: $settings.showStats)
		} header: {
			Text("Display")
		} footer: {
			Text("Fit shows the whole picture, with black bars where the screen is a different shape to 16:9. Zoom fills the screen and crops the overflow. 120 Hz screen gets each frame on screen sooner, for a little more battery.")
		}

		Section {
			VStack(alignment: .leading) {
				HStack {
					Text("Brightness")
					Spacer()
					let pct = Int((settings.colorAdjustments.brightness * 100).rounded())
					Text(pct > 0 ? "+\(pct)%" : "\(pct)%").foregroundStyle(.secondary).monospacedDigit()
				}
				Slider(value: $settings.colorAdjustments.brightness, in: -0.30...0.30, step: 0.02)
			}
			VStack(alignment: .leading) {
				HStack {
					Text("Contrast")
					Spacer()
					Text("\(Int((settings.colorAdjustments.contrast * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
				}
				Slider(value: $settings.colorAdjustments.contrast, in: 0.50...1.50, step: 0.05)
			}
			VStack(alignment: .leading) {
				HStack {
					Text("Saturation")
					Spacer()
					Text("\(Int((settings.colorAdjustments.saturation * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
				}
				Slider(value: $settings.colorAdjustments.saturation, in: 0.00...2.00, step: 0.05)
			}
			VStack(alignment: .leading) {
				HStack {
					Text("Gamma")
					Spacer()
					Text(String(format: "%.2f", settings.colorAdjustments.gamma)).foregroundStyle(.secondary).monospacedDigit()
				}
				Slider(value: $settings.colorAdjustments.gamma, in: 0.70...1.50, step: 0.05)
			}
			Button {
				settings.colorAdjustments = .vividOLED
			} label: {
				Label("Vivid OLED (+10% contrast, +20% sat)", systemImage: "sun.max.fill")
			}
			Button("Reset colors", role: .destructive) {
				settings.colorAdjustments = .neutral
			}
			.disabled(settings.colorAdjustments.isNeutral)
		} header: {
			Text("Color")
		} footer: {
			Text("Adjusts picture colors live on the GPU without reconnecting. Gamma lifts shadows while keeping pure OLED blacks.")
		}

		Section {
			Toggle("Rumble", isOn: $settings.rumble)
			Toggle("Phone gyro for motion controls", isOn: $settings.phoneMotion)
			Toggle("Select button is touchpad click", isOn: $settings.selectIsTouchpad)
		} header: {
			Text("Controller")
		} footer: {
			Text("Phone gyro is used when the controller has no motion sensors, like a GameSir G8+. Hold Select + Start for a second during a stream to open the menu.")
		}
	}
}

struct SettingsView: View {
	@Environment(SettingsStore.self) private var store
	@Environment(ConsoleStore.self) private var consoles
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		@Bindable var store = store
		NavigationStack {
			Form {
				StreamSettingsForm(settings: $store.settings)

				Section {
					ShareLink(
						item: DiagnosticsReport(consoleNames: consoles.consoles.map(\.name), settings: store.settings),
						preview: SharePreview("iPlay5 diagnostics")
					) {
						Label("Share diagnostics", systemImage: "ladybug")
					}
					Link(destination: URL(string: "https://github.com/reefbarman/iPlay5")!) {
						Label("Upstream iPlay5 on GitHub", systemImage: "link")
					}
				} header: {
					Text("Help")
				} footer: {
					Text("The report has your phone model, screen details, settings and the app's logs since it was opened. IP addresses, keys, account IDs and console names are removed. Share it before closing the app, so the logs still cover the problem.")
				}
			}
			.navigationTitle("Settings")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
			}
		}
	}
}
