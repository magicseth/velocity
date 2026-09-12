import AppKit
import CryptoKit

struct UpdateAsset: Decodable, Sendable {
    let name: String
    let browser_download_url: String
    let size: Int
    let digest: String?
}
struct UpdateRelease: Decodable, Sendable {
    let tag_name: String
    let draft: Bool
    let assets: [UpdateAsset]
}
struct AvailableUpdate: Sendable {
    let version: String
    let asset: UpdateAsset
}

enum UpdateService {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func version(_ tag: String) -> String? {
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return value.range(of: #"^\d{1,5}\.\d{1,5}\.\d{1,5}$"#, options: .regularExpression) == nil ? nil : value
    }
    static func newest(_ releases: [UpdateRelease], current: String, experimental: Bool) -> AvailableUpdate? {
        releases.compactMap { release -> AvailableUpdate? in
            guard !release.draft, let version = version(release.tag_name),
                  version.compare(current, options: .numeric) == .orderedDescending else { return nil }
            let name = "Velocity-\(version)-macOS-arm64\(experimental ? "-experimental" : "").zip"
            guard let asset = release.assets.first(where: { $0.name == name }),
                  asset.size > 0, asset.size <= 50_000_000,
                  asset.browser_download_url == "https://github.com/magicseth/velocity/releases/download/\(release.tag_name)/\(name)",
                  let digest = asset.digest, digest.range(of: #"^sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil else { return nil }
            return AvailableUpdate(version: version, asset: asset)
        }.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }
    static func check(current: String, experimental: Bool) async throws -> AvailableUpdate? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/magicseth/velocity/releases?per_page=30")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Velocity/\(current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000 else {
            throw Failure(message: "Couldn’t check GitHub for updates. Try again in a moment.")
        }
        return newest(try JSONDecoder().decode([UpdateRelease].self, from: data), current: current, experimental: experimental)
    }
    static func run(_ command: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(message: "Update verification or installation failed. Your current app has been kept.") }
    }
    static func archivePathAllowed(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return false }
        return path == "Terminal Velocity.app/" || path.hasPrefix("Terminal Velocity.app/")
            || path == "__MACOSX/" || path.hasPrefix("__MACOSX/Terminal Velocity.app/")
    }
    static func inspectArchive(_ archive: URL, workspace: URL) throws {
        func listing(_ option: String) throws -> String {
            let output = workspace.appendingPathComponent("archive-list.txt")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
            process.arguments = [option, archive.path]
            process.standardOutput = handle; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0,
                  (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 1_000_000 else {
                throw Failure(message: "The update archive is invalid.")
            }
            return try String(contentsOf: output, encoding: .utf8)
        }
        let paths = try listing("-1").split(separator: "\n").map(String.init)
        let details = try listing("-l")
        let sizePattern = try NSRegularExpression(pattern: #"(\d+) bytes uncompressed"#)
        let range = NSRange(details.startIndex..., in: details)
        guard !paths.isEmpty, paths.allSatisfy(archivePathAllowed),
              !details.split(separator: "\n").contains(where: { $0.hasPrefix("l") }),
              let match = sizePattern.firstMatch(in: details, range: range),
              let bytesRange = Range(match.range(at: 1), in: details),
              let bytes = Int(details[bytesRange]), bytes <= 100_000_000 else {
            throw Failure(message: "The update archive contains unsupported paths or is too large.")
        }
    }
    static func verifyApp(_ app: URL, version: String, experimental: Bool) throws {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "dev.seth.terminal-velocity",
              info["CFBundleShortVersionString"] as? String == version,
              (info["VelocityExperimental"] as? Bool ?? false) == experimental else {
            throw Failure(message: "The downloaded app has the wrong version or update channel.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R",
            #"=identifier "dev.seth.terminal-velocity" and anchor apple generic and certificate leaf[subject.OU] = "TCU64E3XV4""#, app.path])
    }
    static func prepare(_ update: AvailableUpdate, target: URL, experimental: Bool) async throws -> URL {
        let fm = FileManager.default
        guard target.pathExtension == "app", fm.isWritableFile(atPath: target.deletingLastPathComponent().path),
              !target.path.contains("/AppTranslocation/") else {
            throw Failure(message: "Move Velocity to Applications or another writable folder before updating.")
        }
        let workspace = target.deletingLastPathComponent().appendingPathComponent(".velocity-update-" + UUID().uuidString)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var request = URLRequest(url: URL(string: update.asset.browser_download_url)!)
            request.timeoutInterval = 120
            let (download, response) = try await URLSession.shared.download(for: request)
            defer { try? fm.removeItem(at: download) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "The update download failed. Try again.") }
            let size = try download.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size == update.asset.size else { throw Failure(message: "The update download is incomplete.") }
            let data = try Data(contentsOf: download, options: .mappedIfSafe)
            let digest = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == update.asset.digest else { throw Failure(message: "The update checksum did not match. Nothing was installed.") }
            try inspectArchive(download, workspace: workspace)
            let payload = workspace.appendingPathComponent("payload")
            try run("/usr/bin/ditto", ["-x", "-k", download.path, payload.path])
            let app = payload.appendingPathComponent("Terminal Velocity.app")
            try verifyApp(app, version: update.version, experimental: experimental)
            return workspace
        } catch {
            try? fm.removeItem(at: workspace)
            throw error
        }
    }
}

enum UpdateInstaller {
    // Arguments are passed separately, never interpolated into shell code. Stage and
    // backup share the app's volume, so replacement uses atomic directory renames.
    static let script = #"""
    set -eu
    old_pid="$1"
    workspace="$2"
    target="$3"
    launcher="$4"
    attempts=0
    while /bin/kill -0 "$old_pid" 2>/dev/null; do
      attempts=$((attempts + 1))
      if [ "$attempts" -ge 100 ]; then exit 1; fi
      /bin/sleep 0.1
    done
    backup="$workspace/Previous.app"
    staged="$workspace/payload/Terminal Velocity.app"
    /bin/mv "$target" "$backup" || exit 1
    if ! /bin/mv "$staged" "$target"; then
      /bin/mv "$backup" "$target"
      "$launcher" -n "$target" || true
      exit 1
    fi
    if ! "$launcher" -n "$target"; then
      /bin/mv "$target" "$workspace/Failed.app"
      /bin/mv "$backup" "$target"
      "$launcher" -n "$target" || true
      exit 1
    fi
    /bin/rm -rf "$workspace"
    """#

    static func launch(workspace: URL, target: URL) throws {
        let scriptURL = workspace.appendingPathComponent("install.sh")
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), workspace.path, target.path, "/usr/bin/open"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

@MainActor final class AppUpdater {
    private var checking = false
    func check() {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            do {
                #if !arch(arm64)
                throw UpdateService.Failure(message: "Automatic updates currently support Apple silicon. Intel Macs can update from source.")
                #else
                let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
                guard let update = try await UpdateService.check(current: current, experimental: Features.experimentalAgents) else {
                    alert("You’re up to date", "Velocity \(current) is the newest available version for this build.")
                    return
                }
                let prompt = NSAlert()
                prompt.messageText = "Velocity \(update.version) is available"
                prompt.informativeText = "Download and restart to update. Your settings\(Features.experimentalAgents ? " and experimental features" : "") will be preserved."
                prompt.addButton(withTitle: "Download & Restart")
                prompt.addButton(withTitle: "Later")
                NSApp.activate()
                guard prompt.runModal() == .alertFirstButtonReturn else { return }
                let progress = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
                progress.title = "Updating Velocity"
                let label = NSTextField(labelWithString: "Downloading and verifying update…")
                label.frame = NSRect(x: 20, y: 32, width: 300, height: 20)
                progress.contentView?.addSubview(label)
                progress.center(); progress.makeKeyAndOrderFront(nil)
                defer { progress.orderOut(nil) }
                let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
                let workspace = try await UpdateService.prepare(update, target: target, experimental: Features.experimentalAgents)
                do { try UpdateInstaller.launch(workspace: workspace, target: target) }
                catch { try? FileManager.default.removeItem(at: workspace); throw error }
                NSApp.terminate(nil)
                #endif
            } catch {
                alert("Couldn’t update Velocity", error.localizedDescription)
            }
        }
    }
    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
