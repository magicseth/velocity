import AppKit
import SwiftUI

/// A CHIP THAT FOLLOWS THE ACTIVE WINDOW, naming its project — "every time the active window
/// changes, add the project chip above it." When the window has no project, the chip is a
/// clickable "＋ Tag project" that opens a type-to-filter picker to select or create one.
@MainActor final class ActiveProjectChip {
    private let chip = ClickPanel()
    private var picker: NSPanel?
    private var current: (sig: String, windowID: CGWindowID)?
    var isShowing: Bool { chip.isVisible }
    var projects: () -> [JuliaProjectRow] = { [] }
    var onAssign: (_ sig: String, _ projectId: String) -> Void = { _, _ in }
    var onCreate: (_ sig: String, _ title: String) -> Void = { _, _ in }

    init() {
        chip.onClick = { [weak self] in self?.togglePicker() }
    }

    /// Show/refresh the chip above `windowID`. `project` nil → the tag affordance.
    func show(windowID: CGWindowID, sig: String, project: String?) {
        guard let f = WindowRaise.frame(of: windowID) else { hide(); return }
        current = (sig, windowID)
        chip.render(project: project)
        let size = chip.frame.size
        chip.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height + 15))
        chip.level = NSWindow.Level(rawValue: (WindowRaise.layer(of: windowID) ?? 0) + 1)
        chip.orderFrontRegardless()
        if picker != nil { positionPicker() }
    }
    func hide() { chip.orderOut(nil); closePicker(); current = nil }
    /// Close only the picker (a window switch / click elsewhere), leaving the chip to re-place.
    func dismissPicker() { closePicker() }
    var pickerOpen: Bool { picker != nil }

    private func togglePicker() { if picker == nil { openPicker() } else { closePicker() } }
    private func closePicker() { picker?.orderOut(nil); picker = nil }
    private func openPicker() {
        guard let cur = current else { return }
        let sig = cur.sig
        let view = ProjectPickerView(projects: projects(),
            assign: { [weak self] id in self?.onAssign(sig, id); self?.closePicker() },
            create: { [weak self] title in self?.onCreate(sig, title); self?.closePicker() },
            cancel: { [weak self] in self?.closePicker() })
        let host = NSHostingView(rootView: view)
        host.setFrameSize(NSSize(width: 260, height: 320))
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 320), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .floating; p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.contentView = host
        picker = p
        positionPicker()
        // A key-capable nonactivating panel takes keystrokes WITHOUT activating Velocity as a
        // whole (activating it was making its palette appear). becomesKeyOnlyIfNeeded lets the
        // text field become first responder for typing.
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(host)
    }
    private func positionPicker() {
        guard let p = picker else { return }
        let cf = chip.frame
        p.setFrameOrigin(NSPoint(x: min(cf.midX - 130, (NSScreen.main?.frame.maxX ?? 9999) - 270), y: cf.minY - 328))
    }

    /// A borderless panel that reports a click (the chip taps into the picker).
    final class ClickPanel: NSPanel {
        var onClick: () -> Void = {}
        private let label = NSTextField(labelWithString: "")
        private let bg = NSView()
        init() {
            super.init(contentRect: NSRect(x: 0, y: 0, width: 60, height: 26), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            isOpaque = false; backgroundColor = .clear; hasShadow = true
            collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            bg.wantsLayer = true; bg.layer?.cornerRadius = 9
            label.font = .systemFont(ofSize: 12, weight: .semibold); label.textColor = .white
            bg.addSubview(label); label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 11),
                label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -11),
                label.centerYAnchor.constraint(equalTo: bg.centerYAnchor)])
            contentView = bg
        }
        func render(project: String?) {
            label.stringValue = project.map { "◆  " + $0 } ?? "＋  Tag project"
            bg.layer?.backgroundColor = (project != nil ? NSColor.systemBlue : NSColor.systemGray).withAlphaComponent(0.95).cgColor
            let w = label.fittingSize.width + 22
            setContentSize(NSSize(width: w, height: 26)); bg.frame = NSRect(x: 0, y: 0, width: w, height: 26)
        }
        override func mouseDown(with event: NSEvent) { onClick() }
    }
    final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var becomesKeyOnlyIfNeeded: Bool { get { false } set {} }
    }
}

/// Type to filter existing projects; Enter or a row assigns; "Create" makes a new one.
private struct ProjectPickerView: View {
    let projects: [JuliaProjectRow]
    let assign: (String) -> Void
    let create: (String) -> Void
    let cancel: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool
    private var filtered: [JuliaProjectRow] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return Array(projects.prefix(40)) }
        return projects.filter { p in ([p.title] + p.matchNames).contains { $0.lowercased().contains(q) } }
    }
    private var exact: Bool { projects.contains { $0.title.lowercased() == query.lowercased().trimmingCharacters(in: .whitespaces) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Filter or name a project", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { let q = query.trimmingCharacters(in: .whitespaces); if let f = filtered.first, exact || filtered.count == 1 { assign(f.id) } else if !q.isEmpty { create(q) } }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(filtered) { p in
                        Button { assign(p.id) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Color.blue).frame(width: 6, height: 6)
                                Text(p.title).lineLimit(1)
                                Spacer()
                            }.contentShape(Rectangle()).padding(.vertical, 3).padding(.horizontal, 6)
                        }.buttonStyle(.plain)
                    }
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty, !exact {
                        Divider()
                        Button { create(query.trimmingCharacters(in: .whitespaces)) } label: {
                            HStack(spacing: 6) { Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                                Text("Create “\(query.trimmingCharacters(in: .whitespaces))”").lineLimit(1); Spacer() }
                                .contentShape(Rectangle()).padding(.vertical, 3).padding(.horizontal, 6)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 260, height: 320)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .onExitCommand { cancel() }
        .onAppear { DispatchQueue.main.async { focused = true } }   // type immediately, no click into the field
    }
}
