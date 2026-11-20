import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    MainActor.assumeIsolated { renderSnapshots(to: args[i + 1]) }
    exit(0)
}
if let i = args.firstIndex(of: "--promo"), i + 1 < args.count {
    MainActor.assumeIsolated { renderPromo(to: args[i + 1]) }
    exit(0)
}
if args.contains("--selftest") { exit(runSelfTest()) }
if let i = args.firstIndex(of: "--register-hooks") {
    exit(Setup.registerHooks(install: i + 1 >= args.count || args[i + 1] != "uninstall"))
}
if args.contains("--seed-history") { exit(Setup.seedHistory(force: args.contains("--force"))) }

// Single instance: a second launch just exits.
let pidURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-pulse/app.pid")
if let old = try? String(contentsOf: pidURL, encoding: .utf8), let pid = Int32(old.trimmingCharacters(in: .whitespacesAndNewlines)),
   pid != getpid(), kill(pid, 0) == 0 {
    let running = NSRunningApplication(processIdentifier: pid)
    if running?.bundleIdentifier == Bundle.main.bundleIdentifier { exit(0) }
}
try? FileManager.default.createDirectory(at: pidURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try? "\(getpid())".write(to: pidURL, atomically: true, encoding: .utf8)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
