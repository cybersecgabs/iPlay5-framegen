import GameController
import SwiftUI

struct StreamView: View {
	let console: Console

	@Environment(SettingsStore.self) private var settingsStore
	@Environment(\.dismiss) private var dismiss
	@Environment(\.scenePhase) private var scenePhase
	@State private var session: StreamSession?
	@State private var showMenu = false
	@State private var showMenuButton = false
	@State private var hideMenuButton: Task<Void, Never>?
	@State private var folded = false
	/// Unfolded but the window is portrait: we wait (or pause) and ask the user
	/// to turn the phone. Once a stream is landscape, AppDelegate locks it there.
	@State private var portrait = false
	@State private var windowSize: CGSize = .zero
	/// No controller connected yet; we ask before connecting (there are no on-screen controls)
	@State private var needsController = !Self.hasController
	@State private var showSettingsHint = false
	@State private var pin = ""

	private static var hasController: Bool {
		GCController.controllers().contains { $0.extendedGamepad != nil }
	}

	var body: some View {
		GeometryReader { geo in
			content
				.onAppear { updateFolded(geo.size) }
				.onChange(of: geo.size) { _, size in updateFolded(size) }
		}
		.statusBarHidden()
		.persistentSystemOverlays(.hidden)
		.defersSystemGestures(on: .all)
		// The session itself starts from updateFolded, once we know we're on a usable screen
		.onAppear { AppDelegate.setStreaming(true) }
		.onDisappear(perform: stop)
		.onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
			// A flip between the two landscapes keeps the same window size, so pick
			// up iOS's new orientation (for controller motion) once it has rotated
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { update() }
		}
		.onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
			guard needsController, Self.hasController else { return }
			needsController = false
			update()
		}
		.onChange(of: session?.state == .streaming) { _, streaming in
			if streaming { flashSettingsHint() }
		}
		.onChange(of: scenePhase) { _, phase in
			session?.setPaused(phase != .active || folded || portrait)
		}
		.sheet(isPresented: $showMenu) { menu }
	}

	private var content: some View {
		ZStack {
			Color.black.ignoresSafeArea()

			if let session, let renderer = session.renderer {
				MetalStreamView(
					renderer: renderer,
					onTouch: { [weak session] in session?.screenTouch($0) },
					onTap: { [weak session] in session?.screenTap(slot: $0) },
					onCornerTap: revealMenuButton
				)
				.ignoresSafeArea()
			}

			if let session {
				overlay(for: session)
			}

			if showSettingsHint && !showMenuButton {
				settingsHint
					.transition(.opacity)
			}

			if showMenuButton {
				menuButton
					.transition(.opacity)
			}


			if needsController && session == nil {
				controllerOverlay
			} else if folded {
				pausedOverlay
			} else if portrait {
				rotateOverlay
			}
		}
	}

	/// Used to map controller motion to the screen
	private var interfaceOrientation: UIInterfaceOrientation? {
		(UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation
	}

	// MARK: - Lifecycle

	private func startSession() {
		let session = StreamSession(console: console, settings: settingsStore.settings)
		if let orientation = interfaceOrientation {
			session.input.interfaceOrientation = orientation
		}
		session.input.onMenuCombo = { showMenu = true }
		self.session = session
		session.start()
	}

	private func stop() {
		session?.stop()
		session = nil
		AppDelegate.setStreaming(false)
	}

	/// On a foldable, streaming only happens on the inner screen: we wait for the
	/// unfold before connecting, and pause if it's folded mid-session.
	/// Normal iPhones are never "folded".
	private func updateFolded(_ size: CGSize) {
		guard size.width > 0, size.height > 0 else { return }
		AppDelegate.windowSizeChanged(size)
		windowSize = size
		update()
	}

	private func update() {
		let size = windowSize
		guard size.width > 0, size.height > 0 else { return }
		let isFolded = DeviceLayout.isFolded(size)
		folded = isFolded
		portrait = !isFolded && size.height > size.width
		let canPlay = !isFolded && !portrait
		guard session != nil else {
			if canPlay && !needsController { startSession() }
			return
		}
		session?.setPaused(!canPlay || scenePhase != .active)
		if let orientation = interfaceOrientation {
			session?.input.interfaceOrientation = orientation
		}
	}

	// MARK: - Menu button (top-right hot corner)

	private func revealMenuButton() {
		withAnimation(.easeOut(duration: 0.2)) { showMenuButton = true }
		hideMenuButton?.cancel()
		hideMenuButton = Task { @MainActor in
			try? await Task.sleep(for: .seconds(3))
			guard !Task.isCancelled else { return }
			withAnimation(.easeIn(duration: 0.6)) { showMenuButton = false }
		}
	}

	/// Each time a stream starts, point at the hidden settings corner, then fade out
	private func flashSettingsHint() {
		withAnimation(.easeOut(duration: 0.3)) { showSettingsHint = true }
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(4))
			withAnimation(.easeIn(duration: 0.8)) { showSettingsHint = false }
		}
	}

	private var settingsHint: some View {
		HStack(spacing: 10) {
			Text("Tap this corner for settings")
				.font(.subheadline.weight(.semibold))
				.padding(.horizontal, 14)
				.padding(.vertical, 8)
				.background(.black.opacity(0.65), in: Capsule())
			Image(systemName: "arrow.right")
				.font(.title3.weight(.bold))
			Image(systemName: "gearshape.fill")
				.font(.title2)
				.frame(width: 52, height: 52)
				.background(.black.opacity(0.55), in: Circle())
		}
		.foregroundStyle(.white)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
		.padding(.top, 14)
		.padding(.trailing, 20)
		.ignoresSafeArea()
		.allowsHitTesting(false)
	}

	private var menuButton: some View {
		Button {
			hideMenuButton?.cancel()
			showMenuButton = false
			showMenu = true
		} label: {
			Image(systemName: "gearshape.fill")
				.font(.title2)
				.foregroundStyle(.white)
				.frame(width: 52, height: 52)
				.background(.black.opacity(0.55), in: Circle())
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
		.padding(.top, 14)
		.padding(.trailing, 20)
		.ignoresSafeArea()
	}

	// MARK: - Overlays

	@ViewBuilder
	private func overlay(for session: StreamSession) -> some View {
		switch session.state {
		case .idle, .connecting:
			VStack(spacing: 12) {
				ProgressView().controlSize(.large)
				Text("Connecting to \(console.name)…").foregroundStyle(.secondary)
				Button("Cancel") { dismiss() }.buttonStyle(.bordered)
			}
		case .streaming:
			if session.settings.showStats {
				StatsOverlay(stats: session.stats, settings: session.settings)
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
					.padding(12)
					.allowsHitTesting(false)
			}
		case .needsPIN(let incorrect):
			VStack(spacing: 12) {
				Text(incorrect ? "Incorrect PIN, try again" : "Enter your Remote Play PIN").font(.headline)
				SecureField("PIN", text: $pin)
					.keyboardType(.numberPad)
					.textFieldStyle(.roundedBorder)
					.frame(width: 200)
				HStack {
					Button("Cancel") { dismiss() }.buttonStyle(.bordered)
					Button("OK") {
						session.submitPIN(pin)
						pin = ""
					}
					.buttonStyle(.borderedProminent)
				}
			}
			.padding(24)
			.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
		case .ended(let error):
			VStack(spacing: 12) {
				if let error {
					Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
					Text(error).multilineTextAlignment(.center).frame(maxWidth: 420)
				} else {
					Text("Disconnected")
				}
				HStack {
					Button("Close") { dismiss() }.buttonStyle(.bordered)
					Button("Reconnect") { session.start() }.buttonStyle(.borderedProminent)
				}
			}
			.padding(24)
			.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
		}
	}

	private var controllerOverlay: some View {
		ZStack {
			Color.black.opacity(0.85).ignoresSafeArea()
			VStack(spacing: 8) {
				Image(systemName: "gamecontroller.fill").font(.largeTitle)
				Text("Connect a controller").font(.title2.bold())
				Text("iPlay5 has no on-screen controls. Turn on your controller or pair it in Settings › Bluetooth, and \(console.name) connects as soon as it's found.")
					.multilineTextAlignment(.center)
					.foregroundStyle(.secondary)
					.frame(maxWidth: 420)
				HStack {
					Button("Cancel") { dismiss() }.buttonStyle(.bordered)
					Button("Connect anyway") {
						needsController = false
						update()
					}
					.buttonStyle(.bordered)
				}
				.padding(.top, 8)
			}
			.padding(24)
		}
	}

	private var rotateOverlay: some View {
		ZStack {
			Color.black.opacity(0.85).ignoresSafeArea()
			VStack(spacing: 8) {
				Image(systemName: "rotate.right").font(.largeTitle)
				Text("Turn your phone sideways").font(.title2.bold())
				Text(session == nil ? "\(console.name) connects once you're in landscape." : "Turn to landscape to keep playing.")
					.foregroundStyle(.secondary)
				Button(session == nil ? "Cancel" : "Disconnect") { dismiss() }.buttonStyle(.bordered).padding(.top, 8)
			}
		}
	}

	private var pausedOverlay: some View {
		ZStack {
			Color.black.opacity(0.85).ignoresSafeArea()
			VStack(spacing: 8) {
				Image(systemName: "rectangle.portrait.and.arrow.forward").font(.largeTitle)
				if session == nil {
					Text("Open your phone to play").font(.title2.bold())
					Text("\(console.name) connects as soon as you unfold.").foregroundStyle(.secondary)
					Button("Cancel") { dismiss() }.buttonStyle(.bordered).padding(.top, 8)
				} else {
					Text("Paused").font(.title2.bold())
					Text("Unfold to keep playing.").foregroundStyle(.secondary)
					Button("Disconnect") { dismiss() }.buttonStyle(.bordered).padding(.top, 8)
				}
			}
		}
	}

	private var menu: some View {
		@Bindable var store = settingsStore
		return NavigationStack {
			Form {
				Section {
					Button("Resume") { showMenu = false }
					Button("Put console in rest mode") {
						session?.putConsoleToSleep()
						showMenu = false
					}
					Button("Disconnect", role: .destructive) {
						showMenu = false
						dismiss()
					}
				}
				StreamSettingsForm(settings: $store.settings)
			}
			.navigationTitle(console.name)
			.navigationBarTitleDisplayMode(.inline)
		}
		.onChange(of: store.settings) { _, new in session?.apply(new) }
	}
}

