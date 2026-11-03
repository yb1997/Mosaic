import AppKit
import Observation
import Security

/// Installs an update from the DMG attached to a GitHub release:
/// download → mount → verify the code signature → replace the app → relaunch.
/// Ported from FreeDisplay's updater.
///
/// Safety: the new app must satisfy the RUNNING app's designated requirement (same
/// bundle ID and signing certificate) and be a newer version, read from its own
/// Info.plist. The installed app is left untouched if any step fails.
@MainActor @Observable
final class UpdateInstaller {
    static let shared = UpdateInstaller()
    private init() {}

    enum State: Equatable {
        case idle
        case downloading(Double)  // 0…1
        case verifying
        case installing
        case relaunching
        case failed(String)
    }

    private(set) var state: State = .idle

    var isBusy: Bool {
        switch state {
        case .downloading, .verifying, .installing, .relaunching: true
        case .idle, .failed: false
        }
    }

    @ObservationIgnored private var progressObservation: NSKeyValueObservation?

    private enum UpdateError: Error {
        case message(String)
    }

    // MARK: - Availability

    /// Why this copy can't install updates by itself, or nil when it can.
    var unavailableReason: String? {
        let path = Bundle.main.bundlePath
        // An app run from Downloads without moving it runs from a random read-only
        // location (App Translocation); a mounted DMG is read-only too.
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return "Move Mosaic to the Applications folder to install updates."
        }
        if Self.runningAppRequirement() == nil {
            return "This copy isn’t signed in a way that allows automatic updates."
        }
        return nil
    }

    // MARK: - Install

    /// Downloads the DMG at `dmgURL`, installs the app in it over the running copy and
    /// relaunches. On failure `state` becomes `.failed` and nothing is changed.
    func install(from dmgURL: URL) async {
        guard !isBusy else { return }
        if let reason = unavailableReason {
            state = .failed(reason)
            return
        }
        guard let requirement = Self.runningAppRequirement() else { return }

        let target = Bundle.main.bundleURL
        let currentVersion = UpdateService.shared.currentVersion
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicUpdate-\(UUID().uuidString)", isDirectory: true)
        var mountPoint: URL?

        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            state = .downloading(0)
            let dmg = try await download(dmgURL, to: workDir.appendingPathComponent("update.dmg"))

            state = .verifying
            let mount = try await Task.detached { try Self.attach(dmg, under: workDir) }.value
            mountPoint = mount
            let newApp = try Self.findApp(in: mount)
            try Self.verify(newApp, requirement: requirement, newerThan: currentVersion)

            state = .installing
            try await Self.replace(target, with: newApp)
        } catch {
            if let mount = mountPoint { await Task.detached { Self.detach(mount) }.value }
            try? FileManager.default.removeItem(at: workDir)
            if case UpdateError.message(let message) = error {
                state = .failed(message)
            } else {
                state = .failed("Couldn’t install the update: \(error.localizedDescription)")
            }
            return
        }

        if let mount = mountPoint { await Task.detached { Self.detach(mount) }.value }
        try? FileManager.default.removeItem(at: workDir)

        state = .relaunching
        relaunch(at: target)
    }

    // MARK: - Download

    private func download(_ url: URL, to destination: URL) async throws -> URL {
        let finished: URL = try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200  // file:// has no status
                guard let tmp, status == 200 else {
                    continuation.resume(throwing: UpdateError.message("Couldn’t download the update."))
                    return
                }
                // The temporary file is deleted when this handler returns: move it now.
                do {
                    try FileManager.default.moveItem(at: tmp, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            progressObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
                // Whole percents only; finer steps just redraw the same label.
                let fraction = (progress.fractionCompleted * 100).rounded(.down) / 100
                Task { @MainActor in
                    let installer = UpdateInstaller.shared
                    guard case .downloading(let shown) = installer.state, fraction > shown else { return }
                    installer.state = .downloading(fraction)
                }
            }
            task.resume()
        }
        progressObservation = nil
        return finished
    }

    // MARK: - Mount

    /// Mounts the DMG read-only, hidden from Finder, at a random point under `workDir`.
    private nonisolated static func attach(_ dmg: URL, under workDir: URL) throws -> URL {
        let output = try run("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-readonly", "-noautoopen", "-plist",
            "-mountrandom", workDir.path, dmg.path,
        ])
        guard let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let path = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw UpdateError.message("Couldn’t open the downloaded update.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private nonisolated static func detach(_ mountPoint: URL) {
        if (try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])) == nil {
            _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
        }
    }

    private static func findApp(in mountPoint: URL) throws -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let app = items.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.message("The downloaded update doesn’t contain Mosaic.")
        }
        return app
    }

    // MARK: - Verify

    /// The running app's designated requirement, or nil when it can't be used to check
    /// updates: an ad-hoc signature (no certificate) pins this exact build, so every
    /// update would fail the check.
    private nonisolated static func runningAppRequirement() -> SecRequirement? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certificates = dict[kSecCodeInfoCertificates as String] as? [Any],
              !certificates.isEmpty
        else { return nil }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// Throws unless `app` is validly signed, satisfies `requirement` (same bundle ID and
    /// certificate as the running app) and is newer than `currentVersion`.
    private static func verify(_ app: URL, requirement: SecRequirement, newerThan currentVersion: String) throws {
        var staticCode: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
        else {
            throw UpdateError.message("The downloaded update isn’t signed by Mosaic’s developer, so it wasn’t installed.")
        }

        // Read the version from the downloaded app itself, not from the release tag.
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let bundleID = info?["CFBundleIdentifier"] as? String,
              bundleID == Bundle.main.bundleIdentifier,
              let version = info?["CFBundleShortVersionString"] as? String,
              UpdateService.isNewerVersion(version, than: currentVersion)
        else {
            throw UpdateError.message("The downloaded version isn’t newer than this one, so it wasn’t installed.")
        }
    }

    // MARK: - Replace

    /// Copies the new app next to the old one (same volume), then swaps them. Falls back
    /// to one administrator-authorized step when the folder isn't writable.
    private nonisolated static func replace(_ target: URL, with newApp: URL) async throws {
        let folder = target.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(".Mosaic-update-\(UUID().uuidString).app")

        if FileManager.default.isWritableFile(atPath: folder.path) {
            do {
                _ = try run("/usr/bin/ditto", [newApp.path, staged.path])
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
                return
            } catch {
                try? FileManager.default.removeItem(at: staged)
                // Fall through to the administrator path (e.g. the app itself isn't writable).
            }
        }
        try await MainActor.run { try replaceWithAdministratorPrivileges(target, with: newApp) }
    }

    /// One shell step run with administrator privileges. Paths go through AppleScript's
    /// `quoted form of`, so spaces or quotes in them can't break the command. The old app
    /// is moved aside first and put back if moving the new one into place fails.
    private static func replaceWithAdministratorPrivileges(_ target: URL, with newApp: URL) throws {
        func literal(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = """
            set src to \(literal(newApp.path))
            set dst to \(literal(target.path))
            set newPath to dst & ".new"
            set oldPath to dst & ".old"
            do shell script "/bin/rm -rf " & quoted form of newPath & " " & quoted form of oldPath & " && /usr/bin/ditto " & quoted form of src & " " & quoted form of newPath & " && /bin/mv " & quoted form of dst & " " & quoted form of oldPath & " && { /bin/mv " & quoted form of newPath & " " & quoted form of dst & " || { /bin/mv " & quoted form of oldPath & " " & quoted form of dst & "; exit 1; }; } && /bin/rm -rf " & quoted form of oldPath with administrator privileges
            """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw UpdateError.message("Couldn’t install the update.")
        }
        script.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 {
                throw UpdateError.message("Installation was canceled.")
            }
            let message = error[NSAppleScript.errorMessage] as? String ?? ""
            throw UpdateError.message("Couldn’t install the update: \(message)")
        }
    }

    // MARK: - Relaunch

    /// Starts a small shell helper that waits (up to 30 s) for this process to exit and
    /// then opens the new copy, and quits. PID and path are passed as arguments, never
    /// pasted into the script.
    private func relaunch(at app: URL) {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 150 ]; do sleep 0.2; i=$((i+1)); done; /usr/bin/open \"$2\"",
            "sh", "\(ProcessInfo.processInfo.processIdentifier)", app.path,
        ]
        do {
            try helper.run()
        } catch {
            state = .failed("The update was installed. Quit and reopen Mosaic to finish.")
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    /// Runs a command and returns its standard output; throws when it exits non-zero.
    @discardableResult
    private nonisolated static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.message("Couldn’t install the update.")
        }
        return data
    }
}
