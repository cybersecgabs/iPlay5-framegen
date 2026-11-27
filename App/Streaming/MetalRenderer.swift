import CoreVideo
import Metal
#if !targetEnvironment(simulator)
import MetalFX
#endif
import QuartzCore
import UIKit
import simd

/// Must match RenderUniforms in Shaders.metal
private struct RenderUniforms {
	var ndcScale: SIMD2<Float>
	var uvOrigin: SIMD2<Float>
	var uvSize: SIMD2<Float>
	var lumaSize: SIMD2<Float>
	var matrix: Int32
	var transferMode: Int32
	var bicubic: Int32
	var fullRange: Int32
	var brightness: Float
	var contrast: Float
	var saturation: Float
	var gamma: Float
	var colorAdjust: Int32
	var sharpness: Float
}

/// Must match BlitUniforms in Shaders.metal
private struct BlitUniforms {
	var ndcScale: SIMD2<Float>
	var uvOrigin: SIMD2<Float>
	var uvSize: SIMD2<Float>
	var texSize: SIMD2<Float>
	var transferMode: Int32
	var colorAdjust: Int32
	var brightness: Float
	var contrast: Float
	var saturation: Float
	var gamma: Float
	var bt2020: Int32
	var sharpness: Float
	var downsample4K: Int32
}

struct RendererSnapshot: Equatable {
	var presentedFrames: Int = 0
	var activeUpscaler: String = "Off"
	var fallbackReason: String?
	var inputWidth: Int = 0
	var inputHeight: Int = 0
	var outputWidth: Int = 0
	var outputHeight: Int = 0
	var displayHz: Double = 0
}

/// Draws decoded (or enhanced) YCbCr frames into a CAMetalLayer, optionally
/// routing through MetalFX Spatial Upscaling inside a single command buffer.
///
/// SDR uses an 8-bit BT.709 layer. HDR uses a 10-bit BT.2100 PQ layer with EDR
/// enabled, so the PS5's PQ signal goes to the display untouched and iOS
/// handles the tone mapping for the panel.
final class MetalRenderer {
	let device: MTLDevice
	private let queue: MTLCommandQueue
	private let pipelineSDR: MTLRenderPipelineState
	private let pipelineHDR: MTLRenderPipelineState
	private let pipelineHDR16F: MTLRenderPipelineState
	private let pipelineBlitSDR: MTLRenderPipelineState
	private let pipelineBlitHDR: MTLRenderPipelineState
	private var textureCache: CVMetalTextureCache?

	private let lock = NSLock()
	private let renderLock = NSLock()
	private weak var layer: CAMetalLayer?
	private var drawableSize: CGSize = .zero
	private var hdrOutput = false
	private var displayMode: DisplayMode = .fit
	private var zoomLevel: Double = 0.0
	private var upscalingMode: UpscalingMode = .metalFX
	private var colorAdjustments: ColorAdjustments = .neutral
	private var paused = false

	// Stats protected by lock
	private var _presentedFrames = 0
	private var _activeUpscaler = "Off"
	private var _fallbackReason: String?
	private var _inputWidth = 0
	private var _inputHeight = 0
	private var _outputWidth = 0
	private var _outputHeight = 0
	private var _displayHz: Double = 0

	#if !targetEnvironment(simulator)
	private struct MetalFXKey: Equatable {
		let inW: Int
		let inH: Int
		let outW: Int
		let outH: Int
		let drawableFormat: MTLPixelFormat
	}

	// MetalFX cached resources (protected by renderLock)
	private var metalFXKey: MetalFXKey?
	private var spatialScaler: MTLFXSpatialScaler?
	private var metalFXInputTex: MTLTexture?
	private var metalFXOutputTex: MTLTexture?
	#endif

	var presentedFrames: Int { lock.withLock { _presentedFrames } }
	var displayHz: Double {
		get { lock.withLock { _displayHz } }
		set { lock.withLock { _displayHz = newValue } }
	}

	func snapshot() -> RendererSnapshot {
		lock.withLock {
			RendererSnapshot(
				presentedFrames: _presentedFrames,
				activeUpscaler: _activeUpscaler,
				fallbackReason: _fallbackReason,
				inputWidth: _inputWidth,
				inputHeight: _inputHeight,
				outputWidth: _outputWidth,
				outputHeight: _outputHeight,
				displayHz: _displayHz
			)
		}
	}

