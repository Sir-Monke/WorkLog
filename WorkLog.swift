import AppKit
import ServiceManagement
import SwiftUI

// Settings: edit these for your own setup, then build. Day rate is further down in `dayRates`.
let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Work")   // your repo clones and notes
let historyURL = root.appendingPathComponent("WorkLog/history.json")
let myAuthors = ["Your Name"]                        // matched against git author name <email>
let contractStart = "2026-01-01"                     // count extra days from here
let contractedWeekdays: Set<Int> = [2, 3, 4, 5, 6]   // Mon to Fri (Sunday = 1); any other day you work is extra
let skipDirs: Set<String> = ["node_modules", "target", "build", "dist", ".build", "__pycache__", "WorkLog", "_to_delete"]

let keyFmt = fmt("yyyy-MM-dd", "en_US_POSIX")
let dayFmt = fmt("EEE d MMM", "en_GB")
let monthFmt = fmt("MMMM yyyy", "en_GB")
func fmt(_ f: String, _ locale: String) -> DateFormatter {
    let d = DateFormatter(); d.dateFormat = f; d.locale = Locale(identifier: locale); return d
}
func today() -> String { keyFmt.string(from: Date()) }
func plural(_ n: Int, _ w: String) -> String { "\(n) \(w)\(n == 1 ? "" : "s")" }

func isExtra(_ day: String) -> Bool {
    guard day >= contractStart, let d = keyFmt.date(from: day) else { return false }
    return !contractedWeekdays.contains(Calendar.current.component(.weekday, from: d))
}

struct Commit: Codable, Hashable { var repo, subject, hm: String; var body: String? = nil }
struct Proof: Codable {
    var commits: [Commit] = []
    var files: [String: Int] = [:]   // top-level item in root ("dir/" or "file.md") -> files edited
    var paths: [String]?             // up to 25 edited files, shallowest first (notes, PR bodies, scripts), for Claude
    var note: String?                // what you typed; wins over everything
    var ai: String?                  // Claude's one-line summary; wins over the automatic brief
    var aiStyle: Int?                // which prompt wrote `ai`; older ones get rewritten
    var removed: Bool?               // you undid this day; scans never bring it back
}

/// Bump when the Claude prompt changes so every note is rewritten in the new style.
let noteStyle = 3

/// Counts as worked: found or added, and not undone.
func counted(_ p: Proof?) -> Bool { p != nil && p?.removed != true }

/// One line on what you did: the first two commits grouped by repo, else where you worked.
func brief(_ p: Proof) -> String {
    if let n = p.note ?? (p.aiStyle == noteStyle ? p.ai : nil) { return n }
    var seen = Set<String>()
    let unique = p.commits.filter { seen.insert($0.repo + $0.subject).inserted }
    if unique.isEmpty {
        // Ticket folders and files (t1234, Scripts-T5678-v2) say more than their names.
        let tickets = Set(p.files.keys.compactMap { name in
            name.range(of: #"[Tt]\d{4,5}"#, options: .regularExpression).map { "T" + name[$0].dropFirst() }
        })
        if !tickets.isEmpty { return "Worked on " + tickets.sorted().joined(separator: ", ") }
        let places = p.files.keys.sorted { p.files[$0]! > p.files[$1]! }.prefix(3)
        return "Worked on " + places.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.joined(separator: ", ")
    }
    var parts: [(repo: String, subjects: [String])] = []
    for c in unique.prefix(2) {
        if let i = parts.firstIndex(where: { $0.repo == c.repo }) { parts[i].subjects.append(c.subject) } else { parts.append((c.repo, [c.subject])) }
    }
    let text: String = parts.map { "\($0.repo): " + $0.subjects.joined(separator: "; ") }.joined(separator: " · ")
    return unique.count > 2 ? "\(text) (+\(unique.count - 2) more)" : text
}

/// Extra days (outside contractedWeekdays) in a month ("2026-10"), oldest first.
func extraDays(_ month: String, _ history: [String: Proof]) -> [String] {
    history.keys.filter { $0.hasPrefix(month) && isExtra($0) && counted(history[$0]) }.sorted()
}

func monthTitle(_ month: String, _ history: [String: Proof]) -> String {
    let name = keyFmt.date(from: month + "-01").map { monthFmt.string(from: $0) } ?? month
    let days = extraDays(month, history)
    return "\(name): \(plural(days.count, "extra day")), \(money(pay(days))) gross"
}

/// Gross pay for one extra day, from the date it applies. Add a line when your rate changes; past months keep theirs.
/// Example: [("2026-01-01", Decimal(string: "150.00")!)]. Empty shows £0.00.
let dayRates: [(from: String, amount: Decimal)] = []
func rate(_ day: String) -> Decimal { dayRates.last { $0.from <= day }?.amount ?? 0 }
func pay(_ days: [String]) -> Decimal { days.reduce(0) { $0 + rate($1) } }

let moneyFmt: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .currency; f.locale = Locale(identifier: "en_GB"); return f
}()
func money(_ amount: Decimal) -> String { moneyFmt.string(from: amount as NSDecimalNumber) ?? "£\(amount)" }

