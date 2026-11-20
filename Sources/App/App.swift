import AppKit
import Combine
import SwiftUI

// MARK: - Preferences

final class Prefs: ObservableObject {
    /// Soft Apple alert tones (the modern iOS set ships with macOS), plus the classic Glass.
    static let tones = "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/Modern/"
    static let modern = ["Complete", "Aurora", "Bamboo", "Hello", "Input", "Keys", "Note", "Popcorn"]
    static let classic = ["Purr", "Glass", "Pop", "Tink", "Hero", "Ping", "Submarine", "Blow", "Bottle"]
    static let sounds = modern + classic
    private let d = UserDefaults.standard

    @Published var sound: String { didSet { d.set(sound, forKey: "readySound"); Prefs.play(sound) } }
    @Published var alertQuickReplies: Bool { didSet { d.set(alertQuickReplies, forKey: "alertQuickReplies") } }
    @Published var alwaysShow: Bool { didSet { d.set(alwaysShow, forKey: "alwaysShow") } }
    /// Ask Anthropic for current plan limits with Claude Code's sign-in. Off: show what Claude Code last saved.
    @Published var liveLimits: Bool { didSet { d.set(liveLimits, forKey: "liveLimits") } }
    /// The small floating window with the chats while you are in another app.
    @Published var floatingWindow: Bool { didSet { d.set(floatingWindow, forKey: "floatingWindow") } }

    init() {
        // Keep a sound chosen in the earlier build (stored under "sound").
        sound = d.string(forKey: "readySound") ?? "Bottle"
        alertQuickReplies = d.object(forKey: "alertQuickReplies") as? Bool ?? false
        alwaysShow = d.object(forKey: "alwaysShow") as? Bool ?? false
        liveLimits = d.object(forKey: "liveLimits") as? Bool ?? false
        floatingWindow = d.object(forKey: "floatingWindow") as? Bool ?? true
    }

    private static var current: NSSound?

    static func play(_ name: String) {
        guard !name.isEmpty else { return }
        let path = tones + name + ".m4r"
        let snd = FileManager.default.fileExists(atPath: path)
            ? NSSound(contentsOfFile: path, byReference: true)
            : NSSound(named: NSSound.Name(name))
        snd?.volume = 0.7
        current?.stop()
        current = snd
        snd?.play()
    }
}

// MARK: - Opening a chat

enum Opener {
    static func open(_ s: Session) {
        let entry = s.entry.lowercased()
        let term = s.term.lowercased()
        let dir = s.projectDir.isEmpty ? s.cwd : s.projectDir

        if entry.contains("desktop") {
            activate(bundleID: "com.anthropic.claudefordesktop")
            return
        }
        if entry.contains("vscode") || term == "vscode" || entry.isEmpty {
            // Bring the window of this workspace forward, then ask the Claude Code
            // extension to show this exact chat.
            if !dir.isEmpty { run(["-a", "Visual Studio Code", dir]) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                run(["vscode://anthropic.claude-code/open?session=\(s.id)"])
            }
            return
        }
        switch s.term {
        case "iTerm.app": activate(bundleID: "com.googlecode.iterm2")
        case "ghostty": activate(bundleID: "com.mitchellh.ghostty")
        case "WarpTerminal": activate(bundleID: "dev.warp.Warp-Stable")
        default: activate(bundleID: "com.apple.Terminal")
        }
    }

