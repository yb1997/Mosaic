import Foundation
import Testing
@testable import Mosaic

/// The updater's own mount and eject, on a small DMG built like a release.
struct UpdateMountTests {
    @Test func mountsAndEjectsADiskImage() throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("MosaicMountTest-\(UUID().uuidString)", isDirectory: true)
        let stage = work.appendingPathComponent("stage", isDirectory: true)
        let app = stage.appendingPathComponent("Fake.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: app.appendingPathComponent("marker"))
        defer { try? FileManager.default.removeItem(at: work) }

        let dmg = work.appendingPathComponent("test.dmg")
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        create.arguments = ["image", "create", "from", "--format", "UDZO", "--volumeName", "MosaicTest", stage.path, dmg.path]
        create.standardOutput = Pipe()
        create.standardError = Pipe()
        try create.run()
        create.waitUntilExit()
        try #require(create.terminationStatus == 0, "diskutil image create failed")

        let mountPoint = try UpdateInstaller.attach(dmg, under: work)
        let marker = mountPoint.appendingPathComponent("Fake.app/marker")
        #expect(try Data(contentsOf: marker) == Data("hello".utf8))
        #expect(!FileManager.default.isWritableFile(atPath: mountPoint.path))

        UpdateInstaller.detach(mountPoint)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