	init?() {
		guard let device = MTLCreateSystemDefaultDevice(),
			let queue = device.makeCommandQueue(),
			let library = device.makeDefaultLibrary()
		else { return nil }
		self.device = device
		self.queue = queue

		func makePipeline(vertex: String, fragment: String, format: MTLPixelFormat) -> MTLRenderPipelineState? {
			let desc = MTLRenderPipelineDescriptor()
			desc.vertexFunction = library.makeFunction(name: vertex)
			desc.fragmentFunction = library.makeFunction(name: fragment)
			desc.colorAttachments[0].pixelFormat = format
			return try? device.makeRenderPipelineState(descriptor: desc)
		}

		guard let sdr = makePipeline(vertex: "stream_vertex", fragment: "stream_fragment", format: .bgra8Unorm),
			let hdr = makePipeline(vertex: "stream_vertex", fragment: "stream_fragment", format: .bgr10a2Unorm),
			let hdr16f = makePipeline(vertex: "stream_vertex", fragment: "stream_fragment", format: .rgba16Float),
			let blitSDR = makePipeline(vertex: "blit_vertex", fragment: "blit_fragment", format: .bgra8Unorm),
			let blitHDR = makePipeline(vertex: "blit_vertex", fragment: "blit_fragment", format: .bgr10a2Unorm)
		else { return nil }

		pipelineSDR = sdr
		pipelineHDR = hdr
		pipelineHDR16F = hdr16f
		pipelineBlitSDR = blitSDR
		pipelineBlitHDR = blitHDR
		CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
	}

	// MARK: - Configuration (main thread)

	func attach(_ layer: CAMetalLayer) {
		layer.device = device
		layer.framebufferOnly = true
		layer.maximumDrawableCount = 3
		layer.isOpaque = true
		layer.backgroundColor = UIColor.black.cgColor
		lock.withLock { self.layer = layer }
		applyOutputMode(to: layer)
	}

	func configure(
		hdr: Bool,
		displayMode: DisplayMode,
		upscalingMode: UpscalingMode,
		zoomLevel: Double? = nil,
		colorAdjustments: ColorAdjustments = .neutral
	) {
		let clampedColor = colorAdjustments.clamped
		let resolvedZoom = min(max(zoomLevel ?? (displayMode == .zoom ? 1.0 : 0.0), 0.0), 1.0)
		let changed = lock.withLock { () -> Bool in
			let changed = self.hdrOutput != hdr
			self.hdrOutput = hdr
			self.displayMode = displayMode
			self.zoomLevel = resolvedZoom
			self.upscalingMode = upscalingMode
			self.colorAdjustments = clampedColor
			if !upscalingMode.usesMetalFX {
				_fallbackReason = nil
			}
			return changed
		}
		if changed, let layer = lock.withLock({ self.layer }) {
			applyOutputMode(to: layer)
		}
	}

	func setDisplayMode(_ mode: DisplayMode) {
		lock.withLock {
			displayMode = mode
			zoomLevel = mode == .zoom ? 1.0 : 0.0
		}
	}

	func setZoomLevel(_ zoom: Double) {
		let clamped = min(max(zoom, 0.0), 1.0)
		lock.withLock {
			zoomLevel = clamped
			displayMode = clamped >= 0.5 ? .zoom : .fit
		}
	}

	func setColorAdjustments(_ adjustments: ColorAdjustments) {
		let clamped = adjustments.clamped
		lock.withLock { colorAdjustments = clamped }
	}

	func setPaused(_ paused: Bool) {
		lock.withLock { self.paused = paused }
	}

	func setDrawableSize(_ size: CGSize) {
		lock.withLock {
			drawableSize = size
			layer?.drawableSize = size
		}
	}

	private func applyOutputMode(to layer: CAMetalLayer) {
		let hdr = lock.withLock { hdrOutput }
		if hdr {
			layer.pixelFormat = .bgr10a2Unorm
			layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
			layer.wantsExtendedDynamicRangeContent = true
			// PS5 doesn't send mastering metadata over Remote Play; typical HDR10 values
			layer.edrMetadata = CAEDRMetadata.hdr10(minLuminance: 0.005, maxLuminance: 1000, opticalOutputScale: 100)
		} else {
			layer.pixelFormat = .bgra8Unorm
			layer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
			layer.wantsExtendedDynamicRangeContent = false
			layer.edrMetadata = nil
		}
	}

	// MARK: - Rendering (decoder thread or CADisplayLink main thread)

