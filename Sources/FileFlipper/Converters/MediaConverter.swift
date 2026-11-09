@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct MediaTarget: FormatTarget {
    let title: String
    let ext: String
    var aliases: [String] = []
}

/// Video and audio conversions, built on AVFoundation.
/// Media loading and export use cancellable asynchronous operations.
enum MediaConverter {
    static let videoTargets: [MediaTarget] = [
        MediaTarget(title: "MP4", ext: "mp4"),
        MediaTarget(title: "MOV", ext: "mov", aliases: ["qt"]),
        MediaTarget(title: "GIF", ext: "gif"),
        MediaTarget(title: "M4A", ext: "m4a"),
    ]

    static let audioTargets: [MediaTarget] = [
        MediaTarget(title: "M4A", ext: "m4a"),
        MediaTarget(title: "WAV", ext: "wav", aliases: ["wave"]),
        MediaTarget(title: "AIFF", ext: "aiff", aliases: ["aif"]),
        MediaTarget(title: "CAF", ext: "caf"),
    ]

    // MARK: Convert

    static func convertVideo(_ url: URL, to target: MediaTarget) async throws -> URL {
        switch target.ext {
        case "gif": return try await toGIF(url)
        case "m4a": return try await extractAudio(url, suffix: "")
        case "mov": return try await export(url, preset: AVAssetExportPresetHighestQuality, fileType: .mov, ext: "mov")
        default: return try await export(url, preset: AVAssetExportPresetHighestQuality, fileType: .mp4, ext: "mp4")
        }
    }

    static func convertAudio(_ url: URL, to target: MediaTarget) async throws -> URL {
        if target.ext == "m4a" {
            return try await export(url, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, ext: "m4a")
        }
        return try writePCM(url, ext: target.ext, bigEndian: target.ext == "aiff")
    }

    // MARK: Video tools

    static func compressVideo(_ url: URL) async throws -> URL {
        try await export(url, preset: AVAssetExportPresetMediumQuality, fileType: .mp4, ext: "mp4", suffix: " (compressed)", requireSmaller: true)
    }

    static func resizeVideo720(_ url: URL) async throws -> URL {
        try await export(url, preset: AVAssetExportPreset1280x720, fileType: .mp4, ext: "mp4", suffix: " (720p)")
    }

    static func extractAudio(_ url: URL) async throws -> URL {
        try await extractAudio(url, suffix: " (audio)")
    }

