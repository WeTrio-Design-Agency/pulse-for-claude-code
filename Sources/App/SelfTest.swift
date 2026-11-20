import Foundation

/// `ClaudePulse --selftest`: drives the state machine with a scripted chat and checks each step.
func runSelfTest() -> Int32 {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pulse-selftest-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = Store(base: dir, demo: true)
    var alerts: [AlertKind] = []
    store.onAlert = { k, _ in alerts.append(k) }
    var failures = 0
    let t0 = Date().timeIntervalSince1970 - 5

    func ev(_ name: String, _ dt: Double, _ extra: [String: Any] = [:]) {
        var e: [String: Any] = ["session_id": "s1", "hook_event_name": name, "_ts": t0 + dt,
                                "cwd": "/tmp/proj", "transcript_path": "", "_entry": "claude-vscode",
                                "_proj": "/tmp/proj"]
        extra.forEach { e[$0.key] = $0.value }
        store.apply(e)
    }
    func check(_ what: String, _ ok: Bool) {
        print((ok ? "  ok   " : "  FAIL ") + what)
        if !ok { failures += 1 }
    }
    var s: Session? { store.sessions["s1"] }

    ev("SessionStart", 0)
    check("session registered, idle and hidden", s?.state == .idle && store.ordered.isEmpty)
    ev("UserPromptSubmit", 1, ["prompt": "сделай отчёт по всем проектам"])
    check("prompt -> working, class action", s?.state == .working && s?.cls == "action")
    ev("PreToolUse", 5, ["tool_name": "Edit", "tool_input": ["file_path": "/a/b/Panel.swift"]])
    check("tool -> activity 'Editing Panel.swift', 1 step", s?.activity == "Editing Panel.swift" && s?.steps == 1)
    ev("PreToolUse", 7, ["tool_name": "Bash", "tool_input": ["command": "git push origin main", "description": "Push"]])
    ev("Notification", 8, ["message": "Claude needs your permission to use Bash", "notification_type": "permission_prompt"])
    check("permission -> needs input + alert, says what to allow", s?.state == .needsInput && alerts.last == .needsInput
          && s?.attention == "Allow Bash: git push origin main")
    ev("PostToolUse", 20, ["tool_name": "Bash"])
    check("approved -> working again", s?.state == .working)
    ev("PreToolUse", 25, ["tool_name": "AskUserQuestion"])
    check("question to user -> needs input", s?.state == .needsInput)
    ev("PostToolUse", 40, ["tool_name": "AskUserQuestion"])
    ev("UserPromptSubmit", 41, ["prompt": "ещё добавь графики"])
    check("message mid-turn keeps the start time", s?.startedAt == t0 + 1)
    ev("PreToolUse", 50, ["tool_name": "mcp__claude_ai_Figma__use_figma"])
    check("mcp activity readable", s?.activity == "Figma: use figma")
    let before = store.estimator.samples.count
    ev("Stop", 200)
    check("stop -> done, unread, alert", s?.state == .done && s?.unread == true && alerts.last == .done)
    check("duration recorded to history", store.estimator.samples.count == before + 1 && s?.lastDuration == 199)
    ev("Notification", 260, ["message": "Claude is waiting for your input", "notification_type": "idle_prompt"])
    check("idle reminder after done changes nothing", s?.state == .done && alerts.count == 3)
    ev("UserPromptSubmit", 300, ["prompt": "что дальше?"])
    check("new prompt -> working, read, class question", s?.state == .working && s?.unread == false && s?.cls == "question")
    ev("SessionEnd", 310)
    check("session end removes it", s == nil)

    // Background agents keep a chat in progress after its reply.
    ev("UserPromptSubmit", 400, ["prompt": "проверь код агентами"])
    ev("PreToolUse", 405, ["tool_name": "Agent", "tool_input": ["description": "Review changes", "subagent_type": "general-purpose"]])
    ev("SubagentStart", 406, ["agent_id": "a1", "agent_type": "general-purpose"])
    ev("PostToolUse", 407, ["tool_name": "Agent"])
    ev("PreToolUse", 408, ["tool_name": "Agent", "tool_input": ["description": "Check styles"]])
    ev("SubagentStart", 409, ["agent_id": "a2", "agent_type": "Explore"])
    ev("PostToolUse", 410, ["tool_name": "Agent"])
    check("two agents tracked with their descriptions",
          s?.agentCount == 2 && s?.agentRuns?["a1"]?.label == "Review changes" && s?.agentRuns?["a2"]?.label == "Check styles")
    let alertsBefore = alerts.count
    ev("Stop", 420)
    check("reply done but agents run -> still working, no sound",
          s?.state == .working && s?.isWaitingOnAgents == true && alerts.count == alertsBefore && s?.activity == "2 agents working")
    ev("PreToolUse", 430, ["tool_name": "Read", "agent_id": "a1"])
    check("agent tool use keeps it working", s?.state == .working)
    ev("SubagentStop", 450, ["agent_id": "a1"])
    check("one agent left -> 'Agent: Check styles'", s?.agentCount == 1 && s?.agentsLine == "Agent: Check styles")
    ev("SubagentStop", 460, ["agent_id": "a2"])
    check("all agents done -> waits for the chat to read results", s?.state == .working && s?.agentCount == 0)
    ev("UserPromptSubmit", 461, ["prompt": "<task-notification>done</task-notification>"])
    check("agent report continues the same turn", s?.startedAt == t0 + 400)
    ev("Stop", 470)
    check("final stop -> done with one sound", s?.state == .done && alerts.count == alertsBefore + 1 && s?.lastDuration == 70)
    ev("SubagentStart", 500, ["agent_id": "a3", "agent_type": "general-purpose"])
    check("agent starting in a finished chat -> working again", s?.state == .working && s?.isWaitingOnAgents == true)
    ev("UserPromptSubmit", 510, ["prompt": "а что с дизайном?"])
    check("new message while only agents run starts a new turn", s?.startedAt == t0 + 510 && s?.agentCount == 1)
    ev("Stop", 520)
    check("still in progress while a3 runs", s?.state == .working)
    ev("SubagentStop", 530, ["agent_id": "a3"])
    ev("Stop", 540)
    check("done after the last agent", s?.state == .done && s?.agentRuns == nil)

    // Plan limits parsing (shape of Claude Code's saved usage).
    let parsed = Usage.parse([
        "five_hour": NSNull(),
        "seven_day": ["utilization": 59.0, "resets_at": "2026-11-22T16:00:00.114827+00:00"],
        "limits": [
            ["kind": "weekly_all", "group": "weekly", "percent": 48.0, "severity": "normal",
             "resets_at": "2026-11-22T16:00:00.114827+00:00", "scope": NSNull()],
            ["kind": "weekly_scoped", "group": "weekly", "percent": 98.0, "severity": "critical",
             "resets_at": "2026-11-22T16:00:00.114989+00:00", "scope": ["model": ["display_name": "Fable"]]],
        ],
    ])
    check("limits: weekly all + weekly Fable, Fable critical",
          parsed.map(\.title) == ["Weekly · all models", "Weekly · Fable"] && parsed[1].critical && parsed[0].resetsAt != nil)
    let ref = Date(timeIntervalSince1970: 1_800_000_000)
    check("resets wording", Format.resets(ref.addingTimeInterval(2 * 86400 + 60), now: ref) == "Resets 2d"
          && Format.resets(ref.addingTimeInterval(5 * 3600 + 5), now: ref) == "Resets 5h")

    // Estimator behaviour
    let pool: [Double] = (1...100).map { Double($0) * 10 }   // 10 s ... 1000 s
    let r0 = store.estimator.remaining(elapsed: 0, pool: pool) ?? -1
    let r500 = store.estimator.remaining(elapsed: 500, pool: pool) ?? -1
    let rOver = store.estimator.remaining(elapsed: 990, pool: pool)
    check("about wording", Format.about(30) == "Less than a minute" && Format.about(300) == "About 5 min" && Format.about(4200) == "About 1 h 10 min")
    check("estimate at start ~ median (\(Int(r0)) s)", r0 > 450 && r0 < 650)
    check("estimate moves with elapsed time (\(Int(r500)) s left at 500 s)", r500 > 150 && r500 < 400)
    check("past almost all similar turns -> 'longer than usual'", rOver == nil)
    check("classifier: question", Estimator.classify("сколько это стоит?") == "question")
    check("classifier: approval is action", Estimator.classify("выкатывай") == "action")
    check("format short", Format.short(30) == "<1m" && Format.short(200) == "3m" && Format.short(1300) == "20m")

    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    return failures == 0 ? 0 : 1
}
