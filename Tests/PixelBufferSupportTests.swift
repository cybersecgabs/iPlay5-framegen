import CoreVideo
import XCTest
@testable import iPlay5

final class PixelBufferSupportTests: XCTestCase {
	func testTenBitFormatDetection() {
		XCTAssertTrue(PixelBufferSupport.isTenBitPixelFormat(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange))
		XCTAssertTrue(PixelBufferSupport.isTenBitPixelFormat(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange))
		XCTAssertFalse(PixelBufferSupport.isTenBitPixelFormat(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
		XCTAssertFalse(PixelBufferSupport.isTenBitPixelFormat(kCVPixelFormatType_32BGRA))
	}

	func testExtractSupportedPixelFormatsHandlesSingleAndArray() {
		let singleAttrs: [String: Any] = [
			kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
		]
		XCTAssertEqual(
			PixelBufferSupport.extractSupportedPixelFormats(from: singleAttrs),
			[kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
		)

		let arrayAttrs: [String: Any] = [
			kCVPixelBufferPixelFormatTypeKey as String: [
				NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
				NSNumber(value: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
			],
		]
		XCTAssertEqual(
			PixelBufferSupport.extractSupportedPixelFormats(from: arrayAttrs),
			[kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
		)
	}

	func testResolvePoolAttributesResolvesArrayAndMetalFlags() {
		let attrs: [String: Any] = [
			kCVPixelBufferPixelFormatTypeKey as String: [
				NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
				NSNumber(value: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
			],
		]

		let resolved10 = PixelBufferSupport.resolvePoolAttributes(
			from: attrs,
			preferredFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
			width: 1920,
			height: 1080
		)
		XCTAssertEqual(
			(resolved10[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value,
			kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
		)
		XCTAssertEqual(resolved10[kCVPixelBufferWidthKey as String] as? Int, 1920)
		XCTAssertEqual(resolved10[kCVPixelBufferHeightKey as String] as? Int, 1080)
		XCTAssertEqual(resolved10[kCVPixelBufferMetalCompatibilityKey as String] as? Bool, true)
		XCTAssertNotNil(resolved10[kCVPixelBufferIOSurfacePropertiesKey as String])

		let resolved8 = PixelBufferSupport.resolvePoolAttributes(
			from: attrs,
			preferredFormat: kCVPixelFormatType_32BGRA,
			width: 1280,
			height: 720
		)
		XCTAssertEqual(
			(resolved8[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value,
			kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
		)
	}

	func testChooseBestScaleFactor() {
		XCTAssertEqual(PixelBufferSupport.chooseBestScaleFactor(available: [1.5, 2.0], preferred: 1.5), 1.5)
		XCTAssertEqual(PixelBufferSupport.chooseBestScaleFactor(available: [1.5, 2.0], preferred: 2.0), 2.0)
		XCTAssertEqual(PixelBufferSupport.chooseBestScaleFactor(available: [1.0, 2.0], preferred: 1.5), 2.0)
		XCTAssertNil(PixelBufferSupport.chooseBestScaleFactor(available: [1.0], preferred: 1.5))
		XCTAssertNil(PixelBufferSupport.chooseBestScaleFactor(available: [], preferred: 2.0))
	}

	func testMetalFXTargetSizeForIPhone17Pro() {
		let iphone17ProLandscape = CGSize(width: 2622, height: 1206)

		let fit1080 = PixelBufferSupport.computeUpscaleTargetSize(
			inputWidth: 1920,
			inputHeight: 1080,
			drawableSize: iphone17ProLandscape,
			displayMode: .fit
		)
		XCTAssertEqual(fit1080?.width, 2144)
		XCTAssertEqual(fit1080?.height, 1206)

		let zoom1080 = PixelBufferSupport.computeUpscaleTargetSize(
			inputWidth: 1920,
			inputHeight: 1080,
			drawableSize: iphone17ProLandscape,
			displayMode: .zoom
		)
		XCTAssertEqual(zoom1080?.width, 2622)
		XCTAssertEqual(zoom1080?.height, 1474)

		let fit720 = PixelBufferSupport.computeUpscaleTargetSize(
			inputWidth: 1280,
			inputHeight: 720,
			drawableSize: iphone17ProLandscape,
			displayMode: .fit
		)
		XCTAssertEqual(fit720?.width, 2144)
		XCTAssertEqual(fit720?.height, 1206)

		// Pre-upscaled 4K frames should bypass MetalFX spatial upscaling
		XCTAssertNil(
			PixelBufferSupport.computeUpscaleTargetSize(
				inputWidth: 3840,
				inputHeight: 2160,
				drawableSize: iphone17ProLandscape,
				displayMode: .fit
			)
		)
		XCTAssertNil(
			PixelBufferSupport.computeUpscaleTargetSize(
				inputWidth: 1920,
				inputHeight: 1080,
				drawableSize: .zero,
				displayMode: .fit
			)
		)
	}

	func testBufferCompatibilityCheck() {
		var pb: CVPixelBuffer?
		let attrs: [CFString: Any] = [
			kCVPixelBufferMetalCompatibilityKey: true,
			kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
		]
		let status = CVPixelBufferCreate(
			kCFAllocatorDefault,
			1280,
			720,
			kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
			attrs as CFDictionary,
			&pb
		)
		XCTAssertEqual(status, kCVReturnSuccess)
		guard let pb else { return XCTFail("Missing pixel buffer") }

		let matching: [String: Any] = [
			kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
		]
		XCTAssertTrue(PixelBufferSupport.isBufferCompatible(pb, width: 1280, height: 720, withAttributes: matching))
		XCTAssertFalse(PixelBufferSupport.isBufferCompatible(pb, width: 1920, height: 1080, withAttributes: matching))

		let tenBitOnly: [String: Any] = [
			kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
		]
		XCTAssertFalse(PixelBufferSupport.isBufferCompatible(pb, width: 1280, height: 720, withAttributes: tenBitOnly))
	}
}
