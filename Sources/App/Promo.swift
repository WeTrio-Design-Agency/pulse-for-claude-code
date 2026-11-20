import AppKit
import SwiftUI

/// `--promo <dir>`: renders the real panel, floating window and menu bar icon with made-up chats
/// as transparent PNGs (4x) for the promo video, plus meta.json with their sizes in points.
@MainActor
func renderPromo(to dir: String) {
    let scale: CGFloat = 4
    var meta: [String: [String: Any]] = [:]

    var scheme = ColorScheme.light
    func save<V: View>(_ name: String, _ view: V, extra: [String: Any] = [:]) {
        let r = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        r.scale = scale
        guard let cg = r.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        var m: [String: Any] = ["w": CGFloat(cg.width) / scale, "h": CGFloat(cg.height) / scale]
        extra.forEach { m[$0.key] = $0.value }
        meta[name] = m
    }

    let prefs = Prefs()
    let usage = Usage(configURL: URL(fileURLWithPath: "/nonexistent"))
    usage.loadDemo()

    for (theme, sch) in [("", ColorScheme.light), ("-dark", ColorScheme.dark)] {
    scheme = sch
    for stage in ["start", "later", "opened"] {
        let store = Store(base: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pulse-promo"), demo: true)
        store.loadPromo(stage)

        // Panel, plain and with one row looking hovered.
        for hl in [nil, "a", "b", "c", "d", "Sound"] as [String?] {
            let v = PanelView(store: store, prefs: prefs, usage: usage, onOpen: { _ in }, onSettings: { _ in })
                .environment(\.promoMode, true)
                .environment(\.promoHighlight, hl)
            save("panel-\(stage)\(hl.map { "-\($0)" } ?? "")\(theme)", v)
        }

        // Floating window rows: the replies that came in after you left the editor (since = 10 s ago).
        for hot in [nil, "a", "b", "c"] as [String?] {
            let st = MiniState()
            st.since = store.now - 10
            st.hot = hot
            save("mini-\(stage)\(hot.map { "-\($0)" } ?? "")\(theme)", MiniView(store: store, state: st))
        }

        // Menu bar icon (white, as on a photo wallpaper) and its text.
        let list = store.ordered
        let icon = StatusIcon.image(slots: StatusIcon.slots(for: list), dark: true, glow: false)
        if theme.isEmpty {
            save("status-\(stage)", Image(nsImage: icon), extra: ["label": StatusIcon.label(for: list)])
        }
    }
    save("mini-close\(theme)", MiniClose(hot: false))
    save("mini-close-hot\(theme)", MiniClose(hot: true))
    }

    // Real menu bar symbols, white, at menu bar size.
    scheme = .dark
    for (name, symbol, size) in [("sym-apple", "applelogo", 15.0), ("sym-battery", "battery.100percent", 15.0),
                                 ("sym-wifi", "wifi", 14.0), ("sym-control", "switch.2", 14.0),
                                 ("sym-search", "magnifyingglass", 14.0)] {
        save(name, Image(systemName: symbol).font(.system(size: size, weight: .regular)).foregroundStyle(.white))
    }
    meta["_"] = ["inset": MiniView.inset, "miniWidth": MiniView.width]

    if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: "\(dir)/meta.json"))
    }
}
