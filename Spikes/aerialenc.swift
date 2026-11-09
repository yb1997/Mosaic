// aerialenc <in> <out.mov>: HEVC Main10 via VTCompressionSession, base layer at
// half frame rate, no audio. The lock screen's aerial player needs the base
// layer to slow the video to a stop at unlock (spike run 2, 2026-11-06).
// AVAssetWriterInput rejects BaseLayerFrameRateFraction for hvc1, and the
// hardware encoder only takes the absolute BaseLayerFrameRate (the fraction
// needs low-latency rate control), so this drives VideoToolbox directly.
//   swiftc -O Spikes/aerialenc.swift -o /tmp/aerialenc
import AVFoundation
import VideoToolbox
let args = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let out = URL(fileURLWithPath: args[2]); try? FileManager.default.removeItem(at: out)
let sem = DispatchSemaphore(value: 0)
final class Box: @unchecked Sendable { var input: AVAssetWriterInput?; var writer: AVAssetWriter!; var pending: [CMSampleBuffer] = []; let lock = NSLock() }
let box = Box()
Task {
    let track = try! await asset.loadTracks(withMediaType: .video)[0]
    let size = try! await track.load(.naturalSize)
    let fps = try! await track.load(.nominalFrameRate)
    let reader = try! AVAssetReader(asset: asset)
    let ro = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    reader.add(ro); reader.startReading()
    box.writer = try! AVAssetWriter(outputURL: out, fileType: .mov)
    var session: VTCompressionSession?
    let st = VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height), codecType: kCMVideoCodecType_HEVC,
        encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    precondition(st == noErr, "create \(st)")
    let s = session!
    func set(_ k: CFString, _ v: CFTypeRef) { let r = VTSessionSetProperty(s, key: k, value: v); print("\(k) -> \(r)") }
    set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel)
    set(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
    set(kVTCompressionPropertyKey_AverageBitRate, 12_000_000 as CFNumber)
    set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
    set(kVTCompressionPropertyKey_BaseLayerFrameRate, (fps / 2) as CFNumber)
    set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 1.0 as CFNumber)
    set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
    set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
    set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    VTCompressionSessionPrepareToEncodeFrames(s)
    var count = 0
    while let sb = ro.copyNextSampleBuffer() {
        guard let px = CMSampleBufferGetImageBuffer(sb) else { continue }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        VTCompressionSessionEncodeFrame(s, imageBuffer: px, presentationTimeStamp: pts, duration: CMSampleBufferGetDuration(sb), frameProperties: nil, infoFlagsOut: nil) { status, _, out in
            guard status == noErr, let out else { print("enc err \(status)"); return }
            box.lock.lock(); defer { box.lock.unlock() }
            if box.input == nil {
                let i = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: CMSampleBufferGetFormatDescription(out))
                i.expectsMediaDataInRealTime = false
                box.writer.add(i); box.writer.startWriting(); box.writer.startSession(atSourceTime: .zero); box.input = i
            }
            box.pending.append(out)
            while let first = box.pending.first, box.input!.isReadyForMoreMediaData { box.input!.append(first); box.pending.removeFirst() }
        }
        count += 1
        box.lock.lock(); let backlog = box.pending.count; box.lock.unlock()
        if backlog > 30 { Thread.sleep(forTimeInterval: 0.01) }
    }
    VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
    box.lock.lock()
    while !box.pending.isEmpty { if box.input!.isReadyForMoreMediaData { box.input!.append(box.pending.removeFirst()) } else { box.lock.unlock(); Thread.sleep(forTimeInterval: 0.01); box.lock.lock() } }
    box.lock.unlock()
    box.input!.markAsFinished()
    await box.writer.finishWriting()
    print("frames \(count) status \(box.writer.status.rawValue) \(box.writer.error?.localizedDescription ?? "")")
    sem.signal()
}
sem.wait()
