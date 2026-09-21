import AppKit
import XCTest
@testable import Uziq

final class ArtworkImageCacheTests: XCTestCase {
    func testNonSquareArtworkRetainsEnoughPixelsForAspectFill() throws {
        for (width, height) in [(1024, 256), (256, 1024)] {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let original = try XCTUnwrap(context.makeImage())
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: original).representation(using: .png, properties: [:]))
            let size = CGSize(width: 46, height: 46)
            let maximum = ArtworkImageCache.pixelSize(for: size, scale: 2)
            let image = try XCTUnwrap(ArtworkImageCache.shared.image(for: data, maximumPixelSize: maximum, filling: size))
            let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertGreaterThanOrEqual(min(pixels.width, pixels.height), 92)
            XCTAssertEqual(max(pixels.width, pixels.height), 384)
            XCTAssertTrue(image === ArtworkImageCache.shared.image(for: data, maximumPixelSize: maximum, filling: size))

            let matchingShape = CGSize(width: width, height: height)
            let uncropped = try XCTUnwrap(ArtworkImageCache.shared.image(for: data, maximumPixelSize: maximum, filling: matchingShape))
            let uncroppedPixels = try XCTUnwrap(uncropped.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertEqual(max(uncroppedPixels.width, uncroppedPixels.height), 96)
        }
    }

    func testRowThumbnailsUseSmallerAllocationsWithoutShrinkingLargeArtwork() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let original = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: original).representation(using: .png, properties: [:]))
        let cache = ArtworkImageCache.shared
        let rowSize = ArtworkImageCache.pixelSize(for: CGSize(width: 46, height: 46), scale: 2)
        let row = try XCTUnwrap(cache.image(for: data, maximumPixelSize: rowSize))
        let large = try XCTUnwrap(cache.image(for: data, maximumPixelSize: 768))
        let rowPixels = try XCTUnwrap(row.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let largePixels = try XCTUnwrap(large.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(rowPixels.width, 96)
        XCTAssertEqual(largePixels.width, 768)
        XCTAssertLessThan(rowPixels.bytesPerRow * rowPixels.height, largePixels.bytesPerRow * largePixels.height / 32)
        XCTAssertTrue(row === cache.image(for: data, maximumPixelSize: rowSize))
        XCTAssertFalse(row === large)
        XCTAssertEqual(ArtworkImageCache.pixelSize(for: CGSize(width: 180, height: 180), scale: 2), 384)
    }
}
