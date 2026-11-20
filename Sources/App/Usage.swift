import Foundation

/// One plan limit as the Claude app shows it: "Weekly · all models   48% · Resets 2d".
struct UsageLimit: Identifiable, Equatable {
    var id: String
    var title: String
    var percent: Double
    var resetsAt: Date?
    var critical: Bool
}

/// Plan usage limits.
///
/// Source 1 (always): what Claude Code itself last saved in ~/.claude.json (`cachedUsageUtilization`).
/// No sign-in is read; it is as fresh as Claude Code's last fetch.
/// Source 2 (only with the "Live Plan Limits" setting): asks Anthropic for the current numbers with
/// Claude Code's own sign-in from the Keychain, read-only. The token is never stored or refreshed here.
final class Usage: ObservableObject {
    @Published private(set) var plan = ""
    @Published private(set) var limits: [UsageLimit] = []
    @Published private(set) var fetchedAt: Date?

    var live = false
    private let configURL: URL
    private var configModified: Date?
    private var lastLiveTry: Date?
    private var inFlight = false

    init(configURL: URL? = nil) {
        self.configURL = configURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    }

    /// Cheap: re-reads the saved numbers when the file changed, and asks for live ones at most every `liveEvery` s.
    func refresh(liveEvery: TimeInterval = 300) {
        readSaved()
        guard live, !inFlight else { return }
        if let last = lastLiveTry, Date().timeIntervalSince(last) < liveEvery { return }
        lastLiveTry = Date()
        fetchLive()
    }

    // MARK: Saved by Claude Code

    private func readSaved() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: configURL.path)
        let mod = attrs?[.modificationDate] as? Date
        guard mod != configModified else { return }
        configModified = mod
        guard let data = try? Data(contentsOf: configURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let acct = root["oauthAccount"] as? [String: Any], let name = acct["planDisplayName"] as? String {
            plan = name
        }
        guard let cached = root["cachedUsageUtilization"] as? [String: Any],
              let util = cached["utilization"] as? [String: Any],
              let ms = cached["fetchedAtMs"] as? Double else { return }
        let at = Date(timeIntervalSince1970: ms / 1000)
        if let f = fetchedAt, f >= at { return }
        apply(util, at: at)
    }

    // MARK: Live

    private func fetchLive() {
        inFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let token = Usage.token() else {
                DispatchQueue.main.async { self?.inFlight = false }
                return
            }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.timeoutInterval = 15
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                let obj = ok ? data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } : nil
                DispatchQueue.main.async {
                    self?.inFlight = false
                    if let obj { self?.apply(obj, at: Date()) }
                }
            }.resume()
        }
    }

    /// Claude Code's access token, only while it is still valid (Claude Code refreshes it, we never do).
    private static func token() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let exp = oauth["expiresAt"] as? Double, exp / 1000 < Date().timeIntervalSince1970 + 30 { return nil }
        return token
    }

    // MARK: Parsing

    func apply(_ util: [String: Any], at: Date) {
        let parsed = Usage.parse(util)
        guard !parsed.isEmpty else { return }
        limits = parsed
        fetchedAt = at
    }

    static func parse(_ u: [String: Any]) -> [UsageLimit] {
        var out: [UsageLimit] = []
        func date(_ v: Any?) -> Date? {
            if let s = v as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = f.date(from: s) { return d }
                f.formatOptions = [.withInternetDateTime]
                return f.date(from: s)
            }
            if let n = v as? Double { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
            return nil
        }
        // The 5-hour session window, when the plan has one.
        if let five = u["five_hour"] as? [String: Any], let p = five["utilization"] as? Double {
            out.append(UsageLimit(id: "session", title: "Current session", percent: p,
                                  resetsAt: date(five["resets_at"]), critical: p >= 90))
        }
        if let rows = u["limits"] as? [[String: Any]], !rows.isEmpty {
            for (i, r) in rows.enumerated() {
                guard let p = r["percent"] as? Double else { continue }
                let kind = r["kind"] as? String ?? ""
                let group = r["group"] as? String ?? ""
                let model = ((r["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let title: String
                if group == "weekly" || kind.hasPrefix("weekly") {
                    title = "Weekly · \(model ?? "all models")"
                } else if out.contains(where: { $0.id == "session" }) && (kind.contains("session") || kind.contains("five")) {
                    continue
                } else {
                    title = model.map { "\(group.capitalized) · \($0)" } ?? group.capitalized
                }
                let severity = r["severity"] as? String ?? ""
                out.append(UsageLimit(id: "\(kind)-\(model ?? "")-\(i)", title: title, percent: p,
                                      resetsAt: date(r["resets_at"]),
                                      critical: severity == "critical" || p >= 90))
            }
        } else {
            for (key, title) in [("seven_day", "Weekly · all models"), ("seven_day_opus", "Weekly · Opus"),
                                 ("seven_day_sonnet", "Weekly · Sonnet")] {
                if let w = u[key] as? [String: Any], let p = w["utilization"] as? Double {
                    out.append(UsageLimit(id: key, title: title, percent: p,
                                          resetsAt: date(w["resets_at"]), critical: p >= 90))
                }
            }
        }
        return out
    }

    // MARK: Demo

    func loadDemo() {
        plan = "Ultra"
        let now = Date()
        limits = [
            UsageLimit(id: "w", title: "Weekly · all models", percent: 48, resetsAt: now.addingTimeInterval(2 * 86400 + 3600), critical: false),
            UsageLimit(id: "f", title: "Weekly · Fable", percent: 61, resetsAt: now.addingTimeInterval(2 * 86400 + 3600), critical: false),
        ]
        fetchedAt = now
    }
}

extension Format {
    /// "Resets 2d", "Resets 5h", "Resets 40m".
    static func resets(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "" }
        let s = d.timeIntervalSince(now)
        if s <= 0 { return "Reset" }
        if s >= 86400 { return "Resets \(Int(s / 86400))d" }
        if s >= 3600 { return "Resets \(Int(s / 3600))h" }
        return "Resets \(max(1, Int(s / 60)))m"
    }
}
