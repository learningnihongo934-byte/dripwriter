// DripWriter for macOS: types text into whatever app has focus, keystroke by keystroke.
// The same binary is also the `dripwriter` terminal command (see CLI below).
import SwiftUI
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import ServiceManagement

let appVersion = "2.0.0"

// MARK: - Typing model (shared by the app and the CLI)

enum Rhythm: String, CaseIterable, Identifiable {
    case human = "Human", steady = "Steady", nervous = "Nervous", hacker = "Burst", drip = "Drip"
    var id: String { rawValue }
    var etaFactor: Double { [.human: 1.35, .steady: 1, .nervous: 1.6, .hacker: 0.8, .drip: 2.2][self]! }
    var symbol: String { [.human: "person.fill", .steady: "metronome.fill", .nervous: "bolt.heart.fill", .hacker: "bolt.fill", .drip: "drop.fill"][self]! }
    var blurb: String {
        [.human: "Natural pace, pauses after sentences", .steady: "Every key exactly on the beat",
         .nervous: "Jittery with sudden stalls", .hacker: "Fast bursts, short breaks", .drip: "Slow, swaying, unhurried"][self]!
    }
}

enum NewlineMode: String, CaseIterable, Identifiable {
    case ret = "Return", shiftRet = "Shift+Return", optRet = "Option+Return"
    var id: String { rawValue }
    var hint: String { [.ret: "Editors, docs, notes", .shiftRet: "Slack, Discord, ChatGPT", .optRet: "Some chat apps"][self]! }
}

enum Typing {
    static func gauss() -> Double { let u = Double.random(in: 1e-9..<1), v = Double.random(in: 0..<1); return sqrt(-2 * log(u)) * cos(2 * .pi * v) }

    /// Seconds to wait after typing `ch` at index `pos`.
    static func delay(after ch: Character, pos: Int, cps: Double, rhythm: Rhythm) -> Double {
        let b = 1 / cps
        var d = b
        switch rhythm {
        case .steady: return d
        case .human:
            d *= max(0.35, 1 + gauss() * 0.35)
            if ".!?".contains(ch) { d += b * 8 + .random(in: 0...(b * 6)) }
            else if ",;:".contains(ch) { d += b * 4 }
            else if ch == "\n" { d += b * 6 }
            else if ch == " " && Double.random(in: 0..<1) < 0.04 { d += b * 10 }
        case .nervous:
            d *= max(0.2, 1 + gauss() * 0.8)
            if Double.random(in: 0..<1) < 0.05 { d += b * 20 }
        case .hacker: d *= Double.random(in: 0..<1) < 0.85 ? 0.35 : 2.5
        case .drip:
            d *= 1.8 + sin(Double(pos) / 9) * 0.5
            if ch == "\n" { d += b * 12 }
        }
        return d
    }

    static func clean(_ s: String, quotes: Bool, tabs: Bool, trailing: Bool) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if quotes {
            for (a, b) in [("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{2013}", "-"), ("\u{2014}", "--"), ("\u{2026}", "..."), ("\u{00A0}", " ")] {
                t = t.replacingOccurrences(of: a, with: b)
            }
        }
        if tabs { t = t.replacingOccurrences(of: "\t", with: "    ") }
        if trailing { t = t.split(separator: "\n", omittingEmptySubsequences: false).map { String($0.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed()) }.joined(separator: "\n") }
        return t
    }

    static func speedLabel(_ cps: Double) -> String { cps < 20 ? "\(Int((cps * 12).rounded())) wpm" : "\(Int(cps)) keys/s" }
    static func clock(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Keystrokes

enum Keys {
    private static let src = CGEventSource(stateID: .hidSystemState)
    private static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map(Array.init)

    static func type(_ s: String) {
        let utf16 = Array(s.utf16)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
            e.flags = []
            e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            e.post(tap: .cghidEventTap)
        }
    }

    static func press(_ key: Int, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    static func newline(_ mode: NewlineMode) {
        switch mode {
        case .ret: press(kVK_Return)
        case .shiftRet: press(kVK_Return, flags: .maskShift)
        case .optRet: press(kVK_Return, flags: .maskAlternate)
        }
    }
    static func tab() { press(kVK_Tab) }
    static func backspace() { press(kVK_Delete) }

    static func neighbor(of ch: Character) -> Character? {
        let lo = Character(ch.lowercased())
        for row in rows {
            guard let i = row.firstIndex(of: lo) else { continue }
            let j = i == 0 ? 1 : (i == row.count - 1 ? i - 1 : (Bool.random() ? i - 1 : i + 1))
            let n = row[j]
            return ch.isUppercase ? Character(n.uppercased()) : n
        }
        return nil
    }

    /// Types one character the way the settings say, with an optional typo first. Returns true if a typo was made.
    static func emit(_ ch: Character, newline: NewlineMode, typoPct: Double, wait: (Double) -> Void, base: Double) -> Bool {
        var typo = false
        if typoPct > 0, ch.isLetter, ch.isASCII, Double.random(in: 0..<100) < typoPct, let wrong = neighbor(of: ch) {
            type(String(wrong)); wait(base * 3 + 0.15 + .random(in: 0...0.25))
            backspace(); wait(base * 2.5 + 0.08)
            typo = true
        }
        if ch == "\n" { Keys.newline(newline) } else if ch == "\t" { tab() } else { type(String(ch)) }
        return typo
    }
}

// MARK: - Snippets

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var text: String
    var date = Date()
    static func titled(_ text: String) -> Snippet {
        let first = text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "Untitled"
        return Snippet(name: first.isEmpty ? "Untitled" : String(first.prefix(40)), text: text)
    }
}

