import AppKit
import SwiftUI

@MainActor enum TabOrganizer {
    static let extensionID = "hjbjmjpmcanbfimojboeaddaodobojen"
    static func open(_ page: String) {
        guard let browser = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let url = URL(string: page) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
    }
    static func revealCompanion() {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("TidyTabs") else { return }
        // Copy outside the app bundle so app updates do not invalidate the loaded extension path.
        let destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Velocity/TidyTabs")
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: folder, to: destination) }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }
}

struct TabOrganizerSetupView: View {
    @ObservedObject var model: PaletteModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Tidy tabs", systemImage: "rectangle.stack.badge.minus").font(.system(size: 23, weight: .semibold))
                Spacer()
                Button("Back") { model.showTabOrganizer = false }
            }
            Text("Bring related tabs together. Review old tabs. Clean up exact duplicates.").font(.title3)
            Text("The Chrome companion can organize tabs without reloading their pages, read when they were last active, and preserve pinned or playing tabs. It works locally within each profile.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Text("One-time setup in Chrome").font(.headline)
                Text("1. Show the companion folder below.")
                Text("2. Open Chrome extensions and enable Developer mode.")
                Text("3. Choose Load unpacked and select the TidyTabs folder.")
                HStack {
                    Button("Show companion folder") { TabOrganizer.revealCompanion() }
                    Button("Open Chrome extensions") { TabOrganizer.open("chrome://extensions/") }
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            Text("Requires tab titles and URLs, tab groups, and local storage. No page-content access or AI service. Install separately in each Chrome profile. Safari organization is not supported yet.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Text("Already installed?").foregroundStyle(.secondary)
                Button("Open tab organizer") { TabOrganizer.open("chrome-extension://\(TabOrganizer.extensionID)/organizer.html") }.buttonStyle(.borderedProminent)
            }
        }.padding(26).frame(width: 680, height: 510).background(.regularMaterial)
    }
}