/// Plain text for Slack: the month's extra days, one line each.
func summary(_ month: String, _ history: [String: Proof]) -> String {
    let days: [String] = extraDays(month, history).map { d -> String in
        let day: String = keyFmt.date(from: d).map { dayFmt.string(from: $0) } ?? d
        return "\(day) — \(brief(history[d]!))"
    }
    return ([monthTitle(month, history), ""] + days).joined(separator: "\n")
}

/// History never forgets: a later edit moves a file's date, so keep what earlier scans saw.
func merged(_ old: Proof?, _ new: Proof) -> Proof {
    var p = old ?? Proof()
    // One entry per commit; the newer scan wins so commit bodies fill in.
    var byKey = Dictionary(p.commits.map { ("\($0.repo)|\($0.subject)|\($0.hm)", $0) }, uniquingKeysWith: { a, _ in a })
    let before = byKey.count
    for c in new.commits { byKey["\(c.repo)|\(c.subject)|\(c.hm)"] = c }
    p.commits = byKey.values.sorted { $0.hm < $1.hm }
    p.files.merge(new.files) { max($0, $1) }   // p.note and p.removed are kept: scans never set them
    p.paths = shallowest(Set(p.paths ?? []).union(new.paths ?? []))
    if byKey.count != before { p.ai = nil }    // new commits: the summary is out of date
    return p
}

/// Up to 25 paths, top-level files first: those are the notes, PR bodies and scripts that say what you did.
func shallowest<S: Sequence>(_ paths: S) -> [String] where S.Element == String {
    Array(paths.sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }.prefix(25))
}

// MARK: AI notes (Claude Code, signed in with your Claude account; no API key)

let claudeInstructions = """
    Write one timesheet line saying what was actually done on this day of work. \
    One sentence, 12 to 20 words, past tense, plain UK English. \
    Be specific: name the feature, fix, test or document and the part of the product it touched. \
    Never mention file counts, folder names or "edited files". \
    Put the ticket ID in brackets at the end if there is one, for example: \
    Added CSV export to the reports page and fixed the date range filter (T1234). \
    Reply with the sentence only, no full stop.
    """