	func display(_ pixelBuffer: CVPixelBuffer) {
		lock.lock()
		let layer = self.layer
		let target = drawableSize
		let hdr = hdrOutput
		let zoom = zoomLevel
		let upscaling = upscalingMode
		let color = colorAdjustments
		let paused = self.paused
		lock.unlock()

		guard !paused, let layer, target.width > 0, target.height > 0, let cache = textureCache else { return }

		renderLock.lock()
		defer { renderLock.unlock() }

		CVMetalTextureCacheFlush(cache, 0)

		if !CVPixelBufferIsPlanar(pixelBuffer) {
			displayPackedBuffer(pixelBuffer, layer: layer, target: target, zoom: zoom, upscaling: upscaling, color: color, cache: cache)
			return
		}

		let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
		let tenBit = PixelBufferSupport.isTenBitPixelFormat(pixelFormat)
		let fullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
			|| pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange

		guard let luma = makeTexture(pixelBuffer, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm, cache: cache),
			let chroma = makeTexture(pixelBuffer, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm, cache: cache),
			let lumaTex = CVMetalTextureGetTexture(luma),
			let chromaTex = CVMetalTextureGetTexture(chroma)
		else { return }

		// Colour metadata from the stream
		let transfer = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String
		let matrixKey = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
		let framePQ = transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
		let bt2020 = matrixKey == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) || framePQ

		let transferMode: Int32 =
			switch (framePQ, hdr) {
			case (true, true), (false, false): 0
			case (false, true): 1
			case (true, false): 2
			}

		// Fit / zoom geometry
		let videoW = lumaTex.width
		let videoH = lumaTex.height
		let geo = PixelBufferSupport.computeViewportGeometry(videoWidth: videoW, videoHeight: videoH, drawableSize: target, zoomLevel: zoom)
		let ndcScale = geo.ndcScale
		let uvOrigin = geo.uvOrigin
		let uvSize = geo.uvSize
		let scale = geo.scale

		guard let drawable = layer.nextDrawable(), let commandBuffer = queue.makeCommandBuffer() else { return }
		let drawableFormat = drawable.texture.pixelFormat
		let colorEnabled: Int32 = color.hasColorGrading ? 1 : 0
		let brightness = Float(color.brightness)
		let contrast = Float(color.contrast)
		let saturation = Float(color.saturation)
		let gamma = Float(color.gamma)
		let sharpness = Float(color.sharpness)

