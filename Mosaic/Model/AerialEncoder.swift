import AVFoundation
import os
import VideoToolbox

/// The lock screen's copy of a video. macOS plays it as a custom aerial
/// (docs/LOCK_SCREEN_VIDEO.md), and the aerial player slows the video to a
/// stop at unlock by dropping to a lower frame rate. A file without a
/// temporal base layer breaks it there: the next lock is black and the desktop
/// goes gray (spike run 1). So this is HEVC Main 10 with a base layer at half
/// the frame rate, SDR BT.709, no audio.
///
/// AVAssetWriterInput refuses the base-layer settings for HEVC, and the
/// hardware encoder only takes the absolute `BaseLayerFrameRate` (the fraction
/// needs low-latency rate control), so this drives VideoToolbox itself and
/// writes the compressed samples through unchanged.
extension VideoEncoder {
    /// Writes `source`'s video upright, at most `maxLongSide` pixels on its
    /// long side, to `destination` (a `.mov`). `progress` gets 0–1 on a
    /// background thread.
    nonisolated static func encodeAerial(_ source: URL, to destination: URL, maxLongSide: Int = minimumLongSide,
                                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure(message: "It has no video.")
        }
        let duration = try await asset.load(.duration)
        guard duration.seconds > 0 else { throw Failure(message: "The video is empty.") }
        let (naturalSize, transform, nominalRate, minFrameDuration) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration)

        let upright = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let longSide = max(upright.width, upright.height)
        let scale = longSide > CGFloat(maxLongSide) ? CGFloat(maxLongSide) / longSide : 1
        let width = max(2, Int((upright.width * scale / 2).rounded()) * 2)
        let height = max(2, Int((upright.height * scale / 2).rounded()) * 2)
        let place = transform
            .concatenating(CGAffineTransform(translationX: -upright.minX, y: -upright.minY))
            .concatenating(CGAffineTransform(scaleX: CGFloat(width) / upright.width, y: CGFloat(height) / upright.height))

        let sourceRate = nominalRate > 0 ? Double(nominalRate) : 30
        let frameDuration = minFrameDuration.isValid && minFrameDuration.seconds > 0
            ? minFrameDuration : CMTime(value: 1, timescale: CMTimeScale(sourceRate.rounded()))
        let rate = min(240, 1 / frameDuration.seconds)

        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layer.setTransform(place, at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: duration)))
        let composition = AVVideoComposition(configuration: .init(
            colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
            colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
            colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
            frameDuration: frameDuration,
            instructions: [instruction],
            renderSize: CGSize(width: width, height: height)))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure(message: "The video can't be read.") }
        reader.add(output)

        let session = try makeAerialSession(width: width, height: height, rate: rate)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        try await AerialPump(reader: reader, output: output, session: session, writer: writer, duration: duration)
            .run(progress: progress)
        progress(1)
    }

    /// A hardware HEVC Main 10 session with a base layer at half `rate`.
    private nonisolated static func makeAerialSession(width: Int, height: Int, rate: Double) throws -> VTCompressionSession {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let session = created else {
            throw Failure(message: "The lock screen video can't be encoded (\(status)).")
        }
        // About 0.07 bits per pixel per frame: 1080p24 ≈ 3.5 Mbps, 4K30 ≈ 17 Mbps.
        let bitRate = min(25_000_000, max(4_000_000, Double(width * height) * rate * 0.07))
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel),
            (kVTCompressionPropertyKey_RealTime, kCFBooleanFalse),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AverageBitRate, bitRate as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, rate as CFNumber),
            (kVTCompressionPropertyKey_BaseLayerFrameRate, (rate / 2) as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 1.0 as CFNumber),
            (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for (key, value) in properties {
            let result = VTSessionSetProperty(session, key: key, value: value)
            guard result == noErr else {
                VTCompressionSessionInvalidate(session)
                throw Failure(message: "The lock screen video can't be encoded (\(key) \(result)).")
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }
}

/// Moves frames from the reader through the compression session into the
/// writer on a background queue. The session hands back compressed samples on
/// its own thread; they wait in `pending` and are appended on `queue`, so the
/// writer is only touched there.
private final class AerialPump: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput
    private let session: VTCompressionSession
    private let writer: AVAssetWriter
    private let duration: CMTime
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "in.ybear.Mosaic.aerialEncoder", qos: .utility)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    /// Compressed samples waiting for the writer, and the encoder's first error; guarded by `lock`.
    private var samples: [CMSampleBuffer] = []
    private var encodeError: OSStatus = noErr
    private let lock = NSLock()

    init(reader: AVAssetReader, output: AVAssetReaderOutput, session: VTCompressionSession, writer: AVAssetWriter, duration: CMTime) {
        self.reader = reader
        self.output = output
        self.session = session
        self.writer = writer
        self.duration = duration
    }

    func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        try self.copy(progress: progress)
                        self.finish(continuation)
                    } catch {
                        self.abandon()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    private func copy(progress: @escaping @Sendable (Double) -> Void) throws {
        guard reader.startReading() else {
            throw reader.error ?? VideoEncoder.Failure(message: "The video can't be read.")
        }
        var lastReported = -1.0
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = sample.presentationTimeStamp
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixels, presentationTimeStamp: time, duration: sample.duration,
                frameProperties: nil, infoFlagsOut: nil
            ) { status, _, compressed in
                self.lock.withLock {
                    if status != noErr { self.encodeError = status } else if let compressed { self.samples.append(compressed) }
                }
            }
            guard status == noErr else { throw VideoEncoder.Failure(message: "The lock screen video can't be encoded (\(status)).") }
            frames += 1
            try drain(waitBelow: 30)
            let done = min(1, max(0, time.seconds / duration.seconds))
            if done - lastReported >= 0.01 {
                lastReported = done
                progress(done * 0.99)
            }
        }
        if reader.status == .failed { throw reader.error ?? VideoEncoder.Failure(message: "The video can't be read.") }
        guard frames > 0 else { throw VideoEncoder.Failure(message: "The video has no frames.") }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        try drain(waitBelow: 1)
    }

    /// Appends what the encoder has produced, waiting while more than
    /// `waitBelow` samples are queued and the writer isn't ready.
    private func drain(waitBelow limit: Int) throws {
        while true {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
            let (next, error, count) = lock.withLock { (samples.first, encodeError, samples.count) }
            if error != noErr { throw VideoEncoder.Failure(message: "The lock screen video can't be encoded (\(error)).") }
            guard let next else { return }
            let input = try writerInput(for: next)
            if input.isReadyForMoreMediaData {
                guard input.append(next) else {
                    throw writer.error ?? VideoEncoder.Failure(message: "The lock screen video can't be saved.")
                }
                lock.withLock { _ = samples.removeFirst() }
            } else if writer.status == .failed {
                // A failed writer (say, a full disk) is never ready again.
                throw writer.error ?? VideoEncoder.Failure(message: "The lock screen video can't be saved.")
            } else if count >= limit {
                usleep(2_000)
            } else {
                return
            }
        }
    }

    /// The writer's input, made from the first compressed sample's format.
    private func writerInput(for sample: CMSampleBuffer) throws -> AVAssetWriterInput {
        if let input { return input }
        let made = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: sample.formatDescription)
        made.expectsMediaDataInRealTime = false
        guard writer.canAdd(made) else { throw VideoEncoder.Failure(message: "The lock screen video can't be saved.") }
        writer.add(made)
        guard writer.startWriting() else {
            throw writer.error ?? VideoEncoder.Failure(message: "The lock screen video can't be saved.")
        }
        writer.startSession(atSourceTime: .zero)
        input = made
        return made
    }

    private func finish(_ continuation: CheckedContinuation<Void, Error>) {
        VTCompressionSessionInvalidate(session)
        guard let input else {
            return continuation.resume(throwing: VideoEncoder.Failure(message: "The lock screen video can't be saved."))
        }
        input.markAsFinished()
        writer.finishWriting {
            if self.writer.status == .completed {
                continuation.resume()
            } else {
                continuation.resume(throwing: self.writer.error ?? VideoEncoder.Failure(message: "The lock screen video can't be saved."))
            }
        }
    }

    private func abandon() {
        VTCompressionSessionInvalidate(session)
        reader.cancelReading()
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: writer.outputURL)
    }
}
