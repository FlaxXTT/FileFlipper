import AppKit
import PDFKit
import UniformTypeIdentifiers
import zlib

/// A page-faithful DOCX: each visible PDF page becomes one positioned PNG.
/// The separate text-only DOCX action remains available for editable text.
enum PDFLayoutDOCX {
    private struct Page {
        let width: CGFloat
        let height: CGFloat
        var widthTwips: Int { Int((width * 20).rounded()) }
        var heightTwips: Int { Int((height * 20).rounded()) }
        var widthEMU: Int64 { Int64(widthTwips) * 635 }
        var heightEMU: Int64 { Int64(heightTwips) * 635 }
    }

    static func convert(_ url: URL) throws -> URL {
        let document = try PDFConverter.open(url)
        // ZIP32 uses 16-bit entry counts. Each page has one image plus four XML parts.
        guard document.pageCount <= 65_530 else { throw ConversionError.message(L("This PDF has too many pages for DOCX")) }
        return try OutputNaming.withFile(nextTo: url, ext: "docx") { output in
            let archive = try StoredZipWriter(output)
            var pages: [Page] = []
            pages.reserveCapacity(document.pageCount)
            for index in 0..<document.pageCount {
                try autoreleasepool {
                    try ConversionWork.report(L("Page %@/%@", String(index + 1), String(document.pageCount)))
                    guard let page = document.page(at: index) else {
                        throw ConversionError.message(L("Couldn't read page %@", String(index + 1)))
                    }
                    let bounds = page.bounds(for: .cropBox)
                    let sideways = abs(page.rotation) % 180 != 0
                    let width = sideways ? bounds.height : bounds.width
                    let height = sideways ? bounds.width : bounds.height
                    guard width.isFinite, height.isFinite, width >= 1, height >= 1,
                          width <= 1584, height <= 1584 else {
                        throw ConversionError.message(L("Page %@ is larger than Word supports (22 inches)", String(index + 1)))
                    }
                    let geometry = Page(width: width, height: height)
                    let pixels = CGSize(width: ceil(width * 2.5), height: ceil(height * 2.5))
                    guard pixels.width * pixels.height <= 36_000_000 else {
                        throw ConversionError.message(L("Couldn't render page %@", String(index + 1)))
                    }
                    let thumbnail = page.thumbnail(of: pixels, for: .cropBox)
                    var proposed = CGRect(origin: .zero, size: pixels)
                    guard let image = thumbnail.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
                          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                        throw ConversionError.message(L("Couldn't render page %@", String(index + 1)))
                    }
                    try archive.add(name: "word/media/page\(index + 1).png", data: data)
                    pages.append(geometry)
                }
            }
            try archive.add(name: "[Content_Types].xml", string: contentTypes)
            try archive.add(name: "_rels/.rels", string: rootRelationships)
            try archive.add(name: "word/_rels/document.xml.rels", string: relationships(count: pages.count))
            try archive.add(name: "word/document.xml", string: documentXML(pages))
            try ConversionWork.check()
            try archive.finish()
        }
    }

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Default Extension="png" ContentType="image/png"/>
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """
    private static let rootRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static func relationships(count: Int) -> String {
        let images = (1...count).map {
            "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/page\($0).png\"/>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(images)</Relationships>"
    }

    private static func section(_ page: Page) -> String {
        let orientation = page.width > page.height ? " w:orient=\"landscape\"" : ""
        return """
        <w:sectPr><w:type w:val="nextPage"/><w:pgSz w:w="\(page.widthTwips)" w:h="\(page.heightTwips)"\(orientation)/><w:pgMar w:top="0" w:right="0" w:bottom="0" w:left="0" w:header="0" w:footer="0" w:gutter="0"/></w:sectPr>
        """
    }

    private static func image(_ page: Page, index: Int) -> String {
        let id = index + 1
        let width = page.widthEMU, height = page.heightEMU
        return """
        <w:r><w:drawing><wp:anchor distT="0" distB="0" distL="0" distR="0" simplePos="0" relativeHeight="0" behindDoc="1" locked="0" layoutInCell="1" allowOverlap="1">
        <wp:simplePos x="0" y="0"/><wp:positionH relativeFrom="page"><wp:posOffset>0</wp:posOffset></wp:positionH><wp:positionV relativeFrom="page"><wp:posOffset>0</wp:posOffset></wp:positionV>
        <wp:extent cx="\(width)" cy="\(height)"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:wrapNone/>
        <wp:docPr id="\(id)" name="PDF page \(id)" descr="PDF page \(id)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>
        <pic:nvPicPr><pic:cNvPr id="\(id)" name="page\(id).png"/><pic:cNvPicPr/></pic:nvPicPr>
        <pic:blipFill><a:blip r:embed="rId\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
        </pic:pic></a:graphicData></a:graphic></wp:anchor></w:drawing></w:r>
        """
    }

    private static func documentXML(_ pages: [Page]) -> String {
        var body = ""
        for (index, page) in pages.enumerated() {
            let properties = index < pages.count - 1 ? section(page) : ""
            body += "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"20\" w:lineRule=\"exact\"/>\(properties)</w:pPr>\(image(page, index: index))</w:p>"
        }
        body += section(pages.last!)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)</w:body></w:document>
        """
    }
}