		#if !targetEnvironment(simulator)
		if upscaling.usesMetalFX,
			MTLFXSpatialScalerDescriptor.supportsDevice(device),
			let targetSize = PixelBufferSupport.computeUpscaleTargetSize(
				inputWidth: videoW,
				inputHeight: videoH,
				drawableSize: target,
				zoomLevel: zoom,
				upscalingMode: upscaling
			)
		{
			let is4K = upscaling == .metalFX4K
			let resources = ensureMetalFXResources(
				inputWidth: videoW,
				inputHeight: videoH,
				outputWidth: targetSize.width,
				outputHeight: targetSize.height,
				drawableFormat: drawableFormat
			)
			if let scaler = resources.scaler, let inTex = resources.inTex, let outTex = resources.outTex {
				var pass1Uniforms = RenderUniforms(
					ndcScale: .one,
					uvOrigin: .zero,
					uvSize: .one,
					lumaSize: SIMD2(Float(videoW), Float(videoH)),
					matrix: bt2020 ? 1 : 0,
					transferMode: transferMode,
					bicubic: 0,
					fullRange: fullRange ? 1 : 0,
					brightness: brightness,
					contrast: contrast,
					saturation: saturation,
					gamma: gamma,
					colorAdjust: colorEnabled,
					sharpness: 0
				)
				let pass1 = MTLRenderPassDescriptor()
				pass1.colorAttachments[0].texture = inTex
				pass1.colorAttachments[0].loadAction = .dontCare
				pass1.colorAttachments[0].storeAction = .store
				guard let enc1 = commandBuffer.makeRenderCommandEncoder(descriptor: pass1) else { return }
				enc1.setRenderPipelineState(ycbcrPipeline(for: inTex.pixelFormat))
				enc1.setVertexBytes(&pass1Uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
				enc1.setFragmentBytes(&pass1Uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
				enc1.setFragmentTexture(lumaTex, index: 0)
				enc1.setFragmentTexture(chromaTex, index: 1)
				enc1.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
				enc1.endEncoding()

				scaler.colorTexture = inTex
				scaler.outputTexture = outTex
				scaler.inputContentWidth = videoW
				scaler.inputContentHeight = videoH
				scaler.encode(commandBuffer: commandBuffer)

				var blitUniforms = BlitUniforms(
					ndcScale: ndcScale,
					uvOrigin: uvOrigin,
					uvSize: uvSize,
					texSize: SIMD2(Float(outTex.width), Float(outTex.height)),
					transferMode: 0,
					colorAdjust: 0,
					brightness: 0,
					contrast: 1,
					saturation: 1,
					gamma: 1,
					bt2020: 0,
					sharpness: sharpness,
					downsample4K: is4K ? 1 : 0
				)
				let pass3 = MTLRenderPassDescriptor()
				pass3.colorAttachments[0].texture = drawable.texture
				pass3.colorAttachments[0].loadAction = .clear
				pass3.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
				pass3.colorAttachments[0].storeAction = .store
				guard let enc3 = commandBuffer.makeRenderCommandEncoder(descriptor: pass3) else { return }
				enc3.setRenderPipelineState(drawableFormat == .bgr10a2Unorm ? pipelineBlitHDR : pipelineBlitSDR)
				enc3.setVertexBytes(&blitUniforms, length: MemoryLayout<BlitUniforms>.stride, index: 0)
				enc3.setFragmentBytes(&blitUniforms, length: MemoryLayout<BlitUniforms>.stride, index: 0)
				enc3.setFragmentTexture(outTex, index: 0)
				enc3.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
				enc3.endEncoding()

				commandBuffer.addCompletedHandler { _ in
					_ = luma
					_ = chroma
				}
				commandBuffer.present(drawable)
				commandBuffer.commit()

				recordPresentation(
					upscaler: "\(is4K ? "MetalFX 4K" : "MetalFX") \(videoW)x\(videoH)→\(targetSize.width)x\(targetSize.height)",
					fallback: nil,
					inW: videoW,
					inH: videoH,
					outW: targetSize.width,
					outH: targetSize.height
				)
				return
			}
		}
		#endif

		// Single-pass render (Off, Catmull-Rom, pre-upscaled VT Super Res, or MetalFX fallback)
		let useBicubic = (upscaling == .bicubic || upscaling.usesMetalFX) && scale > 1.01
		var uniforms = RenderUniforms(
			ndcScale: ndcScale,
			uvOrigin: uvOrigin,
			uvSize: uvSize,
			lumaSize: SIMD2(Float(videoW), Float(videoH)),
			matrix: bt2020 ? 1 : 0,
			transferMode: transferMode,
			bicubic: useBicubic ? 1 : 0,
			fullRange: fullRange ? 1 : 0,
			brightness: brightness,
			contrast: contrast,
			saturation: saturation,
			gamma: gamma,
			colorAdjust: colorEnabled,
			sharpness: sharpness
		)

		let pass = MTLRenderPassDescriptor()
		pass.colorAttachments[0].texture = drawable.texture
		pass.colorAttachments[0].loadAction = .clear
		pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
		pass.colorAttachments[0].storeAction = .store

		guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
		encoder.setRenderPipelineState(drawableFormat == .bgr10a2Unorm ? pipelineHDR : pipelineSDR)
		encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
		encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
		encoder.setFragmentTexture(lumaTex, index: 0)
		encoder.setFragmentTexture(chromaTex, index: 1)
		encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
		encoder.endEncoding()

		commandBuffer.addCompletedHandler { _ in
			_ = luma
			_ = chroma
		}
		commandBuffer.present(drawable)
		commandBuffer.commit()

		let label: String
		let fallback: String?
		if upscaling.usesMetalFX && scale <= 1.01 {
			label = "Native 1:1"
			fallback = nil
		} else if upscaling.usesMetalFX {
			label = "Catmull-Rom (MetalFX fallback)"
			fallback = lock.withLock { _fallbackReason }
		} else if useBicubic {
			label = "Catmull-Rom"
			fallback = nil
		} else if upscaling == .vtSuperRes {
			label = "VT Super Res"
			fallback = nil
		} else {
			label = "Bilinear"
			fallback = nil
		}

		recordPresentation(
			upscaler: label,
			fallback: fallback,
			inW: videoW,
			inH: videoH,
			outW: drawable.texture.width,
			outH: drawable.texture.height
		)
	}

	private func displayPackedBuffer(
		_ pixelBuffer: CVPixelBuffer,
		layer: CAMetalLayer,
		target: CGSize,
		zoom: Double,
		upscaling: UpscalingMode,
		color: ColorAdjustments,
		cache: CVMetalTextureCache
	) {
		let cvFmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
		let mtlFormat: MTLPixelFormat
		switch cvFmt {
		case kCVPixelFormatType_32BGRA:
			mtlFormat = .bgra8Unorm
		case kCVPixelFormatType_64RGBAHalf:
			mtlFormat = .rgba16Float
		default:
			return
		}

		guard let texRef = makeTexture(pixelBuffer, plane: 0, format: mtlFormat, cache: cache),
			let srcTex = CVMetalTextureGetTexture(texRef),
			let drawable = layer.nextDrawable(),
			let commandBuffer = queue.makeCommandBuffer()
		else { return }

		let videoW = srcTex.width
		let videoH = srcTex.height
		let geo = PixelBufferSupport.computeViewportGeometry(videoWidth: videoW, videoHeight: videoH, drawableSize: target, zoomLevel: zoom)
		let ndcScale = geo.ndcScale
		let uvOrigin = geo.uvOrigin
		let uvSize = geo.uvSize
		let drawableFormat = drawable.texture.pixelFormat

		var texToBlit: MTLTexture = srcTex
		var label: String
		switch upscaling {
		case .vtSuperRes: label = "VT Super Res"
		case .bicubic: label = "Linear (packed)"
		default: label = "Bilinear"
		}
		var outW = drawable.texture.width
		var outH = drawable.texture.height
		var didDownsample4K = false

		#if !targetEnvironment(simulator)
		if upscaling.usesMetalFX,
			MTLFXSpatialScalerDescriptor.supportsDevice(device),
			let targetSize = PixelBufferSupport.computeUpscaleTargetSize(
				inputWidth: videoW,
				inputHeight: videoH,
				drawableSize: target,
				zoomLevel: zoom,
				upscalingMode: upscaling
			)
		{
			let is4K = upscaling == .metalFX4K
			let res = ensureMetalFXResources(
				inputWidth: videoW,
				inputHeight: videoH,
				outputWidth: targetSize.width,
				outputHeight: targetSize.height,
				drawableFormat: mtlFormat
			)
			if let scaler = res.scaler, let outTex = res.outTex,
				outTex.pixelFormat == mtlFormat,
				srcTex.usage.contains(scaler.colorTextureUsage)
			{
				scaler.colorTexture = srcTex
				scaler.outputTexture = outTex
				scaler.inputContentWidth = videoW
				scaler.inputContentHeight = videoH
				scaler.encode(commandBuffer: commandBuffer)
				texToBlit = outTex
				didDownsample4K = is4K
				label = "\(is4K ? "MetalFX 4K" : "MetalFX") \(videoW)x\(videoH)→\(targetSize.width)x\(targetSize.height)"
				outW = targetSize.width
				outH = targetSize.height
			}
		}
		#endif

		let blitTransferMode: Int32 = (drawableFormat == .bgr10a2Unorm && mtlFormat == .bgra8Unorm) ? 1 : 0
		let colorEnabled: Int32 = color.hasColorGrading ? 1 : 0
		let isBT2020: Int32 = (drawableFormat == .bgr10a2Unorm && blitTransferMode == 0) ? 1 : 0
		var blitUniforms = BlitUniforms(
			ndcScale: ndcScale,
			uvOrigin: uvOrigin,
			uvSize: uvSize,
			texSize: SIMD2(Float(texToBlit.width), Float(texToBlit.height)),
			transferMode: blitTransferMode,
			colorAdjust: colorEnabled,
			brightness: Float(color.brightness),
			contrast: Float(color.contrast),
			saturation: Float(color.saturation),
			gamma: Float(color.gamma),
			bt2020: isBT2020,
			sharpness: Float(color.sharpness),
			downsample4K: didDownsample4K ? 1 : 0
		)
		let pass = MTLRenderPassDescriptor()
		pass.colorAttachments[0].texture = drawable.texture
		pass.colorAttachments[0].loadAction = .clear
		pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
		pass.colorAttachments[0].storeAction = .store
		guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
		encoder.setRenderPipelineState(drawableFormat == .bgr10a2Unorm ? pipelineBlitHDR : pipelineBlitSDR)
		encoder.setVertexBytes(&blitUniforms, length: MemoryLayout<BlitUniforms>.stride, index: 0)
		encoder.setFragmentBytes(&blitUniforms, length: MemoryLayout<BlitUniforms>.stride, index: 0)
		encoder.setFragmentTexture(texToBlit, index: 0)
		encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
		encoder.endEncoding()

		commandBuffer.addCompletedHandler { _ in _ = texRef }
		commandBuffer.present(drawable)
		commandBuffer.commit()
		recordPresentation(upscaler: label, fallback: nil, inW: videoW, inH: videoH, outW: outW, outH: outH)
	}

	private func ycbcrPipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState {
		switch format {
		case .bgr10a2Unorm: pipelineHDR
		case .rgba16Float: pipelineHDR16F
		default: pipelineSDR
		}
	}

	#if !targetEnvironment(simulator)
	private func ensureMetalFXResources(
		inputWidth: Int,
		inputHeight: Int,
		outputWidth: Int,
		outputHeight: Int,
		drawableFormat: MTLPixelFormat
	) -> (scaler: MTLFXSpatialScaler?, inTex: MTLTexture?, outTex: MTLTexture?) {
		let key = MetalFXKey(inW: inputWidth, inH: inputHeight, outW: outputWidth, outH: outputHeight, drawableFormat: drawableFormat)
		if key == metalFXKey {
			return (spatialScaler, metalFXInputTex, metalFXOutputTex)
		}

		metalFXKey = key
		spatialScaler = nil
		metalFXInputTex = nil
		metalFXOutputTex = nil

		let candidates: [MTLPixelFormat]
		switch drawableFormat {
		case .bgr10a2Unorm: candidates = [.rgba16Float, .bgr10a2Unorm]
		case .rgba16Float: candidates = [.rgba16Float]
		default: candidates = [.bgra8Unorm]
		}
		for fmt in candidates {
			let desc = MTLFXSpatialScalerDescriptor()
			desc.inputWidth = inputWidth
			desc.inputHeight = inputHeight
			desc.outputWidth = outputWidth
			desc.outputHeight = outputHeight
			desc.colorTextureFormat = fmt
			desc.outputTextureFormat = fmt
			desc.colorProcessingMode = .perceptual
			guard let scaler = desc.makeSpatialScaler(device: device) else { continue }

			let inDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: inputWidth, height: inputHeight, mipmapped: false)
			inDesc.storageMode = .private
			inDesc.hazardTrackingMode = .tracked
			inDesc.usage = scaler.colorTextureUsage.union([.renderTarget, .shaderRead])

			let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: outputWidth, height: outputHeight, mipmapped: false)
			outDesc.storageMode = .private
			outDesc.hazardTrackingMode = .tracked
			outDesc.usage = scaler.outputTextureUsage.union([.shaderRead])

			guard let inTex = device.makeTexture(descriptor: inDesc),
				let outTex = device.makeTexture(descriptor: outDesc)
			else { continue }

			spatialScaler = scaler
			metalFXInputTex = inTex
			metalFXOutputTex = outTex
			lock.withLock { _fallbackReason = nil }
			return (scaler, inTex, outTex)
		}