    private static func extractAudio(_ url: URL, suffix: String) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw ConversionError.message(L("%@ has no audio", url.lastPathComponent))
        }
        return try await export(url, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, ext: "m4a", suffix: suffix)
    }

    static func mute(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ConversionError.message(L("%@ has no video", url.lastPathComponent))
        }
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: videoTrack, at: .zero)
        track.preferredTransform = try await videoTrack.load(.preferredTransform)

        let isMP4 = ["mp4", "m4v"].contains(url.pathExtension.lowercased())
        return try await export(url, asset: composition, preset: AVAssetExportPresetPassthrough,
                          fileType: isMP4 ? .mp4 : .mov, ext: isMP4 ? "mp4" : "mov", suffix: " (muted)")
    }

    static func snapshot(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        let time = CMTime(seconds: seconds.isFinite ? min(1, seconds / 2) : 0, preferredTimescale: 600)
        let image = try await generator.image(at: time).image
        return try OutputNaming.withFile(nextTo: url, suffix: " (snapshot)", ext: "png") { _ = try ImageConverter.write(image, to: $0, type: .png) }
    }

    /// Up to the first 15 seconds at 10 fps, max 480 px.
    static func toGIF(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = min(CMTimeGetSeconds(try await asset.load(.duration)), 15)
        guard duration.isFinite, duration > 0 else { throw ConversionError.unreadable(url) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let fps = 10.0
        let count = max(1, Int(duration * fps))
        return try await OutputNaming.withFileAsync(nextTo: url, ext: "gif") { output in
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else { throw ConversionError.unsupported("GIF") }
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for index in 0..<count {
                try ConversionWork.report(L("Frame %@/%@", String(index + 1), String(count)))
                let time = CMTime(seconds: Double(index) / fps, preferredTimescale: 600)
                let frame = try await generator.image(at: time).image
                CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
            }
            guard CGImageDestinationFinalize(destination) else { throw ConversionError.writeFailed(output) }
        }
    }

    // MARK: Audio tools

    static func compressAudio(_ url: URL) async throws -> URL {
        try await export(url, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, ext: "m4a", suffix: " (compressed)", requireSmaller: true)
    }

    static func mono(_ url: URL) throws -> URL {
        let input = try AVAudioFile(forReading: url)
        let inputFormat = input.processingFormat
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw ConversionError.unsupported(L("Mono conversion"))
        }
        converter.downmix = true

        return try OutputNaming.withFile(nextTo: url, suffix: " (mono)", ext: "wav") { output in
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: output, settings: settings,
                                   commonFormat: monoFormat.commonFormat, interleaved: monoFormat.isInterleaved)

        let capacity: AVAudioFrameCount = 32_768
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: capacity),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity) else {
            throw ConversionError.message(L("Couldn't allocate audio buffers"))
        }
        while input.framePosition < input.length {
            try ConversionWork.check()
            try input.read(into: inBuffer)
            if inBuffer.frameLength == 0 { break }
            try converter.convert(to: outBuffer, from: inBuffer)
            try file.write(from: outBuffer)
        }
        }
    }

    // MARK: Helpers

    /// Decodes any readable audio file and writes 16-bit PCM (WAV, AIFF or CAF, picked by extension).
    private static func writePCM(_ url: URL, ext: String, bigEndian: Bool) throws -> URL {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        return try OutputNaming.withFile(nextTo: url, ext: ext) { output in
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
        ]
        let file = try AVAudioFile(forWriting: output, settings: settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
            throw ConversionError.message(L("Couldn't allocate an audio buffer"))
        }
        while input.framePosition < input.length {
            try ConversionWork.check()
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try file.write(from: buffer)
        }
        }
    }

    private static func export(_ url: URL, asset: AVAsset? = nil, preset: String, fileType: AVFileType,
                               ext: String, suffix: String = "", requireSmaller: Bool = false) async throws -> URL {
        try ConversionWork.check()
        let asset = asset ?? AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw ConversionError.unsupported(ext.uppercased()) }
        let types: [AVFileType] = await withCheckedContinuation { continuation in
            session.determineCompatibleFileTypes { continuation.resume(returning: $0) }
        }
        guard types.contains(fileType) else { throw ConversionError.unsupported(ext.uppercased()) }
        return try await OutputNaming.withFileAsync(nextTo: url, suffix: suffix, ext: ext) { output in
            if #available(macOS 15.0, *) {
                try await session.export(to: output, as: fileType)
            } else {
                // macOS 14 compatibility; cancellation ends the export before staging is removed.
                session.outputURL = output
                session.outputFileType = fileType
                let handle = LegacyExportHandle(session)
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        session.exportAsynchronously { [handle] in
                            let session = handle.session
                            switch session.status {
                            case .completed: continuation.resume()
                            case .cancelled: continuation.resume(throwing: ConversionError.cancelled)
                            default: continuation.resume(throwing: session.error ?? ConversionError.message(L("Export failed")))
                            }
                        }
                        if Task.isCancelled { session.cancelExport() }
                    }
                } onCancel: { handle.session.cancelExport() }
            }
            try ConversionWork.check()
            if requireSmaller { _ = try FileInfo.requireSmaller(output, than: url) }
        }
    }
}

/// The legacy session is configured before use; its documented cancellation API may be
/// called concurrently with its completion callback. No configuration is mutated there.
private final class LegacyExportHandle: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
