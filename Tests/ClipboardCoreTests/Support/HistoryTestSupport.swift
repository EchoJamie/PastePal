import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ClipboardCore

class HistoryTestSupport: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PastePalTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }

    final func imageData(type: String, frames: Int = 1) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, frames, nil))
        for index in 0..<frames {
            let context = try XCTUnwrap(CGContext(data: nil, width: 18, height: 12, bitsPerComponent: 8, bytesPerRow: 72, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: index == 0 ? 0.9 : 0.1, green: 0.3, blue: index == 0 ? 0.1 : 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 18, height: 12))
            let properties: CFDictionary? = type == UTType.gif.identifier
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
                : nil
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    final func text(_ value: String, extra: [Representation] = []) -> ClipboardContent {
        ClipboardContent(kind: .text, text: value, representations: [Representation(type: "public.utf8-plain-text", data: Data(value.utf8))] + extra)
    }

    final func image() throws -> ClipboardContent {
        let context = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.5)); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return try ContentCodec.decode([Representation(type: "public.png", data: data as Data)])
    }

}