		lock.withLock {
			_fallbackReason = "MetalFX scaler unavailable for \(inputWidth)x\(inputHeight)→\(outputWidth)x\(outputHeight)"
		}
		return (nil, nil, nil)
	}
	#endif

	private func recordPresentation(upscaler: String, fallback: String?, inW: Int, inH: Int, outW: Int, outH: Int) {
		lock.withLock {
			_presentedFrames += 1
			_activeUpscaler = upscaler
			if let fallback { _fallbackReason = fallback }
			_inputWidth = inW
			_inputHeight = inH
			_outputWidth = outW
			_outputHeight = outH
		}
	}

	private func makeTexture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache) -> CVMetalTexture? {
		let w: Int
		let h: Int
		if CVPixelBufferIsPlanar(pb) {
			w = CVPixelBufferGetWidthOfPlane(pb, plane)
			h = CVPixelBufferGetHeightOfPlane(pb, plane)
		} else {
			w = CVPixelBufferGetWidth(pb)
			h = CVPixelBufferGetHeight(pb)
		}
		var texture: CVMetalTexture?
		let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, format, w, h, plane, &texture)
		return status == kCVReturnSuccess ? texture : nil
	}
}

private final class DisplayLinkProxy {
	weak var target: StreamMetalView?
	init(_ target: StreamMetalView) { self.target = target }
	@objc func tick(_ link: CADisplayLink) {
		target?.handleDisplayLink(link)
	}
}