// MARK: - Engine

enum RunState: String { case idle = "Ready", countdown = "Get ready", typing = "Typing", paused = "Paused", done = "Done" }

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @AppStorage("text") var text = """
    Hello from DripWriter.

    Click into any app, then press ⌃⌥⌘D.
    Every space    and tab\tis kept exactly as written.
    """
    @AppStorage("speed") var speed = 0.38            // 0...1, exponential to 1...400 keys/sec
    @AppStorage("rhythm") var rhythmRaw = Rhythm.human.rawValue
    @AppStorage("typos") var typoPct = 0.0
    @AppStorage("newline") var newlineRaw = NewlineMode.ret.rawValue
    @AppStorage("stripIndent") var stripIndent = false
    @AppStorage("countdown") var countdown = 3
    @AppStorage("useClipboard") var useClipboard = false
    @AppStorage("finishIn") var finishIn = false
    @AppStorage("finishMinutes") var finishMinutes = 2.0
    @AppStorage("sound") var sound = "Off"
    @AppStorage("bell") var bell = true
    @AppStorage("showHUD") var showHUD = true
    @AppStorage("pauseOnSwitch") var pauseOnSwitch = true
    @AppStorage("escStops") var escStops = true
    @AppStorage("cleanQuotes") var cleanQuotes = false
    @AppStorage("cleanTabs") var cleanTabs = false
    @AppStorage("cleanTrailing") var cleanTrailing = false
    @AppStorage("lifetimeChars") var lifetimeChars = 0
    @AppStorage("lifetimeRuns") var lifetimeRuns = 0
    @AppStorage("lifetimeTypos") var lifetimeTypos = 0

    @Published var state: RunState = .idle
    @Published var pos = 0
    @Published var total = 0
    @Published var typosFixed = 0
    @Published var countdownLeft = 0
    @Published var autoPaused = false
    @Published var snippets: [Snippet] = [] { didSet { save("snippets", snippets) } }
    @Published var history: [Snippet] = [] { didSet { save("history", history) } }
    @Published var showTestRun = false

    private var task: Task<Void, Never>?
    private var chars: [Character] = []
    private var paceOverride: Double?
    private var targetPID: pid_t?
    private var hideWhenStarting = true

    init() {
        snippets = load("snippets") ?? [
            Snippet(name: "Cover letter opener", text: "Dear Hiring Manager,\n\nI'm writing to apply for the role at your company.\n"),
            Snippet(name: "Fibonacci in Python", text: "def fib(n):\n    if n < 2:\n        return n\n    return fib(n - 1) + fib(n - 2)\n"),
        ]
        history = load("history") ?? []
    }

    var rhythm: Rhythm { Rhythm(rawValue: rhythmRaw) ?? .human }
    var newline: NewlineMode { NewlineMode(rawValue: newlineRaw) ?? .ret }
    var sliderCPS: Double { (exp(log(400.0) * speed) * 10).rounded() / 10 }
    var cps: Double { paceOverride ?? sliderCPS }
    var speedLabel: String { finishIn && state == .idle ? "in \(Typing.clock(finishMinutes * 60))" : Typing.speedLabel(cps) }
    var progress: Double { total == 0 ? 0 : Double(pos) / Double(total) }
    var etaSeconds: Double { Double(total - pos) / cps * rhythm.etaFactor }
    var isActive: Bool { state == .typing || state == .paused || state == .countdown }
    var sourceText: String { useClipboard ? (NSPasteboard.general.string(forType: .string) ?? "") : text }

    // MARK: control

    func toggle() {
        switch state {
        case .typing: state = .paused; autoPaused = false
        case .paused: state = .typing; autoPaused = false
        case .countdown: stop()
        default: start()
        }
    }

    func start(fromClipboard: Bool? = nil, hide: Bool = true, countdownOverride: Int? = nil) {
        guard Accessibility.ensure() else { return }
        let clip = fromClipboard ?? useClipboard
        var source = clip ? (NSPasteboard.general.string(forType: .string) ?? "") : text
        source = Typing.clean(source, quotes: cleanQuotes, tabs: cleanTabs, trailing: cleanTrailing)
        guard !source.isEmpty else { NSSound.beep(); return }
        task?.cancel()
        chars = Array(source); pos = 0; total = chars.count; typosFixed = 0; autoPaused = false
        paceOverride = finishIn ? Double(total) * rhythm.etaFactor / max(5, finishMinutes * 60) : nil
        hideWhenStarting = hide
        remember(source)
        if hide, NSApp.isActive { NSApp.hide(nil) }
        if showHUD && hide { HUD.show() }
        task = Task { await run(countdown: countdownOverride ?? countdown) }
    }

    func stop() {
        task?.cancel(); task = nil
        state = pos >= total && total > 0 ? .done : .idle
        autoPaused = false
        HUD.hideSoon()
    }

    func nudgeSpeed(_ delta: Double) {
        paceOverride = nil
        speed = min(1, max(0, speed + delta))
        objectWillChange.send()
    }

    func appSwitched(to pid: pid_t) {
        guard pauseOnSwitch, let target = targetPID else { return }
        if state == .typing && pid != target { state = .paused; autoPaused = true }
        else if state == .paused && autoPaused && pid == target { state = .typing; autoPaused = false }
    }

    // MARK: loop

    private func run(countdown: Int) async {
        state = .countdown
        for i in stride(from: countdown, to: 0, by: -1) {
            countdownLeft = i
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
        }
        targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        state = .typing
        lifetimeRuns += 1
        var atLineStart = false
        while pos < chars.count {
            if Task.isCancelled { return }
            if state == .paused { try? await Task.sleep(nanoseconds: 50_000_000); continue }
            let ch = chars[pos]

            // editors that auto-indent would double the indentation; skip it and let them indent
            if stripIndent && atLineStart && (ch == " " || ch == "\t") { pos += 1; continue }
            atLineStart = ch == "\n"

            let base = 1 / cps
            // a typo needs two pauses mid-character; collect them and replay with async sleeps
            if typoPct > 0, ch.isLetter, ch.isASCII, Double.random(in: 0..<100) < typoPct, let wrong = Keys.neighbor(of: ch) {
                Keys.type(String(wrong)); click(ch)
                await sleep(base * 3 + 0.15 + .random(in: 0...0.25))
                if Task.isCancelled { return }
                while state == .paused { try? await Task.sleep(nanoseconds: 50_000_000); if Task.isCancelled { return } }
                Keys.backspace(); click(ch)
                await sleep(base * 2.5 + 0.08)
                typosFixed += 1; lifetimeTypos += 1
            }
            _ = Keys.emit(ch, newline: newline, typoPct: 0, wait: { _ in }, base: base)
            click(ch)
            pos += 1
            lifetimeChars += 1
            await sleep(Typing.delay(after: ch, pos: pos, cps: cps, rhythm: rhythm))
        }
        state = .done
        paceOverride = nil
        if sound != "Off" || bell { NSSound(named: "Glass")?.play() }
        HUD.hideSoon()
    }

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(max(0.001, s) * 1_000_000_000)) }

    private func click(_ ch: Character) {
        if ch == "\n" && bell { NSSound(named: "Tink")?.play(); return }
        guard sound != "Off", let s = NSSound(named: NSSound.Name(sound)) else { return }
        s.volume = 0.35
        if !s.isPlaying { s.play() }
    }

    // MARK: library

    func remember(_ s: String) {
        history.removeAll { $0.text == s }
        history.insert(.titled(s), at: 0)
        if history.count > 15 { history.removeLast(history.count - 15) }
    }
    func saveSnippet() { guard !text.isEmpty, !snippets.contains(where: { $0.text == text }) else { return }; snippets.insert(.titled(text), at: 0) }
    func load(_ s: Snippet) { useClipboard = false; text = s.text }

    func openFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.plainText, .sourceCode, .text, .json, .html, .xml]
        p.allowsOtherFileTypes = true
        if p.runModal() == .OK, let url = p.url { importFile(url) }
    }
    func importFile(_ url: URL) {
        if let s = try? String(contentsOf: url, encoding: .utf8) { useClipboard = false; text = s }
        else { NSSound.beep() }
    }

    private func save<T: Encodable>(_ key: String, _ v: T) { UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: key) }
    private func load<T: Decodable>(_ key: String) -> T? { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
}

