import AppKit

/// Excel (.xlsx) → PDF or Markdown. Reads the cell values of every sheet (text, numbers,
/// dates, percentages) and lays them out as tables; formulas show their last calculated value.
enum SpreadsheetConverter {
    struct Sheet {
        let name: String
        let rows: [[String]]
        /// Columns whose cells are mostly numbers are right-aligned.
        let numericColumns: Set<Int>
    }

    // MARK: Convert

    static func toPDF(_ url: URL) throws -> URL {
        let sheets = try read(url)
        return try OutputNaming.withFile(nextTo: url, ext: "pdf") { try renderPDF(sheets, to: $0) }
    }

    static func toMarkdown(_ url: URL) throws -> URL {
        let sheets = try read(url)
        var parts: [String] = []
        for sheet in sheets {
            let rows = sheet.rows.map { $0.map { MarkdownWriter.escape($0).replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ") } }
            parts.append("## " + MarkdownWriter.escape(sheet.name) + "\n\n" + MarkdownWriter.table(rows))
        }
        return try OutputNaming.withFile(nextTo: url, ext: "md") { try (parts.joined(separator: "\n\n") + "\n").write(to: $0, atomically: true, encoding: .utf8) }
    }

    // MARK: Reading

    static func read(_ url: URL) throws -> [Sheet] {
        let archive: ZipArchive
        do { archive = try ZipArchive(url: url) } catch { throw ConversionError.unreadable(url) }
        guard let workbook = OfficePackage.xml(archive, "xl/workbook.xml") else { throw ConversionError.unreadable(url) }
        let relationships = OfficePackage.relationships(archive, for: "xl/workbook.xml")
        let shared = sharedStrings(archive)
        let formats = cellFormats(archive)
        let date1904 = ["1", "true"].contains(workbook.child("workbookPr")?.attr("date1904") ?? "")

        var sheets: [Sheet] = []
        for sheet in workbook.child("sheets")?.children("sheet") ?? [] {
            try ConversionWork.check()
            if sheet.attr("state") == "hidden" || sheet.attr("state") == "veryHidden" { continue }
            guard let id = sheet.relationshipID, let path = relationships[id]?.target,
                  let root = OfficePackage.xml(archive, path) else { throw ConversionError.unreadable(url) }
            let name = sheet.attr("name") ?? "Sheet"
            var grid: [Int: [Int: (String, Bool)]] = [:]
            for row in root.child("sheetData")?.children("row") ?? [] {
                try ConversionWork.check()
                if row.attr("hidden") == "1" { continue }
                for cell in row.children("c") {
                    guard let reference = cell.attr("r"), let (column, rowIndex) = position(reference) else { continue }
                    let (text, numeric) = try value(of: cell, shared: shared, formats: formats, date1904: date1904)
                    if !text.isEmpty { grid[rowIndex, default: [:]][column] = (text, numeric) }
                }
            }
            guard !grid.isEmpty else { continue }
            let rowIndices = grid.keys.sorted()
            let columnIndices = Set(grid.values.flatMap(\.keys)).sorted()
            var rows: [[String]] = []
            var numeric = Set<Int>()
            // Keep original coordinates. Do not allocate the empty rectangle between cells.
            if rowIndices.count > 100_000 / max(1, columnIndices.count) {
                rows.append([L("Cell"), L("Value")])
                for r in rowIndices {
                    try ConversionWork.check()
                    for c in grid[r]!.keys.sorted() {
                        rows.append([columnName(c) + String(r + 1), grid[r]![c]!.0])
                    }
                }
            } else {
                rows.append([L("Row")] + columnIndices.map(columnName))
                var numericCounts: [Int: Int] = [:], totalCounts: [Int: Int] = [:]
                for r in rowIndices {
                    try ConversionWork.check()
                    var line = [String(r + 1)]
                    for (index, c) in columnIndices.enumerated() {
                        let entry = grid[r]?[c]
                        line.append(entry?.0 ?? "")
                        if let entry {
                            totalCounts[index + 1, default: 0] += 1
                            if entry.1 { numericCounts[index + 1, default: 0] += 1 }
                        }
                    }
                    rows.append(line)
                }
                numeric = Set(totalCounts.compactMap { column, total in
                    (numericCounts[column] ?? 0) * 2 > total ? column : nil
                })
            }
            sheets.append(Sheet(name: name, rows: rows, numericColumns: numeric))
        }
        guard !sheets.isEmpty else { throw ConversionError.message(L("%@ has no data", url.lastPathComponent)) }
        return sheets
    }

    private static func sharedStrings(_ archive: ZipArchive) -> [String] {
        guard let root = OfficePackage.xml(archive, "xl/sharedStrings.xml") else { return [] }
        return root.children("si").map { item in
            if let direct = item.child("t") { return direct.stringValue ?? "" }
            return item.children("r").map { $0.child("t")?.stringValue ?? "" }.joined()
        }
    }

    private enum NumberStyle { case general, date(time: Bool), time(seconds: Bool), elapsed(unit: String, seconds: Bool), percent(decimals: Int), fixed(decimals: Int, grouping: Bool) }

    /// Number style for each cell style index (`s` attribute).
    private static func cellFormats(_ archive: ZipArchive) -> [NumberStyle] {
        guard let root = OfficePackage.xml(archive, "xl/styles.xml") else { return [] }
        var custom: [Int: String] = [:]
        for format in root.child("numFmts")?.children("numFmt") ?? [] {
            if let id = format.attr("numFmtId").flatMap(Int.init) { custom[id] = format.attr("formatCode") ?? "" }
        }
        return (root.child("cellXfs")?.children("xf") ?? []).map { xf in
            let id = xf.attr("numFmtId").flatMap(Int.init) ?? 0
            switch id {
            case 14...17: return .date(time: false)
            case 22: return .date(time: true)
            case 18, 20: return .time(seconds: false)
            case 19, 21, 45, 47: return .time(seconds: true)
            case 46: return .elapsed(unit: "h", seconds: true)
            case 9: return .percent(decimals: 0)
            case 10: return .percent(decimals: 2)
            case 1: return .fixed(decimals: 0, grouping: false)
            case 2: return .fixed(decimals: 2, grouping: false)
            case 3: return .fixed(decimals: 0, grouping: true)
            case 4: return .fixed(decimals: 2, grouping: true)
            default: break
            }
            guard let code = custom[id] else { return .general }
            let unquoted = code.components(separatedBy: ";").first!.replacingOccurrences(of: #""[^"]*""#, with: "", options: .regularExpression).lowercased()
            if let range = unquoted.range(of: #"\[([hms])\1*\]"#, options: .regularExpression) {
                let token = String(unquoted[range]).dropFirst().first!
                return .elapsed(unit: String(token), seconds: unquoted.contains("s"))
            }
            let bare = unquoted.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            if bare.contains("y") || bare.contains("d") { return .date(time: bare.contains("h")) }
            if bare.contains("h") || bare.contains("s") { return .time(seconds: bare.contains("s")) }
            if bare.contains("m") && !bare.contains("0") { return .date(time: false) }
            let decimals = bare.range(of: #"\.(0+)"#, options: .regularExpression).map { bare[$0].count - 1 } ?? 0
            if bare.contains("%") { return .percent(decimals: decimals) }
            if bare.contains("0") || bare.contains("#") { return .fixed(decimals: decimals, grouping: bare.contains(",")) }
            return .general
        }
    }

    private static func value(of cell: XMLElement, shared: [String], formats: [NumberStyle],
                              date1904: Bool) throws -> (String, Bool) {
        let raw = cell.child("v")?.stringValue ?? ""
        if cell.child("f") != nil && cell.child("v") == nil {
            throw ConversionError.message(L("A formula has no saved value. Recalculate and save the spreadsheet first."))
        }
        switch cell.attr("t") {
        case "s":
            return (Int(raw).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? "", false)
        case "inlineStr":
            let item = cell.child("is")
            let text = item?.child("t")?.stringValue ?? item?.children("r").map { $0.child("t")?.stringValue ?? "" }.joined() ?? ""
            return (text, false)
        case "b":
            return (raw == "1" ? "TRUE" : "FALSE", false)
        case "str", "e":
            return (raw, false)
        default:
            guard let number = Double(raw) else { return (raw, false) }
            let style = cell.attr("s").flatMap(Int.init).flatMap { formats.indices.contains($0) ? formats[$0] : nil } ?? .general
            if case .general = style { return (raw, true) }
            guard number.isFinite else { return (raw, false) }
            return (format(number, style, date1904: date1904), true)
        }
    }

    private static func format(_ number: Double, _ style: NumberStyle, date1904: Bool) -> String {
        switch style {
        case .date(let time):
            let base = date1904 ? 24_107.0 : 25_569.0   // days from the Excel epoch to 1970-01-01
            let date = Date(timeIntervalSince1970: (number - base) * 86_400)
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = time ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
            return formatter.string(from: date)
        case .elapsed(let unit, let withSeconds):
            let absoluteSeconds = (abs(number) * 86_400).rounded()
            guard absoluteSeconds < Double(Int64.max) else { return String(number) }
            let seconds = Int64(absoluteSeconds)
            let sign = number < 0 ? "-" : ""
            if unit == "s" { return sign + String(seconds) }
            if unit == "m" { return sign + String(seconds / 60) + (withSeconds ? String(format: ":%02lld", seconds % 60) : "") }
            return sign + String(seconds / 3600) + String(format: ":%02lld", seconds / 60 % 60) + (withSeconds ? String(format: ":%02lld", seconds % 60) : "")
        case .time(let withSeconds):
            let fraction = number - floor(number)
            let seconds = Int((fraction * 86_400).rounded()) % 86_400
            return String(format: "%02d:%02d", seconds / 3600, (seconds % 3600) / 60) + (withSeconds ? String(format: ":%02d", seconds % 60) : "")
        case .percent(let decimals):
            return String(format: "%.\(decimals)f%%", number * 100)
        case .fixed(let decimals, let grouping):
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = grouping
            formatter.minimumFractionDigits = decimals
            formatter.maximumFractionDigits = decimals
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
        case .general:
            return String(number)
        }
    }

    /// "C12" → (column 2, row 11), zero-based.
    private static func position(_ reference: String) -> (Int, Int)? {
        var column = 0
        var digits = ""
        for character in reference.uppercased() {
            if let ascii = character.asciiValue, character.isLetter {
                guard ascii >= 65, ascii <= 90, column <= 16384 else { return nil }
                column = column * 26 + Int(ascii - 64)
            } else if character.isNumber {
                digits.append(character)
            }
        }
        guard column > 0, column <= 16384, let row = Int(digits), row > 0, row <= 1_048_576 else { return nil }
        return (column - 1, row - 1)
    }

    // MARK: PDF

    private static func renderPDF(_ sheets: [Sheet], to output: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 792, height: 612)
        guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else { throw ConversionError.writeFailed(output) }
        defer { context.closePDF() }
        let margin: CGFloat = 36, usable: CGFloat = 720, pageBottom: CGFloat = 576
        let font = NSFont.systemFont(ofSize: 9)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
        func height(_ text: String, width: CGFloat) -> CGFloat {
            ceil(NSAttributedString(string: text, attributes: attributes).boundingRect(with: CGSize(width: max(1, width - 10), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 10
        }
        // Split a tall cell at character boundaries so every part is printed on a page.
        func pieces(_ text: String, width: CGFloat) throws -> [String] {
            if height(text, width: width) <= 450 { return [text] }
            let characters = Array(text)
            var start = 0, result: [String] = []
            while start < characters.count {
                try ConversionWork.check()
                var low = 1, high = characters.count - start
                while low < high {
                    let mid = (low + high + 1) / 2
                    if height(String(characters[start..<(start + mid)]), width: width) <= 450 { low = mid } else { high = mid - 1 }
                }
                result.append(String(characters[start..<(start + low)])); start += low
            }
            return result
        }
        for sheet in sheets {
            try ConversionWork.check()
            let count = sheet.rows.first?.count ?? 0
            guard count > 0 else { continue }
            var widths = [CGFloat](repeating: 44, count: count)
            for row in sheet.rows {
                try ConversionWork.check()
                for (index, text) in row.enumerated() { widths[index] = min(220, max(widths[index], (text as NSString).size(withAttributes: [.font: font]).width + 12)) }
            }
            var startColumn = 0
            while startColumn < count {
                var endColumn = startColumn, total: CGFloat = 0
                while endColumn < count && total + widths[endColumn] <= usable { total += widths[endColumn]; endColumn += 1 }
                let chunk = startColumn..<max(startColumn + 1, endColumn)
                var pageOpen = false, y: CGFloat = 0
                func row(_ values: [String], at y: CGFloat, height h: CGFloat, header: Bool) {
                    var x = margin
                    for c in chunk {
                        let rect = NSRect(x: x, y: y, width: widths[c], height: h)
                        if header { NSColor(white: 0.95, alpha: 1).setFill(); rect.fill() }
                        NSColor(white: 0.75, alpha: 1).setStroke()
                        let border = NSBezierPath(rect: rect); border.lineWidth = 0.5; border.stroke()
                        NSAttributedString(string: c < values.count ? values[c] : "", attributes: attributes).draw(with: rect.insetBy(dx: 5, dy: 5), options: [.usesLineFragmentOrigin, .usesFontLeading])
                        x += widths[c]
                    }
                }
                func closePage() {
                    if pageOpen { NSGraphicsContext.restoreGraphicsState(); context.endPage(); pageOpen = false }
                }
                defer { closePage() }
                func newPage() {
                    closePage()
                    context.beginPage(mediaBox: &mediaBox)
                    context.translateBy(x: 0, y: mediaBox.height); context.scaleBy(x: 1, y: -1)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                    pageOpen = true
                    NSAttributedString(string: sheet.name, attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.black]).draw(at: NSPoint(x: margin, y: margin))
                    y = margin + 24
                    row(sheet.rows[0], at: y, height: 24, header: true)
                    y += 24
                }
                newPage()
                for values in sheet.rows.dropFirst() {
                    try ConversionWork.check()
                    var parts = [[String]](repeating: [""], count: count)
                    for c in chunk { parts[c] = try pieces(c < values.count ? values[c] : "", width: widths[c]) }
                    for part in 0..<(chunk.map { parts[$0].count }.max() ?? 1) {
                        let fragment = parts.map { part < $0.count ? $0[part] : "" }
                        let h = max(20, chunk.map { height(fragment[$0], width: widths[$0]) }.max() ?? 20)
                        if y + h > pageBottom { newPage() }
                        row(fragment, at: y, height: h, header: false); y += h
                    }
                }
                closePage()
                startColumn = chunk.upperBound
            }
        }
    }

    private static func columnName(_ index: Int) -> String {
        var index = index + 1
        var name = ""
        while index > 0 {
            let remainder = (index - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            index = (index - 1) / 26
        }
        return name
    }
}
