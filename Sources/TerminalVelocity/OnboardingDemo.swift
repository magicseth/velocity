import SwiftUI
import AppKit

/// A self-contained tutorial. No discovery, networking, app activation, or permissions.
struct OnboardingDemo: View {
    private struct Sample: Identifiable {
        let id: Int
        let title: String
        let detail: String
        let icon: String
        let appID: String
    }
    private let samples = [
        Sample(id: 0, title: "Atlas · Project dashboard", detail: "Google Chrome · Tab · atlas.example", icon: "globe", appID: "com.google.Chrome"),
        Sample(id: 1, title: "Atlas website", detail: "Terminal · Tab · ~/Projects/atlas", icon: "terminal", appID: "com.apple.Terminal"),
        Sample(id: 2, title: "Atlas launch · Maya", detail: "Messages · Conversation", icon: "message.fill", appID: "com.apple.MobileSMS"),
        Sample(id: 3, title: "#atlas-launch", detail: "Slack · Channel · Acme workspace", icon: "number", appID: "com.tinyspeck.slackmacgap"),
        Sample(id: 4, title: "Atlas design notes", detail: "Notes · Window", icon: "note.text", appID: "com.apple.Notes"),
        Sample(id: 5, title: "Fix Atlas sign-in", detail: "Conductor · Workspace", icon: "rectangle.3.group", appID: "com.conductor.app"),
        Sample(id: 6, title: "Plan the Atlas launch", detail: "ChatGPT · Conversation", icon: "text.bubble", appID: "com.openai.chat"),
        Sample(id: 7, title: "Inbox · Gmail", detail: "Google Chrome · Tab · mail.google.com", icon: "envelope", appID: "com.google.Chrome"),
        Sample(id: 8, title: "Swift documentation", detail: "Safari · Tab · swift.org", icon: "safari", appID: "com.apple.Safari")
    ]
    @State private var query = ""
    @State private var selected = 0
    @State private var opened: Sample?
    @FocusState private var focused: Bool
    private var matches: [Sample] {
        let words = query.split(whereSeparator: \.isWhitespace)
        return samples.filter { item in words.allSatisfy { (item.title + " " + item.detail).localizedCaseInsensitiveContains($0) } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tabs, terminals, messages, and more. Try “atlas” or “slack”.")
                .font(.system(size: 14)).foregroundStyle(VelocityStyle.muted).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                HStack {
                    Text("INTERACTIVE DEMO").tracking(1.3)
                    Spacer()
                    Text("SAMPLE DATA")
                }.font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(VelocityStyle.muted).padding(12)
                Divider()
                if let opened {
                    VStack(alignment: .leading, spacing: 13) {
                        Label("You found it.", systemImage: "checkmark.circle.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(VelocityStyle.accent)
                        HStack(spacing: 10) {
                            sampleIcon(opened)
                            Text(opened.title).font(.system(size: 20, weight: .medium))
                        }
                        Text(opened.detail).font(.system(size: 12)).foregroundStyle(VelocityStyle.muted)
                        Text("On your Mac, Velocity would switch to this specific tab, conversation, or workspace in its app.").font(.system(size: 13)).foregroundStyle(VelocityStyle.muted).fixedSize(horizontal: false, vertical: true)
                        Button("Try another search") { reset() }.controlSize(.large)
                    }.padding(18).frame(maxWidth: .infinity, minHeight: 195, alignment: .leading)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(VelocityStyle.muted)
                        TextField("Search tabs, terminals, people…", text: $query)
                            .textFieldStyle(.plain).font(.system(size: 16)).focused($focused)
                            .accessibilityLabel("Search demo windows")
                            .onChange(of: query) { selected = 0 }
                            .onSubmit { choose() }
                            .onKeyPress(.downArrow) { move(1); return .handled }
                            .onKeyPress(.upArrow) { move(-1); return .handled }
                            .onKeyPress(.escape) { query = ""; return .handled }
                    }.padding(13)
                    Divider()
                    ScrollViewReader { proxy in
                    ScrollView {
                    VStack(spacing: 2) {
                        if matches.isEmpty {
                            Text("No sample matches. Try “atlas”, “slack”, or “messages”.")
                                .font(.system(size: 13)).foregroundStyle(VelocityStyle.muted)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                                Button { selected = index; choose() } label: {
                                    HStack(spacing: 11) {
                                        sampleIcon(item)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.title).font(.system(size: 12, weight: .semibold))
                                            Text(item.detail).font(.system(size: 10)).foregroundStyle(VelocityStyle.muted)
                                        }
                                        Spacer()
                                        if index == selected { Image(systemName: "return").font(.system(size: 12)).foregroundStyle(VelocityStyle.muted) }
                                    }.padding(6).contentShape(Rectangle())
                                        .background(index == selected ? VelocityStyle.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain).accessibilityLabel("\(item.title), \(item.detail)").id(item.id)
                            }
                        }
                    }.padding(6).frame(maxWidth: .infinity, alignment: .top)
                    }.frame(height: 180)
                        .onChange(of: selected) {
                            if matches.indices.contains(selected) { proxy.scrollTo(matches[selected].id, anchor: .center) }
                        }
                        .onChange(of: query) {
                            if let first = matches.first { proxy.scrollTo(first.id, anchor: .top) }
                        }
                    }
                }
            }.background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(VelocityStyle.line))
            Text(opened == nil ? "Scroll for more · ↑ ↓ to choose · Return to open" : "Only a demo. No apps were opened or permissions requested.")
                .font(.system(size: 11)).foregroundStyle(VelocityStyle.muted)
        }.onAppear { focused = true }
    }
    @ViewBuilder private func sampleIcon(_ sample: Sample) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sample.appID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().frame(width: 25, height: 25)
        } else {
            Image(systemName: sample.icon).font(.system(size: 19)).frame(width: 25).foregroundStyle(VelocityStyle.accent)
        }
    }
    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selected = (selected + delta + matches.count) % matches.count
    }
    private func choose() {
        guard matches.indices.contains(selected) else { return }
        opened = matches[selected]
    }
    private func reset() { opened = nil; query = ""; selected = 0; focused = true }
}
