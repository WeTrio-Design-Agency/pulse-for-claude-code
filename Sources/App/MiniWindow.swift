import AppKit
import Combine
import SwiftUI

/// A small floating window with the chats at a glance, shown while you are in another app.
/// One line per chat: icon, name, one short value. Click a line to open that chat;
/// hover shows a close button in the corner, like macOS notifications.

final class MiniState: ObservableObject {
    /// What the pointer is over: a session id, "close", or nil.
    @Published var hot: String?
    @Published var hover = false
    /// Chats that finished after this moment count as new (you left VS Code then).
    @Published var since: Double = 0
    var rects: [String: CGRect] = [:]

    /// The close button sits at the window's top-left corner; rows are inside the glass, offset by the inset.
    static let closeRect = CGRect(x: 0, y: 0, width: 24, height: 24)

    func target(at p: CGPoint) -> String? {
        if hover, Self.closeRect.contains(p) { return "close" }
        let q = CGPoint(x: p.x - MiniView.inset, y: p.y - MiniView.inset)
        return rects.first { $0.key != "more" && $0.value.contains(q) }?.key
    }
}

struct MiniRectsKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func miniRect(_ id: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: MiniRectsKey.self, value: [id: g.frame(in: .named("mini"))])
        })
    }
}

struct MiniView: View {
    @ObservedObject var store: Store
    @ObservedObject var state: MiniState

    static let inset: CGFloat = 7
    static let width: CGFloat = 236
    static let maxRows = 4

    /// Working and needs-you chats, plus replies that came in while you were away.
    static func items(_ store: Store, since: Double) -> [Session] {
        store.ordered.filter { $0.isActive || ($0.state == .done && $0.unread && $0.doneAt >= since) }
    }

    var body: some View {
        let items = Self.items(store, since: state.since)
        VStack(alignment: .leading, spacing: 0) {
                ForEach(items.prefix(Self.maxRows)) { s in
                    MiniRow(session: s, hot: state.hot == s.id).miniRect(s.id)
            }
            if items.count > Self.maxRows {
                    Text("\(items.count - Self.maxRows) more in the menu bar")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                }
            }
        .padding(5)
        .frame(width: Self.width, alignment: .leading)
        .coordinateSpace(name: "mini")
        .onPreferenceChange(MiniRectsKey.self) { state.rects = $0 }
    }
}

struct MiniRow: View {
    let session: Session
    let hot: Bool

    var body: some View {
        HStack(spacing: 7) {
            RowIcon(session: session, size: 15, line: 2.2, onAccent: hot).frame(width: 16, height: 16)
            Text(session.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(hot ? Color.white.opacity(0.85) : valueColor)
                .fixedSize()
        }
        .foregroundStyle(hot ? Color.white : Color.primary)
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hot ? Color.accentColor : Color.clear)
        )
    }

    /// Short value: "12m", "2 agents", "Needs you", "Ready".
    private var value: String {
        switch session.state {
        case .needsInput: return "Needs you"
        case .working, .stale:
            if session.isWaitingOnAgents, session.agentCount > 0 {
                let n = session.agentCount
                return "\(n) agent\(n == 1 ? "" : "s")"
            }
            guard let r = session.remaining else { return "Long" }
            return Format.short(r)
        case .done: return "Ready"
        case .idle: return ""
        }
    }

    private var valueColor: Color {
        switch session.state {
        case .needsInput: return .orange
        case .done: return .accentColor
        default: return .secondary
        }
    }
}

/// The round close button that hangs over the top-left corner, as on macOS notifications.
struct MiniCloseLayer: View {
    @ObservedObject var state: MiniState

    var body: some View {
        if state.hover { MiniClose(hot: state.hot == "close") }
    }
}

struct MiniClose: View {
    let hot: Bool

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.primary.opacity(hot ? 0.9 : 0.65))
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color(nsColor: hot ? .controlColor : .windowBackgroundColor)))
            .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .padding(2)
    }
}

// MARK: - Window

/// Takes every mouse event over the window: hover, click and drag. SwiftUI only draws,
/// so it behaves the same while another app is active (the window never becomes key).
final class MiniEvents: NSView {
    weak var controller: MiniController?
    private var tracking: NSTrackingArea?
    private var dragged = false
    private var downAt: NSPoint = .zero

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseEntered(with e: NSEvent) { controller?.hover(at: point(e)) }
    override func mouseMoved(with e: NSEvent) { controller?.hover(at: point(e)) }
    override func mouseExited(with e: NSEvent) { controller?.hover(at: nil) }

    override func mouseDown(with e: NSEvent) {
        dragged = false
        downAt = NSEvent.mouseLocation
    }

    override func mouseDragged(with e: NSEvent) {
        guard !dragged else { return }
        let p = NSEvent.mouseLocation
        if hypot(p.x - downAt.x, p.y - downAt.y) > 3 {
            dragged = true
            window?.performDrag(with: e)
        }
    }

    override func mouseUp(with e: NSEvent) {
        if !dragged { controller?.click(at: point(e)) }
        dragged = false
    }
}

