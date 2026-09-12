import XCTest
@testable import TerminalVelocity

final class UpdateTests: XCTestCase {
    private func release(_ version: String, experimental: Bool = false, draft: Bool = false, host: String = "github.com") -> UpdateRelease {
        let name = "Velocity-\(version)-macOS-arm64\(experimental ? "-experimental" : "").zip"
        return UpdateRelease(tag_name: "v" + version, draft: draft, assets: [UpdateAsset(name: name,
            browser_download_url: "https://\(host)/magicseth/velocity/releases/download/v\(version)/\(name)", size: 100,
            digest: "sha256:" + String(repeating: "a", count: 64))])
    }
    func testChannelVersionAndHostValidation() {
        let releases = [release("0.1.9"), release("0.1.10"), release("0.1.11", experimental: true), release("9.0.0", draft: true), release("8.0.0", host: "example.com")]
        XCTAssertEqual(UpdateService.newest(releases, current: "0.1.8", experimental: false)?.version, "0.1.10")
        XCTAssertEqual(UpdateService.newest(releases, current: "0.1.8", experimental: true)?.version, "0.1.11")
        XCTAssertNil(UpdateService.newest(releases, current: "0.1.11", experimental: true))
        XCTAssertNil(UpdateService.newest([release("0.1.12")], current: "0.1.11", experimental: true), "Never replace an experimental app with a public build")
        XCTAssertNil(UpdateService.version("v1.2.3/../evil"))
    }
    func testArchivePathsCannotEscapeStaging() {
        XCTAssertTrue(UpdateService.archivePathAllowed("Terminal Velocity.app/Contents/MacOS/TerminalVelocity"))
        XCTAssertTrue(UpdateService.archivePathAllowed("__MACOSX/Terminal Velocity.app/Contents/._Info.plist"))
        XCTAssertFalse(UpdateService.archivePathAllowed("Terminal Velocity.app/../../other"))
        XCTAssertFalse(UpdateService.archivePathAllowed("/Applications/Other.app"))
        XCTAssertFalse(UpdateService.archivePathAllowed("Other.app/Contents/Info.plist"))
    }
    func testInstallerReplacementAndRollback() throws {
        for succeeds in [true, false] {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("VelocityUpdateTest-" + UUID().uuidString)
            defer { try? fm.removeItem(at: root) }
            let workspace = root.appendingPathComponent("staging")
            let target = root.appendingPathComponent("Velocity's app.app")
            let staged = workspace.appendingPathComponent("payload/Terminal Velocity.app")
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try fm.createDirectory(at: staged, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: target.appendingPathComponent("version"))
            try Data("new".utf8).write(to: staged.appendingPathComponent("version"))
            let script = root.appendingPathComponent("install.sh")
            try Data(UpdateInstaller.script.utf8).write(to: script)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = [script.path, String(Int32.max), workspace.path, target.path, succeeds ? "/usr/bin/true" : "/usr/bin/false"]
            try task.run(); task.waitUntilExit()
            XCTAssertEqual(task.terminationStatus, succeeds ? 0 : 1)
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("version")), succeeds ? "new" : "old")
        }
    }
    func testUnsignedAppIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UnsignedUpdate-" + UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "dev.seth.terminal-velocity", "CFBundleShortVersionString": "0.1.5", "VelocityExperimental": false]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: root.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try UpdateService.verifyApp(root, version: "0.1.5", experimental: false))
        XCTAssertThrowsError(try UpdateService.verifyApp(root, version: "0.1.5", experimental: true))
    }
}
