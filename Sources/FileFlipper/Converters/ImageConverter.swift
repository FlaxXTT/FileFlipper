import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ImageTarget: FormatTarget {
    let title: String
    let type: UTType
    let ext: String
    var aliases: [String] = []
}

enum ImageConverter {
    static let targets: [ImageTarget] = [
        ImageTarget(title: "PNG", type: .png, ext: "png"),
        ImageTarget(title: "JPG", type: .jpeg, ext: "jpg", aliases: ["jpeg", "jpe"]),
        ImageTarget(title: "HEIC", type: .heic, ext: "heic", aliases: ["heif"]),
        ImageTarget(title: "WEBP", type: .webP, ext: "webp"),
        ImageTarget(title: "TIFF", type: .tiff, ext: "tiff", aliases: ["tif"]),
        ImageTarget(title: "GIF", type: .gif, ext: "gif"),
        ImageTarget(title: "BMP", type: .bmp, ext: "bmp"),
    ]
    private static let writableTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    static func canWrite(_ type: UTType) -> Bool { writableTypes.contains(type.identifier) }

    static func convert(_ url: URL, to type: UTType, ext: String) throws -> URL {
        let source = try imageSource(url)
        let count = CGImageSourceGetCount(source)
        if count > 1 && type != .gif && type != .tiff {
            return try OutputNaming.withFolder(nextTo: url, suffix: " (\(ext.uppercased()))") { folder in
                for index in 0..<count {
                    try autoreleasepool {
                        try ConversionWork.report(L("Frame %@/%@", String(index + 1), String(count)))
                        var image = try orientedImage(source, index: index)
                        if type == .jpeg || type == .bmp { image = flatten(image) ?? image }
                        _ = try write(image, to: folder.appendingPathComponent(String(format: "Frame %03d.%@", index + 1, ext)), type: type, metadata: metadata(source, index: index, image: image, keepPrivate: true))
                    }
                }
            }
        }
        return try OutputNaming.withFile(nextTo: url, ext: ext) { output in
            try writeFrames(source, to: output, type: type) { index in
                let image = try orientedImage(source, index: index)
                return type == .jpeg || type == .bmp ? (flatten(image) ?? image) : image
            }
        }
    }

    static func compress(_ url: URL) throws -> URL {
        let source = try imageSource(url)
        let sourceType = format(of: source)
        let multi = CGImageSourceGetCount(source) > 1
        let type: UTType
        let ext: String
        if multi {
            type = sourceType == .gif ? .gif : .tiff
            ext = type == .gif ? "gif" : "tiff"
        } else if [.jpeg, .heic, .webP].contains(sourceType), canWrite(sourceType) {
            type = sourceType; ext = url.pathExtension.lowercased()
        } else {
            let image = try orientedImage(source)
            type = image.hasAlpha && canWrite(.heic) ? .heic : image.hasAlpha ? .png : .jpeg
            ext = type == .heic ? "heic" : type == .png ? "png" : "jpg"
        }
        return try OutputNaming.withFile(nextTo: url, suffix: " (compressed)", ext: ext) { output in
            try writeFrames(source, to: output, type: type, quality: 0.6) { try orientedImage(source, index: $0) }
            _ = try FileInfo.requireSmaller(output, than: url)
        }
    }

    static func crop(_ url: URL) throws -> URL {
        let source = try imageSource(url)
        try requireSingleFrame(source)
        let image = try orientedImage(source)
        try ConversionWork.check()
        let selection = ConversionWork.onMain { CropWindow.run(image: image, fileName: url.lastPathComponent) }
        try ConversionWork.check()
        guard let rect = selection, let cropped = image.cropping(to: rect) else { throw ConversionError.cancelled }
        return try transformed(url, source: source, suffix: " (cropped)") { _ in cropped }
    }

    static func stripMetadata(_ url: URL) throws -> URL {
        let source = try imageSource(url)
        return try transformed(url, source: source, suffix: " (no metadata)", keepMetadata: false) { try orientedImage(source, index: $0) }
    }

    static func resizeHalf(_ url: URL) throws -> URL {
        let source = try imageSource(url)
        return try transformed(url, source: source, suffix: " (50%)") { index in
            let longest = pixelSize(source, index: index).map { max($0.width, $0.height) } ?? 0
            return try orientedImage(source, index: index, maxPixelSize: max(1, longest / 2))
        }
    }

