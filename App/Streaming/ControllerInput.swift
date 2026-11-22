import ChiakiKit
import CoreHaptics
import CoreMotion
import GameController
import UIKit

/// Maps the connected game controller to chiaki's DualSense state.
///
/// - Buttons are mapped by position (A/bottom = Cross, B/right = Circle, ...).
/// - The Home/PS button and the other system buttons are claimed from iOS so
///   pressing PS opens the PS5 menu instead of the iOS overlay.
/// - Motion comes from the controller if it has sensors (DualSense), otherwise
///   from the phone (e.g. clamped in a GameSir G8+).
final class ControllerInput {
	/// Called on the main thread with the latest pad state.
	var onPad: ((CKPadState) -> Void)?
	/// gyro rad/s, accel g, DualSense axes, monotonic microseconds.
	var onMotion: ((SIMD3<Float>, SIMD3<Float>, UInt32) -> Void)?
	var onTouch: ((TouchEvent) -> Void)?
	/// Select + Start held for a second
	var onMenuCombo: (() -> Void)?
	var onToggleFrameGen: (() -> Void)?
	var onCycleHUD: (() -> Void)?

	enum TouchEvent {
		case down(slot: Int, x: UInt16, y: UInt16)
		case move(slot: Int, x: UInt16, y: UInt16)
		case up(slot: Int)
	}

	struct TouchpadButtonResolution: Equatable {
		let touchpadButtonPressed: Bool
		let shareButtonPressed: Bool
		let needsVirtualCenterTouch: Bool
	}

	static let virtualTouchpadSlot = 20
	static let virtualTouchpadCenter: (x: UInt16, y: UInt16) = (960, 540)

	static func resolveSelectAndTouchpad(
		selectPressed: Bool,
		distinctSharePressed: Bool,
		hardwareTouchpadPressed: Bool,
		hasPhysicalTouchContact: Bool,
		selectIsTouchpad: Bool
	) -> TouchpadButtonResolution {
		let touchpadButtonPressed = hardwareTouchpadPressed || (selectIsTouchpad && selectPressed)
		let shareButtonPressed = distinctSharePressed || (!selectIsTouchpad && selectPressed)
		let needsVirtualCenterTouch = touchpadButtonPressed && !hasPhysicalTouchContact
		return TouchpadButtonResolution(
			touchpadButtonPressed: touchpadButtonPressed,
			shareButtonPressed: shareButtonPressed,
			needsVirtualCenterTouch: needsVirtualCenterTouch
		)
	}

	enum ControllerShortcut: Equatable {
		case toggleFrameGen
		case cycleHUD
	}

	struct ShortcutUpdate: Equatable {
		let triggered: [ControllerShortcut]
		let suppressL1: Bool
		let suppressR1: Bool
	}

	struct ControllerShortcutTracker {
		private var prevSelect = false
		private var prevL1 = false
		private var prevR1 = false
		private var l1Consumed = false
		private var r1Consumed = false

		mutating func reset() {
			prevSelect = false
			prevL1 = false
			prevR1 = false
			l1Consumed = false
			r1Consumed = false
		}

		mutating func update(enabled: Bool, select: Bool, start: Bool, l1: Bool, r1: Bool) -> ShortcutUpdate {
			defer {
				prevSelect = select
				prevL1 = l1
				prevR1 = r1
			}
			guard enabled else {
				l1Consumed = false
				r1Consumed = false
				return ShortcutUpdate(triggered: [], suppressL1: false, suppressR1: false)
			}
			if !l1 { l1Consumed = false }
			if !r1 { r1Consumed = false }

			var triggered: [ControllerShortcut] = []
			if select && !start {
				if r1 && !prevR1 && !r1Consumed {
					r1Consumed = true
					triggered.append(.toggleFrameGen)
				}
				if l1 && !prevL1 && !l1Consumed {
					l1Consumed = true
					triggered.append(.cycleHUD)
				}
			}
			return ShortcutUpdate(
				triggered: triggered,
				suppressL1: l1Consumed && l1,
				suppressR1: r1Consumed && r1
			)
		}
	}

	var selectIsTouchpad = false {
		didSet {
			if selectIsTouchpad != oldValue, let pad = controller?.extendedGamepad {
				padChanged(pad)
			}
		}
	}
	var phoneMotionEnabled = true
	var shortcutsEnabled = true

