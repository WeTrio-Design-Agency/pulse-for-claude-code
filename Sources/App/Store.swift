import AppKit
import Combine
import Foundation

enum SessionState: String, Codable {
    case working, needsInput, done, idle, stale
}

struct Session: Codable, Identifiable {
    var id: String
    var cwd = ""
    var projectDir = ""
    var transcriptPath = ""
    var entry = ""
    var term = ""
    var title: String?
    var prompt = ""
    var promptLen = 0
    var cls = "other"
    var state: SessionState = .idle
    var startedAt: Double = 0
    var lastEventAt: Double = 0
    var doneAt: Double = 0
    var activity = ""
    var steps = 0
    var unread = false
    var progress: Double = 0
    var remaining: Double?
    var lastDuration: Double = 0
    var attention = ""
    /// What the chat is doing right now, as a category: edit, read, run, search, web, agent, tool, think.
    var kind: String?
    /// The last tool call and its subject (command, file, site): what a permission prompt is about.
    var pendingTool: String?
    var pendingDetail: String?
    /// Subagents running in this chat (agent_id -> what it does). Optional so older state files still load.
    var agentRuns: [String: AgentRun]?
    /// Descriptions of Agent calls the main chat made that no subagent has claimed yet.
    var agentQueue: [String]?
    /// The main turn has ended, but agents it started are still working.
    var waitingOnAgents: Bool?

    var agentCount: Int { agentRuns?.count ?? 0 }
    var isWaitingOnAgents: Bool { waitingOnAgents ?? false }

    /// "Agent: Review changes" or "3 agents working".
    /// "Review changes, Check styles": what the running agents do, oldest first.
    var agentNames: String {
        let runs = (agentRuns ?? [:]).values.sorted { $0.startedAt < $1.startedAt }
        var names: [String] = []
        for r in runs where !r.label.isEmpty && !names.contains(r.label) { names.append(r.label) }
        // Same unnamed type three times says less than "3 agents working".
        if names.isEmpty || (names.count == 1 && runs.count > 1) { return agentsLine }
        return names.joined(separator: ", ")
    }

    var agentsLine: String {
        let runs = (agentRuns ?? [:]).values.sorted { $0.startedAt < $1.startedAt }
        if runs.count == 1, let r = runs.first { return r.label.isEmpty ? "1 agent working" : "Agent: \(r.label)" }
        return "\(runs.count) agents working"
    }

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        let p = prompt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? "New chat" : p
    }

    var projectName: String {
        let dir = projectDir.isEmpty ? cwd : projectDir
        return dir.isEmpty ? "" : (dir as NSString).lastPathComponent
    }

    var isActive: Bool { state == .working || state == .needsInput || state == .stale }
}

struct AgentRun: Codable {
    var label: String
    var startedAt: Double
    var lastSeen: Double
}

enum AlertKind { case done, needsInput }

final class Store: ObservableObject {
    @Published private(set) var sessions: [String: Session] = [:]
    @Published private(set) var now = Date().timeIntervalSince1970

    /// Unacknowledged alert: the menu bar blinks until the panel is opened.
    @Published var attentionPending = false

    let base: URL
    let eventsDir: URL
    let estimator: Estimator
    var onAlert: ((AlertKind, Session) -> Void)?

    private var pools: [String: [Double]] = [:]
    private var titleTried = Set<String>()
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var dirty = false
    private var lastSave: Double = 0
    private var lastSlowCheck: Double = 0
    private var lastEstimate: Double = 0
    private var lastNow: Double = 0

    /// True while the panel is open: then the clock ticks every second, otherwise every 15 s.
    var live = false {
        didSet { if live { now = Date().timeIntervalSince1970; refreshEstimates() } }
    }

    init(base: URL? = nil, demo: Bool = false) {
        let root = base ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-pulse", isDirectory: true)
        self.base = root
        eventsDir = root.appendingPathComponent("events", isDirectory: true)
        try? FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        estimator = Estimator(url: root.appendingPathComponent("history.json"))
        if !demo { load() }
    }

    // MARK: Ordering