/// ZIP's stored method is sufficient because PNGs are already compressed. The CRC is
/// part of the required ZIP format; no child process, network, or third-party runtime is used.
private final class StoredZipWriter {
    private struct Entry {
        let name: Data
        let checksum: UInt32
        let size: UInt32
        let offset: UInt32
    }
    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var entries: [Entry] = []
    private let limit = UInt64(UInt32.max)

    init(_ url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ConversionError.writeFailed(url) }
        handle = try FileHandle(forWritingTo: url)
    }
    deinit { try? handle.close() }

    func add(name: String, string: String) throws { try add(name: name, data: Data(string.utf8)) }
    func add(name: String, data: Data) throws {
        try ConversionWork.check()
        let filename = Data(name.utf8)
        guard filename.count <= Int(UInt16.max), UInt64(data.count) <= limit,
              offset + UInt64(data.count) + UInt64(filename.count) + 30 <= limit else { throw tooLarge() }
        let checksum = data.withUnsafeBytes { bytes in
            UInt32(truncatingIfNeeded: crc32(0, bytes.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt(bytes.count)))
        }
        let size = UInt32(data.count)
        var header = Data()
        put(UInt32(0x04034b50), in: &header); put(UInt16(20), in: &header); put(UInt16(0x0800), in: &header)
        put(UInt16(0), in: &header); put(UInt16(0), in: &header); put(UInt16(0x21), in: &header)
        put(checksum, in: &header); put(size, in: &header); put(size, in: &header)
        put(UInt16(filename.count), in: &header); put(UInt16(0), in: &header)
        entries.append(Entry(name: filename, checksum: checksum, size: size, offset: UInt32(offset)))
        try append(header); try append(filename); try append(data)
    }

    func finish() throws {
        guard entries.count <= Int(UInt16.max) else { throw tooLarge() }
        let start = offset
        for entry in entries {
            try ConversionWork.check()
            var header = Data()
            put(UInt32(0x02014b50), in: &header); put(UInt16(20), in: &header); put(UInt16(20), in: &header)
            put(UInt16(0x0800), in: &header); put(UInt16(0), in: &header); put(UInt16(0), in: &header); put(UInt16(0x21), in: &header)
            put(entry.checksum, in: &header); put(entry.size, in: &header); put(entry.size, in: &header)
            put(UInt16(entry.name.count), in: &header); put(UInt16(0), in: &header); put(UInt16(0), in: &header)
            put(UInt16(0), in: &header); put(UInt16(0), in: &header); put(UInt32(0), in: &header); put(entry.offset, in: &header)
            try append(header); try append(entry.name)
        }
        let directorySize = offset - start
        guard start <= limit, directorySize <= limit, offset + 22 <= limit else { throw tooLarge() }
        var end = Data()
        put(UInt32(0x06054b50), in: &end); put(UInt16(0), in: &end); put(UInt16(0), in: &end)
        put(UInt16(entries.count), in: &end); put(UInt16(entries.count), in: &end)
        put(UInt32(directorySize), in: &end); put(UInt32(start), in: &end); put(UInt16(0), in: &end)
        try append(end)
        try handle.close()
    }

    private func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }
    private func put<T: FixedWidthInteger>(_ number: T, in data: inout Data) {
        var little = number.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    private func tooLarge() -> ConversionError { .message(L("The resulting DOCX exceeds 4 GB")) }
}
