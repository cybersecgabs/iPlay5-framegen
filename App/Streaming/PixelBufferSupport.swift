import CoreGraphics
import CoreVideo
import Foundation
import simd

/// Pure CoreVideo / scaling geometry helpers shared by VideoEnhancer, MetalRenderer, and unit tests.
enum PixelBufferSupport {
	static func isTenBitPixelFormat(_ format: OSType) -> Bool {
		format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
			|| format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
	}

	static func extractSupportedPixelFormats(from attributes: [String: Any]) -> [OSType] {
		guard let raw = attributes[kCVPixelBufferPixelFormatTypeKey as String] else { return [] }
		if let single = extractOSType(raw) {
			return [single]
		}
		if let list = raw as? [Any] {
			return list.compactMap(extractOSType)
		}
		return []
	}

	static func isPixelFormatSupported(_ format: OSType, attributes: [String: Any]) -> Bool {
		let supported = extractSupportedPixelFormats(from: attributes)
		return supported.isEmpty || supported.contains(format)
	}

	static func isBufferCompatible(
		_ pixelBuffer: CVPixelBuffer,
		width: Int,
		height: Int,
		withAttributes attributes: [String: Any]
	) -> Bool {
		guard CVPixelBufferGetIOSurface(pixelBuffer) != nil else { return false }
		guard CVPixelBufferGetWidth(pixelBuffer) == width,
			CVPixelBufferGetHeight(pixelBuffer) == height
		else { return false }
		guard isPixelFormatSupported(CVPixelBufferGetPixelFormatType(pixelBuffer), attributes: attributes) else {
			return false
		}

		var left = 0
		var right = 0
		var top = 0
		var bottom = 0
		CVPixelBufferGetExtendedPixels(pixelBuffer, &left, &right, &top, &bottom)

		let checks: [(CFString, Int)] = [
			(kCVPixelBufferExtendedPixelsLeftKey, left),
			(kCVPixelBufferExtendedPixelsRightKey, right),
			(kCVPixelBufferExtendedPixelsTopKey, top),
			(kCVPixelBufferExtendedPixelsBottomKey, bottom),
		]
		for (key, actual) in checks {
			if let desired = (attributes[key as String] as? NSNumber)?.intValue, desired > 0, actual != desired {
				return false
			}
		}
		return true
	}

