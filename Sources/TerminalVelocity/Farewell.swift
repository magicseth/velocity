import AppKit
import SwiftUI

// VELOCITY IS NOW PART OF JULIA (0.2.0, the farewell build). Everything Velocity did — the
// ⌥Space palette, window and tab search, agents that need you, Julia's hands — lives inside
// Julia.app now. This build exists so the updater can carry that news to everyone who has
// Velocity: on launch it says so, offers the download, and does NOTHING else. No scanning,
// no hotkey, no menu-bar icon, and above all no reports to Julia — the merged Julia does
// that, and two reporters would double every row. A velocity:// link that still lands here
// is handed to Julia when it is installed.
enum Farewell {
    static let juliaBundleId = "dev.convex.fractal.mac"
    static let downloadURL = URL(string: "https://github.com/magicseth/velocity/releases/latest")!

    @MainActor static func show() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Velocity"
        window.isReleasedWhenClosed = false
        // A hosting CONTROLLER sized by its content — never a bare NSHostingView forced into a
        // hand-sized frame (the AppKit layout abort).
        let host = NSHostingController(rootView: FarewellView())
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// velocity:// still arrives here from older links: Julia owns those acts now.
    @MainActor static func forward(_ urls: [URL]) {
        guard let julia = NSWorkspace.shared.urlForApplication(withBundleIdentifier: juliaBundleId) else { return }
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        NSWorkspace.shared.open(urls.filter { $0.scheme == "velocity" }, withApplicationAt: julia, configuration: config)
    }
}

private struct FarewellView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                Text("Velocity is now part of Julia").font(.title2.weight(.semibold))
            }
            Text("Window search, ⌥Space, and the agents that need you all live in Julia now. Download Julia, then quit Velocity.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Quit Velocity") { NSApp.terminate(nil) }
                Button("Download Julia") { NSWorkspace.shared.open(Farewell.downloadURL) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