/// UIView backed by a CAMetalLayer at the screen's native pixel density.
/// Routes multi-touch input between on-screen virtual controls (when shown),
/// DualSense touchpad gestures, and the top-left / top-right hot corners.
final class StreamMetalView: UIView {
	private let metalLayer = CAMetalLayer()

	let renderer: MetalRenderer

	/// Touch down/move/up in touchpad coordinates. Screen touches use slots 10 and 11.
	var onTouch: ((ControllerInput.TouchEvent) -> Void)?
	/// A quick tap that didn't move: sent instead of `.up` so it can become a click.
	var onTap: ((Int) -> Void)?
	/// Top-right hot corner (settings / Quick Tuning)
	var onCornerTap: (() -> Void)?
	/// Top-left hot corner (PS button)
	var onLeftCornerTap: (() -> Void)?
	var onVirtualPad: ((VirtualPadState) -> Void)?
	var onReset: (() -> Void)?
	var videoAspectForLetterbox: CGFloat? {
		didSet { if videoAspectForLetterbox != oldValue { setNeedsLayout() } }
	}
	/// Called on every CADisplayLink tick with (targetTimestamp, vsyncIntervalSeconds)
	var onDisplayTick: ((Double, Double) -> Void)?

	private var acceptsInput = false
	private let controls = VirtualControlsOverlay(frame: .zero)
	private var controlsArea = CGRect.null
	private var systemButtonY: CGFloat?