private struct StatsOverlay: View {
	let stats: StreamStats
	let settings: StreamSettings

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text("\(stats.width)×\(stats.height) @ \(Int(stats.fps)) fps")
			Text(String(format: "%.1f Mbps (asked %d)", stats.bitrateMbps, settings.bitrateMbps))
			Text("\(settings.effectiveCodec == .h265 ? "HEVC" : "H.264")\(settings.hdr ? " HDR" : "")  decode \(String(format: "%.1f", stats.decodeMs)) ms")
			Text("lost \(stats.lostFrames)  failed \(stats.failedFrames)")
			if let controller = stats.controller { Text(controller) }
		}
		.font(.caption2.monospaced())
		.padding(8)
		.background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
		.foregroundStyle(.white)
	}
}

/// Hosts the CAMetalLayer-backed view in SwiftUI.
private struct MetalStreamView: UIViewRepresentable {
	let renderer: MetalRenderer
	let onTouch: (ControllerInput.TouchEvent) -> Void
	let onTap: (Int) -> Void
	let onCornerTap: () -> Void

	func makeUIView(context: Context) -> StreamMetalView {
		let view = StreamMetalView(renderer: renderer)
		updateUIView(view, context: context)
		return view
	}

	func updateUIView(_ uiView: StreamMetalView, context: Context) {
		uiView.onTouch = onTouch
		uiView.onTap = onTap
		uiView.onCornerTap = onCornerTap
	}
}