	static func resolvePoolAttributes(
		from attributes: [String: Any],
		preferredFormat: OSType,
		width: Int,
		height: Int
	) -> [String: Any] {
		var resolved = attributes
		let supported = extractSupportedPixelFormats(from: attributes)

		let chosenFormat: OSType
		if supported.isEmpty {
			chosenFormat = preferredFormat
		} else if supported.contains(preferredFormat) {
			chosenFormat = preferredFormat
		} else if isTenBitPixelFormat(preferredFormat) {
			if supported.contains(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
				chosenFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
			} else if supported.contains(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) {
				chosenFormat = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
			} else if supported.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
				chosenFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
			} else {
				chosenFormat = supported[0]
			}
		} else if supported.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
			chosenFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
		} else if supported.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
			chosenFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
		} else {
			chosenFormat = supported[0]
		}

		resolved[kCVPixelBufferPixelFormatTypeKey as String] = NSNumber(value: chosenFormat)
		resolved[kCVPixelBufferWidthKey as String] = width
		resolved[kCVPixelBufferHeightKey as String] = height
		resolved[kCVPixelBufferMetalCompatibilityKey as String] = true
		if resolved[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
			resolved[kCVPixelBufferIOSurfacePropertiesKey as String] = [:] as [String: Any]
		}
		return resolved
	}

	static func chooseBestScaleFactor(available: [Float], preferred: Float) -> Float? {
		let candidates = available.filter { $0 > 1.0 && $0.isFinite }
		guard !candidates.isEmpty else { return nil }
		if let exact = candidates.first(where: { abs($0 - preferred) <= 0.01 }) {
			return exact
		}
		return candidates.min { lhs, rhs in
			let dl = abs(lhs - preferred)
			let dr = abs(rhs - preferred)
			if abs(dl - dr) > 0.0001 {
				return dl < dr
			}
			return lhs < rhs
		}
	}

	struct ViewportGeometry: Equatable {
		let ndcScale: SIMD2<Float>
		let uvOrigin: SIMD2<Float>
		let uvSize: SIMD2<Float>
		let scale: Float
	}

	static func computeViewportGeometry(
		videoWidth: Int,
		videoHeight: Int,
		drawableSize: CGSize,
		zoomLevel: Double
	) -> ViewportGeometry {
		let fw = Float(videoWidth)
		let fh = Float(videoHeight)
		let tw = Float(drawableSize.width)
		let th = Float(drawableSize.height)
		let fitScale = min(tw / fw, th / fh)
		let fillScale = max(tw / fw, th / fh)
		let z = Float(min(max(zoomLevel, 0.0), 1.0))
		let scale: Float =
			if z <= 0 { fitScale }
			else if z >= 1 { fillScale }
			else { fitScale + (fillScale - fitScale) * z }
		let dw = fw * scale
		let dh = fh * scale
		let ndcScale = SIMD2<Float>(min(dw / tw, 1), min(dh / th, 1))
		let uvSize = SIMD2<Float>(min(tw / dw, 1), min(th / dh, 1))
		let uvOrigin = (SIMD2<Float>.one - uvSize) * 0.5
		return ViewportGeometry(ndcScale: ndcScale, uvOrigin: uvOrigin, uvSize: uvSize, scale: scale)
	}

	static func computeUpscaleTargetSize(
		inputWidth: Int,
		inputHeight: Int,
		drawableSize: CGSize,
		displayMode: DisplayMode
	) -> (width: Int, height: Int)? {
		computeUpscaleTargetSize(
			inputWidth: inputWidth,
			inputHeight: inputHeight,
			drawableSize: drawableSize,
			zoomLevel: displayMode == .fit ? 0.0 : 1.0
		)
	}

	static func computeUpscaleTargetSize(
		inputWidth: Int,
		inputHeight: Int,
		drawableSize: CGSize,
		zoomLevel: Double,
		upscalingMode: UpscalingMode
	) -> (width: Int, height: Int)? {
		switch upscalingMode {
		case .metalFX:
			computeUpscaleTargetSize(inputWidth: inputWidth, inputHeight: inputHeight, drawableSize: drawableSize, zoomLevel: zoomLevel)
		case .metalFX4K:
			computeMetalFX4KTargetSize(inputWidth: inputWidth, inputHeight: inputHeight)
		case .off, .bicubic, .vtSuperRes:
			nil
		}
	}

	static func computeMetalFX4KTargetSize(inputWidth: Int, inputHeight: Int) -> (width: Int, height: Int)? {
		guard inputWidth > 0, inputHeight > 0 else { return nil }
		let iw = Double(inputWidth)
		let ih = Double(inputHeight)
		let rawScale = min(3840.0 / iw, 2160.0 / ih)
		guard rawScale > 1.01 else { return nil }
		let scale = min(rawScale, 4.0)
		let outW = roundEven(iw * scale)
		let outH = roundEven(ih * scale)
		guard outW > inputWidth, outH > inputHeight else { return nil }
		return (outW, outH)
	}

	static func computeUpscaleTargetSize(
		inputWidth: Int,
		inputHeight: Int,
		drawableSize: CGSize,
		zoomLevel: Double
	) -> (width: Int, height: Int)? {
		guard inputWidth > 0, inputHeight > 0,
			drawableSize.width > 0, drawableSize.height > 0,
			drawableSize.width.isFinite, drawableSize.height.isFinite
		else { return nil }

		let iw = Double(inputWidth)
		let ih = Double(inputHeight)
		let tw = Double(drawableSize.width)
		let th = Double(drawableSize.height)

		let fitScale = min(tw / iw, th / ih)
		let fillScale = max(tw / iw, th / ih)
		let z = min(max(zoomLevel, 0.0), 1.0)
		let rawScale: Double =
			if z <= 0 { fitScale }
			else if z >= 1 { fillScale }
			else { fitScale + (fillScale - fitScale) * z }
		guard rawScale > 1.01 else { return nil }

		let scale = min(rawScale, 4.0)
		let outW = roundEven(iw * scale)
		let outH = roundEven(ih * scale)
		guard outW > inputWidth, outH > inputHeight else { return nil }
		return (outW, outH)
	}

	static func propagateColorAttachments(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
		CVBufferPropagateAttachments(source, destination)
	}

	// MARK: - Private

	private static func extractOSType(_ raw: Any) -> OSType? {
		if let value = raw as? UInt32 {
			return value
		}
		if let value = raw as? Int, value >= 0, value <= Int(UInt32.max) {
			return OSType(value)
		}
		if let number = raw as? NSNumber {
			return number.uint32Value
		}
		return nil
	}

	private static func roundEven(_ value: Double) -> Int {
		max(2, Int((value / 2.0).rounded()) * 2)
	}
}
