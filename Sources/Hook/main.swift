// pulse-hook: called by Claude Code hooks. Reads the hook JSON from stdin,
// keeps only the small fields the menu bar app needs, and drops it as one file
// into ~/.claude-pulse/events. Must stay silent on stdout (UserPromptSubmit
// stdout is added to the model context) and always exit 0.
import Foundation

let eventArg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let raw = FileHandle.standardInput.readDataToEndOfFile()
var input = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]

var out: [String: Any] = [:]
for key in ["session_id", "transcript_path", "cwd", "hook_event_name", "tool_name",
            "message", "notification_type", "source", "reason", "agent_id", "agent_type",
            "stop_hook_active"] {
    if let v = input[key] { out[key] = v }
}
if out["hook_event_name"] == nil { out["hook_event_name"] = eventArg }

if let prompt = input["prompt"] as? String {
    out["prompt"] = prompt.count > 2000 ? String(prompt.prefix(2000)) : prompt
}

// Tool input: only short descriptive fields, never file contents.
if let ti = input["tool_input"] as? [String: Any] {
    var small: [String: Any] = [:]
    for key in ["file_path", "path", "notebook_path", "description", "pattern", "url",
                "query", "subagent_type", "skill", "command"] {
        if let s = ti[key] as? String { small[key] = s.count > 160 ? String(s.prefix(160)) : s }
    }
    out["tool_input"] = small
}

let env = ProcessInfo.processInfo.environment
out["_entry"] = env["CLAUDE_CODE_ENTRYPOINT"] ?? ""
out["_term"] = env["TERM_PROGRAM"] ?? ""
out["_proj"] = env["CLAUDE_PROJECT_DIR"] ?? ""
let now = Date().timeIntervalSince1970
out["_ts"] = now

let dir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude-pulse/events", isDirectory: true)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

if let data = try? JSONSerialization.data(withJSONObject: out) {
    let name = String(format: "%.6f-%d", now, getpid())
    let tmp = dir.appendingPathComponent("." + name + ".tmp")
    let dst = dir.appendingPathComponent(name + ".json")
    if (try? data.write(to: tmp)) != nil {
        _ = rename(tmp.path, dst.path)
    }
}

// Keep the menu bar app alive without anyone thinking about it: if it is not
// running, start it in the background. It picks up this event on launch.
let base = dir.deletingLastPathComponent()
var running = false
if let s = try? String(contentsOf: base.appendingPathComponent("app.pid"), encoding: .utf8),
   let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0, kill(pid, 0) == 0 {
    running = true
}
if !running {
    let apps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    // Current name first, then the name of earlier builds.
    let app = ["Pulse for Claude Code.app", "Claude Pulse.app"].map { apps.appendingPathComponent($0).path }
        .first { FileManager.default.fileExists(atPath: $0) } ?? ""
    if !app.isEmpty {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/open"), strdup("-g"), strdup(app), nil]
        _ = posix_spawn(&pid, "/usr/bin/open", nil, nil, argv, environ)
    }
}
exit(0)
