import AppKit
import AVFoundation
import Foundation
import Testing
@testable import Mosaic

struct VideoFormatTests {
    @Test func fileNamesRoundTrip() throws {
        let file = VideoFile(sourceHash: String(repeating: "ab", count: 32), format: VideoFormat(frameRate: .fps24, quality: .high))
        #expect(file.fileName == "\(file.sourceHash)-24-high.mov")
        #expect(file.stillName == "\(file.sourceHash)-24-high.heic")
        #expect(file.originalName == "\(file.sourceHash).original")
        #expect(VideoFile(fileName: file.fileName) == file)
        #expect(VideoFile.isVideo(file.fileName))
    }

    @Test func imagesAreNotVideos() {
        #expect(!VideoFile.isVideo("abc.png"))
        #expect(!VideoFile.isVideo("abc.mov"))
        #expect(!VideoFile.isVideo("abc-48-balanced.mov"))
        #expect(!VideoFile.isVideo(nil))
    }

    @Test func originalQualityKeepsEveryFrame() {
        let format = VideoFormat(frameRate: .fps24, quality: .original)
        #expect(format.frameRate == .original)
    }

    @Test func lowerSettingsFitInHigherOnes() {
        let stored = VideoFormat(frameRate: .fps30, quality: .balanced)
        #expect(VideoFormat(frameRate: .fps24, quality: .smaller).isAtMost(stored))
        #expect(stored.isAtMost(stored))
        #expect(!VideoFormat(frameRate: .fps60, quality: .balanced).isAtMost(stored))
        #expect(!VideoFormat(frameRate: .fps24, quality: .high).isAtMost(stored))
    }

    @Test func defaultComesFromSettings() throws {
        let suite = "MosaicTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(VideoFormat.default(in: defaults) == .standard)
        defaults.set("60", forKey: VideoFormat.frameRateKey)
        defaults.set("high", forKey: VideoFormat.qualityKey)
        #expect(VideoFormat.default(in: defaults) == VideoFormat(frameRate: .fps60, quality: .high))
        defaults.set("nonsense", forKey: VideoFormat.qualityKey)
        #expect(VideoFormat.default(in: defaults).quality == .balanced)
    }

    @Test func decodesSourceFileTypes() {
        #expect(VideoFile.isVideoSource(URL(fileURLWithPath: "/a/clip.MOV")))
        #expect(VideoFile.isVideoSource(URL(fileURLWithPath: "/a/clip.mp4")))
        #expect(!VideoFile.isVideoSource(URL(fileURLWithPath: "/a/photo.jpg")))
    }
}

/// Makes a short H.264 test video: `seconds` long, `width`×`height`, `fps` frames a second.
func makeTestVideo(at url: URL, seconds: Int = 2, fps: Int32 = 60, width: Int = 640, height: Int = 360) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<(seconds * Int(fps)) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * row + x * 4
                base[offset] = UInt8((x + frame * 4) & 255)
                base[offset + 1] = UInt8((y + frame * 2) & 255)
                base[offset + 2] = UInt8(frame & 255)
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
}

struct VideoEncoderTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MosaicVideoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func reencodesToHEVCAtTheChosenFrameRate() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.mov")
        try await makeTestVideo(at: source)
        let output = dir.appendingPathComponent("out.mov")
        try await VideoEncoder.encode(source, to: output, format: VideoFormat(frameRate: .fps30, quality: .balanced),
                                      maxLongSide: 3840) { _ in }

        let tracks = try await AVURLAsset(url: output).load(.tracks)
        #expect(tracks.count == 1)
        let track = try #require(tracks.first)
        let (size, descriptions) = try await track.load(.naturalSize, .formatDescriptions)
        #expect(size == CGSize(width: 640, height: 360))
        #expect(descriptions.first.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_HEVC)
        let samples = try await frameCount(of: output)
        #expect((55...65).contains(samples), "2 s at 30 fps, got \(samples) frames")

        let still = dir.appendingPathComponent("out.heic")
        try await VideoEncoder.writeStill(of: output, to: still)
        let image = try #require(NSImage(contentsOf: still))
        #expect(image.representations.first?.pixelsWide == 640)
    }

    @Test func shrinksToTheLongestSideNeeded() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.mov")
        try await makeTestVideo(at: source, seconds: 1)
        let output = dir.appendingPathComponent("out.mov")
        try await VideoEncoder.encode(source, to: output, format: .standard, maxLongSide: 320) { _ in }
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 180))
    }

    /// Longer than two trials, so a sample is encoded first to decide.
    @Test func longVideoIsTriedFirst() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.mov")
        try await makeTestVideo(at: source, seconds: 22, fps: 24, width: 320, height: 180)
        let output = dir.appendingPathComponent("out.mov")
        try await VideoEncoder.encode(source, to: output, format: .standard, maxLongSide: 3840) { _ in }

        // Whichever it kept, it's the whole video and no bigger than the source's track.
        #expect(try await frameCount(of: output) == 22 * 24)
        let sourceSize = try #require(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let outputSize = try #require(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(outputSize <= sourceSize + 4096)
        // The trial file doesn't linger.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("Mosaic-trial-") }
        #expect(leftovers.isEmpty)
    }

    @Test func originalQualityCopiesTheTrack() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.mov")
        try await makeTestVideo(at: source, seconds: 1)
        let output = dir.appendingPathComponent("out.mov")
        try await VideoEncoder.encode(source, to: output, format: VideoFormat(frameRate: .original, quality: .original),
                                      maxLongSide: 3840) { _ in }
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let descriptions = try await track.load(.formatDescriptions)
        #expect(descriptions.first.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_H264)
        #expect(try await frameCount(of: output) == 60)
    }

    @Test func cancellingStopsAndRemovesTheFile() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.mov")
        try await makeTestVideo(at: source, seconds: 4)
        let output = dir.appendingPathComponent("out.mov")
        let task = Task {
            try await VideoEncoder.encode(source, to: output, format: .standard, maxLongSide: 3840) { _ in }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    private func frameCount(of url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { count += 1 }
        }
        return count
    }
}

