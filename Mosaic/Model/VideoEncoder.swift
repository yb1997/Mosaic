import AVFoundation
import ImageIO
import os
import UniformTypeIdentifiers
import VideoToolbox

/// Turns a picked video into a compact, silent wallpaper file: only the video
/// track, re-encoded to HEVC at the chosen frame rate and quality, no larger
/// than the screens need. HEVC is encoded and decoded in hardware on every Mac
/// that runs Mosaic, so importing is quick and playback cheap. See
/// docs/VIDEO_WALLPAPERS.md.
enum VideoEncoder {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The smallest long side a re-encoded video keeps, so a wallpaper still
    /// looks sharp on a 4K screen plugged in later.
    static let minimumLongSide = 3840

    /// How much of a long video is encoded first to see whether re-encoding
    /// pays off. A slide video at 153 kbps took 97 s to re-encode in full and
    /// came out 6× bigger, so it was thrown away.
    static let trialSeconds = 10.0

    /// Writes `source`'s video track to `destination` (a `.mov`) at `format`.
    /// Audio, subtitles, timecode and metadata are left out. If re-encoding
    /// wouldn't make the file smaller, the source's track is copied as it is.
    /// `progress` gets 0–1 on a background thread.
    nonisolated static func encode(_ source: URL, to destination: URL, format: VideoFormat, maxLongSide: Int,
                                   progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure(message: "It has no video.")
        }
        let duration = try await asset.load(.duration)
        guard duration.seconds > 0 else { throw Failure(message: "The video is empty.") }

