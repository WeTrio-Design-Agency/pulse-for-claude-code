import AppKit
import SwiftUI

/// The popover, laid out like the system Battery and Wi-Fi menus:
/// a title line, grey group captions, one plain row per chat, settings at the bottom.
/// No animation, no decoration: icon, name, one line of detail, one value on the right.
struct PanelView: View {
    @ObservedObject var store: Store
    @ObservedObject var prefs: Prefs
    @ObservedObject var usage: Usage
    var onOpen: (Session) -> Void
    /// Gets the Sound row's frame (window coordinates, top-left origin) to hang the list beside it.
    var onSound: (CGRect) -> Void = { _ in }
    @State private var soundRow: CGRect = .zero
    var onSettings: (CGRect) -> Void
    @State private var settingsRow: CGRect = .zero

    private var list: [Session] { store.ordered }
    private var needs: [Session] { list.filter { $0.state == .needsInput } }
    private var working: [Session] { list.filter { $0.state == .working || $0.state == .stale } }
    private var ready: [Session] { list.filter { $0.state == .done && $0.unread } }
    private var recent: [Session] {
        Array(list.filter { ($0.state == .done && !$0.unread) || $0.state == .idle }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude Code").font(.system(size: 13, weight: .bold))
                Spacer()
                Text(summary).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if list.isEmpty {
                Text("No chats running")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            group("Needs You", needs)
            group("Working", working)
            group("Ready", ready)
            group("Recent", recent)

            UsageSection(usage: usage, now: store.now)

            Divider().padding(.horizontal, 14).padding(.vertical, 6)
            ToggleRow(title: "Floating Window", isOn: $prefs.floatingWindow)
                .help("A small window with the chats while you are in another app. Hidden while VS Code is in front.")
            // Both open their list beside the panel, like submenus in system menus.
            MenuRow(title: "Settings", chevron: true) { onSettings(settingsRow) }
                .background(frameReader($settingsRow))
            MenuRow(title: "Sound", value: prefs.sound.isEmpty ? "None" : prefs.sound, chevron: true) { onSound(soundRow) }
                .background(frameReader($soundRow))
            if !ready.isEmpty || !recent.isEmpty {
                Divider().padding(.horizontal, 14).padding(.vertical, 6)
                MenuRow(title: "Clear Finished") { store.clearFinished() }
            }
            Spacer().frame(height: 5)
        }
        .frame(width: 320)
    }

    private func frameReader(_ rect: Binding<CGRect>) -> some View {
        GeometryReader { g in
            Color.clear
                .onAppear { rect.wrappedValue = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in rect.wrappedValue = f }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [Session]) -> some View {
        if !items.isEmpty {
            Divider().padding(.horizontal, 14).padding(.vertical, 6)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 3)
            ForEach(items) { s in
                ChatRow(session: s, now: store.now) { onOpen(s) }
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if !needs.isEmpty { parts.append("\(needs.count) need\(needs.count == 1 ? "s" : "") you") }
        if !working.isEmpty { parts.append("\(working.count) working") }
        if parts.isEmpty, !ready.isEmpty { parts.append("\(ready.count) ready") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Promo rendering

/// For the promo video: which row looks hovered ("chat id", or a menu row title), and draw the switch
/// ourselves (the system one does not render off screen).
private struct PromoHighlightKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct PromoModeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var promoHighlight: String? {
        get { self[PromoHighlightKey.self] }
        set { self[PromoHighlightKey.self] = newValue }
    }
    var promoMode: Bool {
        get { self[PromoModeKey.self] }
        set { self[PromoModeKey.self] = newValue }
    }
}

// MARK: - Row

struct ChatRow: View {
    let session: Session
    let now: Double
    let action: () -> Void
    @State private var hoverState = false
    @Environment(\.promoHighlight) private var promoHighlight
    private var hover: Bool { hoverState || promoHighlight == session.id }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RowIcon(session: session, onAccent: hover)
                    .frame(width: 20, height: 20)
                Text(session.displayTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(hover ? Color.white.opacity(0.85) : Color.secondary)
                    .fixedSize()
            }
            .foregroundStyle(hover ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hover ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hoverState = $0 }
        // The detail line lives in the tooltip: the row itself is icon, name, time.
        .help(detail)
    }

    /// One line: what is happening, in words.
    private var detail: String {
        let project = session.projectName
        let what: String
        switch session.state {
        case .needsInput: what = session.attention.isEmpty ? "Waiting for your answer" : session.attention
        case .working, .stale:
            if session.isWaitingOnAgents {
                what = session.agentCount > 0 ? session.agentNames : session.activity
            } else if session.agentCount > 0, session.kind != "agent" {
                // Agents in the background while the chat itself keeps working.
                let n = session.agentCount
                what = "\(n) agent\(n == 1 ? "" : "s") · \(session.activity)"
            } else if session.agentCount > 1 {
                what = session.agentsLine
            } else {
                what = session.activity
            }
        case .done: what = session.lastDuration > 0 ? "Finished in \(Format.minutes(session.lastDuration))" : "Finished"
        case .idle: what = session.activity.isEmpty ? "Stopped" : session.activity
        }
        return project.isEmpty ? what : "\(project) · \(what)"
    }

    /// One value on the right, like the percentage in the Battery menu.
    private var value: String {
        switch session.state {
        case .needsInput: return ""
        case .working, .stale:
            // Only agents are left: how many, not a time guess.
            if session.isWaitingOnAgents, session.agentCount > 0 {
                let n = session.agentCount
                return "\(n) agent\(n == 1 ? "" : "s")"
            }
            guard let r = session.remaining else { return "Running long" }
            return r < 60 ? "< 1 min left" : "\(Format.minutes(r)) left"
        case .done: return Format.ago(now - session.doneAt)
        case .idle: return ""
        }
    }
}

/// Static icon: a progress ring while working, a filled symbol otherwise.
struct RowIcon: View {
    let session: Session
    var size: CGFloat = 18
    var line: CGFloat = 2.5
    /// On the blue hover highlight the icon turns white, so it does not vanish into the blue.
    var onAccent = false

    var body: some View {
        switch session.state {
        case .working, .stale:
            ZStack {
                Circle().stroke(onAccent ? Color.white.opacity(0.35) : Color.primary.opacity(0.2), lineWidth: line)
                Circle()
                    .trim(from: 0, to: max(0.04, session.progress))
                    .stroke(onAccent ? Color.white : Color.accentColor, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(line * 0.8)
        case .needsInput:
            symbol("exclamationmark.circle.fill", .orange)
        case .done:
            symbol("checkmark.circle.fill", session.unread ? Color.accentColor : Color.secondary.opacity(0.45))
        case .idle:
            symbol("pause.circle.fill", Color.secondary.opacity(0.45))
        }
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: size))
            .foregroundStyle(onAccent ? color : .white, onAccent ? .white : color)
    }
}

// MARK: - Plan limits

/// "Plan Usage Limits · Ultra" with one row per limit, as in the Claude app's menu:
/// name left, "48% · Resets 2d" right, a thin bar under it.
struct UsageSection: View {
    @ObservedObject var usage: Usage
    let now: Double

    var body: some View {
        if !usage.limits.isEmpty {
            Divider().padding(.horizontal, 14).padding(.vertical, 6)
            HStack(alignment: .firstTextBaseline) {
                Text(usage.plan.isEmpty ? "Plan Usage Limits" : "Plan Usage Limits · \(usage.plan)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let age = staleAge {
                    // A pill like in the Claude menu; click to refresh.
                    Text(age)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .contentShape(Capsule())
                        .onTapGesture { usage.refresh(liveEvery: 0) }
                        .help("Refresh")
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
            ForEach(usage.limits) { l in
                LimitRow(limit: l, now: Date(timeIntervalSince1970: now))
            }
        }
    }

    /// "Updated 2 d ago" only when the numbers are old enough to mislead.
    private var staleAge: String? {
        guard let at = usage.fetchedAt else { return nil }
        let s = now - at.timeIntervalSince1970
        return s > 15 * 60 ? "Updated \(Format.ago(s))" : nil
    }
}

struct LimitRow: View {
    let limit: UsageLimit
    let now: Date

    private var reset: Bool { (limit.resetsAt.map { $0 <= now }) ?? false }
    private var percent: Double { reset ? 0 : min(100, max(0, limit.percent)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title).font(.system(size: 13))
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(percent > 0 ? 6 : 0, g.size.width * percent / 100))
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    /// Blue, yellow from 75%, orange at the limit.
    private var barColor: Color {
        if reset { return .accentColor }
        if limit.critical || percent >= 90 { return .orange }
        if percent >= 75 { return .yellow }
        return .accentColor
    }

    private var value: String {
        let r = reset ? "" : Format.resets(limit.resetsAt, now: now)
        let p = "\(Int(percent.rounded()))%"
        return r.isEmpty ? p : "\(p) · \(r)"
    }
}

// MARK: - Menu row

/// A switch row, like "Wi-Fi" in the Wi-Fi menu.
struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.promoMode) private var promoMode

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            if promoMode {
                // Same size and shape as the macOS 26 mini switch.
                Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: 36, height: 16)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Capsule().fill(Color.white).frame(width: 21, height: 13)
                            .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                            .padding(.horizontal, 1.5)
                    }
            } else {
                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 24)
    }
}

struct MenuRow: View {
    let title: String
    var value: String? = nil
    var chevron = false
    let action: () -> Void
    @State private var hoverState = false
    @Environment(\.promoHighlight) private var promoHighlight
    private var hover: Bool { hoverState || promoHighlight == title }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13))
                Spacer()
                if let value {
                    Text(value).font(.system(size: 13))
                        .foregroundStyle(hover ? Color.white.opacity(0.85) : Color.secondary)
                }
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hover ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .foregroundStyle(hover ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hover ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hoverState = $0 }
    }
}