	private(set) var controllerName: String?
	private var controller: GCController?
	private let motionManager = CMMotionManager()
	private let motionQueue = OperationQueue()
	private var observers: [NSObjectProtocol] = []
	private var touchDown = [false, false]
	private var virtualTouchpadDown = false
	private var shortcutTracker = ControllerShortcutTracker()
	private var comboTimer: Timer?
	private var lastPad = CKPadState()

	let rumble = RumbleOutput()

	init() {
		motionQueue.maxConcurrentOperationCount = 1
		motionQueue.qualityOfService = .userInteractive
	}

	func start() {
		GCController.shouldMonitorBackgroundEvents = false
		observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
			self?.pickController()
		})
		observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
			self?.pickController()
		})
		pickController(force: true)
	}

	func stop() {
		observers.forEach(NotificationCenter.default.removeObserver)
		observers.removeAll()
		comboTimer?.invalidate()
		shortcutTracker.reset()
		motionManager.stopDeviceMotionUpdates()
		releaseAllTouches()
		if let controller {
			restoreSystemGestures(controller)
			controller.extendedGamepad?.valueChangedHandler = nil
			controller.physicalInputProfile.buttons[GCInputButtonShare]?.valueChangedHandler = nil
			controller.motion?.valueChangedHandler = nil
			controller.motion?.sensorsActive = false
		}
		controller = nil
		rumble.detach()
	}

	// MARK: - Controller selection

	private func pickController(force: Bool = false) {
		let candidates = GCController.controllers().filter { $0.extendedGamepad != nil }
		let next = GCController.current.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.first
		guard force || next !== controller else { return }

		releaseAllTouches()
		shortcutTracker.reset()
		if let controller {
			restoreSystemGestures(controller)
			controller.extendedGamepad?.valueChangedHandler = nil
			controller.physicalInputProfile.buttons[GCInputButtonShare]?.valueChangedHandler = nil
			controller.motion?.valueChangedHandler = nil
		}
		controller = next
		controllerName = next?.vendorName
		rumble.attach(next)
		guard let next, let pad = next.extendedGamepad else {
			startPhoneMotion()
			return
		}
		let profileKind: String
		let hasTouchpadBtn: Bool
		if let ds = pad as? GCDualSenseGamepad {
			profileKind = "DualSense"
			let tpBtn: GCControllerButtonInput? = ds.touchpadButton
			hasTouchpadBtn = tpBtn != nil
		} else if let ds4 = pad as? GCDualShockGamepad {
			profileKind = "DualShock 4"
			let tpBtn: GCControllerButtonInput? = ds4.touchpadButton
			hasTouchpadBtn = tpBtn != nil
		} else if pad is GCXboxGamepad {
			profileKind = "Xbox"
			hasTouchpadBtn = false
		} else {
			profileKind = "ExtendedGamepad"
			hasTouchpadBtn = false
		}
		let hasOptionsBtn = pad.buttonOptions != nil
		let hasShareBtn = pad.buttons[GCInputButtonShare] != nil
		log.notice("Using controller: \(next.vendorName ?? "?", privacy: .public) (\(next.productCategory, privacy: .public), profile=\(profileKind, privacy: .public), options=\(hasOptionsBtn), share=\(hasShareBtn), touchpadBtn=\(hasTouchpadBtn))")

		claimSystemGestures(next)
		pad.valueChangedHandler = { [weak self] pad, _ in self?.padChanged(pad) }
		if let shareBtn = pad.buttons[GCInputButtonShare], shareBtn !== pad.buttonOptions {
			shareBtn.valueChangedHandler = { [weak self, weak pad] _, _, _ in
				guard let self, let pad else { return }
				self.padChanged(pad)
			}
		}

		if let motion = next.motion, motion.hasRotationRate {
			motionManager.stopDeviceMotionUpdates()
			motion.sensorsActive = true
			motion.valueChangedHandler = { [weak self] motion in self?.controllerMotion(motion) }
		} else {
			startPhoneMotion()
		}
		padChanged(pad)
	}

	private func releaseAllTouches() {
		if virtualTouchpadDown {
			virtualTouchpadDown = false
			onTouch?(.up(slot: Self.virtualTouchpadSlot))
		}
		for slot in 0..<touchDown.count where touchDown[slot] {
			touchDown[slot] = false
			onTouch?(.up(slot: slot))
		}
	}

	private func claimSystemGestures(_ controller: GCController) {
		for button in controller.physicalInputProfile.buttons.values {
			button.preferredSystemGestureState = .disabled
		}
	}

	private func restoreSystemGestures(_ controller: GCController) {
		for button in controller.physicalInputProfile.buttons.values {
			button.preferredSystemGestureState = .enabled
		}
	}

	// MARK: - Buttons and sticks

	private func padChanged(_ pad: GCExtendedGamepad) {
		var b: UInt32 = 0
		func set(_ pressed: Bool, _ flag: CKButton) { if pressed { b |= flag.rawValue } }

		let l1Pressed = pad.leftShoulder.isPressed
		let r1Pressed = pad.rightShoulder.isPressed
		let startPressed = pad.buttonMenu.isPressed

		let optionsBtn = pad.buttonOptions
		let shareBtn = pad.buttons[GCInputButtonShare]
		let primarySelectBtn = optionsBtn ?? shareBtn
		let distinctShareBtn = (shareBtn !== primarySelectBtn) ? shareBtn : nil

		let selectPressed = primarySelectBtn?.isPressed ?? false
		let distinctSharePressed = distinctShareBtn?.isPressed ?? false

		let shortcutUpdate = shortcutTracker.update(
			enabled: shortcutsEnabled,
			select: selectPressed,
			start: startPressed,
			l1: l1Pressed,
			r1: r1Pressed
		)

		set(pad.buttonA.isPressed, CK_BUTTON_CROSS)
		set(pad.buttonB.isPressed, CK_BUTTON_MOON)
		set(pad.buttonX.isPressed, CK_BUTTON_BOX)
		set(pad.buttonY.isPressed, CK_BUTTON_PYRAMID)
		set(pad.dpad.left.isPressed, CK_BUTTON_DPAD_LEFT)
		set(pad.dpad.right.isPressed, CK_BUTTON_DPAD_RIGHT)
		set(pad.dpad.up.isPressed, CK_BUTTON_DPAD_UP)
		set(pad.dpad.down.isPressed, CK_BUTTON_DPAD_DOWN)
		set(l1Pressed && !shortcutUpdate.suppressL1, CK_BUTTON_L1)
		set(r1Pressed && !shortcutUpdate.suppressR1, CK_BUTTON_R1)
		set(pad.leftThumbstickButton?.isPressed ?? false, CK_BUTTON_L3)
		set(pad.rightThumbstickButton?.isPressed ?? false, CK_BUTTON_R3)
		set(startPressed, CK_BUTTON_OPTIONS)
		set(pad.buttonHome?.isPressed ?? false, CK_BUTTON_PS)

		var hardwareTouchpadPressed = false
		if let ds = pad as? GCDualSenseGamepad {
			let tpBtn: GCControllerButtonInput? = ds.touchpadButton
			hardwareTouchpadPressed = tpBtn?.isPressed ?? false
			dualSenseTouch(ds)
		} else if let ds4 = pad as? GCDualShockGamepad {
			let tpBtn: GCControllerButtonInput? = ds4.touchpadButton
			hardwareTouchpadPressed = tpBtn?.isPressed ?? false
		}

		let hasPhysicalTouchContact = touchDown[0] || touchDown[1]
		let resolved = Self.resolveSelectAndTouchpad(
			selectPressed: selectPressed,
			distinctSharePressed: distinctSharePressed,
			hardwareTouchpadPressed: hardwareTouchpadPressed,
			hasPhysicalTouchContact: hasPhysicalTouchContact,
			selectIsTouchpad: selectIsTouchpad
		)
		set(resolved.shareButtonPressed, CK_BUTTON_SHARE)
		set(resolved.touchpadButtonPressed, CK_BUTTON_TOUCHPAD)

		var state = CKPadState()
		state.buttons = b
		state.l2 = UInt8(clamping: Int((pad.leftTrigger.value * 255).rounded()))
		state.r2 = UInt8(clamping: Int((pad.rightTrigger.value * 255).rounded()))
		state.left_x = Self.axis(pad.leftThumbstick.xAxis.value)
		state.left_y = Self.axis(-pad.leftThumbstick.yAxis.value)
		state.right_x = Self.axis(pad.rightThumbstick.xAxis.value)
		state.right_y = Self.axis(-pad.rightThumbstick.yAxis.value)

		lastPad = state
		if resolved.needsVirtualCenterTouch && !virtualTouchpadDown {
			virtualTouchpadDown = true
			onTouch?(.down(slot: Self.virtualTouchpadSlot, x: Self.virtualTouchpadCenter.x, y: Self.virtualTouchpadCenter.y))
			onPad?(state)
		} else if !resolved.needsVirtualCenterTouch && virtualTouchpadDown {
			onPad?(state)
			virtualTouchpadDown = false
			onTouch?(.up(slot: Self.virtualTouchpadSlot))
		} else {
			onPad?(state)
		}
		updateMenuCombo(select: selectPressed, start: startPressed, l1: l1Pressed, r1: r1Pressed)
		for shortcut in shortcutUpdate.triggered {
			let action: (() -> Void)?
			switch shortcut {
			case .toggleFrameGen: action = onToggleFrameGen
			case .cycleHUD: action = onCycleHUD
			}
			guard let action else { continue }
			if Thread.isMainThread {
				action()
			} else {
				DispatchQueue.main.async(execute: action)
			}
		}
	}

	private static func axis(_ v: Float) -> Int16 {
		Int16(clamping: Int((v * 32767).rounded()))
	}

	private func updateMenuCombo(select: Bool, start: Bool, l1: Bool, r1: Bool) {
		if select && start && !l1 && !r1 {
			guard comboTimer == nil else { return }
			comboTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
				self?.comboTimer = nil
				self?.onMenuCombo?()
			}
		} else {
			comboTimer?.invalidate()
			comboTimer = nil
		}
	}

	// MARK: - DualSense touchpad

	private func dualSenseTouch(_ ds: GCDualSenseGamepad) {
		for (slot, pad) in [ds.touchpadPrimary, ds.touchpadSecondary].enumerated() {
			let x = pad.xAxis.value
			let y = pad.yAxis.value
			let touching = x != 0 || y != 0
			let px = UInt16(clamping: Int(((x + 1) / 2 * 1919).rounded()))
			let py = UInt16(clamping: Int(((1 - y) / 2 * 1079).rounded()))
			if touching && !touchDown[slot] {
				touchDown[slot] = true
				onTouch?(.down(slot: slot, x: px, y: py))
			} else if touching {
				onTouch?(.move(slot: slot, x: px, y: py))
			} else if touchDown[slot] {
				touchDown[slot] = false
				onTouch?(.up(slot: slot))
			}
		}
	}

	// MARK: - Motion

	private func controllerMotion(_ motion: GCMotion) {
		// GameController reports DualSense motion in its own frame; untested
		// against real games, so treat as a starting point.
		let r = motion.rotationRate
		let g = motion.gravity
		let u = motion.userAcceleration
		let gyro = SIMD3<Float>(Float(r.x), Float(r.y), Float(r.z))
		let accel = -SIMD3<Float>(Float(g.x + u.x), Float(g.y + u.y), Float(g.z + u.z))
		onMotion?(gyro, accel, Self.nowMicros())
	}

	private func startPhoneMotion() {
		guard phoneMotionEnabled, motionManager.isDeviceMotionAvailable else { return }
		guard !motionManager.isDeviceMotionActive else { return }
		motionManager.deviceMotionUpdateInterval = 1.0 / 100.0
		motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] data, _ in
			guard let self, let data else { return }
			self.phoneMotion(data)
		}
	}

	/// Interface orientation, cached on the main thread for the motion queue.
	var interfaceOrientation: UIInterfaceOrientation = .landscapeRight

	private func phoneMotion(_ m: CMDeviceMotion) {
		// Device axes: x right / y up in portrait, z out of the screen.
		// Map to the screen as held in landscape, which lines up with how a
		// DualSense's axes behave when the phone is upright in a clamp controller.
		let r = m.rotationRate
		let a = (x: m.gravity.x + m.userAcceleration.x, y: m.gravity.y + m.userAcceleration.y, z: m.gravity.z + m.userAcceleration.z)
		let gyro: SIMD3<Float>
		let accel: SIMD3<Float>
		switch interfaceOrientation {
		case .landscapeLeft:  // device top on the right
			gyro = SIMD3(Float(r.y), Float(-r.x), Float(r.z))
			accel = SIMD3(Float(a.y), Float(-a.x), Float(a.z))
		default:  // landscapeRight: device top on the left
			gyro = SIMD3(Float(-r.y), Float(r.x), Float(r.z))
			accel = SIMD3(Float(-a.y), Float(a.x), Float(a.z))
		}
		// CoreMotion reports gravity's direction; DualSense reports the reaction (+1 g up at rest)
		onMotion?(gyro, -accel, UInt32(truncatingIfNeeded: UInt64(m.timestamp * 1_000_000)))
	}

	private static func nowMicros() -> UInt32 {
		UInt32(truncatingIfNeeded: UInt64(CACurrentMediaTime() * 1_000_000))
	}

	// MARK: - Adaptive triggers

	/// Applies a PS5 trigger effect to a DualSense. Decodes the common effect
	/// types approximately; anything unrecognised turns the trigger off.
	func applyTriggerEffect(typeLeft: UInt8, left: [UInt8], typeRight: UInt8, right: [UInt8]) {
		guard let ds = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
		Self.apply(type: typeLeft, data: left, to: ds.leftTrigger)
		Self.apply(type: typeRight, data: right, to: ds.rightTrigger)
	}

	private static func apply(type: UInt8, data d: [UInt8], to trigger: GCDualSenseAdaptiveTrigger) {
		guard d.count >= 10 else { return }
		func zones() -> [Int] {
			let mask = Int(d[0]) | Int(d[1]) << 8
			return (0..<10).filter { mask & (1 << $0) != 0 }
		}
		func strengths() -> [Float] {
			let packed = UInt64(d[2]) | UInt64(d[3]) << 8 | UInt64(d[4]) << 16 | UInt64(d[5]) << 24
			return (0..<10).map { Float((packed >> (3 * UInt64($0))) & 0x7) }
		}
		switch type {
		case 0x21:  // feedback (per-zone resistance)
			let z = zones()
			guard let first = z.first else { return trigger.setModeOff() }
			let s = strengths()
			let avg = z.map { s[$0] + 1 }.reduce(0, +) / Float(z.count) / 8
			trigger.setModeFeedbackWithStartPosition(Float(first) / 9, resistiveStrength: avg)
		case 0x25:  // weapon (resistance that breaks at a point)
			let z = zones()
			guard z.count >= 2 else { return trigger.setModeOff() }
			trigger.setModeWeaponWithStartPosition(Float(z[0]) / 9, endPosition: Float(z[z.count - 1]) / 9, resistiveStrength: (Float(d[2]) + 1) / 8)
		case 0x26:  // vibration
			let z = zones()
			guard let first = z.first else { return trigger.setModeOff() }
			let s = strengths()
			let amp = z.map { s[$0] + 1 }.reduce(0, +) / Float(z.count) / 8
			trigger.setModeVibrationWithStartPosition(Float(first) / 9, amplitude: amp, frequency: Float(d[8]) / 255)
		case 0x01:  // legacy continuous resistance
			trigger.setModeFeedbackWithStartPosition(Float(d[0]) / 255, resistiveStrength: Float(d[1]) / 255)
		case 0x02:  // legacy section resistance
			trigger.setModeWeaponWithStartPosition(Float(d[0]) / 255, endPosition: Float(d[1]) / 255, resistiveStrength: 1)
		case 0x06:  // legacy vibration
			trigger.setModeVibrationWithStartPosition(Float(d[2]) / 255, amplitude: Float(d[1]) / 255, frequency: Float(d[0]) / 255)
		default:
			trigger.setModeOff()
		}
	}
}