/// The `claude` command: your shell's PATH first, then the usual install places, then the copy the Claude app keeps.
let claudePath: String? = {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    let shell = run("/bin/zsh", ["-lc", "command -v claude"], timeout: 10).out   // last line: profiles can print first
    var candidates = [shell.split(separator: "\n").last.map(String.init) ?? "",
                      "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                      "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
    let app = "\(home)/Library/Application Support/Claude"
    for dir in ((try? fm.contentsOfDirectory(atPath: app)) ?? []) where dir.hasPrefix("claude-code") {
        let found = (fm.enumerator(atPath: "\(app)/\(dir)")?.allObjects as? [String] ?? []).filter { $0.hasSuffix("/claude") || $0 == "claude" }
        candidates += found.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(app)/\(dir)/\($0)" }
    }
    return candidates.first { !$0.isEmpty && fm.isExecutableFile(atPath: $0) }
}()

struct ClaudeError: LocalizedError { let errorDescription: String? }

/// What Claude sees: commit messages, the names of files you edited and the titles of your notes. Never code.
func prompt(_ day: String, _ p: Proof) -> String {
    var lines = ["Date: \(day)"]
    var seen = Set<String>()
    for c in p.commits where seen.insert(c.repo + c.subject).inserted {
        lines.append("Commit in \(c.repo): \(c.subject)" + (c.body.map { " — \($0)" } ?? ""))
    }
    for path in p.paths ?? [] {
        lines.append("Edited \(path)" + (title(path).map { " (titled \"\($0)\")" } ?? ""))
    }
    return lines.joined(separator: "\n")
}

/// The first heading of a Markdown or text note, if it has one.
func title(_ path: String) -> String? {
    guard path.hasSuffix(".md") || path.hasSuffix(".txt"),
          let h = FileHandle(forReadingAtPath: root.appendingPathComponent(path).path) else { return nil }
    defer { try? h.close() }
    let head = String(decoding: h.readData(ofLength: 4096), as: UTF8.self)
    let line = head.split(whereSeparator: \.isNewline).first { $0.hasPrefix("#") }
    return line.map { l in String(l.drop { $0 == "#" || $0 == " " }.prefix(100)) }
}

/// `claude -p` with Haiku, run from an empty temp folder so it has nothing to read. Blocks; call off the main thread.
func askClaude(_ text: String) throws -> String {
    guard let exe = claudePath else {
        throw ClaudeError(errorDescription: "Claude Code not found. Install it and sign in once: claude.com/claude-code")
    }
    // Haiku is the smallest, cheapest model. Replacing Claude Code's system prompt and turning off its tools,
    // MCP servers and saved sessions keeps each call to a few hundred tokens.
    let args = ["-p", "--model", "haiku", "--system-prompt", claudeInstructions, "--tools", "",
                "--strict-mcp-config", "--no-session-persistence", text]
    let r = run(exe, args, cwd: FileManager.default.temporaryDirectory, timeout: 120)
    let line = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    guard r.ok, !line.isEmpty else {
        throw ClaudeError(errorDescription: line.isEmpty ? "Claude didn't answer" : "Claude: " + String(line.prefix(160)))
    }
    return line
}

func git(_ args: [String]) -> String { run("/usr/bin/git", args).out }

/// Runs a command and returns its output. Apps opened from Finder get a bare PATH, so add the usual bin folders.
/// Output goes to a temp file, not a pipe: claude can leave helper processes holding a pipe open long after it exits.
func run(_ exe: String, _ args: [String], cwd: URL? = nil, timeout: TimeInterval = 60) -> (out: String, ok: Bool) {
    let fm = FileManager.default
    let outURL = fm.temporaryDirectory.appendingPathComponent("worklog-\(UUID().uuidString).out")
    fm.createFile(atPath: outURL.path, contents: nil)
    defer { try? fm.removeItem(at: outURL) }
    guard let out = try? FileHandle(forWritingTo: outURL) else { return ("", false) }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.currentDirectoryURL = cwd
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "\(fm.homeDirectoryForCurrentUser.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
    p.environment = env
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { try? out.close(); return ("", false) }
    let kill = DispatchWorkItem { if p.isRunning { p.terminate() } }   // never hang on a stuck command
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)
    p.waitUntilExit()
    kill.cancel()
    try? out.close()
    let text = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
    return (text, p.terminationStatus == 0)
}