// MARK: - Accessibility

enum Accessibility {
    static var trusted: Bool { AXIsProcessTrusted() }

    @MainActor static func ensure() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) { return true }
        let a = NSAlert()
        a.icon = NSApp.applicationIconImage
        a.messageText = "Let DripWriter type for you"
        a.informativeText = "macOS needs your OK before an app can press keys in other apps.\n\nOpen System Settings → Privacy & Security → Accessibility, switch on DripWriter, then press Start again."
        a.addButton(withTitle: "Open Settings"); a.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { openSettings() }
        return false
    }
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Global hotkeys and monitors

enum HotKeys {
    // ⌃⌥⌘D start/pause · ⌃⌥⌘V type clipboard · ⌃⌥⌘. stop · ⌃⌥⌘↑/↓ speed
    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            Task { @MainActor in
                let e = Engine.shared
                switch id.id {
                case 1: e.toggle()
                case 2: e.start(fromClipboard: true)
                case 3: e.stop()
                case 4: e.nudgeSpeed(0.04)
                default: e.nudgeSpeed(-0.04)
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
        let mods = UInt32(controlKey | optionKey | cmdKey)
        for (n, key) in [(1, kVK_ANSI_D), (2, kVK_ANSI_V), (3, kVK_ANSI_Period), (4, kVK_UpArrow), (5, kVK_DownArrow)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: OSType(0x4452_5754), id: UInt32(n)), GetApplicationEventTarget(), 0, &ref)
        }
    }

    @MainActor static func monitors() {
        let esc: (NSEvent) -> Void = { ev in
            Task { @MainActor in
                let e = Engine.shared
                if ev.keyCode == UInt16(kVK_Escape), e.escStops, e.isActive { e.stop() }
            }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: esc)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { esc($0); return $0 }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in Engine.shared.appSwitched(to: pid) }
        }
    }
}

// MARK: - Brand

extension Color {
    static let ink = Color(red: 0.18, green: 0.31, blue: 0.84)
    static let inkDeep = Color(red: 0.07, green: 0.10, blue: 0.36)
    static let drop = Color(red: 0.91, green: 0.20, blue: 0.29)
}

