import SwiftUI

/// Compact translucent side drawer for live in-stream tuning without hiding the game.
struct QuickTuningDrawer: View {
	@Binding var settings: StreamSettings
	let phone: PhoneStatus
	let onOpenFullMenu: () -> Void
	let onDisconnect: () -> Void
	let onClose: () -> Void

	var body: some View {
		ZStack(alignment: .trailing) {
			Color.black.opacity(0.001)
				.ignoresSafeArea()
				.onTapGesture(perform: onClose)

			VStack(spacing: 0) {
				header
				Divider().overlay(.white.opacity(0.14))
				ScrollView {
					VStack(alignment: .leading, spacing: 14) {
						enhancerCard
						displayCard
						colorCard
						footerCard
					}
					.padding(14)
				}
			}
			.frame(width: 320)
			.frame(maxHeight: .infinity)
			.background(.ultraThinMaterial)
			.background(Color.black.opacity(0.45))
			.overlay(alignment: .leading) {
				Rectangle()
					.fill(.white.opacity(0.14))
					.frame(width: 0.5)
			}
			.ignoresSafeArea(edges: [.vertical, .trailing])
		}
		.preferredColorScheme(.dark)
	}

	private var header: some View {
		HStack(spacing: 10) {
			Text("Quick Tuning")
				.font(.headline)
				.foregroundStyle(.white)
			Spacer()
			Button("Menu", action: onOpenFullMenu)
				.font(.subheadline.weight(.medium))
				.buttonStyle(.bordered)
				.controlSize(.small)
			Button(action: onClose) {
				Image(systemName: "xmark.circle.fill")
					.font(.title3)
					.foregroundStyle(.secondary)
			}
			.buttonStyle(.plain)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 12)
	}

	private var enhancerCard: some View {
		drawerCard("Frame Gen & Upscaling") {
			VStack(alignment: .leading, spacing: 10) {
				HStack {
					Text("Frame Gen")
						.font(.subheadline)
					Spacer()
					Picker("Frame Gen", selection: $settings.frameGenMode) {
						Text("Off").tag(FrameGenMode.off)
						Text("2x").tag(FrameGenMode.x2)
					}
					.pickerStyle(.segmented)
					.frame(width: 120)
				}

				HStack {
					Text("Upscaling")
						.font(.subheadline)
					Spacer()
					Picker("Upscaling", selection: $settings.upscalingMode) {
						ForEach(UpscalingMode.allCases) { mode in
							Text(mode.label).tag(mode)
						}
					}
					.pickerStyle(.menu)
					.labelsHidden()
				}
				.onChange(of: settings.upscalingMode) { _, new in
					settings.sharpUpscaling = new != .off
				}

				if settings.upscalingMode == .vtSuperRes {
					HStack {
						Text("ML Scale")
							.font(.subheadline)
						Spacer()
						Picker("ML Scale", selection: $settings.vtScaleFactor) {
							Text("1.5x").tag(1.5)
							Text("2.0x").tag(2.0)
						}
						.pickerStyle(.segmented)
						.frame(width: 120)
					}
				}

				if settings.frameGenMode == .x2 && settings.fps >= 60 {
					Toggle("Skip duplicates (30 fps)", isOn: $settings.deduplicateFrames)
						.font(.subheadline)
				}
			}
		}
	}

	private var displayCard: some View {
		drawerCard("Display") {
			VStack(alignment: .leading, spacing: 10) {
				sliderRow(
					title: "Zoom",
					valueText: formattedZoom(settings.zoomLevel),
					value: $settings.zoomLevel,
					range: 0.0...1.0,
					step: 0.05
				)
				.onChange(of: settings.zoomLevel) { _, new in
					settings.displayMode = new >= 0.5 ? .zoom : .fit
				}

				HStack(spacing: 8) {
					Button("Fit") { settings.zoomLevel = 0.0 }
						.buttonStyle(.bordered)
						.controlSize(.mini)
						.frame(maxWidth: .infinity)
					Button("50%") { settings.zoomLevel = 0.5 }
						.buttonStyle(.bordered)
						.controlSize(.mini)
						.frame(maxWidth: .infinity)
					Button("Fill") { settings.zoomLevel = 1.0 }
						.buttonStyle(.bordered)
						.controlSize(.mini)
						.frame(maxWidth: .infinity)
				}

				Toggle("Stats overlay", isOn: $settings.showStats)
					.font(.subheadline)
			}
		}
	}

