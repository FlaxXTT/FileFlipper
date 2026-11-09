import AppKit
import Darwin

/// Localized text: the English text is the key; translations live in Localizable.strings.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Localized text with `%@` placeholders.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}

enum ConversionError: LocalizedError {
    case unreadable(URL)
    case writeFailed(URL)
    case unsupported(String)
    case message(String)
    /// The user backed out (e.g. closed the crop window). Not shown as an error.
    case cancelled
    case partial([URL], String, Bool)

    var errorDescription: String? {
        switch self {
        case .cancelled: return L("Cancelled")
        case .partial(_, let message, _): return message
        case .unreadable(let url): return L("Couldn't read %@", url.lastPathComponent)
        case .writeFailed(let url): return L("Couldn't write %@", url.lastPathComponent)
        case .unsupported(let what): return L("%@ isn't supported on this Mac", what)
        case .message(let text): return text
        }
    }
}

/// Writes into a private staging directory, then publishes without replacing an existing item.
enum OutputNaming {
    static func withFile(nextTo url: URL, suffix: String = "", ext: String, name: String? = nil,
                         _ write: (URL) throws -> Void) throws -> URL {
        try staged(near: url, base: name ?? url.deletingPathExtension().lastPathComponent + suffix,
                   ext: ext, folder: false, write)
    }

    static func withFolder(nextTo url: URL, suffix: String, _ write: (URL) throws -> Void) throws -> URL {
        try staged(near: url, base: url.deletingPathExtension().lastPathComponent + suffix,
                   ext: nil, folder: true, write)
    }

    static func withFileAsync(nextTo url: URL, suffix: String = "", ext: String,
                              _ write: (URL) async throws -> Void) async throws -> URL {
        let directory = url.deletingLastPathComponent()
        let staging = try makeStaging(in: directory)
        defer { try? FileManager.default.removeItem(at: staging) }
        let output = staging.appendingPathComponent("output").appendingPathExtension(ext)
        try await write(output)
        try ConversionWork.check()
        return try publish(output, in: directory, base: url.deletingPathExtension().lastPathComponent + suffix, ext: ext)
    }

    private static func staged(near url: URL, base: String, ext: String?, folder: Bool,
                               _ write: (URL) throws -> Void) throws -> URL {
        try ConversionWork.check()
        let directory = url.deletingLastPathComponent()
        let staging = try makeStaging(in: directory)
        defer { try? FileManager.default.removeItem(at: staging) }
        var output = staging.appendingPathComponent("output", isDirectory: folder)
        if let ext { output.appendPathExtension(ext) }
        if folder { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false) }
        try write(output)
        try ConversionWork.check()
        return try publish(output, in: directory, base: base, ext: ext)
    }

    private static func makeStaging(in directory: URL) throws -> URL {
        let staging = directory.appendingPathComponent(".proteus-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        return staging
    }

    private static func publish(_ staged: URL, in directory: URL, base: String, ext: String?) throws -> URL {
        var number = 1
        while true {
            try ConversionWork.check()
            var candidate = directory.appendingPathComponent(base + (number == 1 ? "" : " \(number)"))
            if let ext { candidate.appendPathExtension(ext) }
            // The destination and staging directory share a filesystem. RENAME_EXCL closes the
            // check-then-write race, including another app creating the same name at this moment.
            if renamex_np(staged.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            let code = errno
            if code == EEXIST || code == ENOTEMPTY { number += 1; continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: candidate.path])
        }
    }
}

enum ConversionWork {
    static let progressContext = TaskLocal<(@Sendable (String) -> Void)?>(wrappedValue: nil)

    static func check() throws {
        if Task.isCancelled { throw ConversionError.cancelled }
    }

    static func report(_ message: String) throws {
        try check()
        progressContext.wrappedValue?(message)
    }

    static func onMain<T>(_ work: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try work() }
        return try DispatchQueue.main.sync(execute: work)
    }
}

enum FileInfo {
    static func bytes(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    static func sizeString(of url: URL) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes(of: url)), countStyle: .file)
    }

    /// For "Compress" tools: keeps `output` only if it really is smaller than `original`.
    static func requireSmaller(_ output: URL, than original: URL) throws -> URL {
        guard bytes(of: output) >= bytes(of: original) else { return output }
        try? FileManager.default.removeItem(at: output)
        throw ConversionError.message(L("%@ is already as small as it gets", original.lastPathComponent))
    }
}
