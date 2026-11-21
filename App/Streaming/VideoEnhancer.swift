import CoreMedia
import CoreVideo
import Foundation
import Metal
#if !targetEnvironment(simulator)
import MetalFX
#endif
import QuartzCore
@preconcurrency import VideoToolbox

struct EnhancerCapabilities: Equatable {
	let metalDeviceName: String
	let metalFXSupported: Bool
	let vtFrameGenSupported: Bool
	let vtFrameGenMinSize: String?
	let vtFrameGenMaxSize: String?
	let vtSuperResSupported: Bool
	let vtSuperResScaleFactors720p: [Float]
	let vtSuperResScaleFactors1080p: [Float]

	static let current: EnhancerCapabilities = probe()

	var shortStatus: String {
		var parts: [String] = []
		parts.append("MetalFX: \(metalFXSupported ? "Ready" : "Unavailable")")
		#if targetEnvironment(simulator)
		parts.append("VT ML Frame Gen/SR: Device-only (Simulator)")
		#else
		if #available(iOS 26.0, *) {
			parts.append("VT Frame Gen: \(vtFrameGenSupported ? "Ready" : "Unsupported")")
			let sfText = vtSuperResScaleFactors1080p.isEmpty
				? (vtSuperResSupported ? "Ready" : "Unsupported")
				: vtSuperResScaleFactors1080p.map { String(format: "%.1fx", $0) }.joined(separator: "/")
			parts.append("VT Super Res (1080p): \(sfText)")
		} else {
			parts.append("VT Frame Gen/SR: Needs iOS 26+")
		}
		#endif
		return parts.joined(separator: " • ")
	}

	var summaryText: String {
		let f720 = vtSuperResScaleFactors720p.isEmpty
			? "none"
			: vtSuperResScaleFactors720p.map { String(format: "%.2fx", $0) }.joined(separator: ", ")
		let f1080 = vtSuperResScaleFactors1080p.isEmpty
			? "none"
			: vtSuperResScaleFactors1080p.map { String(format: "%.2fx", $0) }.joined(separator: ", ")
		return """
		Metal device: \(metalDeviceName)
		MetalFX spatial scaler: \(metalFXSupported)
		VT low-latency frame interpolation: \(vtFrameGenSupported) (min: \(vtFrameGenMinSize ?? "?"), max: \(vtFrameGenMaxSize ?? "?"))
		VT low-latency super resolution: \(vtSuperResSupported) (720p: [\(f720)], 1080p: [\(f1080)])
		"""
	}

	private static func probe() -> EnhancerCapabilities {
		let device = MTLCreateSystemDefaultDevice()
		let metalName = device?.name ?? "None"
		let mfx: Bool
		#if !targetEnvironment(simulator)
		mfx = device.map { MTLFXSpatialScalerDescriptor.supportsDevice($0) } ?? false
		#else
		mfx = false
		#endif

		#if !targetEnvironment(simulator)
		if #available(iOS 26.0, *) {
			let fgSupported = VTLowLatencyFrameInterpolationConfiguration.isSupported
			let fgMin = VTLowLatencyFrameInterpolationConfiguration.minimumDimensions.map { "\($0.width)x\($0.height)" }
			let fgMax = VTLowLatencyFrameInterpolationConfiguration.maximumDimensions.map { "\($0.width)x\($0.height)" }
			let srSupported = VTLowLatencySuperResolutionScalerConfiguration.isSupported
			let sf720 = srSupported
				? VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: 1280, frameHeight: 720)
				: []
			let sf1080 = srSupported
				? VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: 1920, frameHeight: 1080)
				: []
			return EnhancerCapabilities(
				metalDeviceName: metalName,
				metalFXSupported: mfx,
				vtFrameGenSupported: fgSupported,
				vtFrameGenMinSize: fgMin,
				vtFrameGenMaxSize: fgMax,
				vtSuperResSupported: srSupported,
				vtSuperResScaleFactors720p: sf720,
				vtSuperResScaleFactors1080p: sf1080
			)
		}
		#endif

		return EnhancerCapabilities(
			metalDeviceName: metalName,
			metalFXSupported: mfx,
			vtFrameGenSupported: false,
			vtFrameGenMinSize: nil,
			vtFrameGenMaxSize: nil,
			vtSuperResSupported: false,
			vtSuperResScaleFactors720p: [],
			vtSuperResScaleFactors1080p: []
		)
	}
}

struct EnhancerStats: Equatable {
	var activeFrameGen: String = "Off"
	var activeUpscaler: String = "Off"
	var frameGenMs: Double = 0
	var upscaleMs: Double = 0
	var generatedFrames: Int = 0
	var realPacedFrames: Int = 0
	var skippedDuplicates: Int = 0
	var droppedStaleFrames: Int = 0
	var lastError: String?
}

/// GPU luma-plane difference sampler for skipping duplicated 30 fps frames inside 60 fps streams.
private final class LumaDiffDetector {
	private let queue: MTLCommandQueue
	private let pipeline: MTLComputePipelineState
	private let diffBuffer: MTLBuffer
	private var textureCache: CVMetalTextureCache?

