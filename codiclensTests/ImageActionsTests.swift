import CoreGraphics
import ImageIO
import Testing
import Vision
@testable import codiclens

struct ImageActionsTests {
    private let red: [UInt8] = [255, 0, 0, 255]
    private let green: [UInt8] = [0, 255, 0, 255]
    private let blue: [UInt8] = [0, 0, 255, 255]
    private let yellow: [UInt8] = [255, 255, 0, 255]
    private let magenta: [UInt8] = [255, 0, 255, 255]
    private let cyan: [UInt8] = [0, 255, 255, 255]

    @Test func qrCodeRoundTripsUnicodeThroughVision() throws {
        let text = "Hej København — 你好 👋🏽"
        let png = try ImageActions.generateQRCode(for: text)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])

        let payload = try #require(request.results?.first?.payloadStringValue)
        #expect(payload == text)
    }

    @Test func qrEligibilityUsesActualMediumCorrectionCapacity() throws {
        let maximumByteModePayload = String(repeating: "a", count: 2_331)
        let oneByteTooMany = maximumByteModePayload + "a"

        #expect(ImageActions.canGenerateQRCode(for: maximumByteModePayload))
        #expect(!ImageActions.canGenerateQRCode(for: oneByteTooMany))
        _ = try ImageActions.generateQRCode(for: maximumByteModePayload)
        #expect(throws: ImageActions.Error.qrCodeCapacityExceeded) {
            try ImageActions.generateQRCode(for: oneByteTooMany)
        }
    }

    @Test func emptyTextHasNoQRCodeActionPayload() {
        #expect(!ImageActions.canGenerateQRCode(for: ""))
        #expect(throws: ImageActions.Error.emptyQRCode) {
            try ImageActions.generateQRCode(for: "")
        }
    }

    @Test func rotateRightMovesPixelsClockwiseAndPreservesPNG() throws {
        let url = try fixtureURL(fileExtension: "png")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeImage(
            rows: [[red, green], [blue, yellow], [magenta, cyan]],
            type: "public.png" as CFString,
            to: url
        )

        try ImageActions.rotateImage(at: url, direction: .right)

        let decoded = try readImage(at: url)
        #expect(decoded.type == "public.png")
        #expect(decoded.rows == [[magenta, blue, red], [cyan, yellow, green]])
        #expect(decoded.orientation == 1)
    }

    @Test func rotateLeftMovesPixelsCounterclockwise() throws {
        let url = try fixtureURL(fileExtension: "png")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeImage(
            rows: [[red, green], [blue, yellow], [magenta, cyan]],
            type: "public.png" as CFString,
            to: url
        )

        try ImageActions.rotateImage(at: url, direction: .left)

        let decoded = try readImage(at: url)
        #expect(decoded.rows == [[green, yellow, cyan], [red, blue, magenta]])
        #expect(decoded.orientation == 1)
    }

    @Test(arguments: [
        ("public.png", "png"),
        ("public.tiff", "tiff"),
    ])
    func rotationPreservesSourceFormat(type: String, fileExtension: String) throws {
        let url = try fixtureURL(fileExtension: fileExtension)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeImage(rows: [[red, green], [blue, yellow], [magenta, cyan]], type: type as CFString, to: url)

        try ImageActions.rotateImage(at: url, direction: .right)

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == type)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 3)
        #expect(image.height == 2)
    }

    @Test(arguments: [
        (1, 6, 8),
        (2, 7, 5),
        (3, 8, 6),
        (4, 5, 7),
        (5, 2, 4),
        (6, 3, 1),
        (7, 4, 2),
        (8, 1, 3),
    ])
    func jpegRotationIsMetadataOnlyForEveryOrientation(
        originalOrientation: Int,
        rightOrientation: Int,
        leftOrientation: Int
    ) throws {
        let url = try fixtureURL(fileExtension: "jpg")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeImage(
            rows: [[red, green], [blue, yellow], [magenta, cyan]],
            type: "public.jpeg" as CFString,
            to: url,
            properties: [
                kCGImagePropertyOrientation: originalOrientation,
                kCGImageDestinationLossyCompressionQuality: 0.72,
            ]
        )
        let originalData = try Data(contentsOf: url)
        let originalScan = try jpegScanData(originalData)
        let original = try readImage(at: url)

        try ImageActions.rotateImage(at: url, direction: .right)

        let rightData = try Data(contentsOf: url)
        let right = try readImage(at: url)
        #expect(try jpegScanData(rightData) == originalScan)
        #expect(right.rows == original.rows)
        #expect(right.orientation == rightOrientation)
        #expect((right.rows.first?.count, right.rows.count) == (2, 3), "compressed pixel dimensions stay fixed")
        let originalSize = orientedSize(of: original)
        let rightSize = orientedSize(of: right)
        #expect(rightSize.width == originalSize.height)
        #expect(rightSize.height == originalSize.width)

        try ImageActions.rotateImage(at: url, direction: .left)

        let restoredData = try Data(contentsOf: url)
        let restored = try readImage(at: url)
        #expect(try jpegScanData(restoredData) == originalScan)
        #expect(restored.rows == original.rows)
        #expect(restored.orientation == originalOrientation)

        try ImageActions.rotateImage(at: url, direction: .left)

        let leftData = try Data(contentsOf: url)
        let left = try readImage(at: url)
        #expect(try jpegScanData(leftData) == originalScan)
        #expect(left.rows == original.rows)
        #expect(left.orientation == leftOrientation)
        let leftSize = orientedSize(of: left)
        #expect(leftSize.width == originalSize.height)
        #expect(leftSize.height == originalSize.width)
    }

    @Test func highPrecisionImageIsRejectedWithoutChangingOriginal() throws {
        let url = try fixtureURL(fileExtension: "png")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let image = try sixteenBitGrayscaleImage()
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: url)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.bitsPerComponent == 16)

        #expect(throws: ImageActions.Error.unsupportedPixelFormat) {
            try ImageActions.rotateImage(at: url, direction: .right)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func existingOrientationIsAppliedToPixelsThenNormalized() throws {
        let url = try fixtureURL(fileExtension: "tiff")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeImage(
            rows: [[red, green], [blue, yellow], [magenta, cyan]],
            type: "public.tiff" as CFString,
            to: url,
            properties: [kCGImagePropertyOrientation: 6]
        )

        try ImageActions.rotateImage(at: url, direction: .left)

        let decoded = try readImage(at: url)
        #expect(decoded.rows == [[red, green], [blue, yellow], [magenta, cyan]])
        #expect(decoded.orientation == 1)
    }

    @Test func multipageImageIsRejectedWithoutChangingOriginal() throws {
        let url = try fixtureURL(fileExtension: "tiff")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let image = try cgImage(rows: [[red]])
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            "public.tiff" as CFString,
            2,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
        let original = try Data(contentsOf: url)

        #expect(throws: ImageActions.Error.multipleImagesUnsupported) {
            try ImageActions.rotateImage(at: url, direction: .right)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func unreadableFileIsRejectedWithoutChangingOriginal() throws {
        let url = try fixtureURL(fileExtension: "png")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = Data("not an image".utf8)
        try original.write(to: url)

        #expect(throws: ImageActions.Error.unreadableImage) {
            try ImageActions.rotateImage(at: url, direction: .left)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    private func fixtureURL(fileExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codiclens-image-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("fixture.\(fileExtension)")
    }

    private func writeImage(
        rows: [[[UInt8]]],
        type: CFString,
        to url: URL,
        properties: [CFString: Any]? = nil
    ) throws {
        let image = try cgImage(rows: rows)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func cgImage(rows: [[[UInt8]]]) throws -> CGImage {
        let height = rows.count
        let width = try #require(rows.first?.count)
        #expect(rows.allSatisfy { $0.count == width })
        let bytes = rows.flatMap { $0.flatMap { $0 } }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func sixteenBitGrayscaleImage() throws -> CGImage {
        let bytes: [UInt8] = [0x12, 0x34, 0xAB, 0xCD]
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(
            width: 2,
            height: 1,
            bitsPerComponent: 16,
            bitsPerPixel: 16,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: [.byteOrder16Big],
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func jpegScanData(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let marker = try #require(bytes.indices.dropLast(3).first {
            bytes[$0] == 0xFF && bytes[$0 + 1] == 0xDA
        })
        let headerLength = Int(bytes[marker + 2]) << 8 | Int(bytes[marker + 3])
        let scanStart = marker + 2 + headerLength
        let end = try #require(bytes.indices.dropFirst(scanStart).last {
            $0 > scanStart && bytes[$0 - 1] == 0xFF && bytes[$0] == 0xD9
        })
        return Data(bytes[scanStart ..< end - 1])
    }

    private func orientedSize(
        of image: (type: String, rows: [[[UInt8]]], orientation: Int)
    ) -> (width: Int, height: Int) {
        let raw = (width: image.rows.first?.count ?? 0, height: image.rows.count)
        return (5 ... 8).contains(image.orientation)
            ? (raw.height, raw.width)
            : raw
    }

    private func readImage(at url: URL) throws -> (
        type: String,
        rows: [[[UInt8]]],
        orientation: Int
    ) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = stride(from: 0, to: bytes.count, by: 4).map {
            Array(bytes[$0 ..< $0 + 4])
        }
        let rows = stride(from: 0, to: pixels.count, by: image.width).map {
            Array(pixels[$0 ..< $0 + image.width])
        }
        return (CGImageSourceGetType(source)! as String, rows, orientation)
    }
}