	/// Hot corner size in points, at the top-right and top-left of the view
	static let cornerSize = CGSize(width: 140, height: 90)
	private static let tapMaxDuration: TimeInterval = 0.35
	private static let tapMaxMovement: CGFloat = 20

	private struct Tracked {
		let slot: Int
		let start: CGPoint
		let time: TimeInterval
		var moved = false
	}
	private var tracked: [ObjectIdentifier: Tracked] = [:]

	/// Ask a ProMotion screen for 120 Hz while this view is on screen
	var highRefresh = true {
		didSet { if highRefresh != oldValue { updateDisplayLink() } }
	}
	/// Keep CADisplayLink active even on 60 Hz panels when Frame Generation needs pacing
	var frameGenActive = false {
		didSet { if frameGenActive != oldValue { updateDisplayLink() } }
	}
	private var displayLink: CADisplayLink?
	private var displayLinkProxy: DisplayLinkProxy?

	init(renderer: MetalRenderer) {
		self.renderer = renderer
		super.init(frame: .zero)
		backgroundColor = .black
		isMultipleTouchEnabled = true
		controls.isHidden = true
		layer.addSublayer(metalLayer)
		addSubview(controls)
		renderer.attach(metalLayer)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	deinit {
		stopDisplayLink()
	}

	// MARK: Refresh rate

	override func didMoveToWindow() {
		super.didMoveToWindow()
		if window == nil { resetTouches() }
		updateDisplayLink()
	}

	func stopDisplayLink() {
		displayLink?.invalidate()
		displayLink = nil
		displayLinkProxy = nil
		renderer.displayHz = 0
	}

	/// Frames are drawn immediately when Frame Gen is off, or paced cleanly on
	/// vsync ticks when Frame Gen is active. The display link also keeps ProMotion
	/// at 120 Hz and reports real panel Hz.
	private func updateDisplayLink() {
		stopDisplayLink()
		guard let window, (highRefresh || frameGenActive) else { return }
		let maxFPS = Float(window.screen.maximumFramesPerSecond)
		guard frameGenActive || (highRefresh && maxFPS > 60) else { return }
		let proxy = DisplayLinkProxy(self)
		let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
		let targetHz: Float
		if highRefresh && maxFPS > 60 {
			link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, maxFPS), maximum: maxFPS, preferred: maxFPS)
			targetHz = maxFPS
		} else {
			link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
			targetHz = 60
		}
		link.add(to: .main, forMode: .common)
		displayLinkProxy = proxy
		displayLink = link
		log.notice("Display link active at up to \(Int(targetHz)) Hz (frameGen: \(self.frameGenActive))")
	}

	fileprivate func handleDisplayLink(_ link: CADisplayLink) {
		let frame = link.targetTimestamp - link.timestamp
		if frame > 0 { renderer.displayHz = (1 / frame).rounded() }
		let maxFPS = Double(max(window?.screen.maximumFramesPerSecond ?? 60, 60))
		let vsyncInterval = frame > 0 ? frame : (1.0 / maxFPS)
		onDisplayTick?(link.targetTimestamp, vsyncInterval)
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		// Native scale: render at the panel's real resolution, not the UIKit point scale
		let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
		contentScaleFactor = scale
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		metalLayer.frame = bounds
		metalLayer.contentsScale = scale
		let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
		renderer.setDrawableSize(size)
		CATransaction.commit()
		let area = bounds.inset(by: safeAreaInsets)
		let buttonY = bottomSystemButtonY(in: area)
		if controls.frame != bounds || controlsArea != area || systemButtonY != buttonY {
			resetTouches()
			controlsArea = area
			systemButtonY = buttonY
			controls.frame = bounds
			controls.setLayout(in: area, systemButtonY: buttonY)
		}
	}

	private func bottomSystemButtonY(in safeArea: CGRect) -> CGFloat {
		let halfHeight = VirtualControlsOverlay.systemButtonHeight / 2
		if let aspect = videoAspectForLetterbox, aspect > 0 {
			let videoBottom = bounds.midY + bounds.width / aspect / 2
			let firstCentreInBar = videoBottom + halfHeight + 4
			let lastCentreInBar = bounds.maxY - halfHeight - 12
			if firstCentreInBar <= lastCentreInBar {
				let preferredCentre = (videoBottom + safeArea.maxY) / 2
				return min(max(preferredCentre, firstCentreInBar), lastCentreInBar)
			}
		}
		return safeArea.maxY - halfHeight - 4
	}

	override func safeAreaInsetsDidChange() {
		super.safeAreaInsetsDidChange()
		setNeedsLayout()
	}

	/// Size, opacity and stick behaviour. A change lets go of anything held, since the layout moves.
	func setControlsStyle(_ style: VirtualControlsStyle) {
		guard controls.style != style else { return }
		resetTouches()
		controls.style = style
	}

	func setInputMode(acceptsInput: Bool, virtualControls: Bool) {
		let hideControls = !acceptsInput || !virtualControls
		guard self.acceptsInput != acceptsInput || controls.isHidden != hideControls else { return }
		resetTouches()
		self.acceptsInput = acceptsInput
		controls.isHidden = hideControls
	}

	private func resetTouches() {
		tracked.removeAll()
		controls.reset()
		onReset?()
	}

	// MARK: Touchpad & Virtual Controls

	private var shortcutSize: CGSize {
		controls.isHidden ? Self.cornerSize : CGSize(width: 84, height: 52)
	}

	private var cornerRect: CGRect {
		let size = shortcutSize
		return CGRect(x: bounds.maxX - size.width, y: bounds.minY, width: size.width, height: size.height)
	}

	private var leftCornerRect: CGRect {
		let size = shortcutSize
		return CGRect(x: bounds.minX, y: bounds.minY, width: size.width, height: size.height)
	}

	/// With virtual controls, the upper half maps to the whole DualSense touchpad and the
	/// lower half is left for sticks and buttons. Otherwise, the whole picture is the touchpad.
	private var touchpadRect: CGRect {
		guard controls.isHidden else {
			return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height / 2)
		}
		return videoRect
	}

	private var videoRect: CGRect {
		guard let aspect = videoAspectForLetterbox, aspect > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
		if bounds.width / bounds.height > aspect {
			let width = bounds.height * aspect
			return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
		}
		let height = bounds.width / aspect
		return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
	}

	private func startsTouchpadTouch(at p: CGPoint) -> Bool {
		controls.isHidden ? bounds.contains(p) : touchpadRect.contains(p)
	}

	private func touchpadPoint(_ p: CGPoint) -> (UInt16, UInt16) {
		let area = touchpadRect
		guard area.width > 0, area.height > 0 else { return (0, 0) }
		let nx = min(max((p.x - area.minX) / area.width, 0), 1)
		let ny = min(max((p.y - area.minY) / area.height, 0), 1)
		return (UInt16((nx * 1919).rounded()), UInt16((ny * 1079).rounded()))
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		guard acceptsInput else { return }
		for touch in touches {
			let p = touch.location(in: self)
			if cornerRect.contains(p) {
				onCornerTap?()
				continue
			}
			if leftCornerRect.contains(p) {
				onLeftCornerTap?()
				continue
			}
			let inTouchpad = startsTouchpadTouch(at: p)
			if !controls.isHidden {
				let key = ObjectIdentifier(touch)
				let result = controls.begin(key, at: p, allowsStick: !inTouchpad)
				if let state = result.state { onVirtualPad?(state) }
				if result.handled { continue }
			}
			guard inTouchpad else { continue }
			let used = Set(tracked.values.map(\.slot))
			guard let slot = [10, 11].first(where: { !used.contains($0) }) else { continue }
			tracked[ObjectIdentifier(touch)] = Tracked(slot: slot, start: p, time: touch.timestamp)
			let (x, y) = touchpadPoint(p)
			onTouch?(.down(slot: slot, x: x, y: y))
		}
	}

	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			let key = ObjectIdentifier(touch)
			let p = touch.location(in: self)
			guard var t = tracked[key] else {
				if let state = controls.move(key, to: p) { onVirtualPad?(state) }
				continue
			}
			if !t.moved, hypot(p.x - t.start.x, p.y - t.start.y) > Self.tapMaxMovement {
				t.moved = true
				tracked[key] = t
			}
			let (x, y) = touchpadPoint(p)
			onTouch?(.move(slot: t.slot, x: x, y: y))
		}
	}

	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		finishTouches(touches, allowsTap: true)
	}

	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		finishTouches(touches, allowsTap: false)
	}

	private func finishTouches(_ touches: Set<UITouch>, allowsTap: Bool) {
		for touch in touches {
			let key = ObjectIdentifier(touch)
			guard let t = tracked.removeValue(forKey: key) else {
				if let state = controls.end(key) { onVirtualPad?(state) }
				continue
			}
			if allowsTap, !t.moved, touch.timestamp - t.time <= Self.tapMaxDuration {
				onTap?(t.slot)
			} else {
				onTouch?(.up(slot: t.slot))
			}
		}
	}
}
