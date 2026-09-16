import AppKit
import SwiftUI
import ApplicationServices

/// Shared visual vocabulary for the native welcome flow.
enum VelocityStyle {
    static let paper = Color(red: 0.97, green: 0.96, blue: 0.93)
    static let ink = Color(red: 0.13, green: 0.17, blue: 0.18)
    static let muted = Color(red: 0.38, green: 0.42, blue: 0.42)
    static let accent = Color(red: 0.77, green: 0.24, blue: 0.08)
    static let line = ink.opacity(0.12)
}

struct VelocityPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 22).padding(.vertical, 13)
            .foregroundStyle(.white)
            .background(VelocityStyle.ink.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct OnboardingView: View {
    @ObservedObject var model: PaletteModel
    let shortcuts: [String]
    let selectedShortcut: () -> Int
    let chooseShortcut: (Int) -> Bool
    let finish: () -> Void
    @State private var step = 0
    @State private var trusted = AXIsProcessTrusted()
    @State private var shortcutIssue: String?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let titles = ["Try it.\nFind your way back.", "Type. Choose.\nYou’re there.", "Let Velocity find\nyour windows.", "Make it\nsecond nature."]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(nsImage: Branding.menuIcon()).renderingMode(.template).resizable().scaledToFit().frame(width: 25, height: 25)
                    Text("velocity").font(.system(size: 23, weight: .semibold, design: .rounded)).tracking(-0.7)
                }
                Spacer()
                Text("LESS FRICTION.\nMORE FLOW.").font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(2.5).lineSpacing(7).foregroundStyle(Color.white.opacity(0.65))
                Text("Find your\nway back.").font(.system(size: 46, weight: .regular, design: .serif)).tracking(-1.8).lineSpacing(-2).padding(.top, 18)
                Rectangle().fill(Color(red: 1, green: 0.49, blue: 0.29)).frame(width: 44, height: 3).padding(.top, 25)
                Text("The tab. The terminal.\nThe thought you left open.").font(.system(size: 14)).lineSpacing(6).foregroundStyle(Color.white.opacity(0.75)).padding(.top, 23)
                Spacer()
                Text("MADE FOR YOUR MAC").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.8).foregroundStyle(Color.white.opacity(0.55))
            }.padding(34).frame(width: 280).frame(maxHeight: .infinity).background(VelocityStyle.ink).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("WELCOME TO VELOCITY").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.6).foregroundStyle(VelocityStyle.muted)
                    Spacer()
                    Text("0\(step + 1) / 04").font(.system(size: 11, design: .monospaced)).foregroundStyle(VelocityStyle.muted)
                }
                HStack(spacing: 5) {
                    ForEach(0..<4) { index in Capsule().fill(index <= step ? VelocityStyle.accent : VelocityStyle.line).frame(height: 3) }
                }.padding(.top, 18).accessibilityLabel("Step \(step + 1) of 4")
                Text(titles[step]).font(.system(size: 33, weight: .semibold)).tracking(-1.2).fixedSize(horizontal: false, vertical: true).padding(.top, 32)
                Group {
                    switch step {
                    case 0: OnboardingDemo()
                    case 1: howToUse
                    case 2: permissions
                    default: shortcut
                    }
                }.padding(.top, 20)
                Spacer(minLength: 16)
                Rectangle().fill(VelocityStyle.line).frame(height: 1)
                HStack {
                    if step > 0 {
                        Button("Back") { step -= 1 }.buttonStyle(.plain).foregroundStyle(VelocityStyle.muted)
                    } else {
                        Text("No permissions needed.").font(.system(size: 12)).foregroundStyle(VelocityStyle.muted)
                    }
                    Spacer()
                    Button(step == 3 ? "Search your Mac  ↗" : step == 2 && !trusted ? "Set up later  →" : "Continue  →") {
                        if step < 3 { step += 1 } else { finish() }
                    }.buttonStyle(VelocityPrimaryButton()).keyboardShortcut(.return, modifiers: step == 0 ? [.command] : [])
                }.padding(.top, 20)
            }.padding(36).frame(width: 500).frame(maxHeight: .infinity)
        }.frame(width: 780, height: 640).background(VelocityStyle.paper).foregroundStyle(VelocityStyle.ink)
            .tint(VelocityStyle.accent)
            .preferredColorScheme(.light)
            .onReceive(timer) { _ in trusted = AXIsProcessTrusted() }
    }
    private var howToUse: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search with your keyboard, or click a result. Here’s how:")
                .font(.system(size: 14)).lineSpacing(4).foregroundStyle(VelocityStyle.muted).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                feature("1.circle", "Press \(model.shortcut)", "The search box appears over your current app. You can also open it from Velocity’s menu-bar icon.")
                Rectangle().fill(VelocityStyle.line).frame(height: 1)
                feature("2.circle", "Type what you’re looking for", "For example, type “gmail”. Check the app name and tab details to pick the right match.")
                Rectangle().fill(VelocityStyle.line).frame(height: 1)
                feature("3.circle", "Use ↑ ↓, then press Return", "Arrow keys choose a result. Return opens it. Escape closes search and returns to your previous app.")
            }
        }
    }
    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 20, weight: .regular)).foregroundStyle(VelocityStyle.accent).frame(width: 26).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(VelocityStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 12)
    }
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Give Velocity the access it needs to find your open work. You can change this in System Settings anytime.").font(.system(size: 14)).lineSpacing(4).foregroundStyle(VelocityStyle.muted)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Accessibility", systemImage: trusted ? "checkmark.circle.fill" : "macwindow.badge.plus").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(trusted ? "CONNECTED" : "NEEDED FOR WINDOWS").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(trusted ? Color(red: 0.2, green: 0.43, blue: 0.31) : VelocityStyle.accent)
                }
                Text(trusted ? "Velocity can find your windows and bring your selection forward." : "Read window titles and bring your selection forward. Enable Velocity in the Accessibility list.").font(.system(size: 12)).foregroundStyle(VelocityStyle.muted).fixedSize(horizontal: false, vertical: true)
                Button(trusted ? "Open settings" : "Open Accessibility Settings") { model.openAccessibility() }.controlSize(.large)
            }.padding(18).background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Browser tabs").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button(model.browserTabsEnabled ? "Automation Settings" : "Enable tab search") {
                        if model.browserTabsEnabled { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!) }
                        else { model.enableBrowserTabs() }
                    }
                }
                Text("macOS may ask permission for each supported browser. Allow it to include tabs beyond the front window.").font(.system(size: 12)).foregroundStyle(VelocityStyle.muted)
            }
        }
    }
    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Try it now: search for an app or page you have open.").font(.system(size: 14)).foregroundStyle(VelocityStyle.muted)
            Text(model.shortcut).font(.system(size: 38, weight: .medium, design: .rounded)).tracking(2)
                .frame(maxWidth: .infinity).padding(.vertical, 24)
                .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(VelocityStyle.line))
                .accessibilityLabel("Current shortcut: \(model.shortcut)")
            HStack {
                Text("Keyboard shortcut").font(.system(size: 13, weight: .medium))
                Spacer()
                Picker("Keyboard shortcut", selection: Binding(get: selectedShortcut, set: { index in
                    shortcutIssue = chooseShortcut(index) ? nil : "That shortcut is unavailable. Your previous shortcut is unchanged. Try another."
                })) {
                    ForEach(shortcuts.indices, id: \.self) { index in Text(shortcuts[index]).tag(index) }
                }.labelsHidden().frame(width: 170)
            }
            if let issue = shortcutIssue ?? (model.shortcutRegistered ? nil : "The shortcut could not be registered. Choose another, or open Velocity from the menu bar.") { Text(issue).font(.system(size: 12)).foregroundStyle(VelocityStyle.accent) }
            Text("Option–Space is the default; your existing choice is kept. Change it here or under Keyboard Shortcut in the menu-bar menu.").font(.system(size: 12)).lineSpacing(3).foregroundStyle(VelocityStyle.muted)
            if Features.experimentalAgents {
                Label("Experimental: press again for Ask Velocity. Describe a target to open or a link to share, then review before approving.", systemImage: "text.bubble").font(.system(size: 12)).foregroundStyle(VelocityStyle.muted)
            }
        }
    }
}

extension AppDelegate {
    @objc func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 640), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Welcome to Velocity"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.contentView = NSHostingView(rootView: OnboardingView(model: model, shortcuts: shortcuts.map(\.0), selectedShortcut: {
                UserDefaults.standard.object(forKey: "shortcut") as? Int ?? 5
            }, chooseShortcut: { [weak self] in self?.registerShortcut($0) ?? false }, finish: { [weak self] in
                UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                self?.onboardingWindow?.orderOut(nil)
                self?.attentionNotifications.start()
                self?.show()
            }))
            window.center(); onboardingWindow = window
        }
        panel.orderOut(nil)
        NSApp.activate(); onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}