/// Rumble through the controller's haptic motors, or fall back to the iPhone Taptic Engine.
///
/// Uses continuous CoreHaptics pattern players and updates dynamic intensity/sharpness
/// as PS5 rumble or DualSense haptic values arrive, which is cheaper than scheduling new patterns.
final class RumbleOutput {
	struct PhoneHapticParameters: Equatable {
		let intensity: Float
		let sharpness: Float
	}

	static let phoneBaseSharpness: Float = 0.5
	static let phoneNoiseFloor: Float = 0.02

	static func shouldUseControllerEngine(controllerHasHaptics: Bool, target: RumbleTarget) -> Bool {
		guard controllerHasHaptics else { return false }
		switch target {
		case .auto, .controllerOnly: return true
		case .phoneOnly: return false
		}
	}

	static func shouldUsePhoneEngine(controllerHasHaptics: Bool, target: RumbleTarget, deviceSupportsHaptics: Bool) -> Bool {
		guard deviceSupportsHaptics else { return false }
		switch target {
		case .auto: return !controllerHasHaptics
		case .controllerOnly: return false
		case .phoneOnly: return true
		}
	}

	static func computeMotorLevels(left: UInt8, right: UInt8, motorCount: Int, intensity: Float, enabled: Bool) -> [Float] {
		guard motorCount > 0 else { return [] }
		let scale = enabled ? min(max(intensity, 0), 1) : 0
		let l = min(max((Float(left) / 255) * scale, 0), 1)
		let r = min(max((Float(right) / 255) * scale, 0), 1)
		return motorCount >= 2 ? [l, r] : [max(l, r)]
	}