        guard let quality = format.quality.encoderQuality else {
            try await copyTrack(of: asset, track: track, duration: duration, to: destination, progress: progress)
            return
        }
        let dataRate = Double(try await track.load(.estimatedDataRate))
        // An already efficient source can come out bigger. For a long video,
        // find out from a sample from the middle before encoding all of it.
        if dataRate > 0, duration.seconds > trialSeconds * 2 {
            let sampleRate = try await trialBitRate(asset, track: track, duration: duration, format: format,
                                                    quality: quality, maxLongSide: maxLongSide)
            if sampleRate >= dataRate * 0.9 {
                Log.imports.info("A trial showed re-encoding \(source.lastPathComponent, privacy: .public) wouldn't make it smaller (\(Int(sampleRate / 1000)) kbps vs \(Int(dataRate / 1000)) kbps); keeping its track as it is")
                try await copyTrack(of: asset, track: track, duration: duration, to: destination, progress: progress)
                return
            }
        }
        try await reencode(asset, track: track, duration: duration, to: destination, format: format, quality: quality,
                           maxLongSide: maxLongSide, progress: { progress($0 * 0.98) })
        // Keep whichever is smaller, in case the trial guessed wrong (or there was none).
        let untouched = dataRate / 8 * duration.seconds
        let encoded = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init) ?? 0
        if untouched > 0, encoded > untouched {
            Log.imports.info("Re-encoding made \(source.lastPathComponent, privacy: .public) bigger; keeping its track as it is")
            try? FileManager.default.removeItem(at: destination)
            try await copyTrack(of: asset, track: track, duration: duration, to: destination, progress: { _ in })
        }
        progress(1)
    }

    // MARK: Re-encoding

    /// The bit rate re-encoding gives on `trialSeconds` from the middle of the video.
    private nonisolated static func trialBitRate(_ asset: AVURLAsset, track: AVAssetTrack, duration: CMTime, format: VideoFormat,
                                                 quality: Double, maxLongSide: Int) async throws -> Double {
        // Outside the images folder, so cleanup there can't remove it mid-trial.
        let trial = FileManager.default.temporaryDirectory.appendingPathComponent("Mosaic-trial-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: trial) }
        let length = CMTime(seconds: trialSeconds, preferredTimescale: 600)
        let start = CMTime(seconds: (duration.seconds - trialSeconds) / 2, preferredTimescale: 600)
        try await reencode(asset, track: track, duration: duration, to: trial, format: format, quality: quality,
                           maxLongSide: maxLongSide, timeRange: CMTimeRange(start: start, duration: length), progress: { _ in })
        let bytes = (try? trial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Double(bytes) * 8 / trialSeconds
    }

    /// Re-encodes the whole video, or only `timeRange` of it.
    private nonisolated static func reencode(_ asset: AVURLAsset, track: AVAssetTrack, duration: CMTime, to destination: URL,
                                             format: VideoFormat, quality: Double, maxLongSide: Int,
                                             timeRange: CMTimeRange? = nil,
                                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let (naturalSize, transform, nominalRate, minFrameDuration, characteristics, descriptions) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration, .mediaCharacteristics, .formatDescriptions)

        // Upright size, then scaled down to fit `maxLongSide`, in even pixels.
        let upright = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let longSide = max(upright.width, upright.height)
        let scale = longSide > CGFloat(maxLongSide) ? CGFloat(maxLongSide) / longSide : 1
        let width = max(2, Int((upright.width * scale / 2).rounded()) * 2)
        let height = max(2, Int((upright.height * scale / 2).rounded()) * 2)
        let place = transform
            .concatenating(CGAffineTransform(translationX: -upright.minX, y: -upright.minY))
            .concatenating(CGAffineTransform(scaleX: CGFloat(width) / upright.width, y: CGFloat(height) / upright.height))

        // Never more frames than the source has.
        let sourceRate = nominalRate > 0 ? Double(nominalRate) : 30
        let frameDuration: CMTime
        if let wanted = format.frameRate.value, wanted < sourceRate - 0.5 {
            frameDuration = CMTime(value: 1, timescale: CMTimeScale(wanted))
        } else {
            frameDuration = minFrameDuration.isValid && minFrameDuration.seconds > 0
                ? minFrameDuration : CMTime(value: 1, timescale: CMTimeScale(sourceRate.rounded()))
        }
        let rate = 1 / frameDuration.seconds

        let hdr = characteristics.contains(.containsHDRVideo)
        let colors = colorProperties(of: descriptions.first, hdr: hdr)

        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layer.setTransform(place, at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: duration)))
        let composition = AVVideoComposition(configuration: .init(
            colorPrimaries: colors[AVVideoColorPrimariesKey],
            colorTransferFunction: colors[AVVideoTransferFunctionKey],
            colorYCbCrMatrix: colors[AVVideoYCbCrMatrixKey],
            frameDuration: frameDuration,
            instructions: [instruction],
            renderSize: CGSize(width: width, height: height)))

        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: hdr
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure(message: "The video can't be read.") }
        reader.add(output)

        var compression: [String: Any] = [
            AVVideoQualityKey: quality,
            AVVideoExpectedSourceFrameRateKey: rate,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: true,
        ]
        if hdr { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: colors,
            AVVideoCompressionPropertiesKey: compression,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw Failure(message: "The video can't be converted.") }
        writer.add(input)
        let range = timeRange ?? CMTimeRange(start: .zero, duration: duration)
        try await Pump(reader: reader, output: output, writer: writer, input: input, range: range).run(progress: progress)
    }

    /// The source's colours, or Rec. 709 when it doesn't say. HDR keeps
    /// Rec. 2020 with its own transfer function.
    private nonisolated static func colorProperties(of description: CMFormatDescription?, hdr: Bool) -> [String: String] {
        func value(_ key: CFString) -> String? {
            description.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: key) as? String }
        }
        if hdr {
            return [
                AVVideoColorPrimariesKey: value(kCMFormatDescriptionExtension_ColorPrimaries) ?? AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: value(kCMFormatDescriptionExtension_TransferFunction) ?? AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: value(kCMFormatDescriptionExtension_YCbCrMatrix) ?? AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        }
        let primaries = value(kCMFormatDescriptionExtension_ColorPrimaries)
        let sdrPrimaries = [AVVideoColorPrimaries_ITU_R_709_2, AVVideoColorPrimaries_P3_D65]
        return [
            AVVideoColorPrimariesKey: primaries.flatMap { sdrPrimaries.contains($0) ? $0 : nil } ?? AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
    }

    // MARK: Copying the track as it is

    private nonisolated static func copyTrack(of asset: AVURLAsset, track: AVAssetTrack, duration: CMTime, to destination: URL,
                                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let (transform, descriptions) = try await track.load(.preferredTransform, .formatDescriptions)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure(message: "The video can't be read.") }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: descriptions.first)
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw Failure(message: "This kind of video can't be used.") }
        writer.add(input)
        try await Pump(reader: reader, output: output, writer: writer, input: input,
                       range: CMTimeRange(start: .zero, duration: duration)).run(progress: progress)
    }

    // MARK: Still frame

    /// Saves a frame about a second in (first frames are often black) as HEIC,
    /// upright and in SDR, for the system wallpaper and the tile.
    nonisolated static func writeStill(of video: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.dynamicRangePolicy = .forceSDR
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        let time = CMTime(seconds: min(1, duration.seconds / 2), preferredTimescale: 600)
        let (image, _) = try await generator.image(at: time)
        guard let file = CGImageDestinationCreateWithURL(destination as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw Failure(message: "The still frame can't be saved.")
        }
        CGImageDestinationAddImage(file, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(file) else { throw Failure(message: "The still frame can't be saved.") }
    }

    /// The length of a stored video, for its tile.
    nonisolated static func duration(of video: URL) async -> TimeInterval? {
        guard let duration = try? await AVURLAsset(url: video).load(.duration), duration.seconds > 0 else { return nil }
        return duration.seconds
    }
}

