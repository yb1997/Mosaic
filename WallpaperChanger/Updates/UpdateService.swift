import AppKit
import Observation

/// Checks GitHub for a newer release. Automatic checks run at most once a day, at
/// launch and after waking; "Check Now" always checks.
@MainActor @Observable
final class UpdateService {
    static let shared = UpdateService()

    private let repoOwner = "yb1997"
    private let repoName = "WallpaperChanger"
    private let automaticInterval: TimeInterval = 24 * 60 * 60

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    private(set) var latestVersion: String?
    private(set) var releaseURL: URL?
    /// The release's DMG, used by UpdateInstaller. nil when the release has none
    /// (then only the release page can be offered).
    private(set) var dmgURL: URL?
    private(set) var hasUpdate = false
    private(set) var isChecking = false
    /// True when the last check couldn't reach GitHub or got an unusable reply.
    private(set) var lastCheckFailed = false

    var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Keys.automatic) }
    }

    private(set) var lastCheckDate: Date? {
        didSet { UserDefaults.standard.set(lastCheckDate, forKey: Keys.lastCheck) }
    }

    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    private enum Keys {
        static let automatic = "checkForUpdatesAutomatically"
        static let lastCheck = "lastUpdateCheck"
    }

    private init() {
        checksAutomatically = UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true
        lastCheckDate = UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date
    }

    /// Checks shortly after launch and after each wake, if a day has passed. No timer runs.
    func startAutomaticChecks() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await UpdateService.shared.checkIfDue() }
        }
        Task {
            try? await Task.sleep(for: .seconds(10))
            await checkIfDue()
        }
    }

    private func checkIfDue() async {
        guard checksAutomatically else { return }
        if let last = lastCheckDate, Date().timeIntervalSince(last) < automaticInterval { return }
        await checkForUpdates()
    }

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        lastCheckFailed = false
        defer {
            isChecking = false
            lastCheckDate = Date()
        }

        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else {
                lastCheckFailed = true
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            latestVersion = version
            releaseURL = (json["html_url"] as? String).flatMap(URL.init(string:))
            let assets = json["assets"] as? [[String: Any]] ?? []
            dmgURL = assets
                .first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
            hasUpdate = Self.isNewerVersion(version, than: currentVersion)
        } catch {
            lastCheckFailed = true
        }
    }

    func openReleasePage() {
        if let releaseURL { NSWorkspace.shared.open(releaseURL) }
    }

    /// Compares dotted version numbers (1.10.0 > 1.9.2); missing parts count as 0.
    nonisolated static func isNewerVersion(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let l = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
