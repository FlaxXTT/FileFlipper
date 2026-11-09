import PDFKit
import Vision

/// Reads text from PDF pages that have no text layer (scanned or photographed pages),
/// using Vision's on-device text recognition — the same engine as Live Text.
enum TextRecognizer {
    /// Languages to try, in order of preference, limited to what this Mac supports.
    private static let preferredLanguages = [
        "zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR",
        "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "ru-RU",
    ]

    private static func recognize(_ page: PDFPage) throws -> [(box: CGRect, text: String)] {
        try ConversionWork.check()
        guard let image = PDFConverter.render(page, scale: 3, fitForOCR: true) else { throw ConversionError.message(L("Could not render page for OCR")) }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let languages = preferredLanguages.filter { supported.contains($0) }
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }

        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            throw ConversionError.message(L("Text recognition failed: %@", error.localizedDescription))
        }
        let lines = (request.results ?? []).compactMap { observation -> (box: CGRect, text: String)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (observation.boundingBox, text)
        }
        try ConversionWork.check()
        return lines
    }

    /// Retain native text, then add OCR lines from regions not covered by that text.
    static func text(_ page: PDFPage) throws -> String {
        let original = page.string ?? ""
        let recognized = try recognize(page)
        let box = page.bounds(for: .mediaBox)
        let sideways = page.rotation % 180 != 0
        let size = CGSize(width: sideways ? box.height : box.width, height: sideways ? box.width : box.height)
        let transform = PDFConverter.drawingTransform(page, size: size)
        let selections = page.selection(for: box)?.selectionsByLine() ?? []
        let native = selections.compactMap { selection -> (box: CGRect, text: String)? in
            guard let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let rect = selection.bounds(for: page).applying(transform)
            return (CGRect(x: rect.minX / size.width, y: rect.minY / size.height, width: rect.width / size.width, height: rect.height / size.height), text)
        }
        func normalized(_ text: String) -> String {
            String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        let additional = recognized.filter { line in
            !native.contains { existing in
                let intersection = existing.box.intersection(line.box)
                let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
                let area = max(0.000001, min(existing.box.width * existing.box.height, line.box.width * line.box.height))
                let near = abs(existing.box.midY - line.box.midY) < max(existing.box.height, line.box.height)
                return overlap / area > 0.5 || (near && normalized(existing.text) == normalized(line.text))
            }
        }
        if additional.isEmpty { return original }
        if native.isEmpty {
            return original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? joinIntoLines(additional) : original + "\n\n" + joinIntoLines(additional)
        }
        return joinIntoLines(native + additional)
    }

    /// Vision returns pieces of text; put pieces on the same line side by side, top to bottom.
    private static func joinIntoLines(_ pieces: [(box: CGRect, text: String)]) -> String {
        // Vision's coordinates start at the bottom-left, so a larger y is higher on the page.
        let sorted = pieces.sorted { $0.box.midY > $1.box.midY }
        var rows: [[(box: CGRect, text: String)]] = []
        for piece in sorted {
            if let last = rows.last?.first,
               abs(last.box.midY - piece.box.midY) < min(last.box.height, piece.box.height) / 2 {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        return rows.map { row in
            row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
    }
}