	static func computePhoneHapticParameters(left: UInt8, right: UInt8, intensity: Float, enabled: Bool) -> PhoneHapticParameters {
		let scale = enabled ? min(max(intensity, 0), 1) : 0
		guard scale > 0 else { return PhoneHapticParameters(intensity: 0, sharpness: phoneBaseSharpness) }
		let l = Float(left) / 255
		let r = Float(right) / 255
		let scaled = max(l, r) * scale
		guard scaled >= phoneNoiseFloor else {
			return PhoneHapticParameters(intensity: 0, sharpness: phoneBaseSharpness)
		}
		let total = l + r
		let highRatio = total > 0 ? (r / total) : 0.5
		let sharpness = 0.20 + highRatio * 0.65
		return PhoneHapticParameters(
			intensity: min(max(scaled, 0), 1),
			sharpness: min(max(sharpness, 0), 1)
		)
	}

	private let lock = NSLock()
	private var engines: [CHHapticEngine] = []
	private var players: [CHHapticAdvancedPatternPlayer] = []
	private var usingPhoneEngine = false
	private var isAttached = false
	private weak var attachedController: GCController?
	private var _enabled = true
	private var _intensity: Float = 1.0
	private var _target: RumbleTarget = .auto
	private var _paused = false
	private var needsRestart = false
	private var restartScheduled = false
	private var lastSentValues: [Float] = []
	private var lastSentSharpness: Float = -1