/// Every day since contractStart with your commits or file edits in root.
func collect() -> [String: Proof] {
    var out: [String: Proof] = [:]
    let fm = FileManager.default

    // Commits: every repo clone at the top level; the same commit in several clones counts once.
    var seen = Set<String>()
    for name in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    where fm.fileExists(atPath: root.appendingPathComponent(name + "/.git").path) {
        let dir = root.appendingPathComponent(name).path
        // Real repo name from the remote URL, so clones like MyApp-PR12 read as MyApp.
        let url = git(["-C", dir, "config", "--get-regexp", "^remote\\..*\\.url$"])
            .split(separator: "\n").first?.split(separator: " ").last.map(String.init) ?? ""
        var repo = url.split(separator: "/").last.map(String.init) ?? name
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        if repo.isEmpty || repo.contains(":") { repo = name }

        let args = ["-C", dir, "log", "--all", "--no-merges",
                    "--since=\(contractStart) 00:00", "--date=format-local:%Y-%m-%d %H:%M",
                    "--format=%H%x1f%ad%x1f%cd%x1f%s%x1f%b%x1e"] + myAuthors.map { "--author=" + $0 }
        for record in git(args).split(separator: "\u{1e}") {
            let f = record.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
            guard f.count == 5 else { continue }
            let body = f[4].split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { line in !line.isEmpty && !["co-authored-by", "signed-off-by", "claude-session"].contains { line.lowercased().hasPrefix($0) } }
                .joined(separator: " ")
            for stamp in [f[1], f[2]] {   // authored and committed (rebase, amend) both prove work that day
                let day = String(stamp.prefix(10))
                guard day >= contractStart, seen.insert(f[0] + day).inserted else { continue }
                out[day, default: Proof()].commits.append(Commit(repo: repo, subject: f[3], hm: String(stamp.suffix(5)),
                                                                 body: body.isEmpty ? nil : String(body.prefix(300))))
            }
        }
    }

    // Files: modification dates, grouped by top-level folder, plus the paths themselves.
    var paths: [String: [String]] = [:]
    let start = keyFmt.date(from: contractStart)!
    let depth = root.pathComponents.count
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
    if let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
        for case let url as URL in en {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if skipDirs.contains(url.lastPathComponent) { en.skipDescendants() }
                continue
            }
            let parts = url.pathComponents
            guard let m = v.contentModificationDate, m >= start, parts.count > depth else { continue }
            let top = parts[depth] + (parts.count > depth + 1 ? "/" : "")
            let day = keyFmt.string(from: m)
            out[day, default: Proof()].files[top, default: 0] += 1
            paths[day, default: []].append(parts[depth...].joined(separator: "/"))
        }
    }
    for (day, list) in paths { out[day]?.paths = shallowest(list) }
    return out
}

@MainActor final class Store: ObservableObject {
    @Published var history: [String: Proof] = [:]
    @Published var error: String?
    @Published var summarising = false
    @Published var progress = ""      // "2 of 6" while notes are being written
    private var scanning = false
    private var timer: Timer?

    init() {
        history = Store.load()
        // Open at login, but only for the installed copy, never a build Xcode is running.
        if Bundle.main.bundlePath.contains("/Applications/") {
            try? SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
                error = "Turn on WorkLog in System Settings › General › Login Items"
            }
        }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    /// Months with work, newest first ("2026-10").
    var months: [String] { Set(history.keys.filter { isExtra($0) && counted(history[$0]) }.map { String($0.prefix(7)) }).sorted(by: >) }

    /// Saves your note for a day. An unchanged auto note stays automatic; an empty note on a day with no proof removes it.
    func setNote(_ day: String, _ typed: String) {
        var p = history[day] ?? Proof()
        p.removed = nil   // saving a day you undid brings it back
        p.note = nil
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        p.note = (text.isEmpty || text == brief(p)) ? nil : text
        history[day] = (p.note == nil && p.commits.isEmpty && p.files.isEmpty) ? nil : p
        save()
    }

    /// Undo a day. Days found from your work are kept but hidden so the next scan doesn't add them back.
    func remove(_ day: String) {
        guard var p = history[day] else { return }
        p.note = nil
        p.removed = true
        history[day] = (p.commits.isEmpty && p.files.isEmpty) ? nil : p
        save()
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let found = collect()
            await MainActor.run {
                var h = self.history
                for (day, p) in found { h[day] = merged(h[day], p) }
                self.history = h
                self.scanning = false
                self.save()
                Task { await self.summarise() }
            }
        }
    }

    /// Asks Claude for a note on every extra day that has none yet, newest first.
    func summarise() async {
        guard !summarising else { return }
        summarising = true
        defer { summarising = false }
        let todo = history.keys.filter { d in
            guard let p = history[d], isExtra(d), counted(p), p.note == nil else { return false }
            return p.ai == nil || p.aiStyle != noteStyle
        }.sorted(by: >)
        guard !todo.isEmpty else { return }
        let path = await Task.detached { claudePath }.value   // first lookup runs a shell; keep it off the main thread
        print("WorkLog: \(todo.count) notes to write with \(path ?? "no claude")")
        // Each call starts Claude Code, which takes a few seconds, so run four at once.
        // ponytail: fixed batches of 4; a sliding window only matters for dozens of notes
        var done = 0, failed: String?
        progress = "0 of \(todo.count)"
        for start in stride(from: 0, to: todo.count, by: 4) {
            let batch = todo[start..<min(start + 4, todo.count)].compactMap { d in history[d].map { (d, $0) } }
            await withTaskGroup(of: (String, Result<String, Error>).self) { group in
                for (d, p) in batch {
                    group.addTask { (d, Result { try askClaude(prompt(d, p)) }) }
                }
                for await (d, result) in group {
                    done += 1
                    progress = "\(done) of \(todo.count)"
                    switch result {
                    case .success(let line):
                        history[d]?.ai = line
                        history[d]?.aiStyle = noteStyle
                        save()
                    case .failure(let e):
                        failed = e.localizedDescription
                        print("WorkLog: \(d): \(e.localizedDescription)")   // shows in Xcode's console
                    }
                }
            }
        }
        progress = ""
        error = failed
    }

    static func load() -> [String: Proof] {
        guard let data = try? Data(contentsOf: historyURL) else { return [:] }
        if let h = try? JSONDecoder().decode([String: Proof].self, from: data) { return h }
        // Never overwrite a history we cannot read: keep a copy beside it.
        try? data.write(to: historyURL.deletingLastPathComponent().appendingPathComponent("history.unreadable.json"))
        return [:]
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(history).write(to: historyURL, options: .atomic)
            error = nil
        } catch {
            self.error = "Not saved: \(error.localizedDescription)"
        }
    }
}

