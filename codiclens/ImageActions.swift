import CoreImage
import Foundation
import ImageIO

/// Image work performed behind the Effect runner seam.
///
/// Every method is nonisolated because QR rendering and image transcoding can
/// be expensive and must never inherit the app target's default MainActor
/// isolation.
enum ImageActions {
    nonisolated enum RotationDirection: Equatable, Sendable {
        case left
        case right
    }

    nonisolated enum Error: Swift.Error, Equatable, Sendable {
        case emptyQRCode
        case qrCodeCapacityExceeded
        case qrCodeRenderingFailed
        case unreadableImage
        case multipleImagesUnsupported
        case auxiliaryImageDataUnsupported
        case unsupportedImageFormat
        case unsupportedPixelFormat
        case imageEncodingFailed
    }

    /// Answers Core Image's QR encoder directly, so the gate follows encoded
    /// UTF-8 byte capacity rather than an approximate character count.
    nonisolated static func canGenerateQRCode(for text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return qrCodeImage(for: text) != nil
    }

    /// Generates a PNG with an integer-scaled matrix and the QR-standard
    /// four-module quiet zone. Integer scaling keeps every module sharp.
    nonisolated static func generateQRCode(for text: String) throws -> Data {
        guard !text.isEmpty else { throw Error.emptyQRCode }
        guard let matrix = qrCodeImage(for: text) else {
            throw Error.qrCodeCapacityExceeded
        }

        let scale = 12
        let quietZone = 4
        let moduleWidth = Int(matrix.extent.width)
        let moduleHeight = Int(matrix.extent.height)
        let width = (moduleWidth + quietZone * 2) * scale
        let height = (moduleHeight + quietZone * 2) * scale

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ),
              let matrixImage = CIContext(options: [.workingColorSpace: NSNull()])
                .createCGImage(matrix, from: matrix.extent)
        else {
            throw Error.qrCodeRenderingFailed
        }

        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(
            matrixImage,
            in: CGRect(
                x: quietZone * scale,
                y: quietZone * scale,
                width: moduleWidth * scale,
                height: moduleHeight * scale
            )
        )

        guard let image = context.makeImage() else {
            throw Error.qrCodeRenderingFailed
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw Error.qrCodeRenderingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Error.qrCodeRenderingFailed
        }
        return data as Data
    }

    /// Rotates visual pixels one quarter turn, preserving the source format,
    /// then atomically replaces the file. JPEG rotation changes orientation
    /// metadata while copying compressed image data losslessly. Other formats
    /// are rotated into pixels and have their orientation metadata normalized.
    /// Multi-image and auxiliary-image sources are rejected before encoding so
    /// animation, pages, depth maps, and gain maps are never silently dropped.
    nonisolated static func rotateImage(
        at url: URL,
        direction: RotationDirection
    ) throws {
        let targetURL = url.resolvingSymlinksInPath()
        guard let source = CGImageSourceCreateWithURL(targetURL as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete
        else {
            throw Error.unreadableImage
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw Error.multipleImagesUnsupported
        }
        guard !hasAuxiliaryImageData(source) else {
            throw Error.auxiliaryImageDataUnsupported
        }
        guard let type = CGImageSourceGetType(source),
              (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(type as String) == true
        else {
            throw Error.unsupportedImageFormat
        }

        if type as String == "public.jpeg" {
            try rotateJPEGSource(
                source,
                at: targetURL,
                direction: direction,
                properties: CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any] ?? [:]
            )
            return
        }

        guard let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else {
            throw Error.unreadableImage
        }
        guard sourceImage.bitsPerComponent <= 8 else {
            throw Error.unsupportedPixelFormat
        }

        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] ?? [:]
        let orientationValue = (sourceProperties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let sourceOrientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
        let requestedOrientation: CGImagePropertyOrientation = direction == .right ? .right : .left

        let input = CIImage(cgImage: sourceImage)
            .oriented(sourceOrientation)
            .oriented(requestedOrientation)
        guard let rotated = CIContext(options: [.workingColorSpace: NSNull()])
            .createCGImage(input, from: input.extent)
        else {
            throw Error.imageEncodingFailed
        }

        let properties = normalizedProperties(
            sourceProperties,
            width: rotated.width,
            height: rotated.height
        )
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, type, 1, nil) else {
            throw Error.unsupportedImageFormat
        }
        CGImageDestinationAddImage(destination, rotated, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw Error.imageEncodingFailed
        }

        try (encoded as Data).write(to: targetURL, options: .atomic)
    }

    /// `CGImageDestinationCopyImageSource` is ImageIO's metadata-only path: its
    /// contract guarantees the image data is copied losslessly and not decoded.
    nonisolated private static func rotateJPEGSource(
        _ source: CGImageSource,
        at url: URL,
        direction: RotationDirection,
        properties: [CFString: Any]
    ) throws {
        let oldValue = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let oldOrientation = CGImagePropertyOrientation(rawValue: oldValue) ?? .up
        let newOrientation = rotatedOrientation(oldOrientation, direction: direction)
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw Error.unsupportedImageFormat
        }

        var copyError: Unmanaged<CFError>?
        let copied = CGImageDestinationCopyImageSource(destination, source, [
            kCGImageDestinationOrientation: newOrientation.rawValue,
        ] as CFDictionary, &copyError)
        guard copied else {
            throw copyError?.takeRetainedValue() ?? Error.imageEncodingFailed
        }
        try (encoded as Data).write(to: url, options: .atomic)
    }

    nonisolated private static func rotatedOrientation(
        _ orientation: CGImagePropertyOrientation,
        direction: RotationDirection
    ) -> CGImagePropertyOrientation {
        switch (orientation, direction) {
        case (.up, .right): .right
        case (.upMirrored, .right): .rightMirrored
        case (.down, .right): .left
        case (.downMirrored, .right): .leftMirrored
        case (.leftMirrored, .right): .upMirrored
        case (.right, .right): .down
        case (.rightMirrored, .right): .downMirrored
        case (.left, .right): .up
        case (.up, .left): .left
        case (.upMirrored, .left): .leftMirrored
        case (.down, .left): .right
        case (.downMirrored, .left): .rightMirrored
        case (.leftMirrored, .left): .downMirrored
        case (.right, .left): .up
        case (.rightMirrored, .left): .upMirrored
        case (.left, .left): .down
        @unknown default: orientation
        }
    }

    nonisolated private static func qrCodeImage(for text: String) -> CIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        return filter.outputImage
    }

    nonisolated private static func hasAuxiliaryImageData(_ source: CGImageSource) -> Bool {
        let types: [CFString] = [
            kCGImageAuxiliaryDataTypeDepth,
            kCGImageAuxiliaryDataTypeDisparity,
            kCGImageAuxiliaryDataTypePortraitEffectsMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
            kCGImageAuxiliaryDataTypeHDRGainMap,
            kCGImageAuxiliaryDataTypeISOGainMap,
        ]
        return types.contains {
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil
        }
    }

    nonisolated private static func normalizedProperties(
        _ source: [CFString: Any],
        width: Int,
        height: Int
    ) -> [CFString: Any] {
        var properties = source
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = width
        properties[kCGImagePropertyPixelHeight] = height

        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        return properties
    }
}