    static func rotate(_ url: URL) throws -> URL {
        let source = try imageSource(url)
        return try transformed(url, source: source, suffix: " (rotated)") { index in
            let image = try orientedImage(source, index: index)
            return try draw(width: image.height, height: image.width) { context in
                context.translateBy(x: 0, y: CGFloat(image.width)); context.rotate(by: -.pi / 2)
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
        }
    }

    static func flip(_ url: URL) throws -> URL {
        let source = try imageSource(url)
        return try transformed(url, source: source, suffix: " (flipped)") { index in
            let image = try orientedImage(source, index: index)
            return try draw(width: image.width, height: image.height) { context in
                context.translateBy(x: CGFloat(image.width), y: 0); context.scaleBy(x: -1, y: 1)
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
        }
    }

    static func grayscale(_ url: URL) throws -> URL {
        let source = try imageSource(url)
        return try transformed(url, source: source, suffix: " (grayscale)") { index in
            let image = try orientedImage(source, index: index)
            guard let filter = CIFilter(name: "CIColorControls") else { throw ConversionError.unsupported("Grayscale") }
            filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
            filter.setValue(0, forKey: kCIInputSaturationKey)
            guard let output = filter.outputImage, let result = imageContext.createCGImage(output, from: output.extent) else { throw ConversionError.unreadable(url) }
            return result
        }
    }
    private static let imageContext = CIContext()

    static func removeBackground(_ url: URL) throws -> URL {
        let source = try imageSource(url)
        try requireSingleFrame(source)
        let image = try orientedImage(source)
        let cutout = try BackgroundRemover.removeBackground(from: image, name: url.lastPathComponent)
        return try OutputNaming.withFile(nextTo: url, suffix: " (no background)", ext: "png") { _ = try write(cutout, to: $0, type: .png) }
    }

    private static func requireSingleFrame(_ source: CGImageSource) throws {
        guard CGImageSourceGetCount(source) == 1 else { throw ConversionError.message(L("This tool requires a single-frame image; no file was changed")) }
    }

    private static func transformed(_ url: URL, source: CGImageSource, suffix: String, keepMetadata: Bool = true,
                                    _ transform: (Int) throws -> CGImage) throws -> URL {
        let original = format(of: source)
        let multi = CGImageSourceGetCount(source) > 1
        let type: UTType = multi ? (original == .gif ? .gif : .tiff) : canWrite(original) ? original : .png
        let ext = type == original ? url.pathExtension.lowercased() : type == .tiff ? "tiff" : "png"
        return try OutputNaming.withFile(nextTo: url, suffix: suffix, ext: ext) { try writeFrames(source, to: $0, type: type, keepMetadata: keepMetadata, transform) }
    }

    private static func writeFrames(_ source: CGImageSource, to output: URL, type: UTType, quality: Double = 0.9, keepMetadata: Bool = true,
                                    _ transform: (Int) throws -> CGImage) throws {
        let count = CGImageSourceGetCount(source)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, count, nil) else { throw ConversionError.unsupported(type.identifier) }
        // Animation timing and looping survive even when private metadata is removed.
        if type == .gif, let global = CGImageSourceCopyProperties(source, nil) as? [CFString: Any], let gif = global[kCGImagePropertyGIFDictionary] {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: gif] as CFDictionary)
        }
        for index in 0..<count {
            try autoreleasepool {
                try ConversionWork.report(L("Frame %@/%@", String(index + 1), String(count)))
                let image = try transform(index)
                var properties = metadata(source, index: index, image: image, keepPrivate: keepMetadata)
                properties[kCGImageDestinationLossyCompressionQuality] = quality
                if type == .gif, let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any], let gif = sourceProperties[kCGImagePropertyGIFDictionary] {
                    properties[kCGImagePropertyGIFDictionary] = gif
                }
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.writeFailed(output) }
    }

    private static func metadata(_ source: CGImageSource, index: Int, image: CGImage, keepPrivate: Bool) -> [CFString: Any] {
        guard keepPrivate else { return [:] }
        var result = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
        result[kCGImagePropertyOrientation] = 1
        result[kCGImagePropertyPixelWidth] = image.width
        result[kCGImagePropertyPixelHeight] = image.height
        // Pixels have already been oriented. Do not repeat the old rotation on export.
        if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = result[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            result[kCGImagePropertyExifDictionary] = exif
        }
        result.removeValue(forKey: kCGImagePropertyColorModel)
        result.removeValue(forKey: kCGImagePropertyProfileName)
        return result
    }

    static func imageSource(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { throw ConversionError.unreadable(url) }
        return source
    }

    static func write(_ image: CGImage, to output: URL, type: UTType, quality: Double = 0.9, metadata: [CFString: Any] = [:]) throws -> URL {
        try ConversionWork.check()
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else { throw ConversionError.unsupported(type.identifier) }
        var properties = metadata
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.writeFailed(output) }
        return output
    }

    private static func format(of source: CGImageSource) -> UTType { (CGImageSourceGetType(source) as String?).flatMap { UTType($0) } ?? .png }
    private static func pixelSize(_ source: CGImageSource, index: Int) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    static func orientedImage(_ source: CGImageSource, index: Int = 0, maxPixelSize: Int? = nil) throws -> CGImage {
        try ConversionWork.check()
        guard let dimensions = pixelSize(source, index: index), dimensions.width > 0, dimensions.height > 0 else { throw ConversionError.message(L("Couldn't decode the image")) }
        let longest = max(dimensions.width, dimensions.height)
        let size = min(maxPixelSize ?? longest, longest)
        let ratio = Double(size) / Double(longest)
        guard Double(dimensions.width) * Double(dimensions.height) * ratio * ratio <= 64_000_000 else {
            throw ConversionError.message(L("Image exceeds the 64-megapixel processing limit"))
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: size]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { throw ConversionError.message(L("Couldn't decode the image")) }
        return image
    }

    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ConversionError.message(L("Couldn't create a canvas")) }
        context.interpolationQuality = .high
        body(context)
        guard let image = context.makeImage() else { throw ConversionError.message(L("Couldn't render the image")) }
        return image
    }
    static func flatten(_ image: CGImage) -> CGImage? {
        try? draw(width: image.width, height: image.height) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }
}

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo { case .none, .noneSkipFirst, .noneSkipLast: return false; default: return true }
    }
}
