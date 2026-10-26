import UIKit
import XCTest

@testable import Minis

/// [IMG-10] The shared tool-image gate: read_image and browser screenshots
/// pass through `ImagePayloadPrep.gatedToolImage` — format sniffed from
/// magic bytes, 20 MB / 40 MP ceilings (hard under `.rejectOversize`,
/// converged under `.downscaleOversize`), everything re-encoded to
/// context-ready JPEG with EXIF orientation baked in, and refusals that
/// name the specific reason.
final class ToolImageGateTests: XCTestCase {

    private func pngData(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1  // pixel size == point size, so assertions are exact
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let img = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return img.pngData()!
    }

    private func rejection(of result: Result<ImagePayloadPrep.GatedToolImage, ImagePayloadPrep.ToolImageRejection>)
        -> ImagePayloadPrep.ToolImageRejection? {
        if case .failure(let r) = result { return r }
        return nil
    }

    func testGarbage_refusedAsNotAnImage() {
        let junk = Data("this is definitely not an image".utf8)
        XCTAssertEqual(rejection(of: ImagePayloadPrep.gatedToolImage(junk)), .notAnImage)
    }

    func testEmpty_refusedAsNotAnImage() {
        XCTAssertEqual(rejection(of: ImagePayloadPrep.gatedToolImage(Data())), .notAnImage)
    }

    func testOversizeBytes_refusedBeforeDecode() {
        // Valid PNG magic + >20 MB of filler: the byte ceiling must fire
        // from the header-stage checks, before any decode attempt.
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(Data(count: ImagePayloadPrep.toolImageMaxBytes))
        XCTAssertEqual(
            rejection(of: ImagePayloadPrep.gatedToolImage(data)),
            .fileTooLarge(bytes: data.count, limit: ImagePayloadPrep.toolImageMaxBytes)
        )
    }

    func testOversizeBytes_downscalePolicyDoesNotRefuseOnBytes() {
        // Same payload under the browser policy must NOT fail with
        // .fileTooLarge — it proceeds to decode (and fails there as
        // .notAnImage because the filler is not a real PNG body).
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(Data(count: ImagePayloadPrep.toolImageMaxBytes))
        let r = rejection(of: ImagePayloadPrep.gatedToolImage(data, oversize: .downscaleOversize))
        XCTAssertNotNil(r)
        if case .fileTooLarge = r! {
            XCTFail("downscale policy must not refuse on bytes")
        }
    }

    func testValidPNG_passesAsJPEGWithSourceFormat() {
        let data = pngData(width: 120, height: 80)
        guard case .success(let gated) = ImagePayloadPrep.gatedToolImage(data) else {
            return XCTFail("valid PNG should pass the gate")
        }
        XCTAssertEqual(gated.mimeType, "image/jpeg")
        XCTAssertEqual(gated.sourceFormat, "image/png")
        XCTAssertEqual(gated.pixelSize, CGSize(width: 120, height: 80))
        XCTAssertEqual(ImagePayloadPrep.sniffMimeType(gated.data), "image/jpeg")
    }

    func testLargeImage_downscaledToContextCap() {
        let data = pngData(width: 2400, height: 1200)
        guard case .success(let gated) = ImagePayloadPrep.gatedToolImage(data) else {
            return XCTFail("2400px PNG should pass the gate")
        }
        let out = ImagePayloadPrep.pixelSize(gated.data)
        XCTAssertNotNil(out)
        XCTAssertLessThanOrEqual(max(out!.width, out!.height), ImagePayloadPrep.contextMaxLongEdge)
    }
}