	var enabled: Bool {
		get {
			lock.lock()
			defer { lock.unlock() }
			return _enabled
		}
		set {
			let intensity: Float
			let target: RumbleTarget
			lock.lock()
			intensity = _intensity
			target = _target
			lock.unlock()
			configure(enabled: newValue, intensity: intensity, target: target)
		}
	}

	deinit {
		let oldPlayers: [CHHapticAdvancedPatternPlayer]
		let oldEngines: [CHHapticEngine]
		lock.lock()
		oldPlayers = players
		oldEngines = engines
		players = []
		engines = []
		isAttached = false
		attachedController = nil
		lock.unlock()
		Self.teardown(players: oldPlayers, engines: oldEngines)
	}

	func configure(enabled: Bool, intensity: Float, target: RumbleTarget) {
		let clampedIntensity = min(max(intensity, 0), 1)
		var playersToZero: [CHHapticAdvancedPatternPlayer] = []
		var oldPlayers: [CHHapticAdvancedPatternPlayer] = []
		var oldEngines: [CHHapticEngine] = []
		var rebuildController: GCController?
		var shouldRebuild = false

		lock.lock()
		let targetChanged = _target != target
		let enabledChanged = _enabled != enabled
		_enabled = enabled
		_intensity = clampedIntensity
		_target = target

		if !enabled {
			oldPlayers = players
			oldEngines = engines
			players = []
			engines = []
			usingPhoneEngine = false
			needsRestart = false
			restartScheduled = false
			lastSentValues = []
			lastSentSharpness = -1
		} else if clampedIntensity <= 0.001 {
			if !players.isEmpty {
				playersToZero = players
				lastSentValues = Array(repeating: 0, count: players.count)
				lastSentSharpness = Self.phoneBaseSharpness
			}
		} else if isAttached && (targetChanged || enabledChanged || engines.isEmpty) {
			oldPlayers = players
			oldEngines = engines
			players = []
			engines = []
			usingPhoneEngine = false
			needsRestart = false
			restartScheduled = false
			lastSentValues = []
			lastSentSharpness = -1
			rebuildController = attachedController
			shouldRebuild = !_paused
		}
		lock.unlock()

		Self.teardown(players: oldPlayers, engines: oldEngines)
		Self.zero(players: playersToZero)
		if shouldRebuild {
			rebuildEngines(for: rebuildController)
		}
	}