	init?(device: MTLDevice) {
		guard let queue = device.makeCommandQueue(),
			let library = device.makeDefaultLibrary(),
			let fn = library.makeFunction(name: "luma_diff_grid"),
			let pipeline = try? device.makeComputePipelineState(function: fn),
			let diffBuffer = device.makeBuffer(length: MemoryLayout<Float>.stride, options: .storageModeShared)
		else { return nil }

		self.queue = queue
		self.pipeline = pipeline
		self.diffBuffer = diffBuffer
		CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
	}

	func diff(previous: CVPixelBuffer, current: CVPixelBuffer) -> Double? {
		guard let cache = textureCache,
			CVPixelBufferIsPlanar(previous),
			CVPixelBufferIsPlanar(current)
		else { return nil }

		CVMetalTextureCacheFlush(cache, 0)

		guard let prevTexRef = makeLumaTexture(previous, cache: cache),
			let currTexRef = makeLumaTexture(current, cache: cache),
			let prevTex = CVMetalTextureGetTexture(prevTexRef),
			let currTex = CVMetalTextureGetTexture(currTexRef),
			let cb = queue.makeCommandBuffer(),
			let encoder = cb.makeComputeCommandEncoder()
		else { return nil }

		encoder.setComputePipelineState(pipeline)
		encoder.setTexture(prevTex, index: 0)
		encoder.setTexture(currTex, index: 1)
		encoder.setBuffer(diffBuffer, offset: 0, index: 0)
		encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
		encoder.endEncoding()

		cb.commit()
		cb.waitUntilCompleted()
		_ = prevTexRef
		_ = currTexRef

		let value = diffBuffer.contents().assumingMemoryBound(to: Float.self).pointee
		return value.isFinite ? Double(value) : nil
	}

	private func makeLumaTexture(_ pb: CVPixelBuffer, cache: CVMetalTextureCache) -> CVMetalTexture? {
		let tenBit = PixelBufferSupport.isTenBitPixelFormat(CVPixelBufferGetPixelFormatType(pb))
		let format: MTLPixelFormat = tenBit ? .r16Unorm : .r8Unorm
		let w = CVPixelBufferGetWidthOfPlane(pb, 0)
		let h = CVPixelBufferGetHeightOfPlane(pb, 0)
		var tex: CVMetalTexture?
		let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, format, w, h, 0, &tex)
		return status == kCVReturnSuccess ? tex : nil
	}
}

private final class CompletionBox: @unchecked Sendable {
	var error: Error?
}

#if !targetEnvironment(simulator)
@available(iOS 26.0, *)
private final class VTBackendState: @unchecked Sendable {
	private static let modelWarmupTimeoutSeconds: Double = 5.0

	// Frame Interpolation state
	var fgKey: String = ""
	var fgProcessor: VTFrameProcessor?
	var fgSessionStarted = false
	var fgSourceAttrs: [String: Any] = [:]
	var fgSourcePool: CVPixelBufferPool?
	var fgDestPool: CVPixelBufferPool?
	var fgTransfer: VTPixelTransferSession?
	var fgInputWidth = 0
	var fgInputHeight = 0
	var fgDisabled = false
	var fgWarmupStart: TimeInterval?
	var fgConsecutiveErrors = 0

	// Super Resolution state
	var srKey: String = ""
	var srProcessor: VTFrameProcessor?
	var srSessionStarted = false
	var srSourceAttrs: [String: Any] = [:]
	var srSourcePool: CVPixelBufferPool?
	var srDestPool: CVPixelBufferPool?
	var srTransfer: VTPixelTransferSession?
	var srInputWidth = 0
	var srInputHeight = 0
	var srScaleFactor: Float = 1.0
	var srDisabled = false
	var srWarmupStart: TimeInterval?
	var srConsecutiveErrors = 0

	var previousFrame: (rawBuffer: CVPixelBuffer, compatBuffer: CVPixelBuffer, ptsTicks: Int64, width: Int, height: Int, format: OSType)?
	var lastSourcePTSTicks: Int64 = 0

	func resetContinuity() {
		previousFrame = nil
	}

	func endFrameGenSession(keepKey: Bool = false) {
		if fgSessionStarted, let proc = fgProcessor {
			proc.endSession()
		}
		fgSessionStarted = false
		fgProcessor = nil
		fgSourcePool = nil
		fgDestPool = nil
		fgSourceAttrs = [:]
		fgInputWidth = 0
		fgInputHeight = 0
		if !keepKey {
			fgKey = ""
			fgDisabled = false
		}
		fgWarmupStart = nil
		fgConsecutiveErrors = 0
		if let t = fgTransfer {
			VTPixelTransferSessionInvalidate(t)
			fgTransfer = nil
		}
	}

	func endSuperResSession(keepKey: Bool = false) {
		if srSessionStarted, let proc = srProcessor {
			proc.endSession()
		}
		srSessionStarted = false
		srProcessor = nil
		srSourcePool = nil
		srDestPool = nil
		srSourceAttrs = [:]
		srInputWidth = 0
		srInputHeight = 0
		if !keepKey {
			srKey = ""
			srDisabled = false
		}
		srScaleFactor = 1.0
		srWarmupStart = nil
		srConsecutiveErrors = 0
		if let t = srTransfer {
			VTPixelTransferSessionInvalidate(t)
			srTransfer = nil
		}
	}