let gold = Color(red: 0.84, green: 0.58, blue: 0.24)

/// "October 2026  ‹ ›", limited to the contract start and this month.
struct MonthHeader: View {
    @Binding var month: String
    var unlocked: Binding<Bool>? = nil   // set for past months: shows the padlock

    var body: some View {
        HStack {
            Text(keyFmt.date(from: month + "-01").map { monthFmt.string(from: $0) } ?? month).font(.title3.weight(.semibold))
            if let unlocked {
                Button { unlocked.wrappedValue.toggle() } label: {
                    Image(systemName: unlocked.wrappedValue ? "lock.open.fill" : "lock.fill").frame(width: 26, height: 26)
                }
                .foregroundStyle(unlocked.wrappedValue ? gold : Color.secondary)
                .help(unlocked.wrappedValue ? "Lock this month" : "Unlock to change this month")
            }
            Spacer()
            Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 26, height: 26) }
                .disabled(month <= String(contractStart.prefix(7)))
            Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 26, height: 26) }
                .disabled(month >= String(today().prefix(7)))
        }
        .buttonStyle(.borderless)
    }

    func shift(_ n: Int) {
        guard let first = keyFmt.date(from: month + "-01"),
              let next = Calendar(identifier: .gregorian).date(byAdding: .month, value: n, to: first) else { return }
        month = String(keyFmt.string(from: next).prefix(7))
    }
}

/// Month grid. Gold tint = extra day with work, solid gold = picked,
/// gold number = today, faded = contracted day or future (not clickable).
struct MonthGrid: View {
    let month: String
    let size: CGFloat
    let history: [String: Proof]
    var selected: String? = nil
    var locked = false
    let pick: (String) -> Void
    @State private var hovered: String?

    var gap: CGFloat { size / 6 }

    var body: some View {
        let days = cells
        VStack(spacing: gap) {
            HStack(spacing: gap) {
                ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { w in
                    Text(w.prefix(1))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(width: size)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(size), spacing: gap), count: 7), spacing: gap) {
                ForEach(days.indices, id: \.self) { i in
                    if let d = days[i] { cell(d) } else { Color.clear.frame(height: size) }
                }
            }
        }
    }

    func cell(_ d: String) -> some View {
        let open = isExtra(d) && d <= today()
        let worked = open && counted(history[d])
        let picked = d == selected
        let over = hovered == d && open
        let fg: Color = picked ? .white : d == today() || worked ? gold : open ? .primary : Color.secondary.opacity(0.35)
        let bg: Color = picked ? gold : worked ? gold.opacity(over ? 0.3 : 0.16) : over ? Color.primary.opacity(0.07) : .clear
        return Button { pick(d) } label: {
            Text("\(Int(d.suffix(2)) ?? 0)")
                .font(.system(size: size * 0.36, weight: picked || worked || d == today() ? .semibold : .regular))
                .frame(width: size, height: size)
                .foregroundStyle(fg)
                .background(bg, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!open || locked)
        .onHover { hovered = $0 ? d : (hovered == d ? nil : hovered) }
        .help(history[d].map(brief) ?? "")
    }

    /// Leading blanks so the 1st sits under its weekday (Monday first), then each day of the month.
    var cells: [String?] {
        let cal = Calendar(identifier: .gregorian)
        guard let first = keyFmt.date(from: month + "-01"), let count = cal.range(of: .day, in: .month, for: first)?.count else { return [] }
        let lead = (cal.component(.weekday, from: first) + 5) % 7
        let days: [String?] = (0..<count).map { keyFmt.string(from: cal.date(byAdding: .day, value: $0, to: first)!) }
        return Array(repeating: nil, count: lead) + days
    }
}

