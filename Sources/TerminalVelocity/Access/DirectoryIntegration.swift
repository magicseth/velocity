import Foundation

extension AppDelegate {
    /// Enrollment is local process configuration, never a transport operation.
    func bootstrapDirectoryReader() {
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Velocity/Access", isDirectory: true)
            let bridge = try DirectoryBridge(broker: resourceBroker, directory: directory)
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "--enroll-directory-reader") {
                guard index + 1 < args.count, let launchIndex = args.firstIndex(of: "--directory-reader-launch"), launchIndex + 1 < args.count else { throw AccessError.unsupported }
                try bridge.enroll(inventory: URL(fileURLWithPath: args[index + 1]), launch: URL(fileURLWithPath: args[launchIndex + 1]))
            }
            guard bridge.state != nil else { return }
            accessServer.directoryBridge = bridge
            try accessServer.start()
        } catch { model.message = "Directory reader unavailable: " + error.localizedDescription }
    }
}