    var ordered: [Session] {
        func rank(_ s: Session) -> Int {
            switch s.state {
            case .needsInput: return 0
            case .working, .stale: return 1
            case .done: return s.unread ? 2 : 3
            case .idle: return 4
            }
        }
        return sessions.values
            .filter { $0.state != .idle || $0.startedAt > 0 }
            .sorted {
                let (a, b) = (rank($0), rank($1))
                if a != b { return a < b }
                if $0.isActive { return ($0.remaining ?? .infinity) < ($1.remaining ?? .infinity) }
                return max($0.doneAt, $0.lastEventAt) > max($1.doneAt, $1.lastEventAt)
            }
    }

    // MARK: Lifecycle

    func start() {
        drain()
        let fd = open(eventsDir.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            src.setEventHandler { [weak self] in self?.drain() }
            src.setCancelHandler { close(fd) }
            src.resume()
            watcher = src
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Read every pending event file in time order, apply, delete.
    func drain() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: eventsDir.path) else { return }
        let files = names.filter { $0.hasSuffix(".json") }.sorted()
        guard !files.isEmpty else { return }
        for name in files {
            let url = eventsDir.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                apply(obj)
            }
            try? fm.removeItem(at: url)
        }
        refreshEstimates()
        dirty = true
        saveIfNeeded(force: true)
    }

    // MARK: Events

    func apply(_ e: [String: Any]) {
        guard let sid = e["session_id"] as? String, !sid.isEmpty else { return }
        let ev = e["hook_event_name"] as? String ?? ""
        let ts = e["_ts"] as? Double ?? Date().timeIntervalSince1970
        let live = Date().timeIntervalSince1970 - ts < 60
        var s = sessions[sid] ?? Session(id: sid)

        if let v = e["cwd"] as? String, !v.isEmpty { s.cwd = v }
        if let v = e["_proj"] as? String, !v.isEmpty { s.projectDir = v }
        if let v = e["transcript_path"] as? String, !v.isEmpty { s.transcriptPath = v }
        if let v = e["_entry"] as? String, !v.isEmpty { s.entry = v }
        if let v = e["_term"] as? String, !v.isEmpty { s.term = v }
        s.lastEventAt = max(s.lastEventAt, ts)
        let fromSubagent = (e["agent_id"] as? String).map { !$0.isEmpty } ?? false

        switch ev {
        case "SessionStart":
            if s.title == nil { fetchTitle(sid, path: s.transcriptPath) }

        case "UserPromptSubmit":
            let prompt = e["prompt"] as? String ?? ""
            // A turn that only waits for its agents is over for the user: a new message starts a new
            // turn. The automatic wake-up when an agent reports back continues the same one.
            let agentReport = prompt.contains("<task-notification")
            let mainOpen = (s.state == .working || s.state == .needsInput) && (!s.isWaitingOnAgents || agentReport)
            let midTurn = mainOpen && !Transcript.wasInterrupted(s.transcriptPath)
            s.waitingOnAgents = nil
            if !midTurn {
                s.startedAt = ts
                s.steps = 0
                s.progress = 0
                s.prompt = prompt
                s.promptLen = prompt.count
                s.cls = Estimator.classify(prompt)
                pools[sid] = nil
            }
            s.state = .working
            s.activity = "Thinking"
            s.kind = "think"
            s.unread = false
            s.attention = ""
            s.remaining = nil

        case "SubagentStart":
            guard fromSubagent, let aid = e["agent_id"] as? String else { break }
            var queue = s.agentQueue ?? []
            let label = queue.isEmpty ? Activity.agentLabel(e["agent_type"] as? String) : queue.removeFirst()
            s.agentQueue = queue.isEmpty ? nil : queue
            var runs = s.agentRuns ?? [:]
            runs[aid] = AgentRun(label: label, startedAt: ts, lastSeen: ts)
            s.agentRuns = runs
            reopenForAgents(&s, at: ts)

        case "SubagentStop":
            guard fromSubagent, let aid = e["agent_id"] as? String else { break }
            s.agentRuns?[aid] = nil
            if s.agentRuns?.isEmpty == true { s.agentRuns = nil }
            if s.isWaitingOnAgents && s.agentCount == 0 {
                // The chat wakes up to read the report and then stops for real; slowChecks covers silence.
                s.activity = "Reading agent results"
                s.kind = "agent"
            }

        case "PreToolUse":
            if fromSubagent, let aid = e["agent_id"] as? String {
                var runs = s.agentRuns ?? [:]
                if runs[aid] == nil {
                    // Missed the start (app launched later): still an agent at work.
                    runs[aid] = AgentRun(label: Activity.agentLabel(e["agent_type"] as? String), startedAt: ts, lastSeen: ts)
                }
                runs[aid]?.lastSeen = ts
                s.agentRuns = runs
                reopenForAgents(&s, at: ts)
            } else if s.isWaitingOnAgents {
                // The main chat is back at work after its agents.
                s.waitingOnAgents = nil
            }
            if !(s.state == .working || s.state == .needsInput) {
                // We missed the prompt (app started mid-turn): track from here.
                s.state = .working
                s.startedAt = ts
                s.steps = 0
                s.progress = 0
                pools[sid] = nil
            }
            if s.state == .stale { s.state = .working }
            s.steps += 1
            let tool = e["tool_name"] as? String ?? ""
            let input = e["tool_input"] as? [String: Any] ?? [:]
            s.activity = Activity.describe(tool: tool, input: input)
            s.kind = Activity.kind(tool)
            if !fromSubagent {
                s.pendingTool = tool
                s.pendingDetail = Activity.subject(tool: tool, input: input)
                if tool == "Agent" || tool == "Task" {
                    let d = (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? Activity.agentLabel(input["subagent_type"] as? String)
                    s.agentQueue = (s.agentQueue ?? []) + [d]
                }
            }
            if !fromSubagent && (tool == "AskUserQuestion" || tool == "ExitPlanMode") {
                s.state = .needsInput
                s.attention = tool == "AskUserQuestion" ? "Asked you a question" : "Plan ready for your review"
                if live { raise(.needsInput, s) }
            }

        case "PostToolUse":
            if fromSubagent, let aid = e["agent_id"] as? String { s.agentRuns?[aid]?.lastSeen = ts }
            if s.state == .needsInput || s.state == .stale {
                s.state = .working
                s.attention = ""
            }
            if s.state == .working { s.activity = "Thinking"; s.kind = "think" }

        case "Notification":
            let msg = e["message"] as? String ?? ""
            let type = e["notification_type"] as? String ?? ""
            let lower = msg.lowercased()
            if type == "permission_prompt" || type == "elicitation_dialog" || lower.contains("permission") {
                if s.isActive {
                    s.state = .needsInput
                    var m = msg.isEmpty ? "Needs your permission" : msg
                    if m.hasPrefix("Claude needs") { m = "Needs" + m.dropFirst("Claude needs".count) }
                    // Say exactly what to allow: "Allow Bash: git push origin main".
                    if let tool = s.pendingTool, lower.contains(tool.lowercased()) || type == "permission_prompt" {
                        let name = Activity.toolName(tool)
                        if let d = s.pendingDetail, !d.isEmpty { m = "Allow \(name): \(d)" } else { m = "Allow \(name)?" }
                    }
                    s.attention = m
                    if live { raise(.needsInput, s) }
                }
            } else if type == "idle_prompt" || lower.contains("waiting for your input") {
                if s.isActive { finish(&s, at: ts, live: live) }
            }

        case "Stop":
            if fromSubagent { break }
            s.agentQueue = nil
            if s.agentCount > 0 {
                // The reply is written, but agents it started are still at work: stay in progress, no sound yet.
                if !s.isActive { s.state = .working; if s.startedAt == 0 { s.startedAt = ts } }
                if s.state == .needsInput { s.state = .working; s.attention = "" }
                s.waitingOnAgents = true
                s.activity = s.agentsLine
                s.kind = "agent"
            } else if s.isActive {
                finish(&s, at: ts, live: live)
            }
            fetchTitle(sid, path: s.transcriptPath)

        case "SessionEnd":
            sessions[sid] = nil
            pools[sid] = nil
            return

        default:
            break
        }
        sessions[sid] = s
        if s.title == nil, !s.transcriptPath.isEmpty, !titleTried.contains(sid) {
            titleTried.insert(sid)
            fetchTitle(sid, path: s.transcriptPath)
        }
    }

    private func finish(_ s: inout Session, at ts: Double, live: Bool) {
        let duration = ts - s.startedAt
        if s.startedAt > 0, duration > 0 {
            estimator.record(len: s.promptLen, cls: s.cls, duration: duration, tools: s.steps, project: s.projectName)
            s.lastDuration = duration
        }
        pools[s.id] = nil
        s.agentRuns = nil
        s.agentQueue = nil
        s.waitingOnAgents = nil
        s.state = .done
        s.doneAt = ts
        s.progress = 1
        s.remaining = nil
        s.activity = "Ready"
        s.attention = ""
        s.unread = true
        if live { raise(.done, s) }
    }

    /// A background agent is at work in a chat whose reply already finished: the chat is in progress again.
    private func reopenForAgents(_ s: inout Session, at ts: Double) {
        guard !(s.state == .working || s.state == .needsInput) else { return }
        s.state = .working
        s.waitingOnAgents = true
        if s.startedAt == 0 || s.doneAt >= s.startedAt { s.startedAt = ts; s.steps = 0; s.progress = 0; pools[s.id] = nil }
        s.unread = false
        s.activity = s.agentsLine
        s.kind = "agent"
    }

    private func raise(_ kind: AlertKind, _ s: Session) {
        attentionPending = true
        onAlert?(kind, s)
    }

    // MARK: Ticking

    private func tick() {
        let t = Date().timeIntervalSince1970
        if live || t - lastNow >= 15 {
            lastNow = t
            now = t
        }
        if attentionPending, !sessions.values.contains(where: { $0.state == .needsInput || ($0.state == .done && $0.unread) }) {
            attentionPending = false
        }
        if live || t - lastEstimate >= 5 { refreshEstimates() }
        if t - lastSlowCheck > 10 {
            lastSlowCheck = t
            slowChecks()
        }
        saveIfNeeded(force: false)
    }

    private func refreshEstimates() {
        let t = Date().timeIntervalSince1970
        lastEstimate = t
        for (id, var s) in sessions where s.state == .working || s.state == .needsInput || s.state == .stale {
            let before = (s.progress, s.remaining)
            let pool = pools[id] ?? estimator.pool(len: s.promptLen, cls: s.cls, project: s.projectName)
            pools[id] = pool
            let elapsed = max(0, t - s.startedAt)
            let rem = estimator.remaining(elapsed: elapsed, pool: pool)
            s.remaining = rem
            var target: Double
            if let r = rem {
                target = elapsed / (elapsed + r)
            } else {
                // Longer than usual: creep toward the end, never reach it.
                target = s.progress + (0.97 - s.progress) * 0.004
            }
            target = min(0.97, target)
            // The bar only moves forward.
            s.progress = max(s.progress, target)
            // Coarse values: nobody reads seconds here, and fewer changes mean fewer redraws.
            s.remaining = rem.map { ($0 / 15).rounded() * 15 }
            if abs(s.progress - before.0) > 0.004 || s.remaining != before.1 {
                sessions[id] = s
            }
        }
    }

    /// Catch turns that ended without a Stop event (interrupted with Esc) or went silent.
    private func slowChecks() {
        let t = Date().timeIntervalSince1970
        for (id, var s) in sessions {
            switch s.state {
            case .working, .needsInput:
                // Agents that went silent for 30 min are gone (a missed stop event).
                if let runs = s.agentRuns {
                    let alive = runs.filter { t - $0.value.lastSeen < 30 * 60 }
                    if alive.count != runs.count {
                        s.agentRuns = alive.isEmpty ? nil : alive
                        sessions[id] = s
                        dirty = true
                    }
                }
                if s.isWaitingOnAgents, s.agentCount == 0, t - s.lastEventAt > 60 {
                    // Agents done and the chat did not wake up again: the task is finished.
                    finish(&s, at: s.lastEventAt, live: t - s.lastEventAt < 5 * 60)
                    sessions[id] = s
                    dirty = true
                    continue
                }
                if s.isWaitingOnAgents, s.state == .working {
                    let line = s.agentCount > 0 ? s.agentsLine : s.activity
                    if s.activity != line { s.activity = line; sessions[id] = s }
                }
                if t - s.lastEventAt > 30, Transcript.wasInterrupted(s.transcriptPath) {
                    s.state = .idle
                    s.activity = "Interrupted"
                    s.remaining = nil
                    sessions[id] = s
                    dirty = true
                } else if s.state == .working, t - s.lastEventAt > 20 * 60,
                          t - Transcript.modified(s.transcriptPath) > 20 * 60 {
                    s.state = .stale
                    s.activity = "No activity for 20 min"
                    sessions[id] = s
                    dirty = true
                }
            case .done where !s.unread && t - s.doneAt > 6 * 3600:
                sessions[id] = nil
                dirty = true
            case .idle where t - s.lastEventAt > 3600:
                sessions[id] = nil
                dirty = true
            default:
                break
            }
        }
    }

    // MARK: User actions

    func acknowledge() { attentionPending = false }

    func markRead(_ id: String) {
        guard var s = sessions[id] else { return }
        s.unread = false
        sessions[id] = s
        dirty = true
    }

    func clearFinished() {
        sessions = sessions.filter { $0.value.isActive }
        attentionPending = false
        dirty = true
        saveIfNeeded(force: true)
    }

    // MARK: Titles

    private func fetchTitle(_ sid: String, path: String) {
        guard !path.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let title = Transcript.title(path)
            DispatchQueue.main.async { [weak self] in
                guard let self, let title, var s = self.sessions[sid], s.title != title else { return }
                s.title = title
                self.sessions[sid] = s
                self.dirty = true
            }
        }
    }

    // MARK: Persistence

    private var stateURL: URL { base.appendingPathComponent("state.json") }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let list = try? JSONDecoder().decode([Session].self, from: data) else { return }
        sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    private func saveIfNeeded(force: Bool) {
        let t = Date().timeIntervalSince1970
        guard force || (dirty && t - lastSave > 2) || t - lastSave > 15 else { return }
        dirty = false
        lastSave = t
        if let data = try? JSONEncoder().encode(Array(sessions.values)) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    // MARK: Demo data (snapshots)

    func loadDemo() {
        let t = Date().timeIntervalSince1970
        now = t
        var a = Session(id: "a", cwd: "/Users/you/projects/web-app", title: "Task boards redesign",
                        prompt: "сделай доски задач с фильтрами по проектам и людям", promptLen: 300, cls: "action", state: .working,
                        startedAt: t - 254, lastEventAt: t - 2, activity: "Editing BoardColumn.tsx", steps: 23)
        a.progress = 0.58; a.remaining = 185; a.kind = "edit"
        var b = Session(id: "b", cwd: "/Users/you/projects/notes", title: "Weekly outreach plan",
                        prompt: "", promptLen: 80, cls: "other", state: .needsInput,
                        startedAt: t - 96, lastEventAt: t - 10, activity: "Running git push", steps: 9)
        b.progress = 0.41; b.attention = "Allow Bash: git push origin main"; b.kind = "run"
        b.prompt = "отправь план в репо и открой PR"
        var c = Session(id: "c", cwd: "/Users/you/projects/marketing", title: "Black Friday banners",
                        prompt: "", state: .done, startedAt: t - 900, doneAt: t - 75, activity: "Ready",
                        unread: true)
        c.progress = 1; c.lastDuration = 812; c.steps = 34
        c.prompt = "собери баннеры чёрной пятницы в трёх размерах"
        var d = Session(id: "d", cwd: "/Users/you/projects/pulse", title: "Menu bar status app",
                        prompt: "", promptLen: 900, cls: "action", state: .working,
                        startedAt: t - 1460, lastEventAt: t - 1, activity: "Searching the web", steps: 61)
        d.progress = 0.9; d.remaining = nil; d.kind = "agent"
        d.agentRuns = ["x": AgentRun(label: "Review changes", startedAt: t - 300, lastSeen: t - 2),
                       "y": AgentRun(label: "Check styles", startedAt: t - 200, lastSeen: t - 5)]
        d.waitingOnAgents = true; d.activity = d.agentsLine
        d.prompt = "сделай утилиту в строке меню со статусом чатов"
        sessions = ["a": a, "b": b, "c": c, "d": d]
    }

    /// Made-up chats for the promo video, one call per moment of the story.
    func loadPromo(_ stage: String) {
        let t = Date().timeIntervalSince1970
        now = t
        func working(_ id: String, _ title: String, _ cwd: String, progress: Double, left: Double, started: Double) -> Session {
            var s = Session(id: id, cwd: cwd, title: title, prompt: title, promptLen: 200, cls: "action", state: .working,
                            startedAt: t - started, lastEventAt: t - 1, activity: "Editing files", steps: 20)
            s.progress = progress; s.remaining = left
            return s
        }
        func done(_ id: String, _ title: String, _ cwd: String, ago: Double, unread: Bool) -> Session {
            var s = Session(id: id, cwd: cwd, title: title, prompt: title, state: .done, startedAt: t - ago - 300,
                            doneAt: t - ago, activity: "Ready", unread: unread)
            s.progress = 1; s.lastDuration = 300
            return s
        }
        var list: [Session]
        switch stage {
        case "later":
            // Checkout fix has just answered; the others moved on a minute.
            list = [working("a", "Landing page redesign", "/p/site", progress: 0.62, left: 190, started: 400),
                    done("b", "Failed card payment retries", "/p/shop", ago: 2, unread: true),
                    working("c", "Write onboarding emails", "/p/mail", progress: 0.38, left: 370, started: 260),
                    done("d", "Q4 pricing research", "/p/research", ago: 180, unread: true)]
        case "opened":
            // The checkout chat was opened: read.
            list = [working("a", "Landing page redesign", "/p/site", progress: 0.66, left: 175, started: 420),
                    done("b", "Failed card payment retries", "/p/shop", ago: 20, unread: false),
                    working("c", "Write onboarding emails", "/p/mail", progress: 0.42, left: 350, started: 280),
                    done("d", "Q4 pricing research", "/p/research", ago: 200, unread: true)]
        default:
            list = [working("a", "Landing page redesign", "/p/site", progress: 0.48, left: 255, started: 340),
                    working("b", "Failed card payment retries", "/p/shop", progress: 0.8, left: 75, started: 290),
                    working("c", "Write onboarding emails", "/p/mail", progress: 0.24, left: 430, started: 200),
                    done("d", "Q4 pricing research", "/p/research", ago: 120, unread: true)]
        }
        sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }
}

