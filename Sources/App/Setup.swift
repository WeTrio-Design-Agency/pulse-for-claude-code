import Foundation

/// Install-time jobs, built into the app so installing needs nothing else (no Python, no Xcode).
///   ClaudePulse --register-hooks install|uninstall
///   ClaudePulse --seed-history [--force]
enum Setup {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let settingsURL = home.appendingPathComponent(".claude/settings.json")
    static let hookPath = home.appendingPathComponent(".claude-pulse/bin/pulse-hook").path
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                         "Notification", "Stop", "SessionEnd", "SubagentStart", "SubagentStop"]

    // MARK: Hooks in ~/.claude/settings.json

    /// Adds or removes only our entries (commands that mention pulse-hook); the rest of the file stays.
    static func registerHooks(install: Bool) -> Int32 {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                print("~/.claude/settings.json is not valid JSON; left untouched")
                return 1
            }
            root = obj
        }
        let original = root as NSDictionary
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for ev in events {
            var groups = (hooks[ev] as? [[String: Any]] ?? []).filter { group in
                let list = group["hooks"] as? [[String: Any]] ?? []
                return !list.contains { ($0["command"] as? String ?? "").contains("pulse-hook") }
            }
            if install {
                var g: [String: Any] = ["hooks": [["type": "command", "command": "\"\(hookPath)\" \(ev)", "timeout": 5]]]
                if ev == "PreToolUse" || ev == "PostToolUse" { g["matcher"] = "*" }
                groups.append(g)
            }
            hooks[ev] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        if (root as NSDictionary).isEqual(to: original as! [AnyHashable: Any]), fm.fileExists(atPath: settingsURL.path) {
            print("hooks already \(install ? "installed" : "removed"); ~/.claude/settings.json unchanged")
            return 0
        }
        // Back up before the first real change.
        if fm.fileExists(atPath: settingsURL.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            try? fm.copyItem(at: settingsURL, to: settingsURL.appendingPathExtension("bak-pulse-\(stamp)"))
        }
        try? fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]),
              (try? out.write(to: settingsURL, options: .atomic)) != nil else {
            print("could not write ~/.claude/settings.json")
            return 1
        }
        print("hooks \(install ? "installed" : "removed") in ~/.claude/settings.json")
        return 0
    }

    // MARK: History for the estimate

    /// Builds ~/.claude-pulse/history.json from past Claude Code transcripts:
    /// a turn = a real user prompt -> the last assistant message before the next prompt.
    static func seedHistory(force: Bool) -> Int32 {
        let fm = FileManager.default
        let out = home.appendingPathComponent(".claude-pulse/history.json")
        if fm.fileExists(atPath: out.path), !force {
            print("history exists, kept (use --force to rebuild)")
            return 0
        }
        let projects = home.appendingPathComponent(".claude/projects")
        var files: [URL] = []
        for dir in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where f.pathExtension == "jsonl" { files.append(f) }
        }
        var samples: [Sample] = []
        for f in files { samples += turns(in: f) }
        samples.sort { ($0.at ?? 0) < ($1.at ?? 0) }
        try? fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(samples) { try? data.write(to: out, options: .atomic) }
        print("\(samples.count) past replies -> ~/.claude-pulse/history.json")
        return 0
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func turns(in file: URL) -> [Sample] {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return [] }
        let userTag = Data("\"type\":\"user\"".utf8)
        let assistantTag = Data("\"type\":\"assistant\"".utf8)
        var result: [Sample] = []
        var start = 0.0, end = 0.0, len = 0, tools = 0, cls = "", proj = ""
        var open = false

        func close() {
            if open, end > start {
                let d = end - start
                if d > 2, d < 4 * 3600 {
                    result.append(Sample(l: len, c: cls, d: (d * 10).rounded() / 10, t: tools, at: start.rounded(), p: proj))
                }
            }
        }

        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[lineStart..<lineEnd]
            lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
            let isUser = line.range(of: userTag) != nil
            guard isUser || line.range(of: assistantTag) != nil,
                  let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = d["type"] as? String, type == "user" || type == "assistant",
                  (d["isSidechain"] as? Bool) != true,
                  let tsString = d["timestamp"] as? String,
                  let ts = iso.date(from: tsString)?.timeIntervalSince1970 else { continue }
            let content = (d["message"] as? [String: Any])?["content"]
            if type == "user" {
                var text: String?
                if let s = content as? String { text = s }
                else if let arr = content as? [[String: Any]], let first = arr.first, first["type"] as? String == "text" {
                    text = first["text"] as? String
                }
                guard let t = text, (d["isMeta"] as? Bool) != true, !t.hasPrefix("<"),
                      !t.hasPrefix("Base directory"), !t.hasPrefix("[Request interrupted") else { continue }
                close()
                open = true
                start = ts; end = 0; len = t.count; tools = 0
                cls = Estimator.classify(t)
                proj = ((d["cwd"] as? String ?? "") as NSString).lastPathComponent
            } else if open {
                end = ts
                if let arr = content as? [[String: Any]] {
                    tools += arr.filter { $0["type"] as? String == "tool_use" }.count
                }
            }
        }
        close()
        return result
    }
}