	func tearDown() {
		endFrameGenSession()
		endSuperResSession()
		previousFrame = nil
	}

	func ensureFrameGenSession(width: Int, height: Int, format: OSType) -> (ready: Bool, status: String, error: String?) {
		let key = "\(width)x\(height)_\(format)"
		if fgKey == key {
			if fgDisabled {
				return (false, "Disabled (fallback)", "VT Frame Gen disabled after errors")
			}
			return (fgSessionStarted, fgWarmupStart != nil ? "Warming ML..." : "VT 2x", nil)
		}

		endFrameGenSession()
		fgKey = key
		fgDisabled = false

		guard VTLowLatencyFrameInterpolationConfiguration.isSupported else {
			fgDisabled = true
			return (false, "Unsupported", "VTLowLatencyFrameInterpolation unsupported on this device")
		}
		if let minDim = VTLowLatencyFrameInterpolationConfiguration.minimumDimensions,
			width < Int(minDim.width) || height < Int(minDim.height)
		{
			fgDisabled = true
			return (false, "Below min size", "Frame \(width)x\(height) below VT minimum \(minDim.width)x\(minDim.height)")
		}
		if let maxDim = VTLowLatencyFrameInterpolationConfiguration.maximumDimensions,
			width > Int(maxDim.width) || height > Int(maxDim.height)
		{
			fgDisabled = true
			return (false, "Above max size", "Frame \(width)x\(height) exceeds VT maximum \(maxDim.width)x\(maxDim.height)")
		}

		guard let config = VTLowLatencyFrameInterpolationConfiguration(
			frameWidth: width,
			frameHeight: height,
			numberOfInterpolatedFrames: 1
		) else {
			fgDisabled = true
			return (false, "Config failed", "Failed to create VTLowLatencyFrameInterpolationConfiguration")
		}

		let srcAttrs = config.sourcePixelBufferAttributes
		let dstAttrs = config.destinationPixelBufferAttributes
		let srcW = (srcAttrs[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue ?? width
		let srcH = (srcAttrs[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue ?? height
		let dstW = (dstAttrs[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue ?? width
		let dstH = (dstAttrs[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue ?? height

		let resolvedSrc = PixelBufferSupport.resolvePoolAttributes(from: srcAttrs, preferredFormat: format, width: srcW, height: srcH)
		let resolvedDst = PixelBufferSupport.resolvePoolAttributes(from: dstAttrs, preferredFormat: format, width: dstW, height: dstH)

		guard let srcPool = makePool(attributes: resolvedSrc, minCount: 3),
			let dstPool = makePool(attributes: resolvedDst, minCount: 3)
		else {
			fgDisabled = true
			return (false, "Pool failed", "Failed to allocate VT Frame Gen pixel buffer pools")
		}

		var transfer: VTPixelTransferSession?
		VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)

		let proc = VTFrameProcessor()
		do {
			try proc.startSession(configuration: config)
		} catch {
			if let t = transfer { VTPixelTransferSessionInvalidate(t) }
			fgDisabled = true
			return (false, "Start failed", "VT Frame Gen startSession failed: \(error.localizedDescription)")
		}

		fgProcessor = proc
		fgSessionStarted = true
		fgSourceAttrs = srcAttrs
		fgSourcePool = srcPool
		fgDestPool = dstPool
		fgTransfer = transfer
		fgInputWidth = srcW
		fgInputHeight = srcH
		return (true, "VT 2x", nil)
	}

	func ensureSuperResSession(width: Int, height: Int, format: OSType, preferredScale: Double) -> (ready: Bool, status: String, error: String?) {
		let key = "\(width)x\(height)_\(format)_\(String(format: "%.2f", preferredScale))"
		if srKey == key {
			if srDisabled {
				return (false, "Fallback", "VT Super Res disabled after errors")
			}
			let label = String(format: "VT SR %.1fx", srScaleFactor)
			return (srSessionStarted, srWarmupStart != nil ? "Warming SR..." : label, nil)
		}

		endSuperResSession()
		srKey = key
		srDisabled = false

		guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else {
			srDisabled = true
			return (false, "Unsupported", "VTLowLatencySuperResolution unsupported on this device")
		}
		if let minDim = VTLowLatencySuperResolutionScalerConfiguration.minimumDimensions,
			width < Int(minDim.width) || height < Int(minDim.height)
		{
			srDisabled = true
			return (false, "Below min size", "Frame \(width)x\(height) below VT SR minimum")
		}
		if let maxDim = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions,
			width > Int(maxDim.width) || height > Int(maxDim.height)
		{
			srDisabled = true
			return (false, "Above max size", "Frame \(width)x\(height) exceeds VT SR maximum")
		}

		let available = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height)
		guard let chosenScale = PixelBufferSupport.chooseBestScaleFactor(available: available, preferred: Float(preferredScale)) else {
			srDisabled = true
			return (false, "Unsupported", "No VT Super Res scale factors for \(width)x\(height)")
		}

		let config = VTLowLatencySuperResolutionScalerConfiguration(
			frameWidth: width,
			frameHeight: height,
			scaleFactor: chosenScale
		)

		let srcAttrs = config.sourcePixelBufferAttributes
		let dstAttrs = config.destinationPixelBufferAttributes
		let srcW = (srcAttrs[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue ?? width
		let srcH = (srcAttrs[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue ?? height
		let defaultDstW = Int((Double(width) * Double(chosenScale)).rounded())
		let defaultDstH = Int((Double(height) * Double(chosenScale)).rounded())
		let dstW = (dstAttrs[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue ?? defaultDstW
		let dstH = (dstAttrs[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue ?? defaultDstH

		let resolvedSrc = PixelBufferSupport.resolvePoolAttributes(from: srcAttrs, preferredFormat: format, width: srcW, height: srcH)
		let resolvedDst = PixelBufferSupport.resolvePoolAttributes(from: dstAttrs, preferredFormat: format, width: dstW, height: dstH)

		guard let srcPool = makePool(attributes: resolvedSrc, minCount: 2),
			let dstPool = makePool(attributes: resolvedDst, minCount: 3)
		else {
			srDisabled = true
			return (false, "Pool failed", "Failed to allocate VT Super Res pixel buffer pools")
		}

		var transfer: VTPixelTransferSession?
		VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)

		let proc = VTFrameProcessor()
		do {
			try proc.startSession(configuration: config)
		} catch {
			if let t = transfer { VTPixelTransferSessionInvalidate(t) }
			srDisabled = true
			return (false, "Start failed", "VT Super Res startSession failed: \(error.localizedDescription)")
		}

		srProcessor = proc
		srSessionStarted = true
		srSourceAttrs = srcAttrs
		srSourcePool = srcPool
		srDestPool = dstPool
		srTransfer = transfer
		srInputWidth = srcW
		srInputHeight = srcH
		srScaleFactor = chosenScale
		return (true, String(format: "VT SR %.1fx", chosenScale), nil)
	}

	func makeCompatibleInput(
		_ pixelBuffer: CVPixelBuffer,
		width: Int,
		height: Int,
		attributes: [String: Any],
		pool: CVPixelBufferPool?,
		transfer: VTPixelTransferSession?
	) -> CVPixelBuffer? {
		if PixelBufferSupport.isBufferCompatible(pixelBuffer, width: width, height: height, withAttributes: attributes) {
			return pixelBuffer
		}
		guard let pool, let transfer, let converted = makeBuffer(from: pool) else { return nil }
		let status = VTPixelTransferSessionTransferImage(transfer, from: pixelBuffer, to: converted)
		guard status == noErr else { return nil }
		PixelBufferSupport.propagateColorAttachments(from: pixelBuffer, to: converted)
		return converted
	}

	func runInterpolation(
		previous: CVPixelBuffer,
		previousPTSTicks: Int64,
		current: CVPixelBuffer,
		currentPTSTicks: Int64
	) -> (buffer: CVPixelBuffer?, warmingUp: Bool, error: String?) {
		guard fgSessionStarted, let proc = fgProcessor, let dstPool = fgDestPool else {
			return (nil, false, "VT Frame Gen session not started")
		}
		guard let dstPB = makeBuffer(from: dstPool) else {
			return (nil, false, "Failed to dequeue VT Frame Gen destination buffer")
		}

		let midTicks = previousPTSTicks + max(1, (currentPTSTicks - previousPTSTicks) / 2)
		let prevPTS = CMTime(value: previousPTSTicks, timescale: 90_000)
		let currPTS = CMTime(value: currentPTSTicks, timescale: 90_000)
		let midPTS = CMTime(value: midTicks, timescale: 90_000)

		guard let prevFrame = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: prevPTS),
			let currFrame = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: currPTS),
			let dstFrame = VTFrameProcessorFrame(buffer: dstPB, presentationTimeStamp: midPTS),
			let params = VTLowLatencyFrameInterpolationParameters(
				sourceFrame: currFrame,
				previousFrame: prevFrame,
				interpolationPhase: [0.5],
				destinationFrames: [dstFrame]
			)
		else {
			return (nil, false, "Failed to build VTFrameProcessorFrame/Parameters")
		}

		let result = execute(processor: proc, parameters: params)
		if result.timedOut {
			fgSessionStarted = false
			endFrameGenSession(keepKey: true)
			fgDisabled = true
			return (nil, false, "VT Frame Gen timed out and was disabled")
		}
		if let err = result.error {
			let ns = err as NSError
			if isWarmupOrAssetError(err, ns: ns) {
				let now = CACurrentMediaTime()
				if fgWarmupStart == nil { fgWarmupStart = now }
				if now - (fgWarmupStart ?? now) > Self.modelWarmupTimeoutSeconds {
					endFrameGenSession(keepKey: true)
					fgDisabled = true
					return (nil, false, "VT Frame Gen ML warmup timed out")
				}
				return (nil, true, nil)
			}
			fgConsecutiveErrors += 1
			if fgConsecutiveErrors >= 5 {
				endFrameGenSession(keepKey: true)
				fgDisabled = true
			}
			return (nil, false, "VT Frame Gen error (\(ns.code)): \(ns.localizedDescription)")
		}

		fgWarmupStart = nil
		fgConsecutiveErrors = 0
		PixelBufferSupport.propagateColorAttachments(from: current, to: dstPB)
		return (dstPB, false, nil)
	}

	func runSuperRes(
		source: CVPixelBuffer,
		ptsTicks: Int64
	) -> (buffer: CVPixelBuffer?, warmingUp: Bool, error: String?) {
		guard srSessionStarted, let proc = srProcessor, let dstPool = srDestPool else {
			return (nil, false, "VT Super Res session not started")
		}
		guard let compatible = makeCompatibleInput(
			source,
			width: srInputWidth,
			height: srInputHeight,
			attributes: srSourceAttrs,
			pool: srSourcePool,
			transfer: srTransfer
		) else {
			return (nil, false, "Failed to prepare compatible VT Super Res input")
		}
		guard let dstPB = makeBuffer(from: dstPool) else {
			return (nil, false, "Failed to dequeue VT Super Res destination buffer")
		}

		let pts = CMTime(value: ptsTicks, timescale: 90_000)
		guard let srcFrame = VTFrameProcessorFrame(buffer: compatible, presentationTimeStamp: pts),
			let dstFrame = VTFrameProcessorFrame(buffer: dstPB, presentationTimeStamp: pts)
		else {
			return (nil, false, "Failed to wrap VT Super Res frames")
		}

		let params = VTLowLatencySuperResolutionScalerParameters(sourceFrame: srcFrame, destinationFrame: dstFrame)
		let result = execute(processor: proc, parameters: params)
		if result.timedOut {
			srSessionStarted = false
			endSuperResSession(keepKey: true)
			srDisabled = true
			return (nil, false, "VT Super Res timed out and was disabled")
		}
		if let err = result.error {
			let ns = err as NSError
			if isWarmupOrAssetError(err, ns: ns) {
				let now = CACurrentMediaTime()
				if srWarmupStart == nil { srWarmupStart = now }
				if now - (srWarmupStart ?? now) > Self.modelWarmupTimeoutSeconds {
					endSuperResSession(keepKey: true)
					srDisabled = true
					return (nil, false, "VT Super Res ML warmup timed out")
				}
				return (nil, true, nil)
			}
			srConsecutiveErrors += 1
			if srConsecutiveErrors >= 5 {
				endSuperResSession(keepKey: true)
				srDisabled = true
			}
			return (nil, false, "VT Super Res error (\(ns.code)): \(ns.localizedDescription)")
		}

		srWarmupStart = nil
		srConsecutiveErrors = 0
		PixelBufferSupport.propagateColorAttachments(from: source, to: dstPB)
		return (dstPB, false, nil)
	}

	private func isWarmupOrAssetError(_ err: Error, ns: NSError) -> Bool {
		if ns.domain == "com.apple.VideoProcessing" && ns.code == -12911 {
			return true
		}
		if let vtErr = err as? VTFrameProcessorError, vtErr.code == .assetDownloadFailed {
			return true
		}
		return false
	}

	private func execute(processor: VTFrameProcessor, parameters: any VTFrameProcessorParameters) -> (error: Error?, timedOut: Bool) {
		let sem = DispatchSemaphore(value: 0)
		let box = CompletionBox()
		processor.process(parameters: parameters) { _, error in
			box.error = error
			sem.signal()
		}
		if sem.wait(timeout: .now() + .seconds(2)) == .timedOut {
			// Flush/cancel any in-flight work before returning pool buffers
			processor.endSession()
			_ = sem.wait(timeout: .now() + .seconds(1))
			return (nil, true)
		}
		return (box.error, false)
	}

	private func makePool(attributes: [String: Any], minCount: Int) -> CVPixelBufferPool? {
		var pool: CVPixelBufferPool?
		let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: minCount]
		let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attributes as CFDictionary, &pool)
		return status == kCVReturnSuccess ? pool : nil
	}

	private func makeBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
		var pb: CVPixelBuffer?
		let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
		return status == kCVReturnSuccess ? pb : nil
	}
}
#endif

/// Coordinates Apple VideoToolbox ML Frame Generation, VT ML Super Resolution,
/// duplicate-frame detection, and CADisplayLink frame pacing on a dedicated serial queue.
final class VideoEnhancer {
	struct Config: Equatable {
		var upscalingMode: UpscalingMode = .metalFX
		var frameGenMode: FrameGenMode = .off
		var deduplicateFrames: Bool = true
		var vtScaleFactor: Double = 1.5
		var nominalSourceFPS: Int = 60
	}

	private static let duplicateThreshold: Double = 0.0028

	var onImmediateFrame: ((CVPixelBuffer) -> Void)?

	private let workerQueue = DispatchQueue(label: "com.iplay5.videoEnhancer", qos: .userInteractive)
	private let stateLock = NSLock()
	private let pacer = FramePacer<CVPixelBuffer>()
	private let lumaDiff: LumaDiffDetector?

	private var config = Config()
	private var paused = false
	private var invalidated = false
	private var pendingBuffer: CVPixelBuffer?
	private var pendingArrivalTime: Double = 0
	private var pendingDiscontinuity = false
	private var workerScheduled = false

	// Fallback previous buffer for Simulator / pre-iOS 26 duplicate detection
	private var fallbackPreviousRaw: CVPixelBuffer?

	#if !targetEnvironment(simulator)
	private var vtStateBox: AnyObject?
	#endif

	// Stats protected by stateLock
	private var activeFrameGenLabel = "Off"
	private var activeUpscalerLabel = "Off"
	private var lastFrameGenMs: Double = 0
	private var lastUpscaleMs: Double = 0
	private var lastErrorMessage: String?

	init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
		self.lumaDiff = device.flatMap { LumaDiffDetector(device: $0) }
		#if !targetEnvironment(simulator)
		if #available(iOS 26.0, *) {
			self.vtStateBox = VTBackendState()
		}
		#endif
	}

	deinit {
		invalidate()
	}

	func configure(
		upscalingMode: UpscalingMode,
		frameGenMode: FrameGenMode,
		deduplicateFrames: Bool,
		vtScaleFactor: Double,
		nominalSourceFPS: Int
	) {
		let next = Config(
			upscalingMode: upscalingMode,
			frameGenMode: frameGenMode,
			deduplicateFrames: deduplicateFrames,
			vtScaleFactor: vtScaleFactor,
			nominalSourceFPS: nominalSourceFPS
		)
		var fgOrFpsChanged = false
		var shouldCleanup = false
		stateLock.lock()
		if next != config {
			fgOrFpsChanged = next.frameGenMode != config.frameGenMode || next.nominalSourceFPS != config.nominalSourceFPS
			let srTurnedOff = config.upscalingMode == .vtSuperRes && next.upscalingMode != .vtSuperRes
			let srScaleChanged = next.vtScaleFactor != config.vtScaleFactor
			shouldCleanup = fgOrFpsChanged || srTurnedOff || srScaleChanged
			config = next
			if next.frameGenMode == .off {
				activeFrameGenLabel = "Off"
				lastFrameGenMs = 0
			}
			if next.upscalingMode != .vtSuperRes {
				lastUpscaleMs = 0
			}
			if next.frameGenMode == .off && next.upscalingMode != .vtSuperRes {
				lastErrorMessage = nil
			}
		}
		stateLock.unlock()

		pacer.configure(mode: frameGenMode, nominalSourceFPS: Double(nominalSourceFPS))
		if shouldCleanup {
			workerQueue.async { [weak self] in
				guard let self else { return }
				if fgOrFpsChanged {
					self.fallbackPreviousRaw = nil
				}
				#if !targetEnvironment(simulator)
				if #available(iOS 26.0, *), let state = self.captureVTState() as? VTBackendState {
					if fgOrFpsChanged {
						state.resetContinuity()
					}
					if frameGenMode == .off {
						state.endFrameGenSession()
					}
					if upscalingMode != .vtSuperRes {
						state.endSuperResSession()
					}
				}
				#endif
			}
		}
	}

	func setPaused(_ paused: Bool) {
		stateLock.lock()
		let changed = self.paused != paused
		self.paused = paused
		if paused {
			pendingBuffer = nil
			pendingDiscontinuity = true
		}
		stateLock.unlock()

		if changed {
			pacer.reset()
			if paused {
				workerQueue.async { [weak self] in
					self?.resetContinuityOnWorker()
				}
			}
		}
	}

	func markDiscontinuity() {
		stateLock.lock()
		pendingDiscontinuity = true
		stateLock.unlock()
		pacer.reset()
	}

	func submit(_ pixelBuffer: CVPixelBuffer, arrivalTime: Double = CACurrentMediaTime()) {
		var immediateHandler: ((CVPixelBuffer) -> Void)?
		var shouldDispatch = false

		stateLock.lock()
		if invalidated || paused {
			stateLock.unlock()
			return
		}
		let cfg = config
		if cfg.frameGenMode == .off && cfg.upscalingMode != .vtSuperRes {
			immediateHandler = onImmediateFrame
			stateLock.unlock()
			immediateHandler?(pixelBuffer)
			return
		}

		pendingBuffer = pixelBuffer
		pendingArrivalTime = arrivalTime
		if !workerScheduled {
			workerScheduled = true
			shouldDispatch = true
		}
		stateLock.unlock()

		if shouldDispatch {
			workerQueue.async { [weak self] in
				self?.drainWorker()
			}
		}
	}

	func popPacedFrame(forDisplayTimestamp targetTimestamp: Double, vsyncInterval: Double) -> CVPixelBuffer? {
		pacer.popFrame(forDisplayTimestamp: targetTimestamp, vsyncInterval: vsyncInterval)?.frame
	}

	func invalidate() {
		#if !targetEnvironment(simulator)
		var capturedBox: AnyObject?
		#endif

		stateLock.lock()
		let alreadyInvalidated = invalidated
		invalidated = true
		pendingBuffer = nil
		onImmediateFrame = nil
		#if !targetEnvironment(simulator)
		capturedBox = vtStateBox
		vtStateBox = nil
		#endif
		stateLock.unlock()

		pacer.reset()

		guard !alreadyInvalidated else { return }
		workerQueue.async { [weak self] in
			self?.fallbackPreviousRaw = nil
			#if !targetEnvironment(simulator)
			if #available(iOS 26.0, *), let state = capturedBox as? VTBackendState {
				state.tearDown()
			}
			#endif
		}
	}

	func currentStats(rendererUpscaler: String, rendererFallback: String?) -> EnhancerStats {
		let p = pacer.stats
		stateLock.lock()
		let fgLabel = activeFrameGenLabel
		let srLabel = activeUpscalerLabel
		let fgMs = lastFrameGenMs
		let srMs = lastUpscaleMs
		let vtErr = lastErrorMessage
		let cfg = config
		stateLock.unlock()

		let effectiveUpscaler = cfg.upscalingMode == .vtSuperRes ? srLabel : rendererUpscaler
		let combinedError = vtErr ?? rendererFallback
		return EnhancerStats(
			activeFrameGen: fgLabel,
			activeUpscaler: effectiveUpscaler,
			frameGenMs: fgMs,
			upscaleMs: srMs,
			generatedFrames: p.generatedPresented,
			realPacedFrames: p.realPresented,
			skippedDuplicates: p.skippedDuplicates,
			droppedStaleFrames: p.droppedStaleFrames,
			lastError: combinedError
		)
	}

	// MARK: - Worker queue

	#if !targetEnvironment(simulator)
	private func captureVTState() -> AnyObject? {
		stateLock.lock()
		defer { stateLock.unlock() }
		return vtStateBox
	}
	#endif

	private func resetContinuityOnWorker() {
		fallbackPreviousRaw = nil
		#if !targetEnvironment(simulator)
		if #available(iOS 26.0, *), let state = captureVTState() as? VTBackendState {
			state.resetContinuity()
		}
		#endif
	}

	private func drainWorker() {
		while true {
			stateLock.lock()
			if invalidated || paused {
				pendingBuffer = nil
				workerScheduled = false
				stateLock.unlock()
				return
			}
			guard let pixelBuffer = pendingBuffer else {
				workerScheduled = false
				stateLock.unlock()
				return
			}
			let arrivalTime = pendingArrivalTime
			let discontinuity = pendingDiscontinuity
			let cfg = config
			let immediate = onImmediateFrame
			#if !targetEnvironment(simulator)
			let vtBox = vtStateBox
			#else
			let vtBox: AnyObject? = nil
			#endif
			pendingBuffer = nil
			pendingDiscontinuity = false
			stateLock.unlock()

			processFrame(
				pixelBuffer,
				arrivalTime: arrivalTime,
				discontinuity: discontinuity,
				cfg: cfg,
				vtBox: vtBox,
				immediateHandler: immediate
			)
		}
	}

	private func processFrame(
		_ pixelBuffer: CVPixelBuffer,
		arrivalTime: Double,
		discontinuity: Bool,
		cfg: Config,
		vtBox: AnyObject?,
		immediateHandler: ((CVPixelBuffer) -> Void)?
	) {
		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)
		let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

		if discontinuity {
			resetContinuityOnWorker()
		}

		#if !targetEnvironment(simulator)
		if #available(iOS 26.0, *), let state = vtBox as? VTBackendState {
			processWithVT(
				pixelBuffer,
				width: width,
				height: height,
				format: format,
				arrivalTime: arrivalTime,
				cfg: cfg,
				state: state,
				immediateHandler: immediateHandler
			)
			return
		}
		#endif

		// Simulator or pre-iOS 26 fallback: duplicate detector + passthrough
		let fgLabel: String
		#if targetEnvironment(simulator)
		fgLabel = cfg.frameGenMode == .x2 ? "Simulator Passthrough" : "Off"
		#else
		fgLabel = cfg.frameGenMode == .x2 ? "Needs iOS 26+" : "Off"
		#endif

		let srLabel = cfg.upscalingMode == .vtSuperRes ? "Needs iOS 26+" : cfg.upscalingMode.label
		updateStatus(fgLabel: fgLabel, srLabel: srLabel, fgMs: 0, srMs: 0, error: nil)

		if cfg.frameGenMode == .x2 {
			if cfg.deduplicateFrames && cfg.nominalSourceFPS >= 60,
				let prev = fallbackPreviousRaw,
				let diff = lumaDiff?.diff(previous: prev, current: pixelBuffer),
				pacer.evaluateDuplicate(diffScore: diff, threshold: Self.duplicateThreshold, enabled: true) == .skipDuplicate
			{
				return
			}
			_ = pacer.evaluateDuplicate(diffScore: 1, threshold: Self.duplicateThreshold, enabled: false)
			fallbackPreviousRaw = pixelBuffer
			pacer.enqueueRealFrame(pixelBuffer, arrivalTime: arrivalTime)
		} else {
			fallbackPreviousRaw = nil
			immediateHandler?(pixelBuffer)
		}
	}

	#if !targetEnvironment(simulator)
	@available(iOS 26.0, *)
	private func processWithVT(
		_ pixelBuffer: CVPixelBuffer,
		width: Int,
		height: Int,
		format: OSType,
		arrivalTime: Double,
		cfg: Config,
		state: VTBackendState,
		immediateHandler: ((CVPixelBuffer) -> Void)?
	) {
		var fgLabel = "Off"
		var srLabel = cfg.upscalingMode.label
		var fgMs: Double = 0
		var srMs: Double = 0
		var errorMsg: String?

		var srReady = false
		if cfg.upscalingMode == .vtSuperRes {
			let srStatus = state.ensureSuperResSession(width: width, height: height, format: format, preferredScale: cfg.vtScaleFactor)
			srReady = srStatus.ready
			srLabel = srStatus.status
			if let err = srStatus.error { errorMsg = err }
		} else {
			state.endSuperResSession()
		}

		// Compute strictly monotonic PTS in 90 kHz clock
		var ptsTicks = Int64((arrivalTime * 90_000).rounded())
		if ptsTicks <= state.lastSourcePTSTicks + 2 {
			ptsTicks = state.lastSourcePTSTicks + 2
		}
		state.lastSourcePTSTicks = ptsTicks

		func maybeSuperRes(_ pb: CVPixelBuffer, pts: Int64) -> CVPixelBuffer {
			guard cfg.upscalingMode == .vtSuperRes, srReady else { return pb }
			let t0 = CACurrentMediaTime()
			let res = state.runSuperRes(source: pb, ptsTicks: pts)
			srMs += (CACurrentMediaTime() - t0) * 1000
			if res.warmingUp { srLabel = "Warming SR..." }
			if let err = res.error { errorMsg = err }
			return res.buffer ?? pb
		}

		if cfg.frameGenMode == .off {
			state.endFrameGenSession()
			state.previousFrame = nil
			let out = maybeSuperRes(pixelBuffer, pts: ptsTicks)
			updateStatus(fgLabel: fgLabel, srLabel: srLabel, fgMs: 0, srMs: srMs, error: errorMsg)
			immediateHandler?(out)
			return
		}

		// Duplicate frame detection for 30 fps games streamed inside 60 fps containers (e.g. GTA 6)
		if cfg.deduplicateFrames && cfg.nominalSourceFPS >= 60,
			let prev = state.previousFrame,
			prev.width == width && prev.height == height,
			let diff = lumaDiff?.diff(previous: prev.rawBuffer, current: pixelBuffer),
			pacer.evaluateDuplicate(diffScore: diff, threshold: Self.duplicateThreshold, enabled: true) == .skipDuplicate
		{
			return
		}
		_ = pacer.evaluateDuplicate(diffScore: 1, threshold: Self.duplicateThreshold, enabled: false)

		let fgStatus = state.ensureFrameGenSession(width: width, height: height, format: format)
		fgLabel = fgStatus.status
		if let err = fgStatus.error, errorMsg == nil { errorMsg = err }

		let compatCurrent: CVPixelBuffer?
		if fgStatus.ready {
			compatCurrent = state.makeCompatibleInput(
				pixelBuffer,
				width: state.fgInputWidth,
				height: state.fgInputHeight,
				attributes: state.fgSourceAttrs,
				pool: state.fgSourcePool,
				transfer: state.fgTransfer
			)
		} else {
			compatCurrent = nil
		}

		let canInterpolate = fgStatus.ready
			&& compatCurrent != nil
			&& pacer.shouldInterpolate(arrivalTime: arrivalTime)
			&& state.previousFrame?.width == width
			&& state.previousFrame?.height == height
			&& state.previousFrame?.format == format

		let previousSnapshot = state.previousFrame
		if let compatCurrent {
			state.previousFrame = (
				rawBuffer: pixelBuffer,
				compatBuffer: compatCurrent,
				ptsTicks: ptsTicks,
				width: width,
				height: height,
				format: format
			)
		} else {
			state.previousFrame = nil
		}

		if canInterpolate, let prev = previousSnapshot, let currCompat = compatCurrent {
			let t0 = CACurrentMediaTime()
			let interp = state.runInterpolation(
				previous: prev.compatBuffer,
				previousPTSTicks: prev.ptsTicks,
				current: currCompat,
				currentPTSTicks: ptsTicks
			)
			fgMs = (CACurrentMediaTime() - t0) * 1000

			if interp.warmingUp { fgLabel = "Warming ML..." }
			if let err = interp.error { errorMsg = err }

			if let midRaw = interp.buffer {
				let midTicks = prev.ptsTicks + max(1, (ptsTicks - prev.ptsTicks) / 2)
				let finalMid = maybeSuperRes(midRaw, pts: midTicks)
				let finalReal = maybeSuperRes(pixelBuffer, pts: ptsTicks)
				updateStatus(fgLabel: fgLabel, srLabel: srLabel, fgMs: fgMs, srMs: srMs, error: errorMsg)
				pacer.enqueueInterpolatedPair(
					interpolated: finalMid,
					real: finalReal,
					sourceArrivalTime: arrivalTime,
					readyTime: CACurrentMediaTime()
				)
				return
			}
		}

		let finalReal = maybeSuperRes(pixelBuffer, pts: ptsTicks)
		updateStatus(fgLabel: fgLabel, srLabel: srLabel, fgMs: fgMs, srMs: srMs, error: errorMsg)
		pacer.enqueueRealFrame(finalReal, arrivalTime: arrivalTime)
	}
	#endif

	private func updateStatus(fgLabel: String, srLabel: String, fgMs: Double, srMs: Double, error: String?) {
		stateLock.lock()
		activeFrameGenLabel = fgLabel
		activeUpscalerLabel = srLabel
		lastFrameGenMs = fgMs
		lastUpscaleMs = srMs
		lastErrorMessage = error
		stateLock.unlock()
	}
}
