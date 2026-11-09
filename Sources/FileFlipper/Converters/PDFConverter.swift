import AppKit
import PDFKit
import UniformTypeIdentifiers

/// PDF conversion is performed on the conversion worker, one page at a time.
enum PDFConverter {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw ConversionError.unreadable(url) }
        if document.isLocked { throw ConversionError.message(L("%@ is password protected", url.lastPathComponent)) }
        guard document.pageCount > 0 else { throw ConversionError.message(L("%@ has no pages", url.lastPathComponent)) }
        return document
    }

    private static func page(_ document: PDFDocument, _ index: Int) throws -> PDFPage {
        try ConversionWork.report(L("Page %@/%@", String(index + 1), String(document.pageCount)))
        guard let page = document.page(at: index) else {
            throw ConversionError.message(L("Couldn't read page %@", String(index + 1)))
        }
        return page
    }

    static func toImages(_ url: URL, type: UTType, ext: String) throws -> [URL] {
        let document = try open(url)
        if document.pageCount == 1 || type == .tiff {
            return try [OutputNaming.withFile(nextTo: url, ext: ext) { output in
                guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, document.pageCount, nil) else {
                    throw ConversionError.unsupported(ext.uppercased())
                }
                for index in 0..<document.pageCount {
                    try autoreleasepool {
                        guard let image = render(try page(document, index)) else { throw ConversionError.message(L("Couldn't render page %@", String(index + 1))) }
                        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                    }
                }
                guard CGImageDestinationFinalize(destination) else { throw ConversionError.writeFailed(output) }
            }]
        }
        return try [OutputNaming.withFolder(nextTo: url, suffix: " (\(ext.uppercased()))") { folder in
            for index in 0..<document.pageCount {
                try autoreleasepool {
                    guard let image = render(try page(document, index)) else { throw ConversionError.message(L("Couldn't render page %@", String(index + 1))) }
                    let output = folder.appendingPathComponent(String(format: "Page %03d", index + 1)).appendingPathExtension(ext)
                    _ = try ImageConverter.write(image, to: output, type: type)
                }
            }
        }]
    }

    private static func texts(_ url: URL) throws -> [String] {
        let document = try open(url)
        var texts: [String] = []
        for index in 0..<document.pageCount {
            texts.append(try autoreleasepool { try TextRecognizer.text(page(document, index)) })
        }
        guard texts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ConversionError.message(L("No text found in %@", url.lastPathComponent))
        }
        return texts
    }

    static func toText(_ url: URL) throws -> URL {
        let text = try texts(url).joined(separator: "\n\n")
        return try OutputNaming.withFile(nextTo: url, ext: "txt") { try text.write(to: $0, atomically: true, encoding: .utf8) }
    }

    static func toMarkdown(_ url: URL) throws -> URL {
        let markdown = MarkdownWriter.markdown(fromPlainPages: try texts(url))
        return try OutputNaming.withFile(nextTo: url, ext: "md") { try markdown.write(to: $0, atomically: true, encoding: .utf8) }
    }

    /// Editable text export. The format picker explicitly describes the layout limitation.
    static func toDocument(_ url: URL, target: DocumentTarget) throws -> URL {
        let document = try open(url)
        let combined = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            try autoreleasepool {
                let page = try page(document, index)
                let extracted = try TextRecognizer.text(page)
                let text: NSAttributedString
                if extracted == (page.string ?? ""), let attributed = page.attributedString { text = attributed }
                else { text = NSAttributedString(string: extracted, attributes: [.font: NSFont.systemFont(ofSize: 12)]) }
                if index > 0 { combined.append(NSAttributedString(string: "\n\u{0C}")) }
                combined.append(text)
            }
        }
        guard !combined.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.message(L("No text found in %@", url.lastPathComponent))
        }
        return try OutputNaming.withFile(nextTo: url, ext: target.ext) { try DocumentConverter.write(combined, to: $0, target: target) }
    }

    static func makePDF(from urls: [URL], near anchor: URL, name: String? = nil) throws -> URL {
        let result = PDFDocument()
        for url in urls {
            try ConversionWork.check()
            if FileKind(url: url) == .pdf {
                let document = try open(url)
                for index in 0..<document.pageCount {
                    guard let copy = try page(document, index).copy() as? PDFPage else { throw ConversionError.unreadable(url) }
                    result.insert(copy, at: result.pageCount)
                }
            } else {
                let source = try ImageConverter.imageSource(url)
                for index in 0..<CGImageSourceGetCount(source) {
                    try ConversionWork.check()
                    let image = try ImageConverter.orientedImage(source, index: index)
                    guard let page = PDFPage(image: NSImage(cgImage: image, size: .zero)) else { throw ConversionError.unreadable(url) }
                    result.insert(page, at: result.pageCount)
                }
            }
        }
        guard result.pageCount > 0 else { throw ConversionError.message(L("Nothing to put in the PDF")) }
        return try OutputNaming.withFile(nextTo: anchor, ext: "pdf", name: name) { output in
            guard result.write(to: output) else { throw ConversionError.writeFailed(output) }
        }
    }

    static func compress(_ url: URL) throws -> URL {
        let document = try open(url)
        return try OutputNaming.withFile(nextTo: url, suffix: " (compressed)", ext: "pdf") { output in
            guard document.write(to: output, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]) else { throw ConversionError.writeFailed(output) }
            _ = try FileInfo.requireSmaller(output, than: url)
        }
    }

    static func stripMetadata(_ url: URL) throws -> URL {
        let document = try open(url)
        document.documentAttributes = [:]
        return try OutputNaming.withFile(nextTo: url, suffix: " (no metadata)", ext: "pdf") { output in
            guard document.write(to: output) else { throw ConversionError.writeFailed(output) }
        }
    }

    static func rotate(_ url: URL) throws -> URL {
        let document = try open(url)
        for index in 0..<document.pageCount {
            let page = try page(document, index)
            page.rotation = (page.rotation + 90) % 360
        }
        return try OutputNaming.withFile(nextTo: url, suffix: " (rotated)", ext: "pdf") { output in
            guard document.write(to: output) else { throw ConversionError.writeFailed(output) }
        }
    }

    static func split(_ url: URL) throws -> [URL] {
        let document = try open(url)
        guard document.pageCount > 1 else { throw ConversionError.message(L("%@ only has one page", url.lastPathComponent)) }
        return try [OutputNaming.withFolder(nextTo: url, suffix: " (pages)") { folder in
            for index in 0..<document.pageCount {
                try autoreleasepool {
                    guard let copy = try page(document, index).copy() as? PDFPage else { throw ConversionError.unreadable(url) }
                    let single = PDFDocument()
                    single.insert(copy, at: 0)
                    let output = folder.appendingPathComponent(String(format: "Page %03d.pdf", index + 1))
                    guard single.write(to: output) else { throw ConversionError.writeFailed(output) }
                }
            }
        }]
    }

    static func drawingTransform(_ page: PDFPage, size: CGSize) -> CGAffineTransform {
        guard let ref = page.pageRef else { return .identity }
        return ref.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: size),
                                       rotate: Int32(page.rotation) - ref.rotationAngle, preserveAspectRatio: true)
    }

    /// 144 dpi by default. Oversized pages return an error; OCR may reduce its resolution.
    static func render(_ page: PDFPage, scale: CGFloat = 2, fitForOCR: Bool = false) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { return nil }
        let sideways = page.rotation % 180 != 0
        var width = (sideways ? box.height : box.width) * scale
        var height = (sideways ? box.width : box.height) * scale
        let limit: CGFloat = fitForOCR ? 16_000_000 : 36_000_000
        guard width.isFinite, height.isFinite else { return nil }
        if width * height > limit {
            guard fitForOCR else { return nil }
            let factor = sqrt(limit / (width * height))
            width *= factor; height *= factor
        }
        guard width >= 1, height >= 1, width <= 36_000_000, height <= 36_000_000,
              let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: Int(width), height: Int(height)))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(context.width) / ((sideways ? box.height : box.width)), y: CGFloat(context.height) / ((sideways ? box.width : box.height)))
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
