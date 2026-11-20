import Foundation

/// One finished turn: prompt length, class, duration in seconds, tool calls.
struct Sample: Codable {
    var l: Int
    var c: String
    var d: Double
    var t: Int
    var at: Double?
    var p: String?
}

/// Predicts how long a turn will still run from the user's own history.
///
/// Survival estimate: among past turns similar to this one (same class, similar
/// prompt length) that had already run at least as long as this one has, the
/// typical total duration tells how much is left. Early on that is the median of
/// similar turns; as a turn runs long, only the long ones remain, so the
/// estimate moves with it instead of freezing at a wrong number.
final class Estimator {
    private(set) var samples: [Sample] = []
    private let url: URL

    // Also used by Setup.seedHistory for past chats
    private static let action = try! NSRegularExpression(
        pattern: "(сделай|сделать|собери|аудит|проанализ|распланир|реализ|перепиш|исправ|почин|добав|убер|замени|весь|всё|все |полност|луп|выкат|деплой|протестир|сверст|нарисуй|экран|build|implement|refactor|audit|fix|deploy|create|make|write)",
        options: [.caseInsensitive])
    private static let approve = try! NSRegularExpression(
        pattern: "^\\s*(да|ок|ok|okay|yes|выкатывай|дальше|го|продолжай|давай|делай|погнали)\\b",
        options: [.caseInsensitive])

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([Sample].self, from: data) {
            samples = list
        }
    }

    static func classify(_ prompt: String) -> String {
        let range = NSRange(prompt.startIndex..., in: prompt)
        if action.firstMatch(in: prompt, range: range) != nil
            || approve.firstMatch(in: prompt, range: range) != nil { return "action" }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return "question" }
        return "other"
    }

    func record(len: Int, cls: String, duration: Double, tools: Int, project: String) {
        guard duration > 2, duration < 4 * 3600 else { return }
        samples.append(Sample(l: len, c: cls, d: (duration * 10).rounded() / 10, t: tools,
                              at: Date().timeIntervalSince1970, p: project))
        if samples.count > 5000 { samples.removeFirst(samples.count - 5000) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Durations of turns comparable to this one, widest pool that is still large enough.
    func pool(len: Int, cls: String, project: String) -> [Double] {
        let target = log(Double(len) + 20)
        let byClass = samples.filter { $0.c == cls }
        let near = byClass.filter { abs(log(Double($0.l) + 20) - target) < 0.8 }
        // The same project first: work in a code repo and work on texts run differently.
        if !project.isEmpty {
            let mine = near.filter { $0.p == project }
            if mine.count >= 20 { return mine.map(\.d) }
        }
        if near.count >= 25 { return near.map(\.d) }
        if byClass.count >= 25 { return byClass.map(\.d) }
        if samples.count >= 10 { return samples.map(\.d) }
        // No history at all: a rough prior (seconds).
        return [20, 40, 60, 90, 120, 180, 240, 360, 600, 900]
    }

    /// Replies finished today and the total time they took.
    func today() -> (count: Int, seconds: Double) {
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let list = samples.filter { ($0.at ?? 0) + $0.d >= start }
        return (list.count, list.reduce(0) { $0 + $1.d })
    }

    /// Seconds left, or nil when this turn already runs longer than nearly all similar ones.
    func remaining(elapsed: Double, pool: [Double]) -> Double? {
        let alive = pool.filter { $0 > elapsed }.sorted()
        guard alive.count >= 4 else { return nil }
        let idx = min(alive.count - 1, Int(Double(alive.count) * 0.55))
        return max(alive[idx] - elapsed, 5)
    }
}