	func setPaused(_ paused: Bool) {
		var playersToZero: [CHHapticAdvancedPatternPlayer] = []
		var rebuildController: GCController?
		var shouldRebuild = false

		lock.lock()
		guard _paused != paused else {
			lock.unlock()
			return
		}
		_paused = paused
		if paused {
			if !players.isEmpty {
				playersToZero = players
				lastSentValues = Array(repeating: 0, count: players.count)
				lastSentSharpness = Self.phoneBaseSharpness
			}
		} else if isAttached && _enabled && _intensity > 0.001 && (needsRestart || engines.isEmpty) {
			needsRestart = false
			rebuildController = attachedController
			shouldRebuild = true
		}
		lock.unlock()

		Self.zero(players: playersToZero)
		if shouldRebuild {
			rebuildEngines(for: rebuildController)
		}
	}

	func attach(_ controller: GCController?) {
		var oldPlayers: [CHHapticAdvancedPatternPlayer] = []
		var oldEngines: [CHHapticEngine] = []
		var shouldBuild = false

		lock.lock()
		oldPlayers = players
		oldEngines = engines
		players = []
		engines = []
		usingPhoneEngine = false
		isAttached = true
		attachedController = controller
		needsRestart = false
		restartScheduled = false
		lastSentValues = []
		lastSentSharpness = -1
		shouldBuild = _enabled && !_paused && _intensity > 0.001
		lock.unlock()

		Self.teardown(players: oldPlayers, engines: oldEngines)
		if shouldBuild {
			rebuildEngines(for: controller)
		}
	}