final class MiniController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    let state = MiniState()
    private let store: Store
    private let hosting: NSHostingView<AnyView>
    private let closeHost: NSHostingView<AnyView>
    private let glass: NSView
    private var shadeView: NSView?
    var onOpen: ((Session) -> Void)?
    var onDismiss: (() -> Void)?

    private let posKey = "miniTopLeft"

    var isVisible: Bool { panel.isVisible }

    init(store: Store) {
        self.store = store
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow

        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        closeHost = NSHostingView(rootView: AnyView(EmptyView()))
        closeHost.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.style = .regular
            g.cornerRadius = 12
            glass = g
        } else {
            let fx = NSVisualEffectView()
            fx.material = .menu
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 12
            fx.layer?.cornerCurve = .continuous
            fx.layer?.masksToBounds = true
            glass = fx
        }
        glass.translatesAutoresizingMaskIntoConstraints = false

        let events = MiniEvents()
        events.translatesAutoresizingMaskIntoConstraints = false

        // Rows sit inside the glass (so text follows the glass's light or dark look, as in system menus);
        // the close button hangs over the corner outside it.
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: holder.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            g.contentView = holder
        } else {
            glass.addSubview(holder)
            NSLayoutConstraint.activate([
                holder.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                holder.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                holder.topAnchor.constraint(equalTo: glass.topAnchor),
                holder.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            ])
        }

        // A soft shadow under the glass so the window stands out on light backgrounds too.
        let shade = NSView()
        shade.translatesAutoresizingMaskIntoConstraints = false
        shade.wantsLayer = true
        shade.layer?.shadowColor = NSColor.black.cgColor
        shade.layer?.shadowOpacity = 0.22
        shade.layer?.shadowRadius = 6
        shade.layer?.shadowOffset = CGSize(width: 0, height: -2)
        shadeView = shade

        let root = NSView()
        root.addSubview(shade)
        root.addSubview(glass)
        root.addSubview(closeHost)
        root.addSubview(events)
        let inset = MiniView.inset
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            glass.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            glass.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            glass.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
            shade.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            shade.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            shade.topAnchor.constraint(equalTo: glass.topAnchor),
            shade.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            closeHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            closeHost.topAnchor.constraint(equalTo: root.topAnchor),
            closeHost.widthAnchor.constraint(equalToConstant: MiniState.closeRect.width),
            closeHost.heightAnchor.constraint(equalToConstant: MiniState.closeRect.height),
            events.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            events.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            events.topAnchor.constraint(equalTo: root.topAnchor),
            events.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        panel.contentView = root
        super.init()
        events.controller = self
        panel.delegate = self
    }

    func show() {
        if !panel.isVisible {
            // Content is mounted only while the window is out, so a hidden one costs nothing.
            hosting.rootView = AnyView(MiniView(store: store, state: state))
            closeHost.rootView = AnyView(MiniCloseLayer(state: state))
            layout()
            panel.orderFrontRegardless()
        } else {
            layout()
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        hosting.rootView = AnyView(EmptyView())
        closeHost.rootView = AnyView(EmptyView())
        state.hover = false
        state.hot = nil
    }

    /// Size to content, keeping the top-left corner where you put it.
    func layout() {
        let rows = hosting.fittingSize
        guard rows.height > 1 else { return }
        let size = NSSize(width: rows.width + 2 * MiniView.inset, height: rows.height + 2 * MiniView.inset)
        var topLeft = savedTopLeft() ?? defaultTopLeft(width: size.width)
        let screen = NSScreen.screens.first { $0.frame.contains(topLeft) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            topLeft.x = min(max(topLeft.x, vis.minX), vis.maxX - size.width)
            topLeft.y = min(max(topLeft.y, vis.minY + size.height), vis.maxY)
        }
        let frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if let layer = shadeView?.layer {
            let r = NSRect(origin: .zero, size: rows)
            layer.shadowPath = CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil)
        }
    }

    /// Top right of the main screen, just under the menu bar.
    private func defaultTopLeft(width: CGFloat) -> NSPoint {
        let vis = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vis.maxX - width - 10, y: vis.maxY - 4)
    }

    private func savedTopLeft() -> NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: posKey) else { return nil }
        let p = NSPointFromString(s)
        return NSScreen.screens.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(p) } ? p : nil
    }

    func windowDidMove(_ note: Notification) {
        guard panel.isVisible else { return }
        let f = panel.frame
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.minX, y: f.maxY)), forKey: posKey)
    }

    // MARK: Pointer

    func hover(at p: CGPoint?) {
        let inside = p != nil
        if state.hover != inside { state.hover = inside }
        let hot = p.flatMap { state.target(at: $0) }
        if state.hot != hot { state.hot = hot }
    }

    func click(at p: CGPoint) {
        guard let t = state.target(at: p) else { return }
        if t == "close" {
            onDismiss?()
        } else if let s = store.sessions[t] {
            onOpen?(s)
        }
    }
}