    private static func activate(bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private static func run(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        try? p.run()
    }
}

// MARK: - Panel window

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PanelController {
    let panel: KeyPanel
    private let hosting: NSHostingView<AnyView>
    private var monitors: [Any] = []
    private weak var anchor: NSStatusBarButton?
    var onClose: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    private let root: AnyView

    init(root: AnyView) {
        self.root = root
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 344, height: 200),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        // Content is mounted only while the panel is open, so a closed panel costs nothing.
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let background: NSView
        if #available(macOS 26.0, *) {
            // Liquid Glass, the material of system menus and Control Center in macOS 26.
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 18
            background = glass
        } else {
            let fx = NSVisualEffectView()
            fx.material = .menu
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 16
            fx.layer?.cornerCurve = .continuous
            fx.layer?.masksToBounds = true
            background = fx
        }
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: holder.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.contentView = holder
            // The glass draws its own rounded shadow; the window's square one shows at the corners.
            panel.hasShadow = false
        } else {
            background.addSubview(holder)
            NSLayoutConstraint.activate([
                holder.leadingAnchor.constraint(equalTo: background.leadingAnchor),
                holder.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                holder.topAnchor.constraint(equalTo: background.topAnchor),
                holder.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            ])
        }
        panel.contentView = background
    }

    func show(from button: NSStatusBarButton) {
        anchor = button
        hosting.rootView = root
        layout()
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.close(); return nil }
            return e
        } as Any)
    }

    /// Size to content and hang under the menu bar item, top edge fixed.
    func layout() {
        guard let button = anchor, let bw = button.window else { return }
        let size = hosting.fittingSize
        let b = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = bw.screen ?? NSScreen.main
        let vis = screen?.visibleFrame ?? .zero
        // Left edge lines up with the left edge of the menu bar item, like system menus.
        var x = b.minX
        x = min(max(x, vis.minX + 8), vis.maxX - size.width - 8)
        let top = b.minY - 6
        let frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        hosting.rootView = AnyView(EmptyView())
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        onClose?()
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let prefs = Prefs()
    let usage = Usage()
    private var item: NSStatusItem!
    private var panel: PanelController!
    private var bag = Set<AnyCancellable>()
    private var glow = false
    private var lastRenderKey = ""
    private var mini: MiniController!
    /// The editor is in front: the floating window stays out of the way.
    private var codeInFront = false
    /// Closed with its button: stays away until you come back to the editor.
    private var miniDismissed = false
    static let editors: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "ClaudePulse"
        if let b = item.button {
            b.target = self
            b.action = #selector(toggle)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageLeft
            b.imageHugsTitle = true
        }

        let root = PanelView(store: store, prefs: prefs, usage: usage,
                             onOpen: { [weak self] s in self?.open(s) },
                             onSound: { [weak self] row in self?.showSoundMenu(row: row) },
                             onSettings: { [weak self] row in self?.showSettings(row: row) })
        panel = PanelController(root: AnyView(root))
        // Like system menu bar items: a capsule behind the icon while the panel is open.
        panel.onClose = { [weak self] in
            self?.item.button?.highlight(false)
            self?.store.live = false
            self?.updateMini()
        }

        mini = MiniController(store: store)
        mini.onOpen = { [weak self] s in self?.open(s) }
        mini.onDismiss = { [weak self] in
            self?.miniDismissed = true
            self?.updateMini()
        }
        mini.state.since = Date().timeIntervalSince1970
        codeInFront = Self.editors.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let code = Self.editors.contains(app?.bundleIdentifier ?? "")
            if code {
                self.miniDismissed = false
            } else if self.codeInFront {
                // Left the editor now: replies from here on are the ones you have not seen.
                self.mini.state.since = Date().timeIntervalSince1970
            }
            self.codeInFront = code
            self.updateMini()
        }
        prefs.$floatingWindow
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMini() }
            .store(in: &bag)


        store.onAlert = { [weak self] kind, s in self?.alert(kind, s) }
        store.$now.combineLatest(store.$sessions)
            .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.render() }
            .store(in: &bag)
        store.$attentionPending
            .removeDuplicates()
            .sink { [weak self] on in self?.setGlow(on) }
            .store(in: &bag)

        store.start()
        render()

        // Plan limits: the saved numbers are re-read when Claude Code updates them; live ones every
        // 5 min while a chat is working (nothing changes when nobody works) and on opening the panel.
        usage.live = prefs.liveLimits
        usage.refresh()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let busy = self.store.sessions.values.contains { $0.isActive }
            self.usage.refresh(liveEvery: busy ? 300 : 1800)
        }

        // Remote control for scripts: show or hide the panel.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("local.claude-pulse.show"), object: nil, queue: .main) { [weak self] _ in
            guard let self, let b = self.item.button, !self.panel.isVisible else { return }
            self.item.isVisible = true
            self.toggle()
            _ = b
        }
        dnc.addObserver(forName: .init("local.claude-pulse.hide"), object: nil, queue: .main) { [weak self] _ in
            self?.panel.close()
        }
    }

    // MARK: Menu bar item

    private func render() {
        guard let b = item.button else { return }
        let list = store.ordered
        // Shows up only when there is something to see: work in progress, a reply
        // you have not opened, or something finished in the last 15 minutes.
        let relevant = list.contains { $0.isActive || $0.unread || ($0.state == .done && store.now - $0.doneAt < 15 * 60) }
        let visible = prefs.alwaysShow || relevant || panel.isVisible
        if item.isVisible != visible { item.isVisible = visible }
        let dark = b.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let slots = StatusIcon.slots(for: list)
        let text = StatusIcon.label(for: list)
        // Redraw only when what you see changes (ring moved a notch, minutes changed, glow).
        let key = "\(slots.map(StatusIcon.key))|\(text)|\(glow)|\(dark)"
        if key != lastRenderKey {
            lastRenderKey = key
            b.image = StatusIcon.image(slots: slots, dark: dark, glow: glow)
            b.attributedTitle = NSAttributedString(
                string: text.isEmpty ? "" : " " + text,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                             .baselineOffset: 0.5])
        }
        if panel.isVisible {
            panel.layout()
            if !b.isHighlighted { b.highlight(true) }
        }
        updateMini()
    }

    /// Out while you are in another app and a chat is working, needs you, or answered meanwhile.
    private func updateMini() {
        guard let mini else { return }
        let want = prefs.floatingWindow && !codeInFront && !miniDismissed && !panel.isVisible
            && !MiniView.items(store, since: mini.state.since).isEmpty
        if want { mini.show() } else { mini.hide() }
    }

    private func setGlow(_ on: Bool) {
        glow = on
        render()
    }

    /// One sound (Submarine by default) for everything that needs you. No banners.
    private func alert(_ kind: AlertKind, _ s: Session) {
        if kind == .done, !prefs.alertQuickReplies, s.lastDuration < 20 {
            // A quick answer you were most likely watching: no sound, no glow.
            store.attentionPending = store.sessions.values.contains { $0.state == .needsInput }
            return
        }
        Prefs.play(prefs.sound)
    }

    // MARK: Actions

    @objc private func toggle() {
        guard let b = item.button else { return }
        if panel.isVisible {
            panel.close()
        } else {
            store.acknowledge()
            store.live = true
            usage.refresh(liveEvery: 60)
            mini.hide()
            panel.show(from: b)
            // The button drops its own highlight on mouse-up; set it after that.
            DispatchQueue.main.async { b.highlight(true) }
        }
    }

    @objc private func pickSound(_ sender: NSMenuItem) {
        prefs.sound = sender.representedObject as? String ?? ""
    }

    @objc private func toggleQuick() { prefs.alertQuickReplies.toggle() }
    @objc private func toggleAlwaysShow() { prefs.alwaysShow.toggle(); render() }
    @objc private func toggleLiveLimits() {
        prefs.liveLimits.toggle()
        usage.live = prefs.liveLimits
        usage.refresh(liveEvery: 0)
    }

    /// The sound list on its own, hung beside the panel at the "Sound" row like a submenu.
    private func showSoundMenu(row: CGRect) {
        let menu = NSMenu()
        menu.addItem(soundItem(""))
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Modern"))
        Prefs.modern.forEach { menu.addItem(soundItem($0)) }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Classic"))
        Prefs.classic.forEach { menu.addItem(soundItem($0)) }
        popBeside(menu, row: row)
    }

    /// Hangs a menu beside the panel with its top at the row: right when there is room, otherwise left.
    private func popBeside(_ menu: NSMenu, row: CGRect) {
        let pf = panel.panel.frame
        let vis = (panel.panel.screen ?? NSScreen.main)?.visibleFrame ?? pf
        let w = menu.size.width
        let x = pf.maxX + w + 4 <= vis.maxX ? pf.maxX + 2 : pf.minX - w - 2
        let top = pf.maxY - row.minY + 5
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: top), in: nil)
    }

    private func soundItem(_ name: String) -> NSMenuItem {
        let it = NSMenuItem(title: name.isEmpty ? "None" : name, action: #selector(pickSound(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = name
        it.state = prefs.sound == name ? .on : .off
        return it
    }

    private func showSettings(row: CGRect) {
        let menu = NSMenu()
        let quick = NSMenuItem(title: "Sound for Quick Replies", action: #selector(toggleQuick), keyEquivalent: "")
        quick.target = self
        quick.state = prefs.alertQuickReplies ? .on : .off
        quick.toolTip = "Off: replies under 20 seconds finish silently, since you were likely watching."
        menu.addItem(quick)
        let always = NSMenuItem(title: "Always Show in Menu Bar", action: #selector(toggleAlwaysShow), keyEquivalent: "")
        always.target = self
        always.state = prefs.alwaysShow ? .on : .off
        always.toolTip = "Off: the icon appears only while a chat is working or a reply is waiting."
        menu.addItem(always)
        let liveItem = NSMenuItem(title: "Live Plan Limits", action: #selector(toggleLiveLimits), keyEquivalent: "")
        liveItem.target = self
        liveItem.state = prefs.liveLimits ? .on : .off
        liveItem.toolTip = "On: asks Anthropic for current limits with Claude Code's sign-in (read-only). Off: shows what Claude Code last saved."
        menu.addItem(liveItem)
        popBeside(menu, row: row)
    }

    private func open(_ s: Session) {
        store.markRead(s.id)
        panel.close()
        Opener.open(s)
    }
}

// MARK: - Snapshot mode (renders the UI to PNG for review, no window)

@MainActor
func renderSnapshots(to dir: String) {
    let store = Store(base: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pulse-demo"), demo: true)
    store.loadDemo()
    let prefs = Prefs()
    let usage = Usage(configURL: URL(fileURLWithPath: "/nonexistent"))
    usage.loadDemo()
    for (name, scheme) in [("panel-dark", ColorScheme.dark), ("panel-light", ColorScheme.light)] {
        let view = PanelView(store: store, prefs: prefs, usage: usage, onOpen: { _ in }, onSettings: { _ in })
            .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.94))
            .environment(\.colorScheme, scheme)
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage { write(img, to: "\(dir)/\(name).png") }
    }
    let empty = Store(base: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pulse-empty"), demo: true)
    let r = ImageRenderer(content: PanelView(store: empty, prefs: prefs, usage: Usage(configURL: URL(fileURLWithPath: "/nonexistent")), onOpen: { _ in }, onSettings: { _ in })
        .background(Color(white: 0.16)).environment(\.colorScheme, .dark))
    r.scale = 2
    if let img = r.nsImage { write(img, to: "\(dir)/panel-empty.png") }

    // Floating window, with and without the pointer over it.
    for (name, scheme, hover) in [("mini-dark", ColorScheme.dark, false), ("mini-light", ColorScheme.light, false),
                                  ("mini-hover", ColorScheme.dark, true)] {
        let st = MiniState()
        st.hover = hover
        st.hot = hover ? store.ordered.first?.id : nil
        let view = ZStack(alignment: .topLeading) {
            MiniView(store: store, state: st)
                .background(RoundedRectangle(cornerRadius: 12).fill(scheme == .dark ? Color(white: 0.2) : Color(white: 0.96)))
                .padding(.top, MiniView.inset).padding(.leading, MiniView.inset)
            MiniCloseLayer(state: st)
        }
            .padding(10)
            .background(scheme == .dark ? Color(white: 0.05) : Color(white: 0.75))
            .environment(\.colorScheme, scheme)
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage { write(img, to: "\(dir)/\(name).png") }
    }

    // Menu bar item states on a dark strip.
    let states: [(String, [Session])] = [
        ("bar-mixed", store.ordered),
        ("bar-idle", []),
        ("bar-working", store.ordered.filter { $0.state == .working }),
        ("bar-done", store.ordered.filter { $0.state == .done }),
    ]
    for (name, list) in states {
        let icon = StatusIcon.image(slots: StatusIcon.slots(for: list), dark: true, glow: true)
        let text = StatusIcon.label(for: list)
        let view = HStack(spacing: 4) {
            Image(nsImage: icon)
            if !text.isEmpty { Text(text).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.white) }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color(white: 0.12))
        let rr = ImageRenderer(content: view)
        rr.scale = 3
        if let img = rr.nsImage { write(img, to: "\(dir)/\(name).png") }
    }
}

func write(_ img: NSImage, to path: String) {
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}
