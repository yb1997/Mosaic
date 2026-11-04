import Testing
@testable import Mosaic

struct VersionTests {
    @Test(arguments: [
        ("1.2.1", "1.2.0", true),
        ("1.10.0", "1.9.2", true),
        ("2.0", "1.99.99", true),
        ("1.2", "1.2.0", false),
        ("1.2.0", "1.2", false),
        ("1.2.0", "1.2.0", false),
        ("1.1.9", "1.2.0", false),
        ("1.2.0.1", "1.2", true),
    ])
    func comparesDottedVersions(remote: String, local: String, newer: Bool) {
        #expect(UpdateService.isNewerVersion(remote, than: local) == newer)
    }
}
