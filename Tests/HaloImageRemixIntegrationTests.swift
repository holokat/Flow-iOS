import XCTest
import UIKit
@testable import Flow

final class HaloImageRemixIntegrationTests: XCTestCase {
    func testCanvasPointConvertsToVisionCoordinates() {
        let converted = HaloSubjectSegmentation.visionSeedPoint(
            fromCanvasPoint: CGPoint(x: 0.25, y: 0.2)
        )

        XCTAssertEqual(converted.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(converted.y, 0.8, accuracy: 0.0001)
    }

    func testVisionSeedPointClampsBeforeFlipping() {
        let converted = HaloSubjectSegmentation.visionSeedPoint(
            fromCanvasPoint: CGPoint(x: -0.4, y: 1.8)
        )

        XCTAssertEqual(converted.x, 0, accuracy: 0.0001)
        XCTAssertEqual(converted.y, 0, accuracy: 0.0001)
    }

    func testTransparentRemixUsesPNGEncoding() throws {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 20, height: 20),
            format: format
        ).image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            UIColor.red.setFill()
            context.fill(CGRect(x: 4, y: 4, width: 12, height: 12))
        }

        let encoding = try XCTUnwrap(ImageRemixUploadEncoding(image: image))

        XCTAssertEqual(encoding.mimeType, "image/png")
        XCTAssertEqual(encoding.fileExtension, "png")
        XCTAssertEqual(Array(encoding.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testOpaqueRemixUsesJPEGEncoding() throws {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 20, height: 20),
            format: format
        ).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }

        let encoding = try XCTUnwrap(ImageRemixUploadEncoding(image: image))

        XCTAssertEqual(encoding.mimeType, "image/jpeg")
        XCTAssertEqual(encoding.fileExtension, "jpg")
        XCTAssertEqual(Array(encoding.data.prefix(2)), [0xFF, 0xD8])
    }
}