@MainActor
struct VideoStoreTests {
    private func testDisplay() -> Display {
        Display(id: "TEST-DISPLAY", name: "Test Display", isMain: true, screen: NSScreen.screens[0])
    }

    private func waitForImports(_ store: WallpaperStore, _ display: Display) async throws {
        for _ in 0..<500 {
            if !Slot.allCases.contains(where: { store.isImporting($0, display: display) }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Import didn't finish")
    }

    @Test func videoGoesOnTheDesktopWithItsStillAndOriginal() async throws {
        let sandbox = Sandbox()
        let display = testDisplay()
        let store = sandbox.store(displays: [display])
        let source = sandbox.folder.appendingPathComponent("clip.mov")
        try await makeTestVideo(at: source)

        store.setMedia(from: source, slot: .desktop, display: display)
        #expect(store.videoProgress(.desktop, display: display) != nil)
        try await waitForImports(store, display)
        #expect(store.lastError == nil)
        #expect(store.videoProgress(.desktop, display: display) == nil)

        let name = try #require(store.wallpapers(for: display).desktop)
        let file = try #require(VideoFile(fileName: name))
        #expect(file.format == .standard)
        #expect(sandbox.imageFiles == [file.fileName, file.stillName, file.originalName])
        #expect(store.pictureURL(name)?.lastPathComponent == file.stillName)
        #expect(store.videoFormat(on: display) == .standard)
        #expect(store.hasVideos)

        // Picking it again reuses the stored files.
        store.setMedia(from: source, slot: .desktop, display: display)
        try await waitForImports(store, display)
        #expect(sandbox.imageFiles.count == 3)

        store.clear(.desktop, display: display)
        store.dismissUndo()
        #expect(sandbox.imageFiles.isEmpty)
    }

    @Test func lockScreenRefusesVideos() async throws {
        let sandbox = Sandbox()
        let display = testDisplay()
        let store = sandbox.store(displays: [display])
        let source = sandbox.folder.appendingPathComponent("clip.mov")
        try await makeTestVideo(at: source, seconds: 1)

        store.setMedia(from: source, slot: .lock, display: display)
        #expect(store.lastError == "The lock screen can only show images.")
        #expect(!store.isImporting(.lock, display: display))
        #expect(store.wallpapers(for: display).lock == nil)
    }

    @Test func swapNeverPutsAVideoOnTheLockScreen() throws {
        let sandbox = Sandbox()
        let video = VideoFile(sourceHash: String(repeating: "c", count: 64), format: .standard)
        for name in [video.fileName, video.stillName, "b.png"] { try sandbox.addImage(name) }
        try sandbox.writeState(#"{"TEST-DISPLAY": {"desktop": "\#(video.fileName)", "lock": "b.png"}}"#)
        let display = testDisplay()
        let store = sandbox.store(displays: [display])
        #expect(!store.canSwap(on: display))
        // The still frame isn't cleaned up while its video is used.
        #expect(sandbox.imageFiles.contains(video.stillName))
    }

    @Test func lowerSettingsWorkWithoutTheOriginal() async throws {
        let sandbox = Sandbox()
        let display = testDisplay()
        let store = sandbox.store(displays: [display])
        let source = sandbox.folder.appendingPathComponent("clip.mov")
        try await makeTestVideo(at: source)
        store.setMedia(from: source, slot: .desktop, display: display)
        try await waitForImports(store, display)
        let higher = VideoFormat(frameRate: .fps60, quality: .high)
        let lower = VideoFormat(frameRate: .fps24, quality: .smaller)
        #expect(store.canUse(higher, on: display))

        try FileManager.default.removeItem(at: source)
        #expect(!store.canUse(higher, on: display))
        #expect(store.canUse(lower, on: display))
        store.setVideoFormat(higher, display: display)
        #expect(store.lastError?.contains("Choose the video again") == true)
        store.dismissError()

        store.setVideoFormat(lower, display: display)
        try await waitForImports(store, display)
        #expect(store.lastError == nil)
        #expect(store.videoFormat(on: display) == lower)
        #expect(store.undoable != nil)

        // Undo brings back the copy it was made from.
        store.undo()
        let restored = try #require(store.wallpapers(for: display).desktop)
        #expect(VideoFile(fileName: restored)?.format == .standard)
        #expect(sandbox.imageFiles.contains(restored))
    }

    @Test func cancellingKeepsTheOldWallpaper() async throws {
        let sandbox = Sandbox()
        try sandbox.addImage("a.png")
        try sandbox.writeState(#"{"TEST-DISPLAY": {"desktop": "a.png"}}"#)
        let display = testDisplay()
        let store = sandbox.store(displays: [display])
        let source = sandbox.folder.appendingPathComponent("clip.mov")
        try await makeTestVideo(at: source, seconds: 4)

        store.setMedia(from: source, slot: .desktop, display: display)
        store.cancelVideoConversion(.desktop, display: display)
        try await waitForImports(store, display)
        #expect(store.wallpapers(for: display).desktop == "a.png")
        #expect(store.lastError == nil)
        #expect(sandbox.imageFiles == ["a.png"])
    }
}