	private var colorCard: some View {
		drawerCard("Color & Sharpening") {
			VStack(alignment: .leading, spacing: 10) {
				sliderRow(
					title: "Brightness",
					valueText: formattedBrightness(settings.colorAdjustments.brightness),
					value: $settings.colorAdjustments.brightness,
					range: -0.30...0.30,
					step: 0.02
				)
				sliderRow(
					title: "Contrast",
					valueText: "\(Int((settings.colorAdjustments.contrast * 100).rounded()))%",
					value: $settings.colorAdjustments.contrast,
					range: 0.50...1.50,
					step: 0.05
				)
				sliderRow(
					title: "Saturation",
					valueText: "\(Int((settings.colorAdjustments.saturation * 100).rounded()))%",
					value: $settings.colorAdjustments.saturation,
					range: 0.00...2.00,
					step: 0.05
				)
				sliderRow(
					title: "Gamma",
					valueText: String(format: "%.2f", settings.colorAdjustments.gamma),
					value: $settings.colorAdjustments.gamma,
					range: 0.70...1.50,
					step: 0.05
				)
				sliderRow(
					title: "Sharpness (CAS)",
					valueText: "\(Int((settings.colorAdjustments.sharpness * 100).rounded()))%",
					value: $settings.colorAdjustments.sharpness,
					range: 0.00...1.00,
					step: 0.05
				)

				HStack(spacing: 8) {
					Button {
						settings.colorAdjustments = .vividOLED
					} label: {
						Label("Vivid OLED", systemImage: "sun.max.fill")
							.frame(maxWidth: .infinity)
					}
					.buttonStyle(.bordered)
					.controlSize(.small)

					Button("Reset", role: .destructive) {
						settings.colorAdjustments = .neutral
					}
					.buttonStyle(.bordered)
					.controlSize(.small)
					.disabled(settings.colorAdjustments.isNeutral)
				}
			}
		}
	}

	private var footerCard: some View {
		drawerCard("Phone & Session") {
			VStack(alignment: .leading, spacing: 10) {
				HStack {
					Label(phone.batteryText, systemImage: phone.batterySymbol)
						.font(.caption)
						.foregroundStyle(.secondary)
					Spacer()
					Label(phone.thermalText, systemImage: "thermometer.medium")
						.font(.caption)
						.foregroundStyle(phone.isHot ? .orange : .secondary)
				}

				HStack(spacing: 8) {
					Button("Full Menu", action: onOpenFullMenu)
						.buttonStyle(.bordered)
						.controlSize(.small)
						.frame(maxWidth: .infinity)

					Button("Disconnect", role: .destructive, action: onDisconnect)
						.buttonStyle(.bordered)
						.controlSize(.small)
						.frame(maxWidth: .infinity)
				}
			}
		}
	}

	private func drawerCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title.uppercased())
				.font(.caption2.weight(.semibold))
				.foregroundStyle(.secondary)
			content()
		}
		.padding(12)
		.background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
	}

	private func sliderRow(
		title: String,
		valueText: String,
		value: Binding<Double>,
		range: ClosedRange<Double>,
		step: Double
	) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack {
				Text(title)
					.font(.subheadline)
				Spacer()
				Text(valueText)
					.font(.caption.monospacedDigit())
					.foregroundStyle(.secondary)
			}
			Slider(value: value, in: range, step: step)
		}
	}

	private func formattedBrightness(_ value: Double) -> String {
		let pct = Int((value * 100).rounded())
		return pct > 0 ? "+\(pct)%" : "\(pct)%"
	}

	private func formattedZoom(_ value: Double) -> String {
		let pct = Int((value * 100).rounded())
		if pct == 0 { return "Fit" }
		if pct == 100 { return "Fill" }
		return "\(pct)%"
	}
}