/// Moves samples from a reader to a writer on a background queue, until the
/// reader runs out or the task is cancelled. AVFoundation's objects aren't
/// Sendable, so they live here and are only touched on `queue`.
private final class Pump: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    /// The part of the video being copied, for progress.
    private let range: CMTimeRange
    private let queue = DispatchQueue(label: "in.ybear.Mosaic.videoEncoder", qos: .userInitiated)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(reader: AVAssetReader, output: AVAssetReaderOutput, writer: AVAssetWriter, input: AVAssetWriterInput, range: CMTimeRange) {
        self.reader = reader
        self.output = output
        self.writer = writer
        self.input = input
        self.range = range
    }

    func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { self.copy(progress: progress, continuation) }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    private func copy(progress: @escaping @Sendable (Double) -> Void, _ continuation: CheckedContinuation<Void, Error>) {
        guard reader.startReading() else {
            return continuation.resume(throwing: reader.error ?? VideoEncoder.Failure(message: "The video can't be read."))
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            return continuation.resume(throwing: writer.error ?? VideoEncoder.Failure(message: "The video can't be saved."))
        }
        var started = false
        var lastReported = -1.0
        while true {
            if cancelled.withLock({ $0 }) {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: writer.outputURL)
                return continuation.resume(throwing: CancellationError())
            }
            guard input.isReadyForMoreMediaData else {
                // A failed writer (say, a full disk) is never ready again.
                if writer.status == .failed {
                    reader.cancelReading()
                    return continuation.resume(throwing: writer.error ?? VideoEncoder.Failure(message: "The video can't be saved."))
                }
                usleep(2_000)
                continue
            }
            guard let sample = output.copyNextSampleBuffer() else { break }
            let time = sample.presentationTimeStamp
            if !started {
                writer.startSession(atSourceTime: time)
                started = true
            }
            guard input.append(sample) else {
                reader.cancelReading()
                return continuation.resume(throwing: writer.error ?? VideoEncoder.Failure(message: "The video can't be converted."))
            }
            let done = min(1, max(0, (time - range.start).seconds / range.duration.seconds))
            if done - lastReported >= 0.01 {
                lastReported = done
                progress(done)
            }
        }
        if reader.status == .failed {
            writer.cancelWriting()
            return continuation.resume(throwing: reader.error ?? VideoEncoder.Failure(message: "The video can't be read."))
        }
        guard started else {
            writer.cancelWriting()
            return continuation.resume(throwing: VideoEncoder.Failure(message: "The video has no frames."))
        }
        input.markAsFinished()
        writer.finishWriting {
            if self.writer.status == .completed {
                continuation.resume()
            } else {
                continuation.resume(throwing: self.writer.error ?? VideoEncoder.Failure(message: "The video can't be saved."))
            }
        }
    }
}