/// Menu bar panel: the month, how many extra days, the calendar. Click a day to add or change its note right here.
struct Panel: View {
    @ObservedObject var store: Store
    @State private var month = String(today().prefix(7))
    @State private var day: String?
    @State private var note = ""
    @State private var filled = ""
    @State private var copied = false
    @State private var unlocked = false

    var body: some View {
        let days = extraDays(month, store.history)
        let count = days.count
        VStack(alignment: .leading, spacing: 18) {
            MonthHeader(month: $month, unlocked: past ? $unlocked : nil)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(count)").font(.system(size: 44, weight: .semibold, design: .rounded)).foregroundStyle(gold)
                Text(count == 1 ? "extra day" : "extra days").font(.title3).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(money(pay(days))).font(.title3.weight(.semibold).monospacedDigit())
                    Text("gross").font(.caption).foregroundStyle(.secondary)
                }
            }

            MonthGrid(month: month, size: 36, history: store.history, selected: day, locked: past && !unlocked) { d in day = day == d ? nil : d }

            VStack(alignment: .leading, spacing: 10) {
                if let d = day {
                    HStack(alignment: .firstTextBaseline) {
                        Text(keyFmt.date(from: d).map { fmt("EEEE d MMMM", "en_GB").string(from: $0) } ?? d).font(.headline)
                        Spacer()
                        Text(money(rate(d))).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    TextField("What you did", text: $note, axis: .vertical)
                        .lineLimit(4, reservesSpace: true)
                        .font(.callout)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onSubmit(save)
                    HStack(spacing: 8) {
                        if counted(store.history[d]) {
                            Button("Remove", role: .destructive) { store.remove(d); day = nil }.tint(.red)
                        }
                        Spacer()
                        Button("Cancel") { day = nil }
                        Button(counted(store.history[d]) ? "Save" : "Add day", action: save)
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary(month, store.history), forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy for Slack", systemImage: copied ? "checkmark" : "doc.on.doc").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(count == 0)
                }
            }

            HStack(spacing: 6) {
                if store.summarising {
                    ProgressView().controlSize(.small)
                    Text("Writing notes… \(store.progress)").font(.caption).foregroundStyle(.secondary)
                } else if let e = store.error {
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 36 * 7 + 6 * 6 + 40)
        .tint(gold)
        .onAppear { store.scan() }
        // The note fills in from what you did that day: your own note, else Claude's, else the commits.
        .onChange(of: day) { d in filled = auto(d); note = filled }
        .onChange(of: day.flatMap { store.history[$0]?.ai }) { _ in
            if note == filled { filled = auto(day); note = filled }   // Claude's note arrived; keep anything you typed
        }
        .onChange(of: month) { _ in day = nil; unlocked = false }   // past months lock again when you leave them
        .onChange(of: unlocked) { if !$0 { day = nil } }
    }

    /// Months before this one are locked until you click the padlock.
    var past: Bool { month < String(today().prefix(7)) }

    func auto(_ d: String?) -> String { d.flatMap { store.history[$0] }.map(brief) ?? "" }

    func save() {
        guard let d = day else { return }
        store.setNote(d, note)
        day = nil
    }
}

/// Run from Xcode (or anywhere else), the app copies itself into Applications, starts that copy and quits,
/// so it never needs Xcode again. If the copy fails it just keeps running from where it is.
func installAndRelaunch() {
    let fm = FileManager.default
    var folder = URL(fileURLWithPath: "/Applications")
    if !fm.isWritableFile(atPath: folder.path) { folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications") }
    let target = folder.appendingPathComponent("WorkLog.app")

    // Quit the installed copy first, so it can be replaced.
    let old = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").filter { $0 != NSRunningApplication.current }
    old.forEach { $0.terminate() }
    for _ in 0..<30 where old.contains(where: { !$0.isTerminated }) { Thread.sleep(forTimeInterval: 0.1) }
    old.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }

    do {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: Bundle.main.bundleURL, to: target)
    } catch {
        print("WorkLog: could not install into \(folder.path): \(error.localizedDescription)")
        return
    }
    _ = run("/usr/bin/open", [target.path])
    exit(0)
}

@main struct WorkLogApp: App {
    @StateObject private var store = Store()