// MARK: - Transcript helpers

enum Transcript {
    static func tail(_ path: String, bytes: Int) -> String? {
        guard !path.isEmpty, let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// True when the last user entry in the transcript is Claude Code's interrupt marker.
    static func wasInterrupted(_ path: String) -> Bool {
        guard let text = tail(path, bytes: 96_000) else { return false }
        let lines = text.split(separator: "\n")
        for line in lines.reversed() {
            if line.contains("\"type\":\"assistant\"") { return false }
            if line.contains("\"type\":\"user\"") {
                if line.contains("[Request interrupted by user") { return true }
                if line.contains("\"tool_result\"") { continue }
                return false
            }
        }
        return false
    }

    static func modified(_ path: String) -> Double {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }

    /// Chat title as Claude Code shows it: a custom title if renamed, else the AI title.
    static func title(_ path: String) -> String? {
        for bytes in [2_000_000, 30_000_000] {
            guard let text = tail(path, bytes: bytes) else { return nil }
            if let t = lastValue(in: text, key: "customTitle") ?? lastValue(in: text, key: "aiTitle") {
                return t
            }
            if text.utf8.count < bytes { break }
        }
        return nil
    }

    private static func lastValue(in text: String, key: String) -> String? {
        guard let r = text.range(of: "\"\(key)\":\"", options: .backwards) else { return nil }
        var out = ""
        var escaped = false
        for ch in text[r.upperBound...] {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { break }
            out.append(ch)
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Human-readable activity

enum Activity {
    /// "general-purpose" -> "General purpose", "Explore" -> "Explore".
    static func agentLabel(_ type: String?) -> String {
        guard let t = type, !t.isEmpty else { return "" }
        let words = t.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Short subject of a tool call, for permission prompts.
    static func subject(tool: String, input: [String: Any]) -> String? {
        func str(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch tool {
        case "Bash": return str("command").map { $0.replacingOccurrences(of: "\n", with: " ") }
        case "Edit", "MultiEdit", "Write", "Read": return str("file_path").map { ($0 as NSString).lastPathComponent }
        case "NotebookEdit": return str("notebook_path").map { ($0 as NSString).lastPathComponent }
        case "WebFetch": return str("url").flatMap { URL(string: $0)?.host }
        case "WebSearch": return str("query")
        default: return str("description") ?? str("query") ?? str("url") ?? str("file_path")
        }
    }

    /// "Bash", "Figma: use figma", ...
    static func toolName(_ tool: String) -> String {
        if tool.hasPrefix("mcp__") { return describe(tool: tool, input: [:]) }
        return tool
    }

    static func kind(_ tool: String) -> String {
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "edit"
        case "Read": return "read"
        case "Bash": return "run"
        case "Grep", "Glob": return "search"
        case "WebSearch", "WebFetch": return "web"
        case "Agent", "Task": return "agent"
        case "TodoWrite": return "plan"
        case "AskUserQuestion", "ExitPlanMode": return "ask"
        default: return tool.hasPrefix("mcp__") ? "tool" : "think"
        }
    }

    static func symbol(_ kind: String?) -> String {
        switch kind {
        case "edit": return "pencil"
        case "read": return "doc.text"
        case "run": return "terminal"
        case "search": return "magnifyingglass"
        case "web": return "globe"
        case "agent": return "person.2"
        case "plan": return "list.bullet"
        case "ask": return "questionmark"
        case "tool": return "puzzlepiece.extension"
        default: return "sparkles"
        }
    }

    static func describe(tool: String, input: [String: Any]) -> String {
        func base(_ key: String) -> String? {
            (input[key] as? String).map { ($0 as NSString).lastPathComponent }
        }
        switch tool {
        case "Read": return "Reading \(base("file_path") ?? "a file")"
        case "Edit", "MultiEdit": return "Editing \(base("file_path") ?? "a file")"
        case "Write": return "Writing \(base("file_path") ?? "a file")"
        case "NotebookEdit": return "Editing \(base("notebook_path") ?? "a notebook")"
        case "Bash":
            if let d = input["description"] as? String, !d.isEmpty { return d }
            let cmd = (input["command"] as? String ?? "").split(separator: " ").first.map(String.init) ?? "command"
            return "Running \(cmd)"
        case "Grep", "Glob": return "Searching the code"
        case "WebSearch": return "Searching the web"
        case "WebFetch":
            if let u = input["url"] as? String, let host = URL(string: u)?.host { return "Reading \(host)" }
            return "Reading a web page"
        case "Agent", "Task":
            if let d = input["description"] as? String, !d.isEmpty { return "Agent: \(d)" }
            return "Running an agent"
        case "TodoWrite": return "Updating the plan"
        case "AskUserQuestion": return "Asking you a question"
        case "ExitPlanMode": return "Plan ready"
        case "Skill": return "Using \(input["skill"] as? String ?? "a skill")"
        case "ToolSearch": return "Loading tools"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.dropFirst(5).components(separatedBy: "__")
                var server = parts.first ?? ""
                server = server.replacingOccurrences(of: "claude_ai_", with: "")
                    .replacingOccurrences(of: "_", with: " ")
                let action = (parts.count > 1 ? parts[1] : "")
                    .replacingOccurrences(of: "_", with: " ")
                return action.isEmpty ? server : "\(server): \(action)"
            }
            return tool.isEmpty ? "Working" : tool
        }
    }
}