struct DropShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height, cx = r.midX
        p.move(to: CGPoint(x: cx, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.maxY - w / 2), control1: CGPoint(x: cx + w * 0.1, y: r.minY + h * 0.25), control2: CGPoint(x: r.maxX, y: r.minY + h * 0.4))
        p.addArc(center: CGPoint(x: cx, y: r.maxY - w / 2), radius: w / 2, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        p.addCurve(to: CGPoint(x: cx, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + h * 0.4), control2: CGPoint(x: cx - w * 0.1, y: r.minY + h * 0.25))
        return p
    }
}

struct InkButton: ButtonStyle {
    var tint: Color = .ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22).padding(.vertical, 11)
            .background(Capsule().fill(LinearGradient(colors: [tint.opacity(0.9), tint], startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().stroke(.white.opacity(0.18)))
            .shadow(color: tint.opacity(0.35), radius: configuration.isPressed ? 2 : 8, y: configuration.isPressed ? 1 : 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct Card<Content: View>: View {
    let title: String; let symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title.uppercased(), systemImage: symbol).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}

struct StatusPill: View {
    @ObservedObject var e = Engine.shared
    var body: some View {
        let (label, color): (String, Color) = switch e.state {
        case .countdown: ("Starting in \(e.countdownLeft)", .orange)
        case .typing: ("Typing", .ink)
        case .paused: (e.autoPaused ? "Paused · switched apps" : "Paused", .drop)
        case .done: ("Done", .green)
        case .idle: ("Ready", .secondary)
        }
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
                .opacity(e.state == .typing ? 1 : 0.9)
            Text(label).font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Main window

struct MainView: View {
    @ObservedObject var e = Engine.shared
    var body: some View {
        NavigationSplitView {
            LibraryView().navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            ScrollView {
                VStack(spacing: 16) {
                    HeaderView()
                    EditorCard()
                    HStack(alignment: .top, spacing: 16) { PaceCard(); OutputCard() }
                    if e.isActive || e.state == .done { ProgressCard() }
                    ActionBar()
                }
                .padding(22)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }
            .background(LinearGradient(colors: [Color.ink.opacity(0.06), .clear], startPoint: .top, endPoint: .center))
        }
        .frame(minWidth: 940, minHeight: 720)
        .navigationTitle("")
        .tint(.ink)
        .sheet(isPresented: $e.showTestRun) { TestRunSheet() }
    }
}

struct HeaderView: View {
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                (Text("Drip").foregroundColor(.primary) + Text("Writer").foregroundColor(.drop))
                    .font(.system(size: 30, weight: .heavy, design: .rounded)).tracking(-0.6)
                Text("Types your text into any app, one keystroke at a time.").foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill()
        }
    }
}

struct EditorCard: View {
    @ObservedObject var e = Engine.shared
    @State private var dropping = false
    var body: some View {
        Card(title: e.useClipboard ? "Clipboard" : "Manuscript", symbol: e.useClipboard ? "doc.on.clipboard" : "doc.text") {
            ZStack(alignment: .topLeading) {
                if e.useClipboard {
                    ScrollView { Text(e.sourceText.isEmpty ? "The clipboard is empty. Copy some text and it will appear here." : e.sourceText)
                        .font(.system(size: 13, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(8) }
                        .foregroundStyle(.secondary)
                } else {
                    TextEditor(text: e.$text)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                }
                if dropping {
                    RoundedRectangle(cornerRadius: 10).stroke(Color.ink, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .background(Color.ink.opacity(0.06)).overlay(Label("Drop a text file", systemImage: "arrow.down.doc").foregroundStyle(Color.ink))
                }
            }
            .frame(height: 230)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
            .onDrop(of: [.fileURL], isTargeted: $dropping) { items in
                items.first?.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in e.importFile(url) } } }
                return true
            }

            HStack(spacing: 8) {
                Toggle(isOn: e.$useClipboard) { Label("Use clipboard", systemImage: "doc.on.clipboard") }.toggleStyle(.button)
                Button { e.openFile() } label: { Label("Open file…", systemImage: "folder") }
                Button { if let s = NSPasteboard.general.string(forType: .string) { e.useClipboard = false; e.text = s } } label: { Label("Paste", systemImage: "doc.on.doc") }
                Button { e.saveSnippet() } label: { Label("Save snippet", systemImage: "star") }.disabled(e.useClipboard)
                Button(role: .destructive) { e.text = "" } label: { Label("Clear", systemImage: "trash") }.disabled(e.useClipboard)
                Spacer()
                let s = e.sourceText
                Text("\(s.count) chars · \(s.split(whereSeparator: \.isWhitespace).count) words · \(s.isEmpty ? 0 : s.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
    }
}

struct PaceCard: View {
    @ObservedObject var e = Engine.shared
    var body: some View {
        Card(title: "Pace", symbol: "speedometer") {
            Picker("", selection: e.$finishIn) { Text("Set speed").tag(false); Text("Finish in…").tag(true) }
                .pickerStyle(.segmented).labelsHidden()
            if e.finishIn {
                HStack {
                    Slider(value: e.$finishMinutes, in: 0.25...60, step: 0.25)
                    Text(Typing.clock(e.finishMinutes * 60)).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit().frame(width: 76, alignment: .trailing)
                }
                let n = e.sourceText.count
                Text(n > 0 ? "≈ \(Typing.speedLabel(Double(n) * e.rhythm.etaFactor / max(5, e.finishMinutes * 60))) for \(n) characters" : "Add some text to see the speed")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                    Slider(value: e.$speed, in: 0...1)
                    Image(systemName: "hare.fill").foregroundStyle(.secondary)
                    Text(Typing.speedLabel(e.sliderCPS)).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit().frame(width: 104, alignment: .trailing)
                }
                Text("About \(Typing.clock(Double(e.sourceText.count) / e.sliderCPS * e.rhythm.etaFactor)) for this text · ⌃⌥⌘↑ ↓ changes speed while typing")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Rhythm").font(.subheadline.weight(.medium))
            HStack(spacing: 6) {
                ForEach(Rhythm.allCases) { r in
                    Button { e.rhythmRaw = r.rawValue } label: {
                        VStack(spacing: 4) { Image(systemName: r.symbol).font(.system(size: 15)); Text(r.rawValue).font(.caption) }
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9).fill(e.rhythm == r ? Color.ink.opacity(0.15) : Color.primary.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(e.rhythm == r ? Color.ink : .clear, lineWidth: 1.5))
                            .foregroundStyle(e.rhythm == r ? Color.ink : .primary)
                    }.buttonStyle(.plain)
                }
            }
            Text(e.rhythm.blurb).font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Typos").font(.subheadline.weight(.medium))
                Slider(value: e.$typoPct, in: 0...15, step: 0.5)
                Text(e.typoPct == 0 ? "Off" : String(format: "%.1f%%", e.typoPct)).monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            Text("Hits a neighboring key, notices, backspaces and fixes it.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct OutputCard: View {
    @ObservedObject var e = Engine.shared
    var body: some View {
        Card(title: "Output", symbol: "keyboard") {
            Text("New lines are typed as").font(.subheadline.weight(.medium))
            Picker("", selection: e.$newlineRaw) {
                ForEach(NewlineMode.allCases) { m in Text("\(m.rawValue)  —  \(m.hint)").tag(m.rawValue) }
            }.labelsHidden()
            Toggle("Skip indentation after new lines", isOn: e.$stripIndent)
            Text("For code editors that auto-indent, so indents aren't doubled.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Clean up before typing").font(.subheadline.weight(.medium))
            Toggle("Straighten smart quotes and dashes", isOn: e.$cleanQuotes)
            Toggle("Tabs to 4 spaces", isOn: e.$cleanTabs)
            Toggle("Trim trailing spaces", isOn: e.$cleanTrailing)
            Divider()
            HStack {
                Text("Countdown").font(.subheadline.weight(.medium))
                Spacer()
                Stepper("\(e.countdown) s", value: e.$countdown, in: 0...15).monospacedDigit()
            }
            HStack {
                Text("Key sound").font(.subheadline.weight(.medium))
                Spacer()
                Picker("", selection: e.$sound) { ForEach(["Off", "Tink", "Pop", "Morse", "Bottle", "Frog"], id: \.self) { Text($0) } }.labelsHidden().frame(width: 110)
            }
        }
        .frame(width: 330)
    }
}

struct ProgressCard: View {
    @ObservedObject var e = Engine.shared
    var body: some View {
        Card(title: "Progress", symbol: "chart.bar.fill") {
            ProgressView(value: e.progress).tint(.drop)
            HStack(spacing: 22) {
                stat("\(Int(e.progress * 100))%", "done")
                stat("\(e.pos)/\(e.total)", "keys")
                stat(Typing.clock(e.etaSeconds), "left")
                stat(Typing.speedLabel(e.cps), "speed")
                stat("\(e.typosFixed)", "typos fixed")
                Spacer()
            }
        }
    }
    func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(l).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ActionBar: View {
    @ObservedObject var e = Engine.shared
    var body: some View {
        HStack(spacing: 12) {
            Button {
                e.toggle()
            } label: {
                Label(e.state == .typing ? "Pause" : e.state == .paused ? "Resume" : e.state == .countdown ? "Cancel" : "Start typing",
                      systemImage: e.state == .typing ? "pause.fill" : e.state == .countdown ? "xmark" : "play.fill")
            }
            .buttonStyle(InkButton(tint: e.state == .typing ? .drop : .ink))
            .keyboardShortcut(.return, modifiers: .command)

            Button { e.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .controlSize(.large).disabled(!e.isActive)
            Button { e.showTestRun = true } label: { Label("Try it here", systemImage: "eye") }
                .controlSize(.large).disabled(e.isActive)
            Spacer()
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                GridRow { Kbd("⌃⌥⌘D"); Text("start / pause") }
                GridRow { Kbd("⌃⌥⌘V"); Text("type clipboard at cursor") }
                GridRow { Kbd("esc"); Text("stop anytime") }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        Text(e.countdown > 0
             ? "Press Start, then click into the app you want to type into. Typing begins after \(e.countdown) seconds."
             : "Typing starts immediately in the app that's in front.")
            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Kbd: View {
    let k: String
    init(_ k: String) { self.k = k }
    var body: some View {
        Text(k).font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
    }
}

// MARK: - Library sidebar

struct LibraryView: View {
    @ObservedObject var e = Engine.shared
    var body: some View {
        List {
            Section {
                ForEach(e.snippets) { s in row(s, symbol: "star.fill", tint: .orange)
                    .contextMenu { Button("Delete", role: .destructive) { e.snippets.removeAll { $0.id == s.id } } }
                }
                if e.snippets.isEmpty { Text("Save text you type often").font(.caption).foregroundStyle(.secondary) }
            } header: {
                HStack { Text("Snippets"); Spacer(); Button { e.saveSnippet() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("Save the manuscript as a snippet") }
            }
            Section("Recent") {
                ForEach(e.history) { s in row(s, symbol: "clock", tint: .secondary)
                    .contextMenu {
                        Button("Save as snippet") { if !e.snippets.contains(where: { $0.text == s.text }) { e.snippets.insert(s, at: 0) } }
                        Button("Remove", role: .destructive) { e.history.removeAll { $0.id == s.id } }
                    }
                }
                if e.history.isEmpty { Text("Things you type show up here").font(.caption).foregroundStyle(.secondary) }
            }
            Section("Lifetime") {
                LabeledContent("Keys typed", value: e.lifetimeChars.formatted())
                LabeledContent("Runs", value: e.lifetimeRuns.formatted())
                LabeledContent("Typos faked", value: e.lifetimeTypos.formatted())
            }.font(.caption)
        }
        .listStyle(.sidebar)
    }

    func row(_ s: Snippet, symbol: String, tint: Color) -> some View {
        Button { e.load(s) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint).font(.caption).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).lineLimit(1)
                    Text("\(s.text.count) chars · \(s.date.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - Try-it sheet (types into a box inside the app)

struct TestRunSheet: View {
    @ObservedObject var e = Engine.shared
    @State private var scratch = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Try it here").font(.title2.bold()); Spacer(); StatusPill() }
            Text("This is a real run with your current settings, typed into the box below.").foregroundStyle(.secondary)
            TextEditor(text: $scratch).font(.system(size: 14, design: .monospaced)).focused($focused)
                .frame(width: 620, height: 300)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            ProgressView(value: e.progress).tint(.drop)
            HStack {
                Button(e.state == .typing ? "Pause" : "Resume") { e.toggle() }.disabled(!(e.state == .typing || e.state == .paused))
                Button("Restart") { scratch = ""; focused = true; e.start(hide: false, countdownOverride: 0) }
                Spacer()
                Button("Close") { e.stop(); e.showTestRun = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .onAppear {
            focused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { e.start(hide: false, countdownOverride: 0) }
        }
    }
}

// MARK: - Floating HUD

@MainActor
enum HUD {
    static var panel: NSPanel?
    static var hideWork: DispatchWorkItem?

    static func show() {
        hideWork?.cancel()
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 92), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .floating
            p.isFloatingPanel = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView: HUDView())
            if let f = NSScreen.main?.visibleFrame { p.setFrameOrigin(NSPoint(x: f.maxX - 340, y: f.maxY - 112)) }
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    static func hideSoon() {
        hideWork?.cancel()
        let w = DispatchWorkItem { panel?.orderOut(nil) }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: w)
    }
}

struct HUDView: View {
    @ObservedObject var e = Engine.shared
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 5)
                Circle().trim(from: 0, to: e.progress).stroke(Color.drop, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: e.progress)
                if e.state == .countdown {
                    Text("\(e.countdownLeft)").font(.system(size: 20, weight: .bold, design: .rounded))
                } else {
                    DropShape().fill(LinearGradient(colors: [Color(red: 1, green: 0.44, blue: 0.5), .drop], startPoint: .top, endPoint: .bottom)).frame(width: 16, height: 22)
                }
            }
            .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.state == .countdown ? "Click where you want to type…" : e.state == .paused ? (e.autoPaused ? "Paused · come back to resume" : "Paused") : e.state == .done ? "Done" : "Typing \(Int(e.progress * 100))%")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(Typing.speedLabel(e.cps)) · \(Typing.clock(e.etaSeconds)) left · esc to stop")
                    .font(.system(size: 11)).monospacedDigit().opacity(0.7)
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                hudButton(e.state == .typing ? "pause.fill" : "play.fill") { e.toggle() }
                hudButton("stop.fill") { e.stop() }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: 320, height: 92)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(colors: [Color.ink, Color.inkDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.15)))
        )
    }
    func hudButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.15)))
        }.buttonStyle(.plain)
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var e = Engine.shared
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var trusted = Accessibility.trusted
    @State private var cliPath = CLI.installedPath
    var body: some View {
        Form {
            Section("While typing") {
                Toggle("Show floating progress panel", isOn: e.$showHUD)
                Toggle("Pause when I switch to another app, resume when I come back", isOn: e.$pauseOnSwitch)
                Toggle("Esc stops typing", isOn: e.$escStops)
                Toggle("Bell on new lines", isOn: e.$bell)
            }
            Section("System") {
                Toggle("Open at login (menu bar only)", isOn: $loginItem).onChange(of: loginItem) { _, on in
                    do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch { loginItem = !on }
                }
                LabeledContent("Accessibility") {
                    HStack { Text(trusted ? "Allowed" : "Not allowed").foregroundStyle(trusted ? .green : .red)
                        Button("Open Settings") { Accessibility.openSettings() } }
                }
                LabeledContent("Terminal command") {
                    Text(cliPath ?? "Not installed — run the installer").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
            Section("Hotkeys") {
                LabeledContent("Start / pause", value: "⌃⌥⌘D")
                LabeledContent("Type clipboard at cursor", value: "⌃⌥⌘V")
                LabeledContent("Stop", value: "⌃⌥⌘.  or  esc")
                LabeledContent("Faster / slower", value: "⌃⌥⌘↑  ⌃⌥⌘↓")
            }
            Section {
                Button("Reset lifetime stats") { e.lifetimeChars = 0; e.lifetimeRuns = 0; e.lifetimeTypos = 0 }
                Text("DripWriter \(appVersion)").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .onAppear { trusted = Accessibility.trusted }
    }
}

// MARK: - Menu bar

struct MenuView: View {
    @ObservedObject var e = Engine.shared
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(e.isActive ? "\(e.state.rawValue) · \(Int(e.progress * 100))% · \(Typing.speedLabel(e.cps))" : "DripWriter · \(e.state.rawValue)")
        Divider()
        Button(e.state == .typing ? "Pause" : e.state == .paused ? "Resume" : "Start typing") { e.toggle() }.keyboardShortcut("d", modifiers: [.control, .option, .command])
        Button("Type clipboard now") { e.start(fromClipboard: true) }.keyboardShortcut("v", modifiers: [.control, .option, .command])
        Button("Stop") { e.stop() }.disabled(!e.isActive)
        if !e.snippets.isEmpty {
            Divider()
            Menu("Type a snippet") {
                ForEach(e.snippets) { s in Button(s.name) { e.load(s); e.start() } }
            }
        }
        Divider()
        Button("Open DripWriter") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        SettingsLink { Text("Settings…") }
        Button("Quit DripWriter") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// The menu bar label exists from launch, so it also makes sure the main window opens even if macOS restored it closed.
struct MenuBarLabel: View {
    @ObservedObject var e = Engine.shared
    @Environment(\.openWindow) var openWindow
    @State private var opened = false
    var body: some View {
        Group {
            if e.state == .typing { Text("\(Int(e.progress * 100))%") } else { Image(systemName: e.state == .paused ? "pause.circle" : "drop") }
        }
        .onAppear {
            guard !opened else { return }
            opened = true
            if !NSApp.windows.contains(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) { openWindow(id: "main") }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        HotKeys.register()
        MainActor.assumeIsolated { HotKeys.monitors() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

struct DripWriterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var e = Engine.shared
    var body: some Scene {
        Window("DripWriter", id: "main") { MainView() }
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(after: .newItem) {
                    Button("Open Text File…") { e.openFile() }.keyboardShortcut("o")
                    Button("Save as Snippet") { e.saveSnippet() }.keyboardShortcut("s")
                }
            }
        Settings { SettingsView() }
        MenuBarExtra {
            MenuView()
        } label: {
            MenuBarLabel()
        }
    }
}

// MARK: - CLI

enum CLI {
    static let links = ["/usr/local/bin/dripwriter", "/opt/homebrew/bin/dripwriter", NSHomeDirectory() + "/.local/bin/dripwriter"]
    static var installedPath: String? { links.first { FileManager.default.fileExists(atPath: $0) } }

    static var shouldRun: Bool {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") && !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
        if !args.isEmpty { return true }
        var st = stat()
        return fstat(STDIN_FILENO, &st) == 0 && ((st.st_mode & S_IFMT) == S_IFIFO || (st.st_mode & S_IFMT) == S_IFREG)
    }

    static let tty = isatty(STDERR_FILENO) == 1
    static func c(_ code: String, _ s: String) -> String { tty ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    static func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

    static let help = """
    \(c("1;34", "Drip"))\(c("1;31", "Writer")) \(appVersion) — types text into whatever app is in front, keystroke by keystroke.

    \(c("1", "USAGE"))
      dripwriter "some text"            type the text
      dripwriter -f notes.txt           type a file
      pbpaste | dripwriter              type from a pipe
      dripwriter --clipboard            type the clipboard
      dripwriter --open                 open the app

    \(c("1", "OPTIONS"))
      -w, --wpm N         words per minute (default 60)
      -c, --cps N         keys per second instead of wpm
      -t, --time DUR      finish in a set time, e.g. 90s, 5m, 1h
      -r, --rhythm NAME   human | steady | nervous | burst | drip   (default human)
      -T, --typos PCT     chance of a typo per letter, fixed automatically (default 0)
      -d, --delay SEC     countdown before typing starts (default 3)
          --shift-enter   type new lines as Shift+Return (Slack, Discord, ChatGPT)
          --opt-enter     type new lines as Option+Return
          --no-indent     skip indentation after new lines (auto-indenting editors)
          --straighten    turn smart quotes and dashes into plain ones
          --dry           print what would be typed and how long it takes, type nothing
      -q, --quiet         no progress bar
      -h, --help          show this help
      -v, --version       show the version

    Press Ctrl-C to stop. The terminal app needs Accessibility access the first time.
    """

    static func run() -> Int32 {
        var args = Array(CommandLine.arguments.dropFirst())
        var text: String?
        var cps = 5.0, rhythm = Rhythm.human, typos = 0.0, delay = 3.0, newline = NewlineMode.ret
        var noIndent = false, straighten = false, dry = false, quiet = false, finishSecs: Double?
        var words: [String] = []

        func value(_ flag: String) -> String? {
            guard !args.isEmpty else { err(c("31", "Missing value for \(flag)")); exit(2) }
            return args.removeFirst()
        }
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "-h", "--help": print(help); return 0
            case "-v", "--version": print("dripwriter \(appVersion)"); return 0
            case "--open": NSWorkspace.shared.open(Bundle.main.bundleURL); return 0
            case "-f", "--file":
                let p = value(a)!
                guard let s = try? String(contentsOfFile: (p as NSString).expandingTildeInPath, encoding: .utf8) else { err(c("31", "Can't read \(p)")); return 1 }
                text = s
            case "--clipboard": text = NSPasteboard.general.string(forType: .string) ?? ""
            case "-w", "--wpm": cps = (Double(value(a)!) ?? 60) / 12
            case "-c", "--cps": cps = Double(value(a)!) ?? 5
            case "-t", "--time": finishSecs = parseDuration(value(a)!)
            case "-r", "--rhythm":
                let n = value(a)!.lowercased()
                rhythm = Rhythm.allCases.first { $0.rawValue.lowercased() == n } ?? (n == "hacker" ? .hacker : .human)
            case "-T", "--typos": typos = Double(value(a)!) ?? 0
            case "-d", "--delay": delay = Double(value(a)!) ?? 3
            case "--shift-enter": newline = .shiftRet
            case "--opt-enter": newline = .optRet
            case "--no-indent": noIndent = true
            case "--straighten": straighten = true
            case "--dry": dry = true
            case "-q", "--quiet": quiet = true
            default:
                if a.hasPrefix("-") && a.count > 1 { err(c("31", "Unknown option \(a)") + "\nRun dripwriter --help"); return 2 }
                words.append(a)
            }
        }
        if text == nil && !words.isEmpty { text = words.joined(separator: " ") }
        if text == nil, isatty(STDIN_FILENO) == 0 { text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) }
        guard var t = text, !t.isEmpty else { print(help); return 1 }
        t = Typing.clean(t, quotes: straighten, tabs: false, trailing: false)
        let chars = Array(t)
        if let f = finishSecs { cps = Double(chars.count) * rhythm.etaFactor / max(1, f) }
        cps = max(0.2, min(cps, 600))
        let eta = Double(chars.count) / cps * rhythm.etaFactor

        if dry {
            print(t)
            err(c("2", "\(chars.count) keys · \(Typing.speedLabel(cps)) · \(rhythm.rawValue.lowercased()) · about \(Typing.clock(eta))"))
            return 0
        }
        if !AXIsProcessTrusted() {
            err(c("33", "⚠ macOS hasn't allowed this terminal to press keys yet."))
            err("  Open System Settings → Privacy & Security → Accessibility and switch on your terminal app,")
            err("  then run the command again.")
            Accessibility.openSettings()
            return 1
        }

        if !quiet { err(c("1;34", "▸ ") + "Typing \(chars.count) keys at \(Typing.speedLabel(cps)), about \(Typing.clock(eta)). Click into the target app.") }
        var left = delay
        while left > 0 {
            if !quiet { FileHandle.standardError.write("\r  starting in \(Int(left.rounded(.up)))… ".data(using: .utf8)!) }
            Thread.sleep(forTimeInterval: min(1, left)); left -= 1
        }
        signal(SIGINT) { _ in
            FileHandle.standardError.write("\n\u{1B}[33m■ Stopped.\u{1B}[0m\n".data(using: .utf8)!); exit(130)
        }

        let start = Date()
        var atLineStart = false, fixed = 0, lastDraw = Date.distantPast
        for (i, ch) in chars.enumerated() {
            if noIndent && atLineStart && (ch == " " || ch == "\t") { continue }
            atLineStart = ch == "\n"
            if Keys.emit(ch, newline: newline, typoPct: typos, wait: { Thread.sleep(forTimeInterval: $0) }, base: 1 / cps) { fixed += 1 }
            Thread.sleep(forTimeInterval: Typing.delay(after: ch, pos: i, cps: cps, rhythm: rhythm))
            if !quiet && (Date().timeIntervalSince(lastDraw) > 0.1 || i == chars.count - 1) {
                lastDraw = Date()
                let p = Double(i + 1) / Double(chars.count), w = 28, n = Int(p * Double(w))
                let bar = c("31", String(repeating: "█", count: n)) + c("2", String(repeating: "░", count: w - n))
                let remain = Double(chars.count - i - 1) / cps * rhythm.etaFactor
                FileHandle.standardError.write("\r  \(bar) \(String(format: "%3d", Int(p * 100)))%  \(Typing.clock(remain)) left   ".data(using: .utf8)!)
            }
        }
        if !quiet {
            err("\n" + c("32", "✓ ") + "Typed \(chars.count) keys in \(Typing.clock(Date().timeIntervalSince(start)))" + (fixed > 0 ? ", fixed \(fixed) typos" : "") + ".")
        }
        return 0
    }

    static func parseDuration(_ s: String) -> Double {
        let n = Double(s.filter { $0.isNumber || $0 == "." }) ?? 60
        switch s.last { case "h": return n * 3600; case "m": return n * 60; default: return n }
    }
}

// MARK: - Entry

@main
enum Main {
    static func main() {
        if CLI.shouldRun { exit(CLI.run()) }
        // always open the main window at launch instead of restoring a closed one
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        DripWriterApp.main()
    }
}