    init() {
        guard CommandLine.arguments.contains("--selftest") else {
            if !Bundle.main.bundlePath.contains("/Applications/") { installAndRelaunch() }
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            if others.contains(where: { $0 != NSRunningApplication.current && $0.bundleURL?.path.contains("/Applications/") == true }) { exit(0) }   // already running
            return
        }
        precondition(isExtra("2026-10-03") && isExtra("2026-10-04"), "Sat and Sun are extra")
        precondition(!isExtra("2026-10-06") && !isExtra("2025-12-27"), "Tue, and anything before contractStart, is not")
        let c = { (r: String, s: String, hm: String) in Commit(repo: r, subject: s, hm: hm) }
        let p = Proof(commits: [c("A", "x", "09:00"), c("A", "x", "10:00"), c("A", "y", "11:00"), c("B", "z", "12:00"), c("B", "w", "13:00")])
        precondition(brief(p) == "A: x; y (+2 more)", "brief caps at two")
        precondition(brief(Proof(commits: [c("A", "x", "09:00"), c("B", "z", "10:00")])) == "A: x · B: z", "brief groups by repo")
        precondition(brief(Proof(files: ["MyApp-T1234/": 3, "t5678/": 2, "notes.md": 1])) == "Worked on T1234, T5678", "tickets from file names")
        precondition(brief(Proof(files: ["notes.md": 1])) == "Worked on notes.md", "brief without commits or tickets")
        precondition(brief(Proof(commits: [c("A", "x", "09:00")], note: "Planning call", ai: "AI")) == "Planning call", "your note wins")
        precondition(brief(Proof(commits: [c("A", "x", "09:00")], ai: "Fixed X", aiStyle: noteStyle)) == "Fixed X", "Claude's note beats the commits")
        precondition(brief(Proof(commits: [c("A", "x", "09:00")], ai: "Old long note", aiStyle: nil)) == "A: x", "old-style notes are not used")
        precondition(!counted(Proof(commits: [c("A", "x", "09:00")], removed: true)) && counted(Proof()), "undone days don't count")
        precondition(merged(Proof(removed: true), Proof(commits: [c("A", "x", "09:00")])).removed == true, "a scan never brings an undone day back")
        let withBody = merged(Proof(commits: [c("A", "x", "09:00")], ai: "s"), Proof(commits: [Commit(repo: "A", subject: "x", hm: "09:00", body: "why")]))
        precondition(withBody.commits.count == 1 && withBody.commits[0].body == "why" && withBody.ai == "s", "a body fills in without rewriting the note")
        precondition(shallowest(["a/b/c.swift", "notes.md", "t1/plan.md"]) == ["notes.md", "t1/plan.md", "a/b/c.swift"], "top-level files first")
        precondition(merged(Proof(commits: [c("A", "x", "09:00")], ai: "s"), Proof(commits: [c("A", "x", "09:00")])).ai == "s", "same commits keep the summary")
        precondition(merged(Proof(commits: [c("A", "x", "09:00")], ai: "s"), Proof(commits: [c("B", "z", "10:00")])).ai == nil, "new commits clear it")
        let m = merged(Proof(commits: [c("A", "x", "09:00")], files: ["t/": 2]), Proof(commits: [c("A", "x", "09:00"), c("B", "z", "12:00")], files: ["t/": 1, "u/": 4]))
        precondition(m.commits.count == 2 && m.files == ["t/": 2, "u/": 4], "merge keeps the most seen")
        let h = ["2026-10-01": p, "2026-10-03": Proof(files: ["t/": 1])]
        precondition(summary("2026-10", h) == "October 2026: 1 extra day, £0.00 gross\n\nSat 3 Oct — Worked on t", "month summary lists extra days only")
        let all = collect().mapValues { merged(nil, $0) }
        for month in Set(all.keys.map { String($0.prefix(7)) }).sorted() { print(summary(month, all), "\n") }
        print("selftest ok")
        exit(0)
    }

    var body: some Scene {
        MenuBarExtra("WorkLog", systemImage: "briefcase") {
            Panel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
