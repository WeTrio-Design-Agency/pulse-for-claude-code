import AppKit

/// Draws the menu bar glyph: one mini ring per chat in progress (filled to its
/// progress), an orange "!" for a chat that needs you, a white check for a reply
/// you have not seen yet. With nothing going on, a quiet asterisk.
enum StatusIcon {
    static let slot: CGFloat = 15
    static let gap: CGFloat = 4

    enum Slot {
        case ring(Double)
        case overrunAt(Double)
        case overrun
        case needs
        case done
    }

    /// Identity of a glyph for redraw decisions: rings in 1/40 steps.
    static func key(_ s: Slot) -> String {
        switch s {
        case .ring(let p), .overrunAt(let p): return "r\(Int(p * 40))"
        case .overrun: return "o"
        case .needs: return "n"
        case .done: return "d"
        }
    }

    /// At most two glyphs: what needs your attention (a question, or a ready reply),
    /// then one ring for work in progress, followed by the time left.
    static func slots(for sessions: [Session]) -> [Slot] {
        var out: [Slot] = []
        if sessions.contains(where: { $0.state == .needsInput }) {
            out.append(.needs)
        } else if sessions.contains(where: { $0.state == .done && $0.unread }) {
            out.append(.done)
        }
        if let s = soonest(sessions) { out.append(.ring(s.progress)) }
        return out
    }

    /// The working chat that should finish first.
    static func soonest(_ sessions: [Session]) -> Session? {
        sessions.filter { $0.state == .working || $0.state == .stale }
            .min { ($0.remaining ?? .infinity) < ($1.remaining ?? .infinity) }
    }

    /// `glow`: a soft steady halo around the check (reply ready) or the "!" (needs you)
    /// until you open the panel. No blinking.
    static func image(slots: [Slot], dark: Bool, glow: Bool) -> NSImage {
        let fg = dark ? NSColor.white : NSColor.black
        let pad: CGFloat = 4
        let count = max(slots.count, 1)
        let width = CGFloat(count) * slot + CGFloat(count - 1) * gap + pad * 2
        let size = NSSize(width: width, height: 22)
        let img = NSImage(size: size, flipped: false) { _ in
            if slots.isEmpty {
                drawAsterisk(in: NSRect(x: pad, y: 3.5, width: slot, height: slot), color: fg.withAlphaComponent(0.92))
                return true
            }
            for (i, s) in slots.enumerated() {
                let r = NSRect(x: pad + CGFloat(i) * (slot + gap), y: 3.5, width: slot, height: slot)
                switch s {
                case .ring(let p), .overrunAt(let p): drawRing(in: r, progress: p, color: fg)
                case .overrun: drawRing(in: r, progress: 0.9, color: fg)
                case .needs:
                    if glow { halo(r, NSColor.systemOrange) }
                    drawBadge(in: r, color: NSColor.systemOrange, symbol: "!", fg: .white)
                case .done:
                    drawCheck(in: r, color: fg)
                }
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    private static func halo(_ r: NSRect, _ color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = color.withAlphaComponent(0.95)
        sh.shadowBlurRadius = 5
        sh.shadowOffset = .zero
        sh.set()
        color.withAlphaComponent(0.9).setFill()
        let p = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
        p.fill()
        p.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawRing(in r: NSRect, progress: Double, color: NSColor, spinning: Bool = false) {
        let lw: CGFloat = 2.2
        let rect = r.insetBy(dx: lw / 2 + 0.3, dy: lw / 2 + 0.3)
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lw
        color.withAlphaComponent(0.28).setStroke()
        track.stroke()

        let p = max(0.04, min(1, progress))
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                      endAngle: 90 - CGFloat(p) * 360, clockwise: true)
        arc.lineWidth = lw
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
        if spinning {
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 1.4, y: center.y - 1.4, width: 2.8, height: 2.8))
            color.setFill()
            dot.fill()
        }
    }

    private static func drawBadge(in r: NSRect, color: NSColor, symbol: String, fg: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 0.3, dy: 0.3)).fill()
        let font = NSFont.systemFont(ofSize: 11, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
        let str = NSAttributedString(string: symbol, attributes: attrs)
        let s = str.size()
        str.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2 + 0.5))
    }

    private static func drawCheck(in r: NSRect, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 0.3, dy: 0.3)).fill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.minX + r.width * 0.28, y: r.minY + r.height * 0.52))
        path.line(to: NSPoint(x: r.minX + r.width * 0.44, y: r.minY + r.height * 0.34))
        path.line(to: NSPoint(x: r.minX + r.width * 0.73, y: r.minY + r.height * 0.68))
        path.lineWidth = 1.9
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        // Knocked out of the disc, like checkmark.circle.fill: the menu bar shows through.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSColor.black.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawAsterisk(in r: NSRect, color: NSColor) {
        let c = NSPoint(x: r.midX, y: r.midY)
        let path = NSBezierPath()
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3 + .pi / 2
            path.move(to: NSPoint(x: c.x + cos(a) * 1.6, y: c.y + sin(a) * 1.6))
            path.line(to: NSPoint(x: c.x + cos(a) * 6.6, y: c.y + sin(a) * 6.6))
        }
        path.lineWidth = 2
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    // MARK: Text next to the glyph

    static func label(for sessions: [Session]) -> String {
        guard let s = soonest(sessions), let r = s.remaining else { return "" }
        return Format.short(r)
    }
}

enum Format {
    /// Finder-style estimate: "Less than a minute", "About 5 min", "About 1 h 10 min".
    static func about(_ seconds: Double) -> String {
        if seconds < 60 { return "Less than a minute" }
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "About \(m) min" }
        return m % 60 == 0 ? "About \(m / 60) h" : "About \(m / 60) h \(m % 60) min"
    }

    /// "4 min", "25 min", "1 h 5 min"
    static func minutes(_ seconds: Double) -> String {
        let m = max(1, Int((seconds / 60).rounded()))
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// "<1m", "~4m", "15m", "1h 10m"
    static func short(_ seconds: Double) -> String {
        if seconds < 60 { return "<1m" }
        let m = Int((seconds / 60).rounded())
        if m < 10 { return "\(m)m" }
        if m < 60 { return "\(Int((Double(m) / 5).rounded()) * 5)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    static func remaining(_ seconds: Double?) -> String {
        guard let s = seconds else { return "Longer than usual" }
        if s < 60 { return "Less than a minute" }
        let m = Int((s / 60).rounded())
        if m < 10 { return "About \(m) min left" }
        if m < 60 { return "About \(Int((Double(m) / 5).rounded()) * 5) min left" }
        return "About \(m / 60) h \(m % 60) min left"
    }

    /// Stopwatch style: 4:12, 1:02:09
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func ago(_ seconds: Double) -> String {
        if seconds < 60 { return "just now" }
        let m = Int(seconds / 60)
        if m < 60 { return "\(m) min ago" }
        return "\(m / 60) h ago"
    }
}
