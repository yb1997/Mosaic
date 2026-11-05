import Foundation
import UniformTypeIdentifiers

/// How often a stored video wallpaper shows a new frame.
enum FrameRate: String, CaseIterable, Codable, Sendable {
    case fps24 = "24"
    case fps30 = "30"
    case fps60 = "60"
    /// The source's own rate.
    case original

    /// Frames per second, or nil for the source's own rate.
    var value: Double? {
        switch self {
        case .fps24: 24
        case .fps30: 30
        case .fps60: 60
        case .original: nil
        }
    }

    var title: String {
        value.map { "\(Int($0)) fps" } ?? "Original"
    }

    /// Lower rates first, so "at most as high as" can be compared.
    fileprivate var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// How much a stored video wallpaper is compressed.
enum VideoQuality: String, CaseIterable, Codable, Sendable {
    case smaller
    case balanced
    case high
    /// The source's video track, not re-encoded.
    case original

    var title: String {
        switch self {
        case .smaller: "Smaller"
        case .balanced: "Balanced"
        case .high: "High"
        case .original: "Original"
        }
    }

    /// VideoToolbox's constant-quality setting (0–1), or nil to keep the source as it is.
    /// Measured with AVAssetWriter on a 28 s 3024×1964 screen recording (61 MB),
    /// SSIM against the source: 0.5 → 0.973 (5.5 MB), 0.6 → 0.987 (11 MB),
    /// 0.7 → 0.995 (27 MB), 0.75 → 0.996 (33 MB).
    var encoderQuality: Double? {
        switch self {
        case .smaller: 0.5
        case .balanced: 0.65
        case .high: 0.75
        case .original: nil
        }
    }

    fileprivate var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// The frame rate and quality a video wallpaper is stored at.
struct VideoFormat: Hashable, Sendable {
    let frameRate: FrameRate
    let quality: VideoQuality

    /// Original quality keeps the source's track as it is, frames and all.
    init(frameRate: FrameRate, quality: VideoQuality) {
        self.quality = quality
        self.frameRate = quality == .original ? .original : frameRate
    }

    static let standard = VideoFormat(frameRate: .fps30, quality: .balanced)

    /// Whether this needs no more from the source than `other` kept, so it
    /// can be made from a copy stored at `other`.
    func isAtMost(_ other: VideoFormat) -> Bool {
        frameRate.rank <= other.frameRate.rank && quality.rank <= other.quality.rank
    }

    var title: String {
        quality == .original ? "Original" : "\(frameRate.title), \(quality.title)"
    }

    // MARK: Defaults

    static let frameRateKey = "videoFrameRate"
    static let qualityKey = "videoQuality"
    static let pausesOnBatteryKey = "pausesVideosOnBattery"

    /// The format new videos are stored at, set in Settings.
    static func `default`(in defaults: UserDefaults = .standard) -> VideoFormat {
        VideoFormat(
            frameRate: defaults.string(forKey: frameRateKey).flatMap(FrameRate.init) ?? standard.frameRate,
            quality: defaults.string(forKey: qualityKey).flatMap(VideoQuality.init) ?? standard.quality
        )
    }
}

/// A stored video wallpaper's files, all named after a hash of the source
/// video so the same video picked again at the same settings is reused:
/// `<hash>-<fps>-<quality>.mov` (the video), the same name with `.heic`
/// (its still frame), and `<hash>.original` (a bookmark to the source file).
struct VideoFile: Hashable, Sendable {
    /// SHA-256 of the source file, in hex.
    let sourceHash: String
    let format: VideoFormat

    init(sourceHash: String, format: VideoFormat) {
        self.sourceHash = sourceHash
        self.format = format
    }

    /// Reads a stored file name back; nil for images and anything else.
    init?(fileName: String) {
        guard fileName.hasSuffix(".mov") else { return nil }
        let parts = fileName.dropLast(4).split(separator: "-")
        guard parts.count == 3,
              let rate = FrameRate(rawValue: String(parts[1])),
              let quality = VideoQuality(rawValue: String(parts[2]))
        else { return nil }
        sourceHash = String(parts[0])
        format = VideoFormat(frameRate: rate, quality: quality)
    }

    var fileName: String { "\(stem).mov" }
    var stillName: String { "\(stem).heic" }
    var originalName: String { "\(sourceHash).original" }

    private var stem: String { "\(sourceHash)-\(format.frameRate.rawValue)-\(format.quality.rawValue)" }

    /// Whether a stored file name is a video wallpaper.
    static func isVideo(_ fileName: String?) -> Bool {
        fileName.flatMap(VideoFile.init(fileName:)) != nil
    }

    /// Whether a file picked or dropped is a video Mosaic can use.
    static func isVideoSource(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }
}