	func detach() {
		var oldPlayers: [CHHapticAdvancedPatternPlayer] = []
		var oldEngines: [CHHapticEngine] = []

		lock.lock()
		isAttached = false
		attachedController = nil
		oldPlayers = players
		oldEngines = engines
		players = []
		engines = []
		usingPhoneEngine = false
		needsRestart = false
		restartScheduled = false
		lastSentValues = []
		lastSentSharpness = -1
		lock.unlock()

		Self.teardown(players: oldPlayers, engines: oldEngines)
	}

	/// left = low frequency (heavy) motor, right = high frequency (light) motor, 0...255.
	func set(left: UInt8, right: UInt8) {
		var activePlayers: [CHHapticAdvancedPatternPlayer] = []
		var phoneParams: PhoneHapticParameters?
		var motorValues: [Float]?
		var scheduleRestart = false

		lock.lock()
		guard _enabled, !_paused else {
			lock.unlock()
			return
		}
		if needsRestart {
			if (left > 0 || right > 0) && !restartScheduled && isAttached {
				restartScheduled = true
				scheduleRestart = true
			}
			lock.unlock()
			if scheduleRestart {
				DispatchQueue.main.async { [weak self] in
					self?.restartIfNeeded()
				}
			}
			return
		}
		guard !players.isEmpty else {
			lock.unlock()
			return
		}

		if usingPhoneEngine {
			let params = Self.computePhoneHapticParameters(left: left, right: right, intensity: _intensity, enabled: true)
			let sameIntensity = lastSentValues.count == 1
				&& ((params.intensity == 0 && lastSentValues[0] == 0)
					|| (params.intensity > 0 && lastSentValues[0] > 0 && abs(lastSentValues[0] - params.intensity) < 0.005))
			let sameSharpness = params.intensity == 0 || abs(lastSentSharpness - params.sharpness) < 0.02
			if sameIntensity && sameSharpness {
				lock.unlock()
				return
			}
			lastSentValues = [params.intensity]
			lastSentSharpness = params.sharpness
			activePlayers = players
			phoneParams = params
		} else {
			let values = Self.computeMotorLevels(left: left, right: right, motorCount: players.count, intensity: _intensity, enabled: true)
			let unchanged = lastSentValues.count == values.count && zip(lastSentValues, values).allSatisfy { prev, next in
				if next == 0 { return prev == 0 }
				if prev == 0 { return false }
				return abs(prev - next) < 0.005
			}
			if unchanged {
				lock.unlock()
				return
			}
			lastSentValues = values
			activePlayers = players
			motorValues = values
		}
		lock.unlock()

		if let phoneParams, let player = activePlayers.first {
			let sharpnessOffset = min(max(phoneParams.sharpness - Self.phoneBaseSharpness, -1), 1)
			try? player.sendParameters([
				CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: phoneParams.intensity, relativeTime: 0),
				CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpnessOffset, relativeTime: 0),
			], atTime: CHHapticTimeImmediate)
		} else if let motorValues {
			for (player, value) in zip(activePlayers, motorValues) {
				try? player.sendParameters([
					CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: value, relativeTime: 0),
				], atTime: CHHapticTimeImmediate)
			}
		}
	}

	private func rebuildEngines(for controller: GCController?) {
		let target: RumbleTarget
		lock.lock()
		target = _target
		guard isAttached, _enabled, !_paused, _intensity > 0.001, attachedController === controller else {
			lock.unlock()
			return
		}
		lock.unlock()

		let controllerHaptics = controller?.haptics
		let controllerHasHaptics = controllerHaptics != nil
		var newEngines: [CHHapticEngine] = []
		var newPlayers: [CHHapticAdvancedPatternPlayer] = []
		var isPhone = false

		if Self.shouldUseControllerEngine(controllerHasHaptics: controllerHasHaptics, target: target), let haptics = controllerHaptics {
			let localities: [GCHapticsLocality] =
				haptics.supportedLocalities.contains(.leftHandle) && haptics.supportedLocalities.contains(.rightHandle)
				? [.leftHandle, .rightHandle] : [.default]
			for locality in localities {
				guard let engine = haptics.createEngine(withLocality: locality) else { continue }
				if let player = startContinuousPlayer(on: engine, baseSharpness: locality == .rightHandle ? 0.8 : 0.3) {
					newEngines.append(engine)
					newPlayers.append(player)
				}
			}
		} else if Self.shouldUsePhoneEngine(
			controllerHasHaptics: controllerHasHaptics,
			target: target,
			deviceSupportsHaptics: CHHapticEngine.capabilitiesForHardware().supportsHaptics
		) {
			do {
				let engine = try CHHapticEngine()
				engine.playsHapticsOnly = true
				if let player = startContinuousPlayer(on: engine, baseSharpness: Self.phoneBaseSharpness) {
					newEngines.append(engine)
					newPlayers.append(player)
					isPhone = true
					log.notice("Haptics: using iPhone Taptic Engine")
				}
			} catch {
				log.error("Phone haptics init failed: \(error.localizedDescription, privacy: .public)")
			}
		}

		var oldPlayers: [CHHapticAdvancedPatternPlayer] = []
		var oldEngines: [CHHapticEngine] = []
		var installed = false

		lock.lock()
		if isAttached && _enabled && !_paused && _intensity > 0.001 && _target == target && attachedController === controller {
			oldPlayers = players
			oldEngines = engines
			engines = newEngines
			players = newPlayers
			usingPhoneEngine = isPhone
			needsRestart = false
			lastSentValues = Array(repeating: 0, count: newPlayers.count)
			lastSentSharpness = Self.phoneBaseSharpness
			installed = true
		}
		lock.unlock()

		if installed {
			Self.teardown(players: oldPlayers, engines: oldEngines)
		} else {
			Self.teardown(players: newPlayers, engines: newEngines)
		}
	}

	private func startContinuousPlayer(on engine: CHHapticEngine, baseSharpness: Float) -> CHHapticAdvancedPatternPlayer? {
		engine.stoppedHandler = { [weak self] _ in
			self?.markNeedsRestart()
		}
		engine.resetHandler = { [weak self] in
			self?.markNeedsRestart()
		}
		do {
			try engine.start()
			let event = CHHapticEvent(
				eventType: .hapticContinuous,
				parameters: [
					CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
					CHHapticEventParameter(parameterID: .hapticSharpness, value: baseSharpness),
				],
				relativeTime: 0,
				duration: 30
			)
			let pattern = try CHHapticPattern(events: [event], parameters: [])
			let player = try engine.makeAdvancedPlayer(with: pattern)
			player.loopEnabled = true
			try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)], atTime: CHHapticTimeImmediate)
			try player.start(atTime: CHHapticTimeImmediate)
			return player
		} catch {
			engine.stoppedHandler = { _ in }
			engine.resetHandler = {}
			engine.stop()
			log.error("Haptics: \(error.localizedDescription, privacy: .public)")
			return nil
		}
	}

	private func markNeedsRestart() {
		lock.lock()
		needsRestart = true
		lastSentValues = []
		lastSentSharpness = -1
		lock.unlock()
	}

	private func restartIfNeeded() {
		var controller: GCController?
		var oldPlayers: [CHHapticAdvancedPatternPlayer] = []
		var oldEngines: [CHHapticEngine] = []
		var shouldRebuild = false

		lock.lock()
		restartScheduled = false
		if needsRestart && isAttached && _enabled && !_paused && _intensity > 0.001 {
			needsRestart = false
			oldPlayers = players
			oldEngines = engines
			players = []
			engines = []
			usingPhoneEngine = false
			lastSentValues = []
			lastSentSharpness = -1
			controller = attachedController
			shouldRebuild = true
		}
		lock.unlock()

		Self.teardown(players: oldPlayers, engines: oldEngines)
		if shouldRebuild {
			rebuildEngines(for: controller)
		}
	}

	private static func zero(players: [CHHapticAdvancedPatternPlayer]) {
		guard !players.isEmpty else { return }
		let param = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)
		for player in players {
			try? player.sendParameters([param], atTime: CHHapticTimeImmediate)
		}
	}

	private static func teardown(players: [CHHapticAdvancedPatternPlayer], engines: [CHHapticEngine]) {
		for player in players {
			try? player.stop(atTime: CHHapticTimeImmediate)
		}
		for engine in engines {
			engine.stoppedHandler = { _ in }
			engine.resetHandler = {}
			engine.stop()
		}
	}
}
