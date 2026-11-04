// iTherm: a dead simple terminal emulator with tabs and split panes, rendered entirely on the CPU.
// Frames are rasterized by CoreGraphics + CoreText into plain memory bitmaps (CGBitmapContexts
// over IOSurfaces, memory shared with the window server, so nothing is copied) that are kept
// between frames: only rows that changed are redrawn, and scrolled output is moved up with a
// memmove. No Metal, no OpenGL, no Core Animation drawing: the finished bitmap is simply handed
// to macOS as the window's pixels.
//
// Made for benchmarking GPU work: it never submits GPU work of its own, and the bottom bar shows CPU/GPU
// temperature and load, ANE load, memory and its bandwidth, and network. Settings can ramp the fans up
// before the chip throttles.
//
// Build: swiftc -O itherm.swift -o build/itherm    (or ./bundle.sh for build/iTherm.app)
// Keys:  ⌘T new tab   ⌘W close tab   ⌘1-9 / ⌘⇧[ ⌘⇧] switch tabs   ⌘C copy   ⌘V paste   ⌘A select all
//        ⌘D split beside   ⌘⇧D split below   ⌃⌘S show/hide machines   ⌘, settings   ⌘Q quit
// Mouse: drag to select (double-click: word, triple-click: line), wheel scrolls back, click a pane to focus
//        it, right-click one to split it, drag the divider between two to resize them. Click a tab to select it (its × closes it, dragging reorders),
//        right-click one to move it to its own window or close it or the others. Programs that ask for the
//        mouse (vim, htop, tmux) get it; hold ⇧ or ⌥ to select anyway. Drop files to paste their paths.
//        Hover the CPU, GPU or MEM bar for the processes using the most of it. Click the network icon at the left
//        for the ports your programs are listening on, each with a button to kill its process, and the disk icon
//        beside it for a chart of what fills the disk.
// Machines: the sidebar lists this Mac and the ssh machines you have tabs on, each with its tabs under it; new tabs and
//        splits open on the selected one. Its + connects: a new user@host:port (saved unless unticked), a saved or recent
//        connection, or a host from ~/.ssh/config. Dots: a ring while printing, green finished out of
//        sight, yellow rang the bell (or sent a notification) out of sight. Quitting saves the windows, tabs and folders.
import AppKit
import IOKit
import UserNotifications

let defFG: UInt32 = 0x100_0000, defBG: UInt32 = 0x200_0000  // "default color" markers
let indexed: UInt32 = 0x400_0000  // | a 256-color index; 0...15 are looked up in the theme when drawn

func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {  // blend two RGB colors
    [16, 8, 0].reduce(0) { acc, sh in
        acc | UInt32((Double(a >> sh & 255) * (1 - t) + Double(b >> sh & 255) * t).rounded()) << sh
    }
}

func cgColor(_ rgb: UInt32) -> CGColor {
    CGColor(red: CGFloat(rgb >> 16 & 255) / 255, green: CGFloat(rgb >> 8 & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
}

struct Theme {
    let name: String, fg: UInt32, bg: UInt32, ansi: [UInt32]  // ansi: the 16 base colors
    var bar: UInt32 { mix(bg, fg, 0.06) }  // inactive tab
    var tab: UInt32 { mix(bg, fg, 0.16) }  // active tab
    var dim: UInt32 { mix(bg, fg, 0.55) }  // inactive tab text
    var sel: UInt32 { mix(bg, ansi[4], 0.4) }  // selection
}

let solarized: [UInt32] = [0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
                           0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3]
let themes = [  // new themes go at the end: the setting is stored as an index
    Theme(name: "Dark", fg: 0xd0d0d0, bg: 0x1c1c1c, ansi: [
        0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5,
        0x666666, 0xf14c4c, 0x23d18b, 0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xffffff]),
    Theme(name: "Light", fg: 0x202020, bg: 0xfafafa, ansi: [
        0x000000, 0xcd3131, 0x00bc00, 0x949800, 0x0451a5, 0xbc05bc, 0x0598bc, 0x555555,
        0x666666, 0xcd3131, 0x14ce14, 0xb5ba00, 0x0451a5, 0xbc05bc, 0x0598bc, 0xa5a5a5]),
    Theme(name: "Solarized Dark", fg: 0x839496, bg: 0x002b36, ansi: solarized),
    Theme(name: "Solarized Light", fg: 0x657b83, bg: 0xfdf6e3, ansi: solarized),
    Theme(name: "Dracula", fg: 0xf8f8f2, bg: 0x282a36, ansi: [
        0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
        0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff]),
    Theme(name: "Nord", fg: 0xd8dee9, bg: 0x2e3440, ansi: [
        0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
        0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4]),
    Theme(name: "Gruvbox Dark", fg: 0xebdbb2, bg: 0x282828, ansi: [
        0x282828, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984,
        0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2]),
    Theme(name: "Gruvbox Light", fg: 0x3c3836, bg: 0xfbf1c7, ansi: [
        0xfbf1c7, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0x7c6f64,
        0x928374, 0x9d0006, 0x79740e, 0xb57614, 0x076678, 0x8f3f71, 0x427b58, 0x3c3836]),
    Theme(name: "One Dark", fg: 0xabb2bf, bg: 0x282c34, ansi: [
        0x282c34, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xabb2bf,
        0x5c6370, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xffffff]),
    Theme(name: "Tokyo Night", fg: 0xc0caf5, bg: 0x1a1b26, ansi: [
        0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
        0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5]),
    Theme(name: "Catppuccin Mocha", fg: 0xcdd6f4, bg: 0x1e1e2e, ansi: [
        0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de,
        0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xa6adc8]),
    Theme(name: "Monokai", fg: 0xf8f8f2, bg: 0x272822, ansi: [
        0x272822, 0xf92672, 0xa6e22e, 0xf4bf75, 0x66d9ef, 0xae81ff, 0xa1efe4, 0xf8f8f2,
        0x75715e, 0xf92672, 0xa6e22e, 0xf4bf75, 0x66d9ef, 0xae81ff, 0xa1efe4, 0xf9f8f5]),
]

enum Prefs {  // persisted in UserDefaults
    static var font: String { UserDefaults.standard.string(forKey: "font") ?? "" }  // "" = system monospaced
    static var fontSize: CGFloat { let s = UserDefaults.standard.double(forKey: "fontSize"); return s > 0 ? s : 13 }
    static var theme: Int { min(max(UserDefaults.standard.integer(forKey: "theme"), 0), themes.count - 1) }
    static var boldBright: Bool { UserDefaults.standard.bool(forKey: "boldBright") }  // draw bold in the bright colors, as Terminal.app does
    static var optionMeta: Bool { UserDefaults.standard.bool(forKey: "optionMeta") }  // ⌥ sends Esc + the key, as ⌥b / ⌥f want
    static var fanControl: Bool { UserDefaults.standard.bool(forKey: "fanControl") }
    static var fanStart: Int { let v = UserDefaults.standard.integer(forKey: "fanStart"); return v > 0 ? v : 70 }  // °C
    static var fanSpeed: Int { let v = UserDefaults.standard.integer(forKey: "fanSpeed"); return v > 0 ? v : 100 }  // %
    static var sidebar: Bool { !UserDefaults.standard.bool(forKey: "hideSidebar") }
    // ssh connections as [user@]host[:port]: the ones kept in the sidebar's + menu, and the last 8 connected to, newest first
    static var saved: [String] { UserDefaults.standard.stringArray(forKey: "saved") ?? [] }
    static var recents: [String] { UserDefaults.standard.stringArray(forKey: "recents") ?? [] }
}

/// The hosts named in ~/.ssh/config, not its patterns.
func sshHosts() -> [String] {
    let config = (try? String(contentsOfFile: NSHomeDirectory() + "/.ssh/config", encoding: .utf8)) ?? ""
    return config.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
        let w = line.split { $0 == " " || $0 == "\t" || $0 == "=" }.map(String.init)
        return w.first?.lowercased() == "host" ? w.dropFirst().filter { !$0.contains { "*?!".contains($0) } } : []
    }
}

/// The branch checked out in dir's repository (a short commit when detached), from its HEAD; nil outside one.
func gitBranch(_ dir: String) -> String? {
    var d = URL(fileURLWithPath: dir)
    while true {
        let git = d.appendingPathComponent(".git")
        var head = git.appendingPathComponent("HEAD")
        if let s = try? String(contentsOf: git, encoding: .utf8), s.hasPrefix("gitdir: ") {  // a worktree or submodule: .git names the real one
            head = URL(fileURLWithPath: s.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: d).appendingPathComponent("HEAD")
        }
        if let h = try? String(contentsOf: head, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            return h.hasPrefix("ref: refs/heads/") ? String(h.dropFirst(16)) : String(h.prefix(7))
        }
        if d.path == "/" { return nil }
        d.deleteLastPathComponent()
    }
}

/// What a tab's dot says, least to most urgent: printing; went quiet while out of sight; rang for you while out of sight.
enum Mark: Int, Comparable {
    case idle, working, done, needs
    static func < (a: Mark, b: Mark) -> Bool { a.rawValue < b.rawValue }
}

// xterm 256-color entries 16...255: a 6x6x6 color cube, then 24 grays.
let cube: [UInt32] = {
    let lv: [UInt32] = [0, 95, 135, 175, 215, 255]
    var p: [UInt32] = []
    for r in lv { for g in lv { for b in lv { p.append(r << 16 | g << 8 | b) } } }
    for i in 0..<24 { let v = UInt32(8 + i * 10); p.append(v << 16 | v << 8 | v) }
    return p
}()

// DEC special graphics (ESC ( 0), used by old ncurses for line drawing: maps 0x60...0x7e.
let acs = "◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·".unicodeScalars.map { $0.value }

struct Cell: Equatable {
    var ch: UInt32 = 32
    var fg = defFG, bg = defBG
    var bold = false, faint = false, italic = false, strike = false, inverse = false
    var ul = 0  // the underline: 0 none, 1 line, 2 double, 3 curly, 4 dotted, 5 dashed
    var cursor = 0  // the cell the cursor sits on: 1 an underline, 2 a bar (a block cursor is drawn as inverse)
    var selected = false  // set only on the view's copies of rows, never in the terminal's grid
}

// MARK: - Terminal: pty + VT/xterm parser + screen grid

final class Term {
    var cols: Int, rows: Int
    var g: [[Cell]], other: [[Cell]]  // active screen and the inactive one (main/alt)
    var history: [[Cell]] = []
    var alt = false, scrollOff = 0
    var cx = 0, cy = 0, wrap = false, top = 0, bot: Int
    var pen = Cell(), saved = (0, 0, Cell())
    var cursorOn = true, appCursor = false, bracketed = false, graphics = false
    var mouseMode = 0, sgrMouse = false  // mouseMode: 0 off, 9 press only, 1000 press/release, 1002 +drag, 1003 +motion
    var cursorStyle = 0  // DECSCUSR: 0/1/2 block, 3/4 underline, 5/6 bar (blinking is not rendered)
    var focusReport = false  // 1004: the program wants to hear when our window gains or loses the keyboard
    var sync = false  // 2026: hold drawing until the end of the frame the program is building
    var pal: [UInt32?] = Array(repeating: nil, count: 16)  // OSC 4: the theme's 16 colors, with the ones this terminal overrode
    var dfg: UInt32?, dbg: UInt32?  // OSC 10/11: this terminal's default foreground and background
    var title: String, titled = false  // titled: a program set it (OSC 0/2)
    var onChange: (Term) -> Void = { _ in }, onExit: (Term) -> Void = { _ in }
    var onBell: (Term, String?) -> Void = { _, _ in }  // BEL, or a notification's text (OSC 9, OSC 777)
    var mark = Mark.idle  // set while out of sight (working, then done; or needs), cleared once seen
    private(set) var active = 0.0  // when it last printed on its own
    private var poked = CACurrentMediaTime() + 2  // when we last sent it input or resized it; startup output (prompt, banner) isn't work either
    var busy: Bool { CACurrentMediaTime() - active < 3 }
    var dot: Mark { max(mark, busy ? .working : .idle) }

    private enum State { case ground, esc, csi, osc, str, charset(Bool) }
    private var state = State.ground
    private var params: [Int] = [], num = -1, priv: UInt8 = 0, inter: UInt8 = 0
    private var subs: [Bool] = [], subLast = false  // which parameter followed a ':' (SGR sub-parameters, as in 4:3)
    private var syncHeld = 0  // chunks 2026 has held drawing for, in case a program never clears the mode
    private var osc: [UInt8] = []
    private var u8need = 0, u8cp: UInt32 = 0, lastCh: UInt32 = 32

    private let fd: Int32, pid: pid_t
    private var src: DispatchSourceRead!
    private var out: [UInt8] = [], outSrc: DispatchSourceWrite?  // input the program hasn't taken yet
    private var buf = [UInt8](repeating: 0, count: 1 << 16)

    /// A login shell in cwd (nil: home), or with ssh set ([user@]host[:port], or a Host from ~/.ssh/config) a shell there.
    /// The ssh connections to one machine share the first one's (ControlMaster), so later tabs open at once, without logging in again.
    init(cols: Int, rows: Int, cwd: String? = nil, ssh: String = "") {
        self.cols = cols; self.rows = rows; bot = rows - 1
        g = Array(repeating: Array(repeating: Cell(), count: cols), count: rows); other = g
        let shell = String(cString: getenv("SHELL") ?? getpwuid(getuid())?.pointee.pw_shell ?? strdup("/bin/zsh"))
        title = ssh.isEmpty ? (shell as NSString).lastPathComponent : ssh
        // ssh failing to connect, or losing the connection, exits 255: its message stays up until Return
        let args = ssh.isEmpty ? ["-" + title]  // "-zsh" = login shell
            : ["sh", "-c", "ssh -o ControlMaster=auto -o ControlPath='~/.ssh/itherm-%C' -o ControlPersist=60 \"$@\"; "
                + "[ $? = 255 ] && printf '\\r\\n[connection closed: press Return] ' && read _", "sh"]
                + (ssh.contains(":") ? ["ssh://" + ssh] : ssh.split(separator: " ").map(String.init))  // ssh takes a port only in its URI form
        // everything the child needs is prepared before fork; it only chdirs and execs
        let path = strdup(ssh.isEmpty ? shell : "/bin/sh"), argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        let dir = strdup(cwd ?? ProcessInfo.processInfo.environment["HOME"] ?? "/")
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let p = forkpty(&master, nil, nil, &ws)
        if p == 0 {
            if chdir(dir) != 0, let home = getenv("HOME") { chdir(home) }  // the directory may be gone
            argv.withUnsafeBufferPointer { _ = execv(path, $0.baseAddress) }
            _exit(127)
        }
        precondition(p > 0, "forkpty failed")
        free(path); argv.forEach { free($0) }; free(dir)
        fd = master; pid = p
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [unowned self] in readPty() }
        src.setCancelHandler { [fd] in Darwin.close(fd) }
        src.resume()
        let reaper = DispatchSource.makeProcessSource(identifier: p, eventMask: .exit, queue: .main)
        reaper.setEventHandler { waitpid(p, nil, 0); reaper.cancel() }
        reaper.resume()
    }

    /// The shell's current directory, for new tabs to start in.
    var cwd: String? {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0 else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    func hangup() { outSrc?.cancel(); src.cancel(); kill(pid, SIGHUP) }

    func send(_ s: String) { send(Array(s.utf8)) }

    func send(_ b: [UInt8]) { poked = CACurrentMediaTime(); out += b; flush() }

    private func reply(_ s: String) { out += Array(s.utf8); flush() }  // an answer to a query: not input, it doesn't poke

    /// Writes what the pty takes now and queues the rest until it drains, so the main thread keeps reading
    /// the program's output (blocking here deadlocks with a program that is itself blocked writing to us).
    private func flush() {
        while !out.isEmpty {
            let n = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { out.removeFirst(n) } else if n < 0 && errno == EINTR { continue } else if n < 0 && errno == EAGAIN { break } else { out = [] }
        }
        if out.isEmpty { outSrc?.cancel(); outSrc = nil } else if outSrc == nil {
            outSrc = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
            outSrc!.setEventHandler { [unowned self] in flush() }
            outSrc!.resume()
        }
    }

    func resize(_ c: Int, _ r: Int) {
        guard c != cols || r != rows else { return }
        poked = CACurrentMediaTime()
        let shift = max(0, cy - (r - 1))  // keep the cursor row on screen
        if !alt { history.append(contentsOf: g.prefix(shift)) }
        func remap(_ old: [[Cell]], _ sh: Int) -> [[Cell]] {
            (0..<r).map { y in
                var row = Array((y + sh < old.count ? old[y + sh] : []).prefix(c))
                row.append(contentsOf: repeatElement(Cell(), count: c - row.count))
                return row
            }
        }
        g = remap(g, shift); other = remap(other, 0)
        cols = c; rows = r; cy -= shift; cx = min(cx, c - 1); top = 0; bot = r - 1; wrap = false
        saved.0 = min(saved.0, c - 1); saved.1 = min(saved.1, r - 1)
        var ws = winsize(ws_row: UInt16(r), ws_col: UInt16(c), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, 0x8008_7467 /* TIOCSWINSZ */, &ws)
    }

    /// Line i of scrollback followed by the screen ("absolute" rows, used by selection).
    func absLine(_ i: Int) -> [Cell] {
        i < 0 ? [] : i < history.count ? history[i] : i - history.count < rows ? g[i - history.count] : []
    }

    /// Absolute row shown at view row y.
    func abs(_ y: Int) -> Int { history.count - scrollOff + y }

    /// Reports a mouse event (button code incl. modifier/motion bits) at cell x,y to the program.
    func sendMouse(_ b: Int, _ x: Int, _ y: Int, _ press: Bool) {
        if b & 32 != 0 && !out.isEmpty { return }  // drop motion while the program is behind
        if sgrMouse { send("\u{1b}[<\(b);\(x + 1);\(y + 1)\(press ? "M" : "m")"); return }
        let code = press ? b : b & ~3 | 3  // legacy encoding can't say which button was released
        send([0x1B, 0x5B, 0x4D, UInt8(32 + code), UInt8(min(33 + x, 255)), UInt8(min(33 + y, 255))])
    }

    private func readPty() {
        let n = read(fd, &buf, buf.count)
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
        if n <= 0 { onExit(self); return }
        if CACurrentMediaTime() - poked > 0.5 { active = CACurrentMediaTime() }  // on its own: not echoing input, nor redrawing after a resize or focus change
        for i in 0..<n { byte(buf[i]) }
        if frameEnd() { syncHeld = 0; onChange(self) }
    }

    /// Does this batch of output end a frame? Mode 2026 holds the draw until the program says the frame is whole, but a
    /// program that turns it on and never off must not freeze us (hence the cap).
    private func frameEnd() -> Bool {
        guard sync else { return true }
        syncHeld += 1
        return syncHeld > 8
    }

    private func byte(_ b: UInt8) {
        switch state {
        case .ground: ground(b)
        case .esc: escape(b)
        case .csi: csi(b)
        case .osc:
            if b == 7 || b == 0x1B { oscDone(); state = b == 7 ? .ground : .esc }  // BEL or ESC \ ends it
            else if osc.count < 1 << 14 { osc.append(b) }  // long enough for an OSC 52 clipboard set
        case .str: if b == 7 { state = .ground } else if b == 0x1B { state = .esc }  // DCS/APC/PM: ignored
        case .charset(let g0): if g0 { graphics = b == UInt8(ascii: "0") }; state = .ground
        }
    }

    private func ground(_ b: UInt8) {
        if u8need > 0 {
            if b & 0xC0 == 0x80 {
                u8cp = u8cp << 6 | UInt32(b & 0x3F); u8need -= 1
                if u8need == 0 { put(u8cp) }
                return
            }
            u8need = 0; put(0xFFFD)
        }
        switch b {
        case 0x1B: state = .esc
        case 0x0D: cx = 0; wrap = false
        case 0x0A, 0x0B, 0x0C: lineFeed(); wrap = false
        case 0x08: cx = max(0, cx - 1); wrap = false
        case 0x09: cx = min(cols - 1, (cx / 8 + 1) * 8)
        case 0x20..<0x7F: put(UInt32(b))
        case 0xC0..<0xE0: u8cp = UInt32(b & 0x1F); u8need = 1
        case 0xE0..<0xF0: u8cp = UInt32(b & 0x0F); u8need = 2
        case 0xF0..<0xF8: u8cp = UInt32(b & 0x07); u8need = 3
        case 0x80...: put(0xFFFD)
        case 0x07: onBell(self, nil)
        default: break  // other C0 controls
        }
    }

    private func escape(_ b: UInt8) {
        state = .ground
        switch Unicode.Scalar(b) {
        case "[": params.removeAll(); subs.removeAll(); subLast = false; num = -1; priv = 0; inter = 0; state = .csi
        case "]": osc.removeAll(); state = .osc
        case "P", "X", "^", "_": state = .str
        case "(": state = .charset(true)
        case ")", "*", "+": state = .charset(false)
        case "7": saveCursor()
        case "8": restoreCursor()
        case "D": lineFeed()
        case "E": cx = 0; lineFeed()
        case "M": if cy == top { scrollDown(top, 1) } else { cy = max(0, cy - 1) }
        case "c": reset()
        default: break
        }
    }

    private func csi(_ b: UInt8) {
        switch b {
        case 0x30...0x39: num = min(max(num, 0) * 10 + Int(b - 0x30), 99999)
        case 0x3B: params.append(num); subs.append(subLast); subLast = false; num = -1
        case 0x3A: params.append(max(num, 0)); subs.append(subLast); subLast = true; num = -1  // ':' opens a sub-parameter, an empty one is 0
        case 0x3C...0x3F: priv = b
        case 0x20...0x2F: inter = b
        case 0x40...0x7E: params.append(num); subs.append(subLast); state = .ground; dispatch(Unicode.Scalar(b))
        case 0x1B: state = .esc
        default: break
        }
    }

    private func arg(_ i: Int, _ def: Int = 1) -> Int {
        let v = i < params.count ? params[i] : -1
        return v > 0 ? v : def
    }

    private func dispatch(_ f: Unicode.Scalar) {
        if inter != 0 { return }
        if priv == UInt8(ascii: "?") {
            if f == "h" || f == "l" { for p in params { mode(p, f == "h") } }
            return
        }
        if priv != 0 { return }
        let n = arg(0)
        if f != "m" { wrap = false }
        switch f {
        case "A": cy = max(0, cy - n)
        case "B", "e": cy = min(rows - 1, cy + n)
        case "C", "a": cx = min(cols - 1, cx + n)
        case "D": cx = max(0, cx - n)
        case "E": cy = min(rows - 1, cy + n); cx = 0
        case "F": cy = max(0, cy - n); cx = 0
        case "G", "`": cx = min(cols - 1, n - 1)
        case "d": cy = min(rows - 1, n - 1)
        case "H", "f": cy = min(rows - 1, arg(0) - 1); cx = min(cols - 1, arg(1) - 1)
        case "J":
            switch arg(0, 0) {
            case 0: erase(cy, cx, cols); for y in cy + 1..<rows { erase(y, 0, cols) }
            case 1: for y in 0..<cy { erase(y, 0, cols) }; erase(cy, 0, cx + 1)
            default:
                for y in 0..<rows { erase(y, 0, cols) }
                if arg(0, 0) == 3 { history.removeAll(); scrollOff = 0 }
            }
        case "K":
            switch arg(0, 0) {
            case 0: erase(cy, cx, cols)
            case 1: erase(cy, 0, cx + 1)
            default: erase(cy, 0, cols)
            }
        case "L": if (top...bot).contains(cy) { scrollDown(cy, n); cx = 0 }
        case "M": if (top...bot).contains(cy) { scrollUp(cy, n); cx = 0 }
        case "@": let k = min(n, cols - cx); g[cy].insert(contentsOf: blanks(k), at: cx); g[cy].removeLast(k)
        case "P": let k = min(n, cols - cx); g[cy].removeSubrange(cx..<cx + k); g[cy].append(contentsOf: blanks(k))
        case "X": erase(cy, cx, cx + n)
        case "S": scrollUp(top, n)
        case "T": if params.count == 1 { scrollDown(top, n) }
        case "b": for _ in 0..<min(n, cols * rows) { put(lastCh) }
        case "m": sgr()
        case "r":
            top = min(rows - 1, arg(0) - 1); bot = min(rows - 1, arg(1, rows) - 1)
            if top >= bot { top = 0; bot = rows - 1 }
            cx = 0; cy = 0
        case "s": saveCursor()
        case "u": restoreCursor()
        case "n":
            if arg(0, 0) == 6 { reply("\u{1b}[\(cy + 1);\(cx + 1)R") } else if arg(0, 0) == 5 { reply("\u{1b}[0n") }
        case "c": reply("\u{1b}[?1;2c")
        case "q": cursorStyle = max(0, params.first ?? 0)  // DECSCUSR, what vim and friends use for the mode's cursor shape
        default: break
        }
    }

    private func mode(_ p: Int, _ on: Bool) {
        switch p {
        case 1: appCursor = on
        case 25: cursorOn = on
        case 1004: focusReport = on
        case 2026: sync = on; syncHeld = 0  // 2026: frameEnd decides when the frame it builds gets drawn
        case 47, 1047: setAlt(on)
        case 1048: if on { saveCursor() } else { restoreCursor() }
        case 1049: if on { saveCursor(); setAlt(true) } else { setAlt(false); restoreCursor() }
        case 2004: bracketed = on
        case 9, 1000, 1002, 1003: mouseMode = on ? p : 0
        case 1006: sgrMouse = on
        default: break
        }
    }

    private func sgr() {
        var i = 0
        while i < params.count {
            let v = max(params[i], 0)
            if i > 0, subs[i] { i += 1; continue }  // a sub-parameter of what we just read (4:3) or of something we ignore (58:5:n)
            switch v {
            case 0: pen = Cell()
            case 1: pen.bold = true
            case 2: pen.faint = true
            case 3: pen.italic = true
            case 4:  // 4:n picks the style: 1 line, 2 double, 3 curly, 4 dotted, 5 dashed, 0 off
                pen.ul = 1
                if i + 1 < params.count, subs[i + 1] { pen.ul = min(max(params[i + 1], 0), 5); i += 1 }
            case 7: pen.inverse = true
            case 9: pen.strike = true
            case 21: pen.ul = 2  // xterm's double underline
            case 22: pen.bold = false; pen.faint = false
            case 23: pen.italic = false
            case 24: pen.ul = 0
            case 27: pen.inverse = false
            case 29: pen.strike = false
            case 30...37: pen.fg = indexed | UInt32(v - 30)
            case 39: pen.fg = defFG
            case 40...47: pen.bg = indexed | UInt32(v - 40)
            case 49: pen.bg = defBG
            case 90...97: pen.fg = indexed | UInt32(v - 82)
            case 100...107: pen.bg = indexed | UInt32(v - 92)
            case 38, 48, 58:  // 58 sets the underline's color: read past it, we don't draw it
                var color: UInt32?
                if i + 2 < params.count, params[i + 1] == 5 {
                    color = indexed | UInt32(min(max(params[i + 2], 0), 255)); i += 2
                } else if i + 4 < params.count, params[i + 1] == 2 {
                    var j = i + 2  // "38;2;r;g;b": the rgb follow the 2 directly
                    // "38:2::r:g:b" has a colorspace id before the rgb: five sub-parameters after the 38, not four
                    if subs[i + 1], (i + 1..<params.count).prefix(while: { subs[$0] }).count >= 5 { j = i + 3 }
                    if j + 2 < params.count {
                        let c = params[j...j + 2].map { UInt32(min(max($0, 0), 255)) }
                        color = c[0] << 16 | c[1] << 8 | c[2]; i = j + 2
                    }
                }
                if let color, v != 58 { if v == 38 { pen.fg = color } else { pen.bg = color } }
            default: break
            }
            i += 1
        }
    }

    /// OSC 0/1/2 set the window title, 4/10/11 the palette (base16-shell and friends), 104/110/111 reset it, 52 the clipboard,
    /// 9 and 777 post a notification (what Claude Code, Codex and friends send when they finish or need you).
    private func oscDone() {
        let s = String(decoding: osc, as: UTF8.self)
        let semi = s.firstIndex(of: ";") ?? s.endIndex  // OSC 104/110/111 carry no argument at all
        guard let n = Int(s[s.startIndex..<semi]) else { return }
        let arg = s[semi...].dropFirst()  // a "?" asks for the current value, which we don't answer
        switch n {
        case 0, 2: title = String(arg); titled = true
        case 9 where arg.range(of: #"^\d+(;|$)"#, options: .regularExpression) == nil: onBell(self, String(arg))  // not ConEmu's 9;4 progress and kin
        case 777:  // 777 ; notify ; title ; body
            let p = arg.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            if p.count == 3, p[0] == "notify" { onBell(self, p[1].isEmpty ? String(p[2]) : "\(p[1]): \(p[2])") }
        case 4:  // 4 ; index ; color
            let p = arg.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            if p.count == 2, let i = Int(p[0]), (0..<16).contains(i), !p[1].hasPrefix("?") { pal[i] = parseColor(p[1]) }
        case 10: if !arg.hasPrefix("?") { dfg = parseColor(arg) }
        case 11: if !arg.hasPrefix("?") { dbg = parseColor(arg) }
        case 104: pal = Array(repeating: nil, count: 16)
        case 110: dfg = nil
        case 111: dbg = nil
        case 52:  // 52 ; buffers ; base64: how a program reached over ssh fills the clipboard
            let p = arg.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            if p.count == 2, let d = Data(base64Encoded: String(p[1]), options: [.ignoreUnknownCharacters]),
               let text = String(data: d, encoding: .utf8), !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        default: break
        }
    }

    /// "#rrggbb" or "rgb:rr/gg/bb" (one to four hex digits a component), the forms OSC 4/10/11 take.
    private func parseColor(_ s: Substring) -> UInt32? {
        let parts: [Substring]
        if s.hasPrefix("#") {
            let h = s.dropFirst()
            guard h.count == 6 else { return nil }
            parts = [h.prefix(2), h.dropFirst(2).prefix(2), h.dropFirst(4)]
        } else if s.hasPrefix("rgb:") {
            parts = Array(s.dropFirst(4).split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false))
        } else { return nil }
        guard parts.count == 3 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let x = UInt32(p, radix: 16) else { return nil }
            v = v << 8 | min(p.count == 1 ? x * 17 : p.count == 2 ? x : x >> ((p.count - 2) * 4), 255)  // one digit scales by 17, wide ones are 12 or 16 bit
        }
        return v
    }

    /// 1004: our window gained or lost the keyboard.
    func focused(_ on: Bool) { if focusReport { send(on ? "\u{1b}[I" : "\u{1b}[O") } }

    private func put(_ c0: UInt32) {
        var c = c0
        if graphics, (0x60...0x7E).contains(c) { c = acs[Int(c - 0x60)] }
        let w = c < 0x7F ? 1 : Int(wcwidth(wchar_t(c)))
        guard w > 0 else { return }  // combining marks etc. are dropped
        if wrap || cx + w > cols { cx = 0; lineFeed() }
        wrap = false
        var cell = pen; cell.ch = c
        g[cy][cx] = cell
        if w == 2 { cell.ch = 0; g[cy][cx + 1] = cell }  // right half of a wide char
        lastCh = c
        if cx + w >= cols { cx = cols - 1; wrap = true } else { cx += w }
    }

    private func lineFeed() {
        if cy != bot { cy = min(rows - 1, cy + 1); return }
        if top == 0 && !alt {
            history.append(g[0])
            if history.count > 10_000 { history.removeFirst(1_000) }
            if scrollOff > 0 { scrollOff += 1 }  // keep a scrolled-back view still
            scrollOff = min(scrollOff, history.count)
        }
        scrollUp(top, 1)
    }

    private var blank: Cell { var c = Cell(); c.bg = pen.bg; return c }
    private func blanks(_ n: Int) -> [Cell] { Array(repeating: blank, count: n) }
    private func erase(_ y: Int, _ from: Int, _ to: Int) { for x in stride(from: from, to: min(cols, to), by: 1) { g[y][x] = blank } }
    private func scrollUp(_ t: Int, _ n: Int) { for _ in 0..<min(n, bot - t + 1) { g.remove(at: t); g.insert(blanks(cols), at: bot) } }
    private func scrollDown(_ t: Int, _ n: Int) { for _ in 0..<min(n, bot - t + 1) { g.remove(at: bot); g.insert(blanks(cols), at: t) } }
    private func saveCursor() { saved = (cx, cy, pen) }
    private func restoreCursor() { (cx, cy, pen) = saved; cx = min(cx, cols - 1); cy = min(cy, rows - 1); wrap = false }

    private func setAlt(_ on: Bool) {
        guard on != alt else { return }
        swap(&g, &other); alt = on; scrollOff = 0
        if on { g = Array(repeating: Array(repeating: Cell(), count: cols), count: rows) }
    }

    private func reset() {
        pen = Cell(); alt = false; scrollOff = 0
        g = Array(repeating: Array(repeating: Cell(), count: cols), count: rows); other = g
        cx = 0; cy = 0; wrap = false; top = 0; bot = rows - 1
        cursorOn = true; appCursor = false; bracketed = false; graphics = false; mouseMode = 0; sgrMouse = false
        cursorStyle = 0; focusReport = false; sync = false; syncHeld = 0
        pal = Array(repeating: nil, count: 16); dfg = nil; dbg = nil
    }
}

// MARK: - Monitor: sensors, stats, fan control

func fcc(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }  // "F0Ac" -> SMC key

/// The Apple SMC: temperatures and fans. Reading is unprivileged, writing needs root (see fanHelper).
final class SMC {
    private var conn: io_connect_t = 0, forced = false
    private var cpu: [UInt32] = [], gpu: [UInt32] = []
    private var fans: [(mode: UInt32, target: UInt32, min: Float, max: Float)] = []
    private var unlock = false  // older Apple Silicon needs Ftst=1 before fans can be forced; M5 has no such key

    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        defer { IOObjectRelease(svc) }
        guard svc != 0, IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
        for i in 0..<(call(fcc("#KEY"), 5, size: 4).map { UInt32(bigEndian: u32($0, 48)) } ?? 0) {
            guard let k = call(0, 8, index: i).map({ u32($0, 0) }), k >> 24 == 84 /* T */, info(k)?.1 == fcc("flt ") else { continue }
            switch k >> 16 & 255 {
            case 112, 101: cpu.append(k)  // Tp*, Te*: performance / efficiency cores
            case 103: gpu.append(k)  // Tg*
            default: break
            }
        }
        for i in 0..<Int(call(fcc("FNum"), 5, size: 1)?[48] ?? 0) {
            let key = { fcc("F\(i)" + $0) }
            fans.append((info(key("md")) != nil ? key("md") : key("Md"), key("Tg"), float(key("Mn")) ?? 0, float(key("Mx")) ?? 0))
        }
        unlock = info(fcc("Ftst")) != nil
    }

    /// One AppleSMC user-client call. Its 80-byte struct is packed by offset: key @0, info.size @28,
    /// info.type @32, result @40, command @42, index @44, data @48.
    private func call(_ key: UInt32, _ cmd: UInt8, size: UInt32 = 0, index: UInt32 = 0, data: [UInt8] = []) -> [UInt8]? {
        var inp = [UInt8](repeating: 0, count: 80), out = inp, n = 80
        for (v, at) in [(key, 0), (size, 28), (index, 44)] { withUnsafeBytes(of: v) { inp.replaceSubrange(at..<at + 4, with: $0) } }
        inp[42] = cmd
        inp.replaceSubrange(48..<48 + data.count, with: data)
        guard IOConnectCallStructMethod(conn, 2, inp, 80, &out, &n) == KERN_SUCCESS, out[40] == 0 else { return nil }
        return out
    }

    private func u32(_ b: [UInt8], _ at: Int) -> UInt32 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }
    private func info(_ key: UInt32) -> (UInt32, UInt32)? { call(key, 9).map { (u32($0, 28), u32($0, 32)) } }
    private func float(_ key: UInt32) -> Float? { call(key, 5, size: 4).map { Float(bitPattern: u32($0, 48)) } }
    private func write(_ key: UInt32, _ data: [UInt8]) { _ = call(key, 6, size: UInt32(data.count), data: data) }

    /// Hottest CPU and GPU sensor, °C.
    func temps() -> (Double?, Double?) {
        func hottest(_ keys: [UInt32]) -> Double? { keys.compactMap { float($0) }.filter { $0 > 10 && $0 < 150 }.max().map(Double.init) }
        return (hottest(cpu), hottest(gpu))
    }

    /// Forces every fan to pct% of its min...max range, or hands them back to macOS (nil).
    func setFans(_ pct: Int?) {
        if (pct != nil) != forced {
            forced = pct != nil
            if unlock { write(fcc("Ftst"), [forced ? 1 : 0]); if forced { usleep(500_000) } }
            for f in fans { write(f.mode, [forced ? 1 : 0]) }
        }
        if let pct { for f in fans { write(f.target, withUnsafeBytes(of: f.min + (f.max - f.min) * Float(pct) / 100) { Array($0) }) } }
    }
}

/// ANE load and DRAM bandwidth from IOReport, the private library behind powermetrics, as mactop reads it (readable without root).
/// ANE load: the share of time the ANE's performance-floor requests sat above their lowest state (its Energy Model
/// counters stopped counting in macOS 27). Bandwidth: each memory controller (one per die) keeps a histogram of the
/// GB/s it moved, in 64 GB/s buckets labelled by their upper edge, so the mean of the bucket midpoints is good to about ±32 per die.
final class IOStats {
    private typealias Sample = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Name = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias Count = @convention(c) (CFDictionary) -> Int32
    private typealias Residency = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private let sub: OpaquePointer, chans: CFMutableDictionary
    private let sample: Sample, delta: Delta, name: Name, count: Count, residency: Residency, stateName: StateName
    private var last: CFDictionary?

    init?() {
        typealias Copy = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
        typealias Subscribe = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
                                              UInt64, CFTypeRef?) -> OpaquePointer?
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func fn<T>(_ s: String, _: T.Type) -> T? { dlsym(h, s).map { unsafeBitCast($0, to: T.self) } }
        guard let copy = fn("IOReportCopyChannelsInGroup", Copy.self), let subscribe = fn("IOReportCreateSubscription", Subscribe.self),
              let sample = fn("IOReportCreateSamples", Sample.self), let delta = fn("IOReportCreateSamplesDelta", Delta.self),
              let name = fn("IOReportChannelGetChannelName", Name.self), let group = fn("IOReportChannelGetSubGroup", Name.self),
              let count = fn("IOReportStateGetCount", Count.self), let residency = fn("IOReportStateGetResidency", Residency.self),
              let stateName = fn("IOReportStateGetNameForIndex", StateName.self)
        else { return nil }
        // "ANE0-AF-BW" in "SOC Floor", "ANE1-DCS-BW" in "DCS Floor", "AMCC0 RD+WR" in "DCS BW", ...; Max and Ultra chips have a PMP group per die
        let wanted = ["PMP", "PMP0", "PMP1", "PMP2", "PMP3"].flatMap { g in
            (copy(g as CFString, nil, 0, 0, 0)?.takeRetainedValue() as NSDictionary?)?["IOReportChannels"] as? [NSDictionary] ?? []
        }.filter {
            let n = name($0)?.takeUnretainedValue() as String? ?? "", g = group($0)?.takeUnretainedValue() as String? ?? ""
            return n.hasPrefix("ANE") && g.contains("Floor") || n.hasPrefix("AMCC") && n.hasSuffix("RD+WR") && g == "DCS BW"
        }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard !wanted.isEmpty, let sub = subscribe(nil, NSMutableDictionary(dictionary: ["IOReportChannels": wanted]), &subbed, 0, nil),
              let subbed else { return nil }
        self.sub = sub; chans = subbed.takeRetainedValue()
        self.sample = sample; self.delta = delta; self.name = name; self.count = count; self.residency = residency; self.stateName = stateName
    }

    /// Since the last call (zeros on the first): the % of the time the busiest ANE floor was above idle, and the DRAM GB/s.
    func read() -> (ane: Double, bw: Double) {
        guard let now = sample(sub, chans, nil)?.takeRetainedValue() else { return (0, 0) }
        defer { last = now }
        guard let last, let d = delta(last, now, nil)?.takeRetainedValue() as NSDictionary? else { return (0, 0) }
        var ane = 0.0, bw = 0.0
        for c in d["IOReportChannels"] as? [NSDictionary] ?? [] {
            let r = (0..<count(c)).map { residency(c, $0) }, total = r.reduce(0, +)
            guard total > 0 else { continue }
            if (name(c)?.takeUnretainedValue() as String?)?.hasPrefix("AMCC") == true {
                let edges = (0..<count(c)).map { Double((stateName(c, $0)?.takeUnretainedValue() as String?)?.filter(\.isNumber) ?? "") ?? 0 }
                bw += zip(r, edges).reduce(0) { $0 + Double($1.0) * ($1.1 - edges[0] / 2) } / Double(total)
            } else {
                ane = max(ane, Double(total - r[0]) / Double(total) * 100)
            }
        }
        return (ane, bw)
    }
}

/// Spec memory bandwidth (GB/s) of this Mac's chip, to scale the bandwidth bar: the top configuration where the chip
/// comes in two (M3 Max 300, M4 Max 410, M5 Max 460 are the others). 0 for a chip not listed: its bar stays empty.
let peakBandwidth: Double = {
    var buf = [CChar](repeating: 0, count: 64), n = buf.count
    sysctlbyname("machdep.cpu.brand_string", &buf, &n, nil, 0)
    let table: [String: Double] = [
        "M1": 68, "M1 Pro": 200, "M1 Max": 400, "M1 Ultra": 800, "M2": 100, "M2 Pro": 200, "M2 Max": 400, "M2 Ultra": 800,
        "M3": 100, "M3 Pro": 150, "M3 Max": 400, "M3 Ultra": 819, "M4": 120, "M4 Pro": 273, "M4 Max": 546,
        "M5": 153, "M5 Pro": 307, "M5 Max": 614, "M5 Ultra": 1200]
    return table[String(cString: buf).replacingOccurrences(of: "Apple ", with: "")] ?? 0
}()

struct Stats {
    var cpuT: Double?, gpuT: Double?
    var cpu = 0, gpu = 0, ane = 0.0, bw = 0.0, up = 0.0, down = 0.0
    var mem = 0.0, memTotal = Double(ProcessInfo.processInfo.physicalMemory)
}

func procName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "pid \(pid)"
}

/// Samples the machine every 2s off the main thread, and tells the fan helper what speed to run.
final class Monitor {
    private(set) var stats = Stats()  // main thread
    private let q = DispatchQueue(label: "monitor", qos: .utility)
    private var timer: DispatchSourceTimer?, smc: SMC?, io: IOStats?, gpu: io_service_t = 0, host = mach_host_self()
    private var last = 0.0, lastCPU: (UInt32, UInt32) = (0, 0), lastNet: (UInt64, UInt64) = (0, 0)
    private var helper: Int32 = -1, sent = Int.min  // FIFO to the root fan helper; last % sent (-1: automatic)
    private var lock: Int32 = -1  // flock held while this instance controls the fans
    private(set) var locked = false  // main thread: another iTherm instance holds the lock
    private(set) var top: [[(name: String, value: Double)]]?  // main thread, while watched: the 3 busiest by CPU %, GPU %, memory bytes
    private typealias Proc = (cpu: Double, gpu: Double, mem: Double)
    private var watching = false, procs: [pid_t: Proc] = [:], procsAt = 0.0
    private let ns: Double = { var t = mach_timebase_info(); mach_timebase_info(&t); return Double(t.numer) / Double(t.denom) }()

    init() {
        q.async { [self] in
            smc = SMC(); io = IOStats()
            gpu = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
            timer = DispatchSource.makeTimerSource(queue: q)
            timer?.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(500))
            timer?.setEventHandler { [self] in sample() }
            timer?.resume()
        }
        if Prefs.fanControl { control(true) }
    }

    /// Starts or stops fan control. Starting asks for the admin password once and launches this binary as a root
    /// helper that reads fan % from a FIFO; closing our end (turned off, iTherm quit or crashed) gives the fans back.
    /// Only one iTherm instance (of any user) may do this: the first to lock /tmp/itherm-fan.lock, released on exit.
    func control(_ on: Bool) {
        q.async { [self] in
            if helper >= 0 { close(helper); helper = -1; close(lock); lock = -1 }
            guard on, let exe = Bundle.main.executablePath else { return }
            let l = open("/tmp/itherm-fan.lock", O_CREAT | O_RDONLY, 0o644)
            guard l >= 0, flock(l, LOCK_EX | LOCK_NB) == 0 else {
                if l >= 0 { close(l) }
                DispatchQueue.main.async { [self] in locked = true; delegate.syncFanCheck() }
                return
            }
            lock = l
            let fifo = NSTemporaryDirectory() + "itherm-fan-\(getpid())"
            unlink(fifo)
            guard mkfifo(fifo, 0o600) == 0 else { return }
            let fd = open(fifo, O_RDWR | O_NONBLOCK)  // read+write, so neither side blocks waiting for the other
            helper = fd; sent = Int.min
            // The paths go in as arguments and AppleScript quotes them, so no character in them can break the command.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "on run argv", "-e", "do shell script quoted form of item 1 of argv & \" --fan-helper \" & quoted form of item 2 of argv & \" >/dev/null 2>&1 &\" with prompt \"iTherm needs admin rights to control the fans.\" with administrator privileges", "-e", "end run", exe, fifo]
            p.terminationHandler = { [self] p in
                guard p.terminationStatus != 0 else { return }  // cancelled: switch it back off
                unlink(fifo)
                q.async { [self] in if helper == fd { close(fd); helper = -1; close(lock); lock = -1 } }
                DispatchQueue.main.async { UserDefaults.standard.set(false, forKey: "fanControl"); delegate.syncFanCheck() }
            }
            do { try p.run() } catch { p.terminationHandler?(p) }
        }
    }

    /// Starts or stops listing the busiest processes: only while the pointer is over a bar, as it scans every process.
    func watch(_ on: Bool) {
        top = nil
        q.async { [self] in
            watching = on
            procs = on ? processes() : [:]; procsAt = CACurrentMediaTime()
            if on { q.asyncAfter(deadline: .now() + 0.25) { [self] in if watching { listTop() } } }  // then every sample
        }
    }

    private func listTop() {
        let now = CACurrentMediaTime(), dt = now - procsAt, p = processes()
        func busiest(_ value: (pid_t, Proc) -> Double?) -> [(name: String, value: Double)] {
            p.compactMap { pid, x in value(pid, x).map { (pid, $0) } }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(3).map { (procName($0.0), $0.1) }
        }
        let t = [busiest { pid, x in procs[pid].map { (x.cpu - $0.cpu) / dt / 1e7 } },  // ns per second, as %
                 busiest { pid, x in procs[pid].map { (x.gpu - $0.gpu) / dt / 1e7 } },
                 busiest { _, x in x.mem }]
        procs = p; procsAt = now
        DispatchQueue.main.async { [self] in top = t; for v in TermView.all { v.showTop() } }
    }

    /// CPU and GPU time (ns) and memory footprint of every process. CPU and memory only for this user's (the rest
    /// need root); GPU for all, from the driver's per-client accounting (what Activity Monitor's GPU column shows).
    private func processes() -> [pid_t: Proc] {
        var out: [pid_t: Proc] = [:], pids = [pid_t](repeating: 0, count: 16384)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        for pid in pids.prefix(Int(max(n, 0))) {
            var ri = rusage_info_v2()
            guard withUnsafeMutablePointer(to: &ri, { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) } }) == 0
            else { continue }
            out[pid] = (Double(ri.ri_user_time + ri.ri_system_time) * ns, 0, Double(ri.ri_phys_footprint))  // times are in mach ticks
        }
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(gpu, kIOServicePlane, &it) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(it) }
        while case let c = IOIteratorNext(it), c != 0 {
            defer { IOObjectRelease(c) }
            guard let creator = IORegistryEntryCreateCFProperty(c, "IOUserClientCreator" as CFString, nil, 0)?.takeRetainedValue() as? String,
                  let pid = pid_t(creator.dropFirst(4).prefix { $0 != "," }),  // "pid 172, WindowServer"
                  let use = IORegistryEntryCreateCFProperty(c, "AppUsage" as CFString, nil, 0)?.takeRetainedValue() as? [[String: Any]]
            else { continue }
            out[pid, default: (0, 0, 0)].gpu += use.reduce(0) { $0 + ($1["accumulatedGPUTime"] as? Double ?? 0) }
        }
        return out
    }

    private func sample() {
        var s = Stats()
        let now = CACurrentMediaTime(), dt = now - last, first = last == 0
        last = now

        var cpu = host_cpu_load_info(), n = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / 4)
        _ = withUnsafeMutablePointer(to: &cpu) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &n) } }
        let t = cpu.cpu_ticks, busy = t.0 &+ t.1 &+ t.3, total = busy &+ t.2  // user + system + nice, + idle
        s.cpu = Int(Double(busy &- lastCPU.0) / Double(max(total &- lastCPU.1, 1)) * 100)
        lastCPU = (busy, total)

        var vm = vm_statistics64(), m = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / 4)
        _ = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(m)) { host_statistics64(host, HOST_VM_INFO64, $0, &m) } }
        let used = Int(vm.internal_page_count) - Int(vm.purgeable_count) + Int(vm.wire_count) + Int(vm.compressor_page_count)
        s.mem = Double(used) * Double(vm_kernel_page_size)  // Activity Monitor's "Memory Used": app + wired + compressed

        if let ps = IORegistryEntryCreateCFProperty(gpu, "PerformanceStatistics" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any] {
            s.gpu = ps["Device Utilization %"] as? Int ?? 0
        }

        let net = netBytes()
        func rate(_ now: UInt64, _ before: UInt64) -> Double { Double(now > before ? now - before : 0) / dt }  // an interface vanishing lowers the total
        if !first { s.down = rate(net.0, lastNet.0); s.up = rate(net.1, lastNet.1) }
        lastNet = net

        (s.ane, s.bw) = io?.read() ?? (0, 0)

        if let smc {
            (s.cpuT, s.gpuT) = smc.temps()
            // linear ramp: automatic below the start temperature, up to the set speed 15°C above it, flat out at 95°C
            let hot = max(s.cpuT ?? 0, s.gpuT ?? 0), start = Double(Prefs.fanStart)
            let pct = hot < start ? -1 : hot >= 95 ? 100 : Int(min((hot - start) / 15, 1) * Double(Prefs.fanSpeed))
            if helper >= 0, pct != sent { sent = pct; _ = Darwin.write(helper, "\(pct)\n", "\(pct)\n".utf8.count) }
        }
        DispatchQueue.main.async { [self] in stats = s; TermView.tick() }
        if watching { listTop() }
    }

    /// Bytes (in, out) since boot over Ethernet and Wi-Fi (not loopback, VPN tunnels or bridges, which would double count;
    /// nor interfaces that never received a packet: bridge members like en3 report phantom output).
    private func netBytes() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0], len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }
        return buf.withUnsafeBytes { p in
            var i = 0, rx: UInt64 = 0, tx: UInt64 = 0
            while i + MemoryLayout<if_msghdr>.size <= len {
                let h = p.loadUnaligned(fromByteOffset: i, as: if_msghdr.self)
                if Int32(h.ifm_type) == RTM_IFINFO2 {
                    let d = p.loadUnaligned(fromByteOffset: i, as: if_msghdr2.self).ifm_data
                    if Int32(d.ifi_type) == IFT_ETHER && d.ifi_ipackets > 0 { rx += d.ifi_ibytes; tx += d.ifi_obytes }
                }
                i += Int(h.ifm_msglen)
            }
            return (rx, tx)
        }
    }
}

/// Root side of fan control (see Monitor.control): applies each fan % read from the FIFO, and gives
/// the fans back to macOS once iTherm closes it, whether iTherm quit or crashed.
func fanHelper(_ fifo: String) -> Never {
    signal(SIGHUP, SIG_IGN)
    guard let smc = SMC(), freopen(fifo, "r", stdin) != nil else { exit(1) }
    unlink(fifo)
    while let line = readLine() { smc.setFans(Int(line).flatMap { $0 < 0 ? nil : min($0, 100) }) }
    smc.setFans(nil)
    exit(0)
}

// MARK: - View: tabs, input, CPU rendering

/// How a tab is divided: one terminal, or two parts with a 1pt divider between them.
indirect enum Layout {
    case leaf(Term)
    case split(Layout, Layout, columns: Bool, ratio: CGFloat)  // columns: side by side, else stacked; ratio: the first's share

    var terms: [Term] {
        switch self {
        case .leaf(let t): [t]
        case .split(let a, let b, _, _): a.terms + b.terms
        }
    }

    /// A split's two rects within r, the divider between them.
    static func parts(_ r: CGRect, columns: Bool, ratio: CGFloat) -> (CGRect, CGRect) {
        let edge: CGRectEdge = columns ? .minXEdge : .minYEdge
        let (first, rest) = r.divided(atDistance: ((columns ? r.width : r.height) * ratio).rounded(.down), from: edge)
        return (first, rest.divided(atDistance: 1, from: edge).remainder)
    }

    /// Each terminal's rect within r.
    func rects(in r: CGRect) -> [(Term, CGRect)] {
        switch self {
        case .leaf(let t): return [(t, r)]
        case .split(let a, let b, let columns, let ratio):
            let (first, rest) = Layout.parts(r, columns: columns, ratio: ratio)
            return a.rects(in: first) + b.rects(in: rest)
        }
    }

    /// Every divider within r: its split's path from the root (false: first part, true: second), a 7pt band
    /// around the 1pt gap to grab it by, and whether it stands between columns.
    func dividers(in r: CGRect) -> [(path: [Bool], rect: CGRect, columns: Bool)] {
        guard case .split(let a, let b, let columns, let ratio) = self else { return [] }
        let (first, rest) = Layout.parts(r, columns: columns, ratio: ratio)
        let band = columns ? CGRect(x: first.maxX - 3, y: r.minY, width: 7, height: r.height) : CGRect(x: r.minX, y: first.maxY - 3, width: r.width, height: 7)
        return [([], band, columns)] + a.dividers(in: first).map { ([false] + $0.path, $0.rect, $0.columns) }
            + b.dividers(in: rest).map { ([true] + $0.path, $0.rect, $0.columns) }
    }

    /// With the divider of the split at path (see dividers) moved to p; each part keeps at least a tenth.
    func moving(_ path: ArraySlice<Bool>, in r: CGRect, to p: CGPoint) -> Layout {
        guard case .split(let a, let b, let columns, let ratio) = self else { return self }
        let (first, rest) = Layout.parts(r, columns: columns, ratio: ratio)
        switch path.first {
        case nil: return .split(a, b, columns: columns, ratio: min(max(columns ? (p.x - r.minX) / r.width : (p.y - r.minY) / r.height, 0.1), 0.9))
        case false?: return .split(a.moving(path.dropFirst(), in: first, to: p), b, columns: columns, ratio: ratio)
        case true?: return .split(a, b.moving(path.dropFirst(), in: rest, to: p), columns: columns, ratio: ratio)
        }
    }

    /// Splits t's pane in two, the new terminal n going after it.
    func splitting(_ t: Term, with n: Term, columns: Bool) -> Layout {
        switch self {
        case .leaf(let l): l === t ? .split(self, .leaf(n), columns: columns, ratio: 0.5) : self
        case .split(let a, let b, let c, let r): .split(a.splitting(t, with: n, columns: columns), b.splitting(t, with: n, columns: columns), columns: c, ratio: r)
        }
    }

    /// Without t's pane (its sibling takes the space); nil if t was all there was.
    func removing(_ t: Term) -> Layout? {
        switch self {
        case .leaf(let l): return l === t ? nil : self
        case .split(let a, let b, let columns, let ratio):
            guard let ra = a.removing(t) else { return b }
            guard let rb = b.removing(t) else { return a }
            return .split(ra, rb, columns: columns, ratio: ratio)
        }
    }
}

/// A layout as saved across launches: each pane's folder in place of its terminal.
indirect enum Saved: Codable {
    case leaf(String?)
    case split(Saved, Saved, columns: Bool, ratio: CGFloat)
}

extension Layout {
    var saved: Saved {
        switch self {
        case .leaf(let t): .leaf(t.cwd)
        case .split(let a, let b, let c, let r): .split(a.saved, b.saved, columns: c, ratio: r)
        }
    }

    /// Fresh shells on machine in the saved folders (drawing fits them to their panes).
    init(_ s: Saved, on machine: String) {
        switch s {
        case .leaf(let dir): self = .leaf(Term(cols: 80, rows: 24, cwd: dir, ssh: machine))
        case .split(let a, let b, let c, let r): self = .split(Layout(a, on: machine), Layout(b, on: machine), columns: c, ratio: r)
        }
    }
}

/// A tab: its panes, the one that has the keyboard, and the machine they run on.
final class Tab {
    var layout: Layout, focus: Term
    let machine: String  // "" this Mac, else how ssh reaches it
    private(set) var folder: String?, branch: String?  // the focused pane's, on this Mac (see refresh)
    init(_ layout: Layout, _ machine: String) { self.layout = layout; focus = layout.terms[0]; self.machine = machine; refresh() }
    var dot: Mark { layout.terms.map(\.dot).max() ?? .idle }

    /// What the program titled it, without what agents put first (Claude Code's ✳, a spinner); else its folder, or its machine.
    var name: String {
        let n = focus.title.drop { !$0.isLetter && !$0.isNumber }
        return focus.titled && !n.isEmpty ? String(n) : folder.map { ($0 as NSString).lastPathComponent } ?? (machine.isEmpty ? focus.title : machine)
    }

    func refresh() {  // with the status bar: a shell's folder is a syscall away, its branch a few file reads
        guard machine.isEmpty else { return }
        folder = focus.cwd; branch = folder.flatMap(gitBranch)
    }
}

/// A machine's tabs in one window, and the one shown.
struct Space {
    var tabs: [Tab] = [], active = 0

    mutating func remove(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: i)
        if i < active { active -= 1 }  // the same tab stays active; a removed last one clamps it
        active = max(min(active, tabs.count - 1), 0)
    }
}

/// A window as saved when iTherm quits, reopened on the next launch with fresh shells in the same folders.
struct Session: Codable {
    struct Space: Codable { var tabs: [Saved], active: Int }
    var frame: String, machine: String, spaces: [String: Space]
}

/// A bitmap in memory shared with the window server, and the grid rows each pane (by rect) shows, as
/// drawn: cursor, selection. [] = draw it all.
final class Buffer {
    let surface: IOSurface, c: CGContext
    var drawn: [CGRect: [[Cell]]] = [:]
    var chrome = ""  // what its tab bar and sidebar show (TermView.chromeKey); they're redrawn only when it changes
    init(_ surface: IOSurface, _ c: CGContext) { self.surface = surface; self.c = c }
}

final class TermView: NSView, NSWindowDelegate {
    static var all: [TermView] = []  // every open window's view
    private var spaces: [String: Space] = [:]  // each machine's tabs; a machine without any has no entry
    private var machine = ""  // the one whose tabs are shown
    var tabs: [Tab] { get { spaces[machine]?.tabs ?? [] } set { spaces[machine, default: Space()].tabs = newValue } }
    var active: Int { get { spaces[machine]?.active ?? 0 } set { spaces[machine, default: Space()].active = newValue } }
    private var allTabs: [Tab] { spaces.values.flatMap(\.tabs) }
    private(set) var sideW: CGFloat = 0  // the machines sidebar, with the 1pt line at its edge; 0 when hidden
    var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont
    var boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold) as CTFont
    var italFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont  // the family's italic face,
    var boldItalFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold) as CTFont  // or the regular outlines, sheared
    var cw: CGFloat = 8, ch: CGFloat = 16, ascent: CGFloat = 12
    var theme = themes[0]
    var boldBright = false
    let pad: CGFloat = 4
    var tabH: CGFloat { ch + 8 }
    private var tabsX: CGFloat { sideW + tabH }  // the tabs start after the sidebar and its show/hide button, a square at the tab bar's left
    private var tabW: CGFloat { (bounds.width - tabsX - tabH) / CGFloat(max(tabs.count, 1)) }  // a square at the right end holds the + button
    var cur: Term? { tabs.indices.contains(active) ? tabs[active].focus : nil }
    private var buffers: [Buffer] = []  // one on screen, one or two being drawn or still being read by macOS
    private var glyphs: [UInt64: (CTFont, CGGlyph)] = [:]  // (char, bold, italic) -> the font and glyph to draw it with
    private var lastDraw = 0.0, wheel: CGFloat = 0, lastMouse = (-1, -1)
    private var selA: (Int, Int)?, selB = (0, 0), selUnit = 1  // (absolute row, col); unit: 1 char, 2 word, 3 line
    private var draggingTab = false, dragDivider: [Bool]?  // the divider being dragged: its split's path (Layout.dividers)
    private var cursorPanes: [CGRect] = []  // the pane rects the cursor rects were made for
    private var spots: [(ClosedRange<CGFloat>, Int)] = []  // status bar x ranges of the CPU, GPU and MEM sections: index into monitor.top
    private var hover: Int? { didSet { if hover != oldValue { monitor.watch(hover != nil); showTop() } } }
    private var netRect = CGRect.zero, diskRect = CGRect.zero  // the status bar's network and disk symbols (view coordinates)
    private var symbols: [String: NSImage] = [:]  // SF Symbols by name, in the theme's dim color
    private var ui = NSFont.systemFont(ofSize: 13) as CTFont, uiSmall = NSFont.systemFont(ofSize: 11) as CTFont, uiBadge = NSFont.systemFont(ofSize: 10) as CTFont  // set in applySettings: the sidebar's and tab bar's type
    private var collapsed: Set<String> = []  // machines whose tabs the sidebar hides
    private var machines: [String] { [""] + spaces.keys.filter { !$0.isEmpty }.sorted() }  // the sidebar's: this Mac, then those with tabs here
    private let ports = NSPopover(), top = NSPopover()  // the listening ports, over the network symbol; the busiest processes, over the hovered bar

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        registerForDraggedTypes([.fileURL, .string])
        ports.behavior = .transient
        ports.contentViewController = Ports()
        top.behavior = .applicationDefined; top.animates = false
        top.contentViewController = Top()
        applySettings()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() { applySettings() }
    override func viewDidChangeBackingProperties() { applySettings() }  // another scale: snap cells to its pixels, or the scroll blit's rowPx outgrows its rows

    func applySettings() {
        func make(_ bold: Bool) -> CTFont {
            let fm = NSFontManager.shared, family = Prefs.font, size = Prefs.fontSize
            let f = family.isEmpty ? nil : fm.font(withFamily: family, traits: bold ? .boldFontMask : [], weight: 5, size: size)
                ?? fm.font(withFamily: family, traits: [], weight: 5, size: size)
            return (f ?? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)) as CTFont
        }
        font = make(false); boldFont = make(true)
        let s = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var m: UniChar = 77, gl: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font, &m, &gl, 1)
        cw = ceil(CTFontGetAdvancesForGlyphs(font, .horizontal, &gl, nil, 1) * s) / s  // snap cells to pixels
        ch = ceil((CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) * s) / s
        ascent = CTFontGetAscent(font)
        // italics: the family's own italic face when it has one as wide as the regular, else the same outlines sheared a little
        func ital(_ f: CTFont) -> CTFont {
            let a = CTFontGetAdvancesForGlyphs(f, .horizontal, &gl, nil, 1)
            let i = NSFontManager.shared.convert(f as NSFont, toHaveTrait: .italicFontMask) as CTFont
            if CTFontCopyFamilyName(i) as String == CTFontCopyFamilyName(f) as String, CTFontGetAdvancesForGlyphs(i, .horizontal, &gl, nil, 1) == a { return i }
            var shear = CGAffineTransform(1, 0, 0.22, 1, 0, 0)  // a synthetic oblique: it leaves the advance alone, the cell stays one cell
            return withUnsafePointer(to: &shear) { CTFontCreateWithGraphicsFont(CTFontCopyGraphicsFont(f, nil), CTFontGetSize(f), $0, nil) }
        }
        italFont = ital(font); boldItalFont = ital(boldFont)
        glyphs.removeAll(); buffers.removeAll()
        theme = themes[Prefs.theme]
        boldBright = Prefs.boldBright
        sideW = Prefs.sidebar ? (26 * cw).rounded() + 1 : 0
        let size = Prefs.fontSize
        ui = NSFont.systemFont(ofSize: size) as CTFont; uiSmall = NSFont.systemFont(ofSize: size - 1.5) as CTFont
        uiBadge = NSFont.systemFont(ofSize: size - 3, weight: .semibold) as CTFont
        func color(_ c: UInt32) -> NSColor { NSColor(red: CGFloat(c >> 16 & 255) / 255, green: CGFloat(c >> 8 & 255) / 255, blue: CGFloat(c & 255) / 255, alpha: 1) }
        let dim = color(theme.dim)
        for (name, pt) in [("network", size), ("internaldrive", size), ("desktopcomputer", size - 1), ("server.rack", size - 1),
                           ("plus", size - 2), ("chevron.down", size - 3), ("chevron.right", size - 3), ("xmark", size - 4), ("sidebar.left", size),
                           ("square.split.2x1", size - 3), ("square.split.1x2", size - 3)] {
            symbols[name] = NSImage(systemSymbolName: name, accessibilityDescription: name)!
                .withSymbolConfiguration(.init(pointSize: pt, weight: .medium).applying(.init(paletteColors: [dim])))!
        }
        window?.appearance = NSAppearance(named: theme.bg & 0xff < 0x80 ? .darkAqua : .aqua)  // title bar to match
        window?.backgroundColor = color(theme.bar)  // shows through the transparent title bar, one piece with the tab bar
        window?.invalidateCursorRects(for: self)  // the bars changed height with the font
        needsDisplay = true
    }

    /// Between the tab bar and the status bar (top-left origin, like drawing).
    var area: CGRect { CGRect(x: sideW, y: tabH, width: bounds.width - sideW, height: bounds.height - 2 * tabH) }

    /// Where each of a tab's terminals is drawn.
    private func panes(_ tab: Tab) -> [(Term, CGRect)] { tab.layout.rects(in: area) }

    /// Columns and rows that fit in a pane.
    private func grid(_ r: CGRect) -> (Int, Int) { (max(2, Int((r.width - 2 * pad) / cw)), max(1, Int((r.height - 2 * pad) / ch))) }

    // MARK: windows and tabs

    /// Opens a window showing tabs, or a new shell; cascaded from the key window.
    @discardableResult
    static func open(_ tabs: [Tab] = []) -> TermView {
        let v = TermView(frame: .zero)
        v.setFrameSize(NSSize(width: 100 * v.cw + 2 * v.pad + v.sideW, height: 30 * v.ch + 2 * v.tabH + 2 * v.pad))
        let w = NSWindow(contentRect: v.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.titlebarAppearsTransparent = true; w.titlebarSeparatorStyle = .none  // the title bar and tab bar read as one, as in Terminal
        w.contentView = v
        w.delegate = v
        w.makeFirstResponder(v)
        w.center()
        if let k = NSApp.keyWindow { w.setFrameTopLeftPoint(k.cascadeTopLeft(from: .zero)) }
        w.makeKeyAndOrderFront(nil)
        all.append(v)
        if tabs.isEmpty { v.newTab() } else { tabs.forEach(v.adopt) }
        return v
    }

    /// This window, to reopen on the next launch.
    var session: Session {
        Session(frame: window.map { NSStringFromRect($0.frame) } ?? "", machine: machine,
                spaces: spaces.mapValues { .init(tabs: $0.tabs.map(\.layout.saved), active: $0.active) })
    }

    /// Reopens the windows open when iTherm last quit, or a new one.
    static func restore() {
        let saved = UserDefaults.standard.data(forKey: "session").flatMap { try? JSONDecoder().decode([Session].self, from: $0) } ?? []
        if saved.isEmpty { open() }
        for s in saved {
            let v = open(s.spaces.flatMap { m, space in space.tabs.map { Tab(Layout($0, on: m), m) } })
            for (m, space) in s.spaces { v.spaces[m]?.active = min(space.active, space.tabs.count - 1) }
            if v.spaces[s.machine] != nil { v.changing { v.machine = s.machine } }
            v.window?.setFrame(NSRectFromString(s.frame), display: true)
        }
    }

    /// Every 2 s (with the status bar): a terminal out of sight that prints is working, and done once it goes quiet.
    static func tick() {
        for v in all {
            for tab in v.allTabs { tab.refresh() }
            for t in v.allTabs.flatMap(\.layout.terms) {
                if v.seen(t) { t.mark = .idle } else if t.busy { t.mark = max(t.mark, .working) } else if t.mark == .working { t.mark = .done }
            }
            v.needsDisplay = true
        }
        badge()
    }

    /// The Dock icon counts the tabs that finished or rang for you out of sight.
    static func badge() {
        let n = all.flatMap(\.allTabs).filter { $0.layout.terms.contains { $0.mark >= .done } }.count
        let label = n > 0 ? "\(n)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    private func seen(_ t: Term) -> Bool { window?.isKeyWindow == true && isShown(t) }

    /// A terminal rang the bell or posted a notification (OSC 9/777). Out of sight, its tab gets the yellow dot; with iTherm
    /// in the background the Dock icon bounces too, and macOS shows the message.
    private func bell(_ t: Term, _ message: String?) {
        guard !seen(t), t.mark != .needs else { return }
        t.mark = .needs; needsDisplay = true; TermView.badge()
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
        guard Bundle.main.bundleIdentifier != nil else { return }  // only an app bundle may post notifications
        let n = UNMutableNotificationContent(), m = allTabs.first { $0.layout.terms.contains { $0 === t } }?.machine ?? ""
        n.title = m.isEmpty ? t.title : "\(t.title) on \(m)"
        n.body = message ?? "Needs you"
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            if ok { center.add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil)) }
        }
    }

    /// 1004: the programs in this window's panes hear about the keyboard coming and going.
    func windowDidBecomeKey(_ n: Notification) { cur?.focused(true) }
    func windowDidResignKey(_ n: Notification) { cur?.focused(false) }

    func windowShouldClose(_ w: NSWindow) -> Bool {
        if tabs.isEmpty { return true }
        confirm("Close window?", "Anything running in its \(allTabs.count) tabs will be stopped.") { w.close() }
        return false
    }

    func windowWillClose(_ n: Notification) {
        for tab in allTabs { for t in tab.layout.terms { t.hangup() } }
        TermView.all.removeAll { $0 === self }
        if TermView.all.isEmpty { NSApp.terminate(nil) }
    }

    @objc func newTab(_ sender: Any? = nil) { adopt(Tab(.leaf(spawn(near: cur)), machine)) }

    /// A shell on the selected machine; on this Mac, in t's folder.
    private func spawn(near t: Term?) -> Term {
        if !machine.isEmpty { UserDefaults.standard.set(Array(([machine] + Prefs.recents.filter { $0 != machine }).prefix(8)), forKey: "recents") }
        let (cols, rows) = grid(area)
        return Term(cols: cols, rows: rows, cwd: machine.isEmpty ? t?.cwd : nil, ssh: machine)
    }

    /// Shows tab as a new tab of this window, on its machine.
    func adopt(_ tab: Tab) {
        for t in tab.layout.terms { wire(t) }
        changing { machine = tab.machine; tabs.append(tab); active = tabs.count - 1 }
    }

    /// Shows machine m's tabs, or opens one there if it has none.
    func show(_ m: String) {
        changing { machine = m }
        if tabs.isEmpty { newTab() }
    }

    /// Makes a change that may show another terminal, and tells the two (1004) the keyboard moved.
    private func changing(_ change: () -> Void) {
        let was = cur
        change()
        selA = nil; needsDisplay = true
        if window?.isKeyWindow == true, was !== cur { was?.focused(false); cur?.focused(true) }
    }

    private func wire(_ t: Term) {
        t.onChange = { [weak self] t in if self?.isShown(t) == true { self?.dirty() } }
        t.onExit = { [weak self] t in self?.close(t) }
        t.onBell = { [weak self] t, message in self?.bell(t, message) }
    }

    private func isShown(_ t: Term) -> Bool { !tabs.isEmpty && tabs[active].layout.terms.contains { $0 === t } }

    /// Splits the focused pane: ⌘D puts the new one beside it, ⌘⇧D below it.
    private func split(columns: Bool) {
        guard let t = cur else { return }
        let n = spawn(near: t)  // drawing fits it to its half
        wire(n)
        tabs[active].layout = tabs[active].layout.splitting(t, with: n, columns: columns)
        focus(n)
    }
    @objc func splitVertically(_ sender: Any?) { split(columns: true) }
    @objc func splitHorizontally(_ sender: Any?) { split(columns: false) }

    private func focus(_ t: Term) {
        guard t !== cur else { return }
        let was = cur
        tabs[active].focus = t; selA = nil; needsDisplay = true
        if window?.isKeyWindow == true { was?.focused(false); t.focused(true) }
    }

    @objc func moveToWindow(_ item: NSMenuItem) {
        guard let tab = item.representedObject as? Tab else { return }
        TermView.open([tab])  // before removing: an emptied window closes, and the last one quits
        remove(tab)
    }

    @objc func closeTab(_ sender: Any?) { if !tabs.isEmpty { close(tabs[active]) } }
    @objc func prevTab(_ sender: Any?) { select(active - 1) }
    @objc func nextTab(_ sender: Any?) { select(active + 1) }

    @objc func closeTabItem(_ item: NSMenuItem) { if let tab = item.representedObject as? Tab { close(tab) } }
    @objc func closeOtherTabs(_ item: NSMenuItem) { for tab in tabs where tab !== item.representedObject as? Tab { close(tab) } }

    private func tabAt(_ x: CGFloat) -> Int { min(max(Int((x - tabsX) / tabW), 0), tabs.count - 1) }

    /// Tab i's buttons, right to left: its ×, then on the active tab split below and split beside, which split its focused pane.
    private func tabButtons(_ i: Int) -> [CGRect] {
        let maxX = tabsX + CGFloat(i + 1) * tabW
        return (0..<(i == active ? 3 : 1)).map { CGRect(x: maxX - 24 - CGFloat($0) * 20, y: 0, width: 18, height: tabH) }
    }

    /// Asks before something running gets hung up.
    private func confirm(_ title: String, _ text: String, then: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        a.addButton(withTitle: "Close"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window!) { if $0 == .alertFirstButtonReturn { then() } }
    }

    private func confirmClose(_ tab: Tab) {  // the tab's ×
        confirm("Close “\(tab.focus.title)”?", "Anything running in this tab will be stopped.") { [weak self] in self?.close(tab) }
    }

    func close(_ tab: Tab) { for t in tab.layout.terms { t.hangup() }; remove(tab) }

    /// Closes t's pane (its shell ended); the tab goes with its last one.
    func close(_ t: Term) {
        guard let tab = allTabs.first(where: { $0.layout.terms.contains { $0 === t } }) else { return }
        guard let rest = tab.layout.removing(t) else { close(tab); return }
        t.hangup()
        let i = tab.layout.terms.firstIndex { $0 === t }!
        tab.layout = rest
        if tab.focus === t { tab.focus = rest.terms[min(i, rest.terms.count - 1)]; selA = nil }
        needsDisplay = true
    }

    /// Drops tab from its machine's tabs. A machine with none left shows the next that has some; a window with none closes.
    private func remove(_ tab: Tab) {
        guard let m = spaces.first(where: { $0.value.tabs.contains { $0 === tab } })?.key else { return }
        let wasShown = m == machine && tabs.firstIndex { $0 === tab } == active
        if wasShown, window?.isKeyWindow == true { cur?.focused(false) }
        spaces[m]!.remove(tab)
        if spaces[m]!.tabs.isEmpty { spaces[m] = nil }
        if spaces.isEmpty { window?.close(); return }
        if spaces[machine] == nil { machine = machines.first { spaces[$0] != nil }! }
        selA = nil; needsDisplay = true
        if wasShown, window?.isKeyWindow == true { cur?.focused(true) }
    }

    func select(_ i: Int) { changing { active = (i + tabs.count) % tabs.count } }

    @objc func toggleMachines(_ sender: Any?) {
        UserDefaults.standard.set(Prefs.sidebar, forKey: "hideSidebar")
        for v in TermView.all { v.applySettings() }
    }

    // MARK: machines sidebar

    private enum SideRow { case header, machine(String), tab(Tab) }

    /// The sidebar, top down: Machines, then each machine and (unless collapsed) its tabs.
    private func sideRows() -> [(row: SideRow, rect: CGRect)] {
        var rows: [(row: SideRow, rect: CGRect)] = [], y: CGFloat = 0
        func add(_ row: SideRow, _ h: CGFloat) { rows.append((row, CGRect(x: 0, y: y, width: sideW - 1, height: h))); y += h }
        add(.header, tabH)
        for m in machines {
            add(.machine(m), tabH + 4)
            if !collapsed.contains(m) { for tab in spaces[m]?.tabs ?? [] { add(.tab(tab), tabH + 8) } }
        }
        return rows
    }

    /// Where a machine's row has its + (a new tab there) and its chevron (show or hide its tabs); the header's + is where the chevron is.
    private func buttons(_ r: CGRect) -> (plus: CGRect, chevron: CGRect) {
        (CGRect(x: r.maxX - 58, y: r.minY, width: 20, height: r.height), CGRect(x: r.maxX - 26, y: r.minY, width: 20, height: r.height))
    }

    /// The header's + connects to a machine. A machine's row shows its tabs, its + opens one more, its chevron folds them away.
    /// A tab's row shows it. Right-click a tab for its menu, an ssh machine to save or forget it or close its tabs.
    private func sidebarClick(_ q: CGPoint, _ e: NSEvent, right: Bool = false) {
        guard let hit = sideRows().first(where: { $0.rect.contains(q) }) else { return }
        switch hit.row {
        case .header: if !right { addMenu(e) }
        case .machine(let m) where right:
            guard !m.isEmpty else { return }
            popUp([Prefs.saved.contains(m) ? ("Forget Connection", #selector(forget)) : ("Save Connection", #selector(save)),
                   ("Close Its Tabs", #selector(closeMachine))], m, e)
        case .machine(let m):
            let b = buttons(hit.rect)
            if b.chevron.contains(q) { if collapsed.remove(m) == nil { collapsed.insert(m) }; needsDisplay = true }
            else if b.plus.contains(q) { changing { machine = m }; newTab() } else { show(m) }
        case .tab(let tab):
            changing { machine = tab.machine; active = tabs.firstIndex { $0 === tab }! }
            if right { tabMenu(tab, e) }
        }
    }

    /// New Connection…, then the saved connections, the recent ones and the hosts in ~/.ssh/config. Hold ⌥ to forget one.
    private func addMenu(_ e: NSEvent) {
        let m = NSMenu(), saved = Prefs.saved, recents = Prefs.recents.filter { !saved.contains($0) }
        m.addItem(withTitle: "New Connection…", action: #selector(newConnection), keyEquivalent: "").target = self
        for (title, hosts, forgettable) in [("Saved", saved, true), ("Recent", recents, true),
                                            ("~/.ssh/config", sshHosts().filter { !saved.contains($0) && !recents.contains($0) }, false)] where !hosts.isEmpty {
            m.addItem(.separator())
            m.addItem(.sectionHeader(title: title))
            for h in hosts {
                let go = m.addItem(withTitle: h, action: #selector(connect), keyEquivalent: "")
                go.target = self; go.representedObject = h; go.keyEquivalentModifierMask = []
                guard forgettable else { continue }
                let drop = m.addItem(withTitle: "Forget \(h)", action: #selector(forget), keyEquivalent: "")
                drop.target = self; drop.representedObject = h; drop.keyEquivalentModifierMask = .option; drop.isAlternate = true
            }
        }
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }

    @objc private func connect(_ item: NSMenuItem) { show(item.representedObject as! String) }

    @objc private func save(_ item: NSMenuItem) {
        UserDefaults.standard.set(Prefs.saved + [item.representedObject as! String], forKey: "saved")
    }

    /// Off the saved list and the recent one.
    @objc private func forget(_ item: NSMenuItem) {
        let m = item.representedObject as! String
        for key in ["saved", "recents"] { UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != m }, forKey: key) }
    }

    /// User, host and port, saved for next time unless unticked.
    @objc private func newConnection(_ item: NSMenuItem) {
        let user = NSTextField(), host = NSTextField(), port = NSTextField(), keep = NSButton(checkboxWithTitle: "Save in the + menu", target: nil, action: nil)
        user.placeholderString = NSUserName(); host.placeholderString = "address, or a Host from ~/.ssh/config"; port.placeholderString = "22"
        keep.state = .on
        for f in [user, host, port] { f.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        let grid = NSGridView(views: [[NSTextField(labelWithString: "User:"), user], [NSTextField(labelWithString: "Host:"), host],
                                      [NSTextField(labelWithString: "Port:"), port], [NSGridCell.emptyContentView, keep]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .lastBaseline
        grid.frame.size = grid.fittingSize
        let a = NSAlert()
        a.messageText = "New SSH Connection"
        a.accessoryView = grid
        a.addButton(withTitle: "Connect"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = host
        a.beginSheetModal(for: window!) { [weak self] r in
            func value(_ f: NSTextField) -> String { f.stringValue.filter { !$0.isWhitespace } }
            let h = value(host), u = value(user), p = Int(value(port)).map { $0 == 22 ? "" : ":\($0)" } ?? ""
            guard r == .alertFirstButtonReturn, !h.isEmpty else { return }
            let m = (u.isEmpty ? "" : u + "@") + h + p
            if keep.state == .on, !Prefs.saved.contains(m) { UserDefaults.standard.set(Prefs.saved + [m], forKey: "saved") }
            self?.show(m)
        }
    }

    @objc private func closeMachine(_ item: NSMenuItem) {
        let m = item.representedObject as! String, tabs = spaces[m]?.tabs ?? []
        confirm("Close \(tabs.count) tabs on \(m)?", "Anything running in them will be stopped.") { [weak self] in for tab in tabs { self?.close(tab) } }
    }

    // MARK: keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with e: NSEvent) {
        guard let t = cur else { return }
        let m = e.modifierFlags
        if m.contains(.command) {  // the other ⌘ shortcuts live in the menu bar
            if let n = Int(e.charactersIgnoringModifiers ?? ""), (1...tabs.count).contains(n) { select(n - 1) }
            return
        }
        let ss3 = t.appCursor ? "\u{1b}O" : "\u{1b}["
        let out: String? = switch e.keyCode {
        case 126: ss3 + "A"
        case 125: ss3 + "B"
        case 124: m.contains(.option) ? "\u{1b}f" : ss3 + "C"  // ⌥→ / ⌥← jump words
        case 123: m.contains(.option) ? "\u{1b}b" : ss3 + "D"
        case 115: "\u{1b}[H"
        case 119: "\u{1b}[F"
        case 116: "\u{1b}[5~"
        case 121: "\u{1b}[6~"
        case 117: "\u{1b}[3~"
        case 51: "\u{7f}"
        case 36, 76: "\r"
        case 53: "\u{1b}"
        case 48: m.contains(.shift) ? "\u{1b}[Z" : "\t"
        // ⌥ as Meta: Esc + the plain key, what readline and the TUIs want, instead of the character macOS types
        default: Prefs.optionMeta && m.contains(.option) && !m.contains(.control)
            ? "\u{1b}" + (e.charactersIgnoringModifiers ?? "")  // keeps shift: ⌥⇧b sends B
            : e.characters
        }
        guard let out, !out.isEmpty else { return }
        t.scrollOff = 0; selA = nil
        t.send(out)
    }

    @objc func paste(_ sender: Any?) {
        guard let t = cur, let s = NSPasteboard.general.string(forType: .string) else { return }
        paste(s, to: t)
    }

    private func paste(_ s: String, to t: Term) {
        let text = s.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        t.scrollOff = 0
        t.send(t.bracketed ? "\u{1b}[200~" + text + "\u{1b}[201~" : text)
    }

    // MARK: drag and drop: files become shell-escaped paths, text is pasted, into the pane under the mouse

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { cur == nil ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let t = pane(at: convert(sender.draggingLocation, from: nil)) ?? cur else { return false }
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let special = Set(" \t\\'\"`$!&*()[]{}<>|;?#~=")
            paste(urls.map { $0.path.map { special.contains($0) ? "\\\($0)" : "\($0)" }.joined() + " " }.joined(), to: t)
        } else if let s = pb.string(forType: .string) {
            paste(s, to: t)
        } else { return false }
        focus(t)
        return true
    }

    // MARK: selection

    @objc func copy(_ sender: Any?) {
        guard let t = cur, let (s, e) = selRange(t) else { return }
        let text = (s.0...e.0).map { r in
            let row = t.absLine(r), from = r == s.0 ? s.1 : 0, to = min(r == e.0 ? e.1 : Int.max, row.count - 1)
            var line = ""
            if from <= to { for c in row[from...to] where c.ch != 0 { line.unicodeScalars.append(Unicode.Scalar(c.ch) ?? " ") } }
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let t = cur else { return }
        selA = (0, 0); selB = (t.abs(t.rows - 1), t.cols - 1); selUnit = 3
        needsDisplay = true
    }

    /// Ordered selection bounds, grown to whole words/lines for double/triple clicks; nil if nothing is selected.
    private func selRange(_ t: Term) -> ((Int, Int), (Int, Int))? {
        guard let a = selA else { return nil }
        var (s, e) = a < selB ? (a, selB) : (selB, a)
        switch selUnit {
        case 1: if s == e { return nil }
        case 2: s.1 = wordEdge(t.absLine(s.0), s.1, -1); e.1 = wordEdge(t.absLine(e.0), e.1, 1)
        default: s.1 = 0; e.1 = Int.max
        }
        return (s, e)
    }

    private func wordEdge(_ row: [Cell], _ x: Int, _ dir: Int) -> Int {
        func isWord(_ c: UInt32) -> Bool { c == 0 || c > 32 && !"'\"`()[]{}<>,;|".unicodeScalars.contains { $0.value == c } }
        guard x < row.count else { return x }
        let word = isWord(row[x].ch)
        var i = x
        while row.indices.contains(i + dir), isWord(row[i + dir].ch) == word { i += dir }
        return i
    }

    // MARK: mouse

    override func resetCursorRects() {  // the panes, and the dividers between them; not the tab or status bar
        guard !tabs.isEmpty else { return }
        for (_, r) in panes(tabs[active]) { addCursorRect(unflip(r), cursor: .iBeam) }
        for d in tabs[active].layout.dividers(in: area) { addCursorRect(unflip(d.rect), cursor: d.columns ? .resizeLeftRight : .resizeUpDown) }
    }

    /// A top-left origin rect (drawing, layout) as a view rect.
    private func unflip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height) }

    /// The terminal under p (view coordinates), if any.
    private func pane(at p: CGPoint) -> Term? {
        let q = CGPoint(x: p.x, y: bounds.height - p.y)
        return tabs.isEmpty ? nil : panes(tabs[active]).first { $0.1.contains(q) }?.0
    }

    /// The cell of t's grid under the mouse, clamped to it.
    private func cellAt(_ e: NSEvent, in t: Term) -> (Int, Int) {
        let p = convert(e.locationInWindow, from: nil), r = panes(tabs[active]).first { $0.0 === t }!.1
        return (min(max(Int((p.x - r.minX - pad) / cw), 0), t.cols - 1), min(max(Int((bounds.height - p.y - r.minY - pad) / ch), 0), t.rows - 1))
    }

    /// Forwards a mouse event to the program if it asked for them; false means it's ours (selection etc).
    private func report(_ e: NSEvent, _ button: Int, press: Bool = true, motion: Bool = false) -> Bool {
        guard let t = cur, t.mouseMode != 0, e.modifierFlags.isDisjoint(with: [.shift, .option]) else { return false }
        let (x, y) = cellAt(e, in: t)
        if motion {  // 1002 wants drags, 1003 all movement; only report when the cell changes
            guard t.mouseMode == 1003 || (t.mouseMode == 1002 && button != 3), (x, y) != lastMouse else { return true }
        } else if !press && t.mouseMode == 9 { return true }
        lastMouse = (x, y)
        t.sendMouse(button | (motion ? 32 : 0) | (e.modifierFlags.contains(.control) ? 16 : 0), x, y, press)
        return true
    }

    override func mouseDown(with e: NSEvent) {
        guard cur != nil else { return }
        let p = convert(e.locationInWindow, from: nil)
        if p.y < tabH {  // the status bar: its network symbol opens the ports list, its disk symbol the disk usage window
            if diskRect.contains(p) { DiskUsage.shared.present(); return }
            if !netRect.contains(p) { return }
            if ports.isShown { ports.close() } else { ports.show(relativeTo: netRect, of: self, preferredEdge: .maxY) }
            return
        }
        let q = CGPoint(x: p.x, y: bounds.height - p.y)
        if q.x < sideW { sidebarClick(q, e); return }
        if q.y < tabH {
            if p.x < tabsX { toggleMachines(nil); return }
            if p.x >= bounds.width - tabH { newTab(); return }
            let i = tabAt(p.x)
            switch tabButtons(i).firstIndex(where: { p.x >= $0.minX - 2 }) {
            case 0: confirmClose(tabs[i])
            case 1: split(columns: false)
            case 2: split(columns: true)
            default: select(i); draggingTab = true
            }
            return
        }
        if let d = tabs[active].layout.dividers(in: area).first(where: { $0.rect.contains(q) }) { dragDivider = d.path; return }
        if let t = pane(at: p) { focus(t) }
        if report(e, 0) { return }
        let t = cur!, (x, y) = cellAt(e, in: t)
        selA = (t.abs(y), x); selB = (t.abs(y), x); selUnit = e.clickCount
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        if draggingTab {  // move the active tab to the slot under the mouse
            let i = tabAt(convert(e.locationInWindow, from: nil).x)
            if i != active { let tab = tabs.remove(at: active); tabs.insert(tab, at: i); active = i; needsDisplay = true }
            return
        }
        if let path = dragDivider {
            let p = convert(e.locationInWindow, from: nil)
            tabs[active].layout = tabs[active].layout.moving(path[...], in: area, to: CGPoint(x: p.x, y: bounds.height - p.y))
            needsDisplay = true
            return
        }
        if report(e, 0, motion: true) { return }
        guard let t = cur, selA != nil else { return }
        let (x, y) = cellAt(e, in: t)
        selB = (t.abs(y), x)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if draggingTab { draggingTab = false } else if dragDivider != nil { dragDivider = nil } else { _ = report(e, 0, press: false) }
    }
    override func rightMouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil), onTab = bounds.height - p.y < tabH && !tabs.isEmpty
        if p.x < sideW { sidebarClick(CGPoint(x: p.x, y: bounds.height - p.y), e, right: true); return }
        if onTab { if p.x >= tabsX { tabMenu(tabs[tabAt(p.x)], e) }; return }
        if let t = pane(at: p) { focus(t) }
        if report(e, 2) { return }
        popUp([("Split Vertically", #selector(splitVertically)), ("Split Horizontally", #selector(splitHorizontally))], nil, e)
    }

    private func tabMenu(_ tab: Tab, _ e: NSEvent) {
        popUp([("Move to New Window", #selector(moveToWindow)), ("Close Tab", #selector(closeTabItem)), ("Close Other Tabs", #selector(closeOtherTabs))], tab, e)
    }

    private func popUp(_ items: [(String, Selector)], _ object: Any?, _ e: NSEvent) {
        let m = NSMenu()
        for (title, action) in items {
            let item = m.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = object
        }
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }

    override func rightMouseUp(with e: NSEvent) { _ = report(e, 2, press: false) }
    override func rightMouseDragged(with e: NSEvent) { _ = report(e, 2, motion: true) }
    override func otherMouseDown(with e: NSEvent) { _ = report(e, 1) }
    override func otherMouseUp(with e: NSEvent) { _ = report(e, 1, press: false) }
    override func otherMouseDragged(with e: NSEvent) { _ = report(e, 1, motion: true) }
    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        hover = p.y < tabH ? spots.first { $0.0.contains(p.x) }?.1 : nil  // the status bar is the bottom tabH points
        _ = report(e, 3, motion: true)
    }
    override func mouseExited(with e: NSEvent) { hover = nil }

    override func scrollWheel(with e: NSEvent) {
        guard let t = pane(at: convert(e.locationInWindow, from: nil)) ?? cur else { return }
        wheel += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / ch : e.scrollingDeltaY
        let lines = Int(wheel)
        wheel -= CGFloat(lines)
        guard lines != 0 else { return }
        if t.mouseMode != 0 {  // wheel = buttons 64/65
            let (x, y) = cellAt(e, in: t)
            for _ in 0..<Swift.abs(lines) { t.sendMouse(lines > 0 ? 64 : 65, x, y, true) }
        } else if t.alt {  // full-screen apps without mouse support (less, man): scroll with arrow keys
            t.send(String(repeating: (t.appCursor ? "\u{1b}O" : "\u{1b}[") + (lines > 0 ? "A" : "B"), count: Swift.abs(lines)))
        } else {
            t.scrollOff = min(max(t.scrollOff + lines, 0), t.history.count)
            needsDisplay = true
        }
    }

    // MARK: rendering (CPU only)

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { render() }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); needsDisplay = true }

    func dirty() {
        // A flood of output can keep the run loop from idling (where AppKit draws), so draw at ~60fps ourselves.
        if CACurrentMediaTime() - lastDraw > 1.0 / 60 { render(); CATransaction.flush() } else { needsDisplay = true }
    }

    func render() {
        guard let layer, let win = window else { return }
        lastDraw = CACurrentMediaTime()
        let s = win.backingScaleFactor
        let pw = Int(bounds.width * s), ph = Int(bounds.height * s)
        guard pw > 0, ph > 0 else { return }
        // draw into a buffer that's neither on screen nor still being read by the window server
        buffers.removeAll { $0.c.width != pw || $0.c.height != ph }
        let onScreen = layer.contents as AnyObject?
        guard let b = buffers.first(where: { $0.surface !== onScreen && !$0.surface.isInUse }) ?? (buffers.count < 3 ? newBuffer(pw, ph, s) : nil) else {
            // the window server is behind (a busy GPU): skip this frame rather than pile up surfaces, and try again shortly
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in self?.needsDisplay = true }
            return
        }
        let c = b.c
        b.surface.lock(options: [], seed: nil)
        defer { b.surface.unlock(options: [], seed: nil); layer.contents = b.surface }
        c.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // un-flip glyphs; glyph positions are in this text space, so their y is negated
        for tab in allTabs { for (t, r) in panes(tab) { let (cols, rows) = grid(r); t.resize(cols, rows) } }

        let shown = tabs.isEmpty ? [] : panes(tabs[active])
        if win.isKeyWindow, shown.contains(where: { $0.0.mark != .idle }) { for (t, _) in shown { t.mark = .idle }; TermView.badge() }
        if shown.map(\.1) != cursorPanes { cursorPanes = shown.map(\.1); window?.invalidateCursorRects(for: self) }  // another layout: new pane and divider cursors
        if Set(shown.map { $0.1 }) != Set(b.drawn.keys) {  // another layout (or a new buffer): start over; the gaps left between panes are the dividers
            fill(c, 0, 0, bounds.width, bounds.height, theme.tab)
            b.drawn = [:]
            for (t, r) in shown { fill(c, r.minX, r.minY, r.width, r.height, theme.bg); b.drawn[r] = Array(repeating: [], count: t.rows) }
            b.chrome = ""
        }
        if case let key = chromeKey, b.chrome != key { drawTabs(c); if sideW > 0 { drawSidebar(c) }; b.chrome = key }
        for (t, r) in shown { drawGrid(b, t, r, s) }
        if let w = window, let t = cur, w.title != t.title { w.title = t.title }
        drawStatus(c)
    }

    /// Everything the tab bar and sidebar show: when it's unchanged, so are they.
    private var chromeKey: String {
        ([machine, "\(active)", collapsed.sorted().joined(separator: " ")] + machines.flatMap { m in
            [m] + (spaces[m]?.tabs ?? []).map { "\($0.name)\t\($0.branch ?? "")\t\($0.dot.rawValue)" }
        }).joined(separator: "\n")
    }

    /// The sidebar's show/hide button, then each tab: its number, its name, its dot and its ×; the active one on a rounded tab, the others
    /// split by thin lines. A + for a new tab at the right end.
    private func drawTabs(_ c: CGContext) {
        fill(c, sideW, 0, bounds.width - sideW, tabH, theme.bar)
        icon(c, "sidebar.left", CGRect(x: sideW, y: 0, width: tabH, height: tabH))
        icon(c, "plus", CGRect(x: bounds.width - tabH, y: 0, width: tabH, height: tabH))
        let tw = tabW
        for (i, tab) in tabs.enumerated() {
            let r = CGRect(x: tabsX + CGFloat(i) * tw, y: 0, width: tw, height: tabH), on = i == active, mid = r.midY
            if on { pill(c, r.insetBy(dx: 3, dy: 3), 6, theme.tab) }
            else if i + 1 < tabs.count, i + 1 != active { fill(c, r.maxX - 1, 7, 1, tabH - 14, theme.tab) }
            let x = r.minX + 12 + label(c, "\(i + 1)", r.minX + 12, mid, uiSmall, theme.dim, 24) + 8
            let buttons = tabButtons(i)
            var right = buttons.last!.minX - 4
            if tab.dot != .idle { drawMark(c, tab.dot, right - 5, mid); right -= 16 }
            label(c, tab.name, x, mid, ui, on ? theme.fg : theme.dim, right - x)
            for (b, name) in zip(buttons, ["xmark", "square.split.1x2", "square.split.2x1"]) { icon(c, name, b) }
        }
    }

    /// Machines and +; each machine with its icon, +, dot and chevron; under it its tabs, each with a letter, its name, git
    /// branch and dot. The tab on screen sits on a rounded highlight.
    private func drawSidebar(_ c: CGContext) {
        let w = sideW - 1, palette = [6, 3, 4, 2, 5, 1].map { theme.ansi[$0] }
        fill(c, 0, 0, w, bounds.height - tabH, theme.bar)
        for (row, r) in sideRows() where r.minY < bounds.height - tabH {
            let mid = r.midY
            switch row {
            case .header:
                label(c, "Machines", 14, mid, ui, theme.dim, w - 50)
                icon(c, "plus", buttons(r).chevron)
            case .machine(let m):
                let b = buttons(r)
                icon(c, m.isEmpty ? "desktopcomputer" : "server.rack", CGRect(x: 12, y: r.minY, width: 18, height: r.height))
                icon(c, "plus", b.plus)
                drawMark(c, spaces[m]?.tabs.map(\.dot).max() ?? .idle, b.plus.maxX + 6, mid)
                icon(c, collapsed.contains(m) ? "chevron.right" : "chevron.down", b.chevron)
                label(c, m.isEmpty ? "This Mac" : m, 38, mid, ui, theme.dim, b.plus.minX - 42)
            case .tab(let tab):
                let on = tab.machine == machine && tab === tabs[active], name = tab.name
                if on { pill(c, r.insetBy(dx: 6, dy: 2), 7, theme.tab) }
                let side = r.height - 14, badge = CGRect(x: 14, y: mid - side / 2, width: side, height: side)
                let letter = name.first.map { String($0).uppercased() } ?? "?"
                pill(c, badge, 4, palette[Int(letter.unicodeScalars.first!.value) % palette.count])
                let lw = label(c, letter, 0, mid, uiBadge, 0xffffff, side, measure: true)
                label(c, letter, badge.midX - lw / 2, mid, uiBadge, 0xffffff, side)
                var right = w - 14
                if tab.dot != .idle { drawMark(c, tab.dot, right - 5, mid) }
                right -= 18
                if let branch = tab.branch {
                    let bw = label(c, branch, 0, mid, uiSmall, theme.dim, w * 0.35, measure: true)
                    label(c, branch, right - bw, mid, uiSmall, theme.dim, bw); right -= bw + 10
                }
                label(c, name, badge.maxX + 10, mid, ui, on ? theme.fg : mix(theme.dim, theme.fg, 0.5), right - badge.maxX - 10)
            }
        }
    }

    /// A tab's dot: a ring while it prints, green once it went quiet out of sight, yellow when it rang for you.
    private func drawMark(_ c: CGContext, _ m: Mark, _ x: CGFloat, _ y: CGFloat) {
        switch m {
        case .idle: return
        case .working:
            c.setLineWidth(1.5)
            for (color, from, to) in [(mix(theme.bar, theme.ansi[4], 0.35), 0.0, 2 * CGFloat.pi), (theme.ansi[4], -CGFloat.pi / 2, CGFloat.pi * 0.8)] {
                c.setStrokeColor(cgColor(color))
                c.addArc(center: CGPoint(x: x, y: y), radius: 5, startAngle: from, endAngle: to, clockwise: false)
                c.strokePath()
            }
        case .done, .needs:
            setColor(c, m == .done ? theme.ansi[2] : theme.ansi[3])
            c.fillEllipse(in: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7))
        }
    }

    /// Proportional text (the system font, unlike the grid's) from x, centred on midY, cut short with … to fit width.
    /// Returns its width; measure only measures.
    @discardableResult
    private func label(_ c: CGContext, _ s: String, _ x: CGFloat, _ midY: CGFloat, _ font: CTFont, _ color: UInt32, _ width: CGFloat, measure: Bool = false) -> CGFloat {
        guard width > 0, !s.isEmpty else { return 0 }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        if CTLineGetTypographicBounds(line, nil, nil, nil) > width,
           let cut = CTLineCreateTruncatedLine(line, width, .end, CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))) { line = cut }
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard !measure else { return w }
        setColor(c, color)
        c.textPosition = CGPoint(x: x.rounded(), y: (midY + CTFontGetCapHeight(font) / 2).rounded())
        CTLineDraw(line, c)
        c.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // drawing moved its origin; the grid's glyphs need it back at 0
        return w
    }

    /// An SF Symbol, centred in r.
    private func icon(_ c: CGContext, _ name: String, _ r: CGRect) {
        guard let img = symbols[name] else { return }
        let s = img.size
        c.saveGState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
        img.draw(in: CGRect(x: (r.midX - s.width / 2).rounded(), y: (r.midY - s.height / 2).rounded(), width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.current = nil
        c.restoreGState()
        c.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // not part of the saved state; AppKit may have changed it
    }

    private func pill(_ c: CGContext, _ r: CGRect, _ radius: CGFloat, _ rgb: UInt32) {
        setColor(c, rgb)
        c.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        c.fillPath()
    }

    private func newBuffer(_ pw: Int, _ ph: Int, _ s: CGFloat) -> Buffer? {
        guard let surface = IOSurface(properties: [.width: pw, .height: ph, .bytesPerElement: 4, .pixelFormat: 0x4247_5241 /* BGRA */]),
              let c = CGContext(data: surface.baseAddress, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        c.translateBy(x: 0, y: CGFloat(ph))
        c.scaleBy(x: s, y: -s)  // draw in points with a top-left origin
        buffers.append(Buffer(surface, c))
        return buffers.last
    }

    /// Redraws only the rows that differ from what the buffer already shows. Rows share storage with the
    /// terminal's (copy-on-write), so an unchanged row compares equal in O(1).
    private func drawGrid(_ b: Buffer, _ t: Term, _ r: CGRect, _ s: CGFloat) {
        var drawn = b.drawn.removeValue(forKey: r)!
        defer { b.drawn[r] = drawn }
        let c = b.c, focused = t === cur, sel = focused ? selRange(t) : nil, rows = t.rows, p = palette(t)
        let now = (0..<rows).map { y in
            let a = t.abs(y)
            var line = t.absLine(a)
            if line.count > t.cols { line = Array(line.prefix(t.cols)) }
            if focused && t.cursorOn && t.scrollOff == 0 && y == t.cy && t.cx < line.count {
                if t.cursorStyle >= 5 { line[t.cx].cursor = 2 }  // a bar
                else if t.cursorStyle >= 3 { line[t.cx].cursor = 1 }  // an underline
                else { line[t.cx].inverse.toggle() }  // a block
            }
            if let sel, sel.0.0 <= a, a <= sel.1.0 {
                for x in line.indices where sel.0 <= (a, x) && (a, x) <= sel.1 { line[x].selected = true }
            }
            return line
        }
        // Output scrolled k lines: move the pixels up rather than redraw every row.
        func matches(_ k: Int) -> Int { (0..<rows - k).filter { now[$0] == drawn[$0 + k] }.count }
        if now[0] != drawn[0], let k = (1..<rows).first(where: { now[0] == drawn[$0] }), matches(k) > matches(0) {
            let bpr = c.bytesPerRow, rowPx = Int((ch * s).rounded())
            let base = c.data! + Int(((r.minY + pad) * s).rounded()) * bpr + Int((r.minX * s).rounded()) * 4, width = Int((r.width * s).rounded()) * 4
            for line in 0..<(rows - k) * rowPx { memmove(base + line * bpr, base + (line + k * rowPx) * bpr, width) }  // just this pane's columns
            drawn = Array(drawn[k...]) + repeatElement([], count: k)
        }
        for y in 0..<rows where now[y] != drawn[y] {
            drawRow(c, now[y], r.minX, r.minY + pad + CGFloat(y) * ch, r.width, p)
            drawn[y] = now[y]
        }
    }

    /// The theme's colors as one terminal's OSC 4/10/11 requests changed them.
    private func palette(_ t: Term) -> (fg: UInt32, bg: UInt32, sel: UInt32, ansi: [UInt32]) {
        (t.dfg ?? theme.fg, t.dbg ?? theme.bg, theme.sel, theme.ansi.enumerated().map { i, c in t.pal[i] ?? c })
    }

    /// Bold in the bright colors, as Terminal.app draws it: the base 8 only, and only while bold.
    private func bright(_ cell: Cell) -> UInt32 {
        cell.bold && cell.fg & indexed != 0 && (cell.fg & 255) < 8 ? cell.fg | 8 : cell.fg
    }

    private func drawRow(_ c: CGContext, _ line: [Cell], _ left0: CGFloat, _ top: CGFloat, _ width: CGFloat, _ p: (fg: UInt32, bg: UInt32, sel: UInt32, ansi: [UInt32])) {
        let rect = CGRect(x: left0, y: top, width: width, height: ch)
        fill(c, rect.minX, rect.minY, rect.width, rect.height, p.bg)
        c.saveGState(); defer { c.restoreGState() }
        c.clip(to: rect)  // so glyphs can't leave marks in rows that won't be redrawn
        let colors = line.map { cell -> (fg: UInt32, bg: UInt32) in
            var fg = resolve(boldBright ? bright(cell) : cell.fg, p.fg), bg = resolve(cell.bg, p.bg)
            if cell.inverse { swap(&fg, &bg) }
            if cell.faint { fg = mix(fg, bg, 0.5) }  // dim: half way to the background
            return (fg: fg, bg: cell.selected ? p.sel : bg)
        }
        var x = 0
        while x < line.count {  // backgrounds first, one fill per run of the same color
            var e = x + 1
            while e < line.count && colors[e].bg == colors[x].bg { e += 1 }
            if colors[x].bg != p.bg { fill(c, left0 + pad + CGFloat(x) * cw, top, CGFloat(e - x) * cw, ch, colors[x].bg) }
            x = e
        }
        var gs: [CGGlyph] = [], ps: [CGPoint] = []
        var runFont = font, runColor: UInt32 = 0
        func flush() {  // glyphs are batched into runs of the same font and color
            guard !gs.isEmpty else { return }
            setColor(c, runColor)
            CTFontDrawGlyphs(runFont, gs, ps, gs.count, c)
            gs.removeAll(keepingCapacity: true); ps.removeAll(keepingCapacity: true)
        }
        for (x, cell) in line.enumerated() {
            let left = left0 + pad + CGFloat(x) * cw, fg = colors[x].fg, uy = top + ascent + 1
            switch cell.ul {  // the underline styles, one fill per mark
            case 1: fill(c, left, uy, cw, 1, fg)
            case 2: fill(c, left, uy, cw, 1, fg); fill(c, left, uy + 2, cw, 1, fg)
            case 3: for dx in 0..<Int(cw.rounded()) {  // a squiggle, one wave to the cell
                fill(c, left + CGFloat(dx), uy + 1 + (sin(CGFloat(dx) / cw * 2 * .pi)).rounded(), 1, 1, fg)
            }
            case 4: for dx in stride(from: 0, to: Int(cw.rounded()), by: 2) { fill(c, left + CGFloat(dx), uy, 1, 1, fg) }
            case 5: for dx in stride(from: 0, to: Int(cw.rounded()), by: 4) { fill(c, left + CGFloat(dx), uy, 2, 1, fg) }
            default: break
            }
            if cell.strike { fill(c, left, top + ascent * 0.45, cw, 1, fg) }
            if cell.cursor == 1 { fill(c, left, top + ch - 2, cw, 2, fg) }  // the cursor, when it is not a block
            else if cell.cursor == 2 { fill(c, left, top, 2, ch, fg) }
            guard cell.ch > 32 else { continue }
            let (f, gl) = glyph(cell.ch, cell.bold, cell.italic)
            if f !== runFont || fg != runColor { flush(); runFont = f; runColor = fg }
            gs.append(gl); ps.append(CGPoint(x: left, y: -(top + ascent)))
        }
        flush()
    }

    /// CPU 62° ███░░░░░ 35% │ GPU 71° ████████ 98% │ ANE █░░░░░░░ 12% │ MEM ████░░░░ 50/256G │ ↑1.2K ↓30M
    ///                                                                  BW  ██░░░░░░ 640G/s   (the two MEM rows in smaller type)
    private func drawStatus(_ c: CGContext) {
        let s = monitor.stats, top = bounds.height - tabH, start = Double(Prefs.fanStart), gb = Double(1 << 30)
        fill(c, 0, top, bounds.width, tabH, theme.bar)
        func temp(_ t: Double?) -> (String, UInt32) {  // yellow once the fans ramp, red when they're at the set speed
            guard let t else { return ("--°", theme.dim) }
            return ("\(Int(t))°", t >= start + 15 ? theme.ansi[1] : t >= start ? theme.ansi[3] : theme.fg)
        }
        func rate(_ b: Double) -> String {
            var v = b, u = 0
            while v >= 1000 && u < 3 { v /= 1024; u += 1 }
            return (u > 0 && v < 10 ? String(format: "%.1f", v) : "\(Int(v))") + ["B", "K", "M", "G"][u]
        }
        func bar(_ pct: Double) -> (String, UInt32) {  // 8 cells; green, yellow from 60%, red from 85%
            let n = Int((pct / 100 * 8).rounded())
            return (String(repeating: "█", count: n) + String(repeating: "░", count: 8 - n),
                    pct >= 85 ? theme.ansi[1] : pct >= 60 ? theme.ansi[3] : theme.ansi[2])
        }
        let bandwidth = s.bw >= 1000 ? String(format: "%.1fT/s", s.bw / 1000) : "\(Int(s.bw))G/s"
        let sections: [(Int?, [[(String, UInt32)]])] = [  // (index into monitor.top, rows of parts; two rows share the height in smaller type)
            (0, [[("CPU ", theme.dim), temp(s.cpuT), (" ", theme.fg), bar(Double(s.cpu)), (" \(s.cpu)%", theme.fg)]]),
            (1, [[("GPU ", theme.dim), temp(s.gpuT), (" ", theme.fg), bar(Double(s.gpu)), (" \(s.gpu)%", theme.fg)]]),
            (nil, [[("ANE ", theme.dim), bar(s.ane), (" \(Int(s.ane))%", theme.fg)]]),
            (2, [[("MEM ", theme.dim), bar(s.mem / s.memTotal * 100), (" \(Int(s.mem / gb))/\(Int(s.memTotal / gb))G", theme.fg)],
                 [("BW  ", theme.dim), bar(peakBandwidth > 0 ? s.bw / peakBandwidth * 100 : 0), (" " + bandwidth, theme.fg)]]),
            (nil, [[("↑\(rate(s.up)) ↓\(rate(s.down))", theme.fg)]])]
        let net = symbols["network"]!.size, disk = symbols["internaldrive"]!.size
        netRect = CGRect(origin: CGPoint(x: 8, y: (tabH - net.height) / 2), size: net)
        diskRect = CGRect(origin: CGPoint(x: netRect.maxX + 8, y: (tabH - disk.height) / 2), size: disk)
        icon(c, "network", netRect.offsetBy(dx: 0, dy: top))
        icon(c, "internaldrive", diskRect.offsetBy(dx: 0, dy: top))
        var x = diskRect.maxX
        spots = []
        for (spot, rows) in sections {
            x = text(c, " │ ", x, top + 4, theme.dim, bounds.width - 8)
            let x0 = x, k: CGFloat = rows.count > 1 ? 0.65 : 1, rowH = ch * k
            var end = x0
            for (r, parts) in rows.enumerated() {
                var rx = x0
                let y = top + (tabH - CGFloat(rows.count) * rowH) / 2 + CGFloat(r) * rowH  // centred in the bar
                for (str, color) in parts { rx = text(c, str, rx, y, color, bounds.width - 8, k) }
                end = max(end, rx)
            }
            x = end
            if let spot { spots.append((x0...x, spot)) }
        }
    }

    /// The busiest processes for the hovered status bar section, in a popover above it, once the monitor has listed them.
    func showTop() {
        guard let h = hover, let rows = monitor.top?[h], let spot = spots.first(where: { $0.1 == h })?.0 else { top.close(); return }
        (top.contentViewController as! Top).set(rows, percent: h < 2)
        let at = CGRect(x: spot.lowerBound, y: 0, width: spot.upperBound - spot.lowerBound, height: tabH)
        if top.isShown { top.positioningRect = at } else { top.show(relativeTo: at, of: self, preferredEdge: .maxY) }
    }

    /// Draws a line of text at x, clipped at maxX, k times the usual size, and returns where it ended.
    @discardableResult
    private func text(_ c: CGContext, _ s: String, _ x0: CGFloat, _ top: CGFloat, _ color: UInt32, _ maxX: CGFloat, _ k: CGFloat = 1) -> CGFloat {
        var x = x0
        setColor(c, color)
        c.saveGState()
        c.scaleBy(x: k, y: k)
        for u in s.unicodeScalars where x + cw * k <= maxX {
            let (f, gl) = glyph(u.value, false)
            CTFontDrawGlyphs(f, [gl], [CGPoint(x: x / k, y: -(top / k + ascent))], 1, c)
            x += cw * k
        }
        c.restoreGState()
        return x
    }

    private func resolve(_ c: UInt32, _ def: UInt32) -> UInt32 {
        if c == defFG || c == defBG { return def }
        guard c & indexed != 0 else { return c }  // truecolor
        let i = Int(c & 255)
        return i < 16 ? theme.ansi[i] : cube[i - 16]
    }

    private func glyph(_ ch: UInt32, _ bold: Bool, _ italic: Bool = false) -> (CTFont, CGGlyph) {
        let key = UInt64(ch) | (bold ? 1 << 31 : 0) | (italic ? 1 << 32 : 0)
        if let hit = glyphs[key] { return hit }
        let s = String(Unicode.Scalar(ch).map(Character.init) ?? "?")
        let u = Array(s.utf16)
        var gs = [CGGlyph](repeating: 0, count: u.count)
        var f = bold ? (italic ? boldItalFont : boldFont) : italic ? italFont : font
        if !CTFontGetGlyphsForCharacters(f, u, &gs, u.count) {  // not in the font: let CoreText pick a fallback
            let size = CTFontGetSize(f)
            f = CTFontCreateForString(f, s as CFString, CFRange(location: 0, length: u.count))
            // CoreText reaches for Apple Color Emoji even for symbols that are text unless asked otherwise (Claude Code's ⏺ and ✳,
            // ✔, ⚠): a picture a cell wide that runs into the next. Terminal.app draws them in a text font, and so do we.
            if (CTFontCopyPostScriptName(f) as String).contains("Emoji"), Unicode.Scalar(ch)?.properties.isEmojiPresentation == false,
               let t = ["Menlo", "Apple Symbols", "STIX Two Math"].lazy.map({ CTFontCreateWithName($0 as CFString, size, nil) })
                   .first(where: { CTFontGetGlyphsForCharacters($0, u, &gs, u.count) }) { f = t }
            CTFontGetGlyphsForCharacters(f, u, &gs, u.count)
        }
        glyphs[key] = (f, gs[0])
        return (f, gs[0])
    }

    private func setColor(_ c: CGContext, _ rgb: UInt32) {
        c.setFillColor(red: CGFloat(rgb >> 16 & 255) / 255, green: CGFloat(rgb >> 8 & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    private func fill(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rgb: UInt32) {
        setColor(c, rgb)
        c.fill(CGRect(x: x, y: y, width: w, height: h))
    }
}

// MARK: - Popovers: busiest processes, open ports

/// A popover's body: a padded grid of rows, sized to fit.
class Popup: NSViewController {
    override func loadView() { view = NSView() }

    @discardableResult
    func set(_ rows: [[NSView]]) -> NSGridView {
        view.subviews.forEach { $0.removeFromSuperview() }
        let grid = NSGridView(views: rows)
        grid.rowAlignment = .lastBaseline
        grid.columnSpacing = 12
        view.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        preferredContentSize = view.fittingSize
        return grid
    }

    static func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        return l
    }
}

/// The busiest processes of a status bar section: CPU % or GPU % (percent) or memory.
final class Top: Popup {
    func set(_ rows: [(name: String, value: Double)], percent: Bool) {
        guard !rows.isEmpty else { set([[Popup.label("idle")]]); return }  // one column: no second to align
        set(rows.map { r in
            let gb = r.value / Double(1 << 30)
            return [Popup.label(r.name), Popup.label(percent ? "\(Int(r.value))%" : gb >= 1 ? String(format: "%.1fG", gb) : "\(Int(gb * 1024))M")]
        }).column(at: 1).xPlacement = .trailing
    }
}

/// The TCP ports this user's programs are listening on (other users' need root): each port is a link to it in the
/// browser, with a button that kills its process.
final class Ports: Popup {
    override func viewWillAppear() { reload() }

    private func reload() {
        let found = listening()
        guard !found.isEmpty else { set([[Popup.label("Nothing is listening")]]); return }
        set(found.map { port, pid in
            let kill = NSButton(title: "Kill", target: self, action: #selector(kill(_:)))
            kill.tag = Int(pid); kill.controlSize = .small
            let open = NSButton(title: "", target: self, action: #selector(open(_:)))  // a link: opens http://localhost:port
            open.attributedTitle = NSAttributedString(string: ":\(port)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue])
            open.isBordered = false; open.tag = port
            return [open, Popup.label("\(procName(pid))  (\(pid))"), kill]
        }).column(at: 0).xPlacement = .trailing
    }

    @objc private func open(_ b: NSButton) { NSWorkspace.shared.open(URL(string: "http://localhost:\(b.tag)")!) }

    @objc private func kill(_ b: NSButton) {
        Darwin.kill(pid_t(b.tag), SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.reload() }  // the row is gone if it obeyed
    }

    /// Every (port, pid) with a listening TCP socket, by port. A server often listens on IPv4 and IPv6 at once, and
    /// nginx's workers share a port: each pair once.
    private func listening() -> [(port: Int, pid: pid_t)] {
        var ports: [Int: Set<pid_t>] = [:], pids = [pid_t](repeating: 0, count: 16384)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)), fdSize = MemoryLayout<proc_fdinfo>.size
        for pid in pids.prefix(Int(max(n, 0))) {
            let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard need > 0 else { continue }  // another user's
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(need) / fdSize)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, need)
            for fd in fds.prefix(Int(max(got, 0)) / fdSize) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
                var si = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size, si.psi.soi_kind == SOCKINFO_TCP,
                      si.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
                let port = UInt16(truncatingIfNeeded: si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport).byteSwapped  // network byte order
                ports[Int(port), default: []].insert(pid)
            }
        }
        return ports.sorted { $0.key < $1.key }.flatMap { port, pids in pids.sorted().map { (port, $0) } }
    }
}

// MARK: - Disk usage: what fills the disk, as rings around the folder being looked at

func diskSize(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

/// A file or folder and the bytes it takes on disk. A scanned folder keeps its children largest first, those of at
/// least a thousandth of its size and at most 100; the rest become one "smaller items" leaf. They would be too thin to
/// see anyway, and it keeps a whole disk's tree small.
final class DiskNode: Codable {
    enum Kind: UInt8, Codable { case folder, file, rest }
    let name: String, kind: Kind  // the root's name is its path
    var size: Int64, children: [DiskNode] = []
    unowned var parent: DiskNode?
    private enum CodingKeys: CodingKey { case name, kind, size, children }
    init(_ name: String, _ kind: Kind, _ size: Int64) { self.name = name; self.kind = kind; self.size = size }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name); kind = try c.decode(Kind.self, forKey: .kind); size = try c.decode(Int64.self, forKey: .size)
        children = try c.decode([DiskNode].self, forKey: .children)
        for k in children { k.parent = self }
    }

    var path: String { parent.map { p in let pp = p.path; return (pp == "/" ? "" : pp) + "/" + name } ?? name }

    func add(_ n: DiskNode) { n.parent = self; children.append(n); size += n.size }

    func clone() -> DiskNode {
        let n = DiskNode(name, kind, size)
        for k in children { let c = k.clone(); c.parent = n; n.children.append(c) }
        return n
    }

    /// The deepest folder this tree has for a path under its root, nil if the path is elsewhere.
    func find(_ p: String) -> DiskNode? {
        guard p == name || p.hasPrefix(name.hasSuffix("/") ? name : name + "/") else { return nil }
        var n = self
        for c in p.dropFirst(name.count).split(separator: "/") {
            guard let k = n.children.first(where: { $0.kind == .folder && $0.name == c }) else { break }
            n = k
        }
        return n
    }

    private static func order(_ a: DiskNode, _ b: DiskNode) -> Bool { (a.kind == .rest ? 0 : 1, a.size) > (b.kind == .rest ? 0 : 1, b.size) }

    private func finish() {
        children.sort(by: DiskNode.order)
        var keep = 0
        while keep < min(children.count, 100), children[keep].size > 0, children[keep].size * 1000 >= size { keep += 1 }
        guard keep < children.count else { return }
        let rest = children[keep...]
        let r = DiskNode("\(rest.count) smaller items", .rest, rest.reduce(0) { $0 + $1.size })
        children.removeSubrange(keep...)
        if r.size > 0 { r.parent = self; children.append(r) }
    }

    /// Walks a folder without leaving its volume, counting a hard-linked file once. Its subfolders named in reuse
    /// aren't walked: those nodes are taken as they are. Reports (files, bytes) every 20,000 files.
    static func scan(_ root: String, reuse: [String: DiskNode] = [:], progress: (Int, Int64) -> Void) -> DiskNode? {
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(root), nil]
        defer { free(argv[0]) }
        guard let fts = fts_open(argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return nil }  // NOCHDIR: our cwd is the shells'
        defer { fts_close(fts) }
        var open: [DiskNode] = [], done: DiskNode?, linked = Set<UInt64>(), files = 0, bytes: Int64 = 0
        func close(to level: Int) {  // once fts reaches an entry at some level, every open folder at that level or deeper is complete
            while open.count > level {
                let n = open.removeLast()
                n.finish()
                if let p = open.last { p.add(n) } else { done = n }
            }
        }
        let nameAt = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name)!
        while let e = fts_read(fts) {
            let level = Int(e.pointee.fts_level), info = Int32(e.pointee.fts_info)
            close(to: level)  // a folder's post-order visit (FTS_DP, or FTS_DNR if it couldn't be read) closes it here
            guard [FTS_D, FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT].contains(info) else { continue }
            let st = e.pointee.fts_statp.pointee, size = Int64(st.st_blocks) * 512
            let name = level == 0 ? root : String(cString: (UnsafeRawPointer(e) + nameAt).assumingMemoryBound(to: CChar.self))
            if info == FTS_D {
                if level == 1, let old = reuse[name] { fts_set(fts, e, FTS_SKIP); open.last?.add(old) } else { open.append(DiskNode(name, .folder, size)) }
                continue
            }
            if st.st_nlink > 1, !linked.insert(st.st_ino).inserted { continue }
            open.last?.add(DiskNode(name, .file, size))
            files += 1; bytes += size
            if files % 20000 == 0 { progress(files, bytes) }
        }
        close(to: 0)
        return done
    }

    /// Scans this folder again: all of it (deep), or keeping the subfolders it has. Its ancestors' sizes follow.
    private func rescan(deep: Bool, progress: (Int, Int64) -> Void) {
        let reuse = deep ? [:] : Dictionary(children.filter { $0.kind == .folder }.map { ($0.name, $0) }) { a, _ in a }
        guard let fresh = DiskNode.scan(path, reuse: reuse, progress: progress) else { return }  // gone: its parent changed too, and drops it
        let delta = fresh.size - size
        children = fresh.children
        for k in children { k.parent = self }
        var n: DiskNode? = self
        while let x = n { x.size += delta; x.parent?.children.sort(by: DiskNode.order); n = x.parent }
    }

    /// Brings a scan up to date from FSEvents' log of the folders changed since an event: each is scanned again, deepest
    /// first, keeping the subfolders it has (the changed ones among them done by then). Without the log, all of it.
    static func update(_ tree: DiskNode, since id: FSEventStreamEventId, progress: (Int, Int64) -> Void) -> DiskNode? {
        guard let events = changes(tree.name, since: id) else { return scan(tree.name, progress: progress) }
        var targets: [ObjectIdentifier: (node: DiskNode, deep: Bool)] = [:]
        for (p, deep) in events {
            // the log's paths go through the firmlinks: /Users, not /System/Volumes/Data/Users
            guard let n = tree.find(p.hasPrefix(tree.name) || tree.name != DiskUsage.dataVolume ? p : tree.name + p) else { continue }
            let k = ObjectIdentifier(n)
            targets[k] = (n, deep || targets[k]?.deep == true)
        }
        if targets[ObjectIdentifier(tree)]?.deep == true { return scan(tree.name, progress: progress) }
        func above(_ n: DiskNode) -> [DiskNode] { var a: [DiskNode] = [], x = n; while let p = x.parent { a.append(p); x = p }; return a }
        let deep = Set(targets.values.filter(\.deep).map { ObjectIdentifier($0.node) }), depth = targets.mapValues { above($0.node).count }
        for (_, t) in targets.sorted(by: { depth[$0.key]! > depth[$1.key]! })
            where !above(t.node).contains(where: { deep.contains(ObjectIdentifier($0)) }) {  // a deep rescan above covers it
            t.node.rescan(deep: t.deep, progress: progress)
        }
        return tree
    }

    /// The folders FSEvents logged changes in under a path since an event, each with whether it says to rescan all of
    /// it (it merged or dropped events); nil without a log to go on.
    private static func changes(_ root: String, since id: FSEventStreamEventId) -> [(String, Bool)]? {
        final class Log { var events: [(String, Bool)] = [], finished = false; let done = DispatchSemaphore(value: 0) }
        let log = Log(), q = DispatchQueue(label: "fsevents")
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(log).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        guard let s = FSEventStreamCreate(nil, { _, info, n, paths, flags, _ in
            let log = Unmanaged<Log>.fromOpaque(info!).takeUnretainedValue(), ps = unsafeBitCast(paths, to: NSArray.self) as! [String]
            let all = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
            for i in 0..<n where !log.finished {
                if flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { log.finished = true; log.done.signal() }
                else { log.events.append((ps[i], flags[i] & all != 0)) }
            }
        }, &ctx, [root] as CFArray, id, 0, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return nil }
        FSEventStreamSetDispatchQueue(s, q)
        FSEventStreamStart(s)
        let ok = log.done.wait(timeout: .now() + 30) == .success
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        return ok ? q.sync { log.events } : nil
    }
}

/// The chart: the folder in the middle, its contents in rings around it, each one's share of the circle its share of
/// the bytes, clockwise from the top. Hue follows the angle, so a folder's contents share its color.
final class Sunburst: NSView {
    var folder: DiskNode? { didSet { hovered = nil; needsDisplay = true } }
    private(set) var hovered: DiskNode? { didSet { if hovered !== oldValue { needsDisplay = true; onHover() } } }
    var onHover = {}, onClick: (DiskNode) -> Void = { _ in }, onMenu: (DiskNode) -> NSMenu? = { _ in nil }
    private let rings = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The centre, the middle circle's radius and each ring's width.
    private var geometry: (o: CGPoint, r0: CGFloat, w: CGFloat) {
        let r = max(min(bounds.width, bounds.height) / 2 - 12, 60)
        return (CGPoint(x: bounds.midX, y: bounds.midY), r * 0.22, r * 0.78 / CGFloat(rings))
    }

    /// t: where the item's middle is, as a fraction of the circle.
    static func color(_ n: DiskNode, _ t: Double, _ depth: Int) -> NSColor {
        n.kind == .rest ? .systemGray : NSColor(hue: t * 0.85, saturation: 0.45 + 0.07 * CGFloat(depth), brightness: 1 - 0.07 * CGFloat(depth), alpha: 1)
    }

    override func draw(_ dirty: NSRect) {
        guard let folder, let c = NSGraphicsContext.current?.cgContext else { return }
        let (o, r0, w) = geometry
        func angle(_ t: Double) -> CGFloat { .pi / 2 - 2 * .pi * t }
        c.setStrokeColor(NSColor.windowBackgroundColor.cgColor)
        func ring(_ n: DiskNode, _ depth: Int, _ t0: Double, _ t1: Double) {
            guard depth <= rings, n.size > 0 else { return }
            let inner = r0 + CGFloat(depth - 1) * w
            var t = t0
            for k in n.children {
                let t2 = t + (t1 - t0) * Double(k.size) / Double(n.size)
                if (t2 - t) * 2 * .pi * Double(inner + w) >= 1 {  // at least a point wide
                    c.beginPath()
                    c.addArc(center: o, radius: inner + w, startAngle: angle(t), endAngle: angle(t2), clockwise: true)
                    c.addArc(center: o, radius: inner, startAngle: angle(t2), endAngle: angle(t), clockwise: false)
                    c.closePath()
                    let color = Sunburst.color(k, (t + t2) / 2, depth)
                    c.setFillColor((k === hovered ? color.blended(withFraction: 0.4, of: .white)! : color).cgColor)
                    c.drawPath(using: .fillStroke)
                    ring(k, depth + 1, t, t2)
                }
                t = t2
            }
        }
        ring(folder, 1, 0, 1)
        c.setFillColor((hovered === folder ? NSColor.unemphasizedSelectedContentBackgroundColor : NSColor.controlBackgroundColor).cgColor)
        c.fillEllipse(in: CGRect(x: o.x - r0, y: o.y - r0, width: 2 * r0, height: 2 * r0).insetBy(dx: 2, dy: 2))
        let s = NSAttributedString(string: diskSize(folder.size), attributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.labelColor])
        s.draw(at: CGPoint(x: o.x - s.size().width / 2, y: o.y - s.size().height / 2))
    }

    /// What's under a point: the folder itself in the middle, nil outside the rings.
    private func node(at p: CGPoint) -> DiskNode? {
        guard var n = folder else { return nil }
        let (o, r0, w) = geometry, d = hypot(p.x - o.x, p.y - o.y)
        if d < r0 { return n }
        let depth = Int((d - r0) / w) + 1
        guard depth <= rings else { return nil }
        var t = 0.25 - Double(atan2(p.y - o.y, p.x - o.x)) / (2 * .pi)
        t -= floor(t)
        for _ in 0..<depth {  // down the rings, t becoming a fraction of each child it falls in
            guard n.size > 0 else { return nil }
            var a = 0.0, hit: DiskNode?
            for k in n.children {
                let f = Double(k.size) / Double(n.size)
                if t < a + f { hit = k; t = (t - a) / f; break }
                a += f
            }
            guard let hit else { return nil }
            n = hit
        }
        return n
    }

    override func mouseMoved(with e: NSEvent) { hovered = node(at: convert(e.locationInWindow, from: nil)) }
    override func mouseExited(with e: NSEvent) { hovered = nil }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let n = node(at: p) { onClick(n); hovered = node(at: p) }
    }
    override func menu(for e: NSEvent) -> NSMenu? { node(at: convert(e.locationInWindow, from: nil)).flatMap(onMenu) }
}

/// The disk usage window: the chart, beside it the folder's contents largest first, and buttons to scan again or
/// scan another folder. Click a folder to look inside it, the middle to go back up; right-click to show it in Finder.
final class DiskUsage: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    static let shared = DiskUsage()
    static let dataVolume = "/System/Volumes/Data"  // the startup disk's files; "/" is the sealed system volume
    private let chart = Sunburst(), table = NSTableView(), path = NSPathControl()
    private let name = NSTextField(labelWithString: ""), size = NSTextField(labelWithString: ""), status = NSTextField(labelWithString: "")
    private let rescan = NSButton(title: "Rescan", target: nil, action: nil), other = NSButton(title: "Scan Folder…", target: nil, action: nil)
    private var root = dataVolume, scanning = false, rows: [(DiskNode, NSColor)] = []
    private var tree: DiskNode?, event: FSEventStreamEventId = 0  // the whole scan (a node only holds its parent unowned), and as of when
    private var folder: DiskNode? { didSet { show() } }

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: true)
        w.title = "Disk Usage"; w.isReleasedWhenClosed = false; w.contentMinSize = NSSize(width: 640, height: 400)
        super.init(window: w)
        w.delegate = self
        chart.onHover = { [unowned self] in describe() }
        chart.onClick = { [unowned self] in zoom($0) }
        chart.onMenu = { [unowned self] n in let m = NSMenu(); addReveal(n, to: m); return m }
        path.pathStyle = .standard; path.isEditable = false; path.target = self; path.action = #selector(pathClicked)
        name.font = .boldSystemFont(ofSize: 15); name.lineBreakMode = .byTruncatingMiddle
        size.textColor = .secondaryLabelColor; status.textColor = .secondaryLabelColor
        rescan.target = self; rescan.action = #selector(scanAgain)
        other.target = self; other.action = #selector(scanOther)
        for id in ["name", "size"] { table.addTableColumn(NSTableColumn(identifier: .init(id))) }
        table.tableColumns[1].width = 76
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = nil; table.style = .plain; table.selectionHighlightStyle = .none
        table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(rowClicked)
        table.menu = NSMenu(); table.menu!.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        table.backgroundColor = .clear

        let v = w.contentView!
        for x in [path, chart, name, size, scroll, rescan, status, other] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            path.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            path.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            path.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            chart.topAnchor.constraint(equalTo: path.bottomAnchor, constant: 8),
            chart.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: -8),
            chart.bottomAnchor.constraint(equalTo: rescan.topAnchor, constant: -10),
            name.topAnchor.constraint(equalTo: chart.topAnchor, constant: 4),
            name.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            name.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            size.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            size.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: size.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: chart.bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalToConstant: 320),
            rescan.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            rescan.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -12),
            status.leadingAnchor.constraint(equalTo: rescan.trailingAnchor, constant: 12),
            status.trailingAnchor.constraint(lessThanOrEqualTo: other.leadingAnchor, constant: -12),
            status.centerYAnchor.constraint(equalTo: rescan.centerYAnchor),
            other.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            other.centerYAnchor.constraint(equalTo: rescan.centerYAnchor),
        ])
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Brings the window up with the last scan (it's cached), and brings that up to date.
    func present() {
        showWindow(nil)
        guard !scanning else { return }
        if tree == nil, let c = DiskUsage.cached() { root = c.root; event = c.event; tree = c.tree; folder = c.tree }
        scanAgain()
    }

    @objc func closeTab(_ sender: Any?) { close() }  // ⌘W
    @objc private func scanAgain() {  // only the folders changed since the last scan
        guard let tree else { return scan(root) }
        let copy = tree.clone(), since = event  // the window keeps showing the old one meanwhile
        run(root) { DiskNode.update(copy, since: since, progress: $0) }
    }
    @objc private func scanOther() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Scan"
        p.beginSheetModal(for: window!) { if $0 == .OK, let u = p.url { self.scan(u.path) } }
    }
    private func scan(_ dir: String) { run(dir) { DiskNode.scan(dir, progress: $0) } }

    /// Scans off the main thread, its progress below the chart, then shows the result in the same folder and caches it.
    private func run(_ dir: String, _ work: @escaping (_ progress: (Int, Int64) -> Void) -> DiskNode?) {
        root = dir; scanning = true; rescan.isEnabled = false; other.isEnabled = false
        let v = try? URL(fileURLWithPath: dir).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        window?.subtitle = v.map { "\(diskSize($0.volumeAvailableCapacityForImportantUsage ?? 0)) free of \(diskSize(Int64($0.volumeTotalCapacity ?? 0)))" } ?? ""
        let start = Date(), id = FSEventsGetCurrentEventId()  // what changes from here on, the next update rescans
        func took() -> String { let s = Int(Date().timeIntervalSince(start)); return String(format: "%d:%02d", s / 60, s % 60) }
        status.stringValue = "Scanning…"
        DispatchQueue.global(qos: .userInitiated).async {
            let tree = work { files, bytes in
                DispatchQueue.main.async { self.status.stringValue = "Scanning… \(files.formatted()) files, \(diskSize(bytes)), \(took())" }
            }
            if let tree { DiskUsage.save(Cache(root: dir, event: id, tree: tree)) }
            DispatchQueue.main.async {
                self.scanning = false; self.rescan.isEnabled = true; self.other.isEnabled = true
                let at = self.folder?.path
                self.tree = tree; self.event = id
                self.folder = at.flatMap { tree?.find($0) } ?? tree
                self.status.stringValue = tree.map { "\(diskSize($0.size)), up to date in \(took())" } ?? "Can't read \(dir)"
            }
        }
    }

    /// The last scan, kept between launches.
    private struct Cache: Codable { var root: String, event: FSEventStreamEventId, tree: DiskNode }
    private static let cacheFile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iTherm/disk.plist")
    private static func cached() -> Cache? { (try? Data(contentsOf: cacheFile)).flatMap { try? PropertyListDecoder().decode(Cache.self, from: $0) } }
    private static func save(_ c: Cache) {
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? e.encode(c).write(to: cacheFile, options: .atomic)
    }

    private func title(_ n: DiskNode) -> String {
        n.parent != nil ? n.name : FileManager.default.displayName(atPath: n.name == DiskUsage.dataVolume ? "/" : n.name)
    }

    private func show() {
        chart.folder = folder
        let chain = folder.map { Array(sequence(first: $0, next: { $0.parent }).reversed()) } ?? []
        path.pathItems = chain.map { n in let i = NSPathControlItem(); i.title = title(n); return i }
        var t = 0.0
        rows = (folder?.children ?? []).map { k in
            let f = Double(k.size) / Double(max(folder!.size, 1))
            defer { t += f }
            return (k, Sunburst.color(k, t + f / 2, 1))
        }
        table.reloadData()
        describe()
    }

    /// The hovered item's name and size above the list, or the folder's.
    private func describe() {
        let n = chart.hovered ?? folder
        name.stringValue = n.map(title) ?? ""
        size.stringValue = n.map { diskSize($0.size) } ?? ""
    }

    private func zoom(_ n: DiskNode) {
        if n === folder { if let p = n.parent { folder = p } } else if n.kind == .folder { folder = n }
    }

    @objc private func pathClicked() {
        guard let item = path.clickedPathItem, let i = path.pathItems.firstIndex(of: item), var n = folder else { return }
        for _ in i + 1 ..< path.pathItems.count { n = n.parent! }
        folder = n
    }

    @objc private func rowClicked() { if rows.indices.contains(table.clickedRow) { zoom(rows[table.clickedRow].0) } }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let (n, color) = rows[row], l = NSTextField(labelWithString: diskSize(n.size)), font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        if col?.identifier.rawValue == "size" { l.alignment = .right; l.textColor = .secondaryLabelColor; return l }
        let s = NSMutableAttributedString(string: "● ", attributes: [.font: font, .foregroundColor: color])
        s.append(NSAttributedString(string: n.name, attributes: [.font: font, .foregroundColor: n.kind == .rest ? NSColor.secondaryLabelColor : .labelColor]))
        l.attributedStringValue = s; l.lineBreakMode = .byTruncatingMiddle
        return l
    }

    func menuNeedsUpdate(_ m: NSMenu) {  // the list's right-click menu
        m.removeAllItems()
        if rows.indices.contains(table.clickedRow) { addReveal(rows[table.clickedRow].0, to: m) }
    }

    private func addReveal(_ n: DiskNode, to m: NSMenu) {
        let i = m.addItem(withTitle: "Show in Finder", action: #selector(reveal), keyEquivalent: "")
        i.target = self; i.representedObject = n
    }

    @objc private func reveal(_ i: NSMenuItem) {
        guard let n = i.representedObject as? DiskNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (n.kind == .rest ? n.parent! : n).path)])
    }
}

// MARK: - App: menu bar + settings window

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: NSWindow?
    private let fontPop = NSPopUpButton(), themePop = NSPopUpButton(), sizeStep = NSStepper()
    private let fanCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let boldCheck = NSButton(checkboxWithTitle: "Bold text in the bright colors", target: nil, action: nil)
    private let metaCheck = NSButton(checkboxWithTitle: "Option is Meta (sends Esc + the key)", target: nil, action: nil)
    private let fanStart = NSSlider(value: 0, minValue: 50, maxValue: 90, target: nil, action: nil)
    private let fanSpeed = NSSlider(value: 0, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: ""), startLabel = NSTextField(labelWithString: "")
    private let speedLabel = NSTextField(labelWithString: "")

    func applicationWillTerminate(_ n: Notification) {  // closing the last window saves none: it was closed on purpose
        UserDefaults.standard.set(try? JSONEncoder().encode(TermView.all.map(\.session)), forKey: "session")
    }

    @objc func showSettings(_ sender: Any?) {
        if settings == nil {
            let fm = NSFontManager.shared
            fontPop.addItem(withTitle: "System Monospaced")
            fontPop.addItems(withTitles: fm.availableFontFamilies.filter {
                fm.font(withFamily: $0, traits: [], weight: 5, size: 12)?.isFixedPitch == true
            })
            if !Prefs.font.isEmpty { fontPop.selectItem(withTitle: Prefs.font) }
            sizeStep.minValue = 8; sizeStep.maxValue = 36; sizeStep.doubleValue = Prefs.fontSize
            themePop.addItems(withTitles: themes.map(\.name))
            themePop.selectItem(at: Prefs.theme)
            syncFanCheck()
            boldCheck.state = Prefs.boldBright ? .on : .off
            metaCheck.state = Prefs.optionMeta ? .on : .off
            fanStart.integerValue = Prefs.fanStart; fanSpeed.integerValue = Prefs.fanSpeed
            for s in [fanStart, fanSpeed] { s.widthAnchor.constraint(equalToConstant: 180).isActive = true }
            labels()
            for c in [fontPop, sizeStep, themePop, fanCheck, fanStart, fanSpeed, boldCheck, metaCheck] as [NSControl] { c.target = self; c.action = #selector(changed) }
            let grid = NSGridView(views: [
                [NSTextField(labelWithString: "Font:"), fontPop],
                [NSTextField(labelWithString: "Size:"), NSStackView(views: [sizeStep, sizeLabel])],
                [NSTextField(labelWithString: "Theme:"), themePop],
                [NSTextField(labelWithString: "Text:"), boldCheck],
                [NSTextField(labelWithString: "Keys:"), metaCheck],
                [NSTextField(labelWithString: "Fans:"), fanCheck],
                [NSTextField(labelWithString: "Start at:"), NSStackView(views: [fanStart, startLabel])],
                [NSTextField(labelWithString: "Up to:"), NSStackView(views: [fanSpeed, speedLabel])],
            ])
            grid.column(at: 0).xPlacement = .trailing
            grid.rowAlignment = .lastBaseline
            let vc = NSViewController()
            vc.view = NSView()
            vc.view.addSubview(grid)
            grid.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                grid.topAnchor.constraint(equalTo: vc.view.topAnchor, constant: 20),
                grid.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor, constant: -20),
                grid.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 20),
                grid.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -20),
            ])
            let w = NSWindow(contentViewController: vc)
            w.title = "Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settings = w
        }
        settings?.makeKeyAndOrderFront(nil)
    }

    @objc func changed(_ sender: Any?) {
        let d = UserDefaults.standard
        d.set(fontPop.indexOfSelectedItem == 0 ? "" : fontPop.titleOfSelectedItem, forKey: "font")
        d.set(sizeStep.doubleValue, forKey: "fontSize")
        d.set(themePop.indexOfSelectedItem, forKey: "theme")
        d.set(fanStart.integerValue, forKey: "fanStart")
        d.set(fanSpeed.integerValue, forKey: "fanSpeed")
        d.set(boldCheck.state == .on, forKey: "boldBright")
        d.set(metaCheck.state == .on, forKey: "optionMeta")
        if sender as? NSButton === fanCheck {  // only then: a locked-out instance must not switch it off for the other
            d.set(fanCheck.state == .on, forKey: "fanControl")
            monitor.control(fanCheck.state == .on)
        }
        labels()
        for v in TermView.all { v.applySettings() }
    }

    func syncFanCheck() {
        fanCheck.isEnabled = !monitor.locked
        fanCheck.state = Prefs.fanControl && !monitor.locked ? .on : .off
        fanCheck.title = monitor.locked ? "Disabled: another iTherm instance has the fan lock" : "Ramp up when hot (asks for admin password)"
    }

    private func labels() {
        sizeLabel.stringValue = "\(Int(sizeStep.doubleValue)) pt"
        startLabel.stringValue = "\(fanStart.integerValue)°C"
        speedLabel.stringValue = "\(fanSpeed.integerValue)% by \(fanStart.integerValue + 15)°C"
    }
}

func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let m = NSMenuItem()
    m.submenu = NSMenu(title: title)
    for i in items { m.submenu!.addItem(i) }
    return m
}

func item(_ title: String, _ action: Selector, _ key: String, _ target: AnyObject? = nil) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
    i.target = target  // nil: goes to the focused terminal view
    return i
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--fan-helper" { fanHelper(CommandLine.arguments[2]) }

for v in ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID"] { unsetenv(v) }  // don't inherit the launching terminal's identity
setenv("TERM", "xterm-256color", 1)
setenv("COLORTERM", "truecolor", 1)  // what makes vim, bat, delta and friends use 24-bit color
let lang = getenv("LANG").map { String(cString: $0) } ?? ""
if !lang.lowercased().contains("utf-8") { setenv("LANG", "en_US.UTF-8", 1) }  // a C locale, or none at all, would turn our UTF-8 into ?
setlocale(LC_CTYPE, "en_US.UTF-8")  // so wcwidth knows about wide characters

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.mainMenu = NSMenu()
let machinesItem = item("Show/Hide Machines", #selector(TermView.toggleMachines), "s")
machinesItem.keyEquivalentModifierMask = [.command, .control]
for m in [
    menu("iTherm", [item("Settings…", #selector(AppDelegate.showSettings), ",", delegate), .separator(),
                  item("Hide iTherm", #selector(NSApplication.hide), "h"), item("Quit iTherm", #selector(NSApplication.terminate), "q")]),
    menu("Shell", [item("New Tab", #selector(TermView.newTab), "t"), item("Close Tab", #selector(TermView.closeTab), "w"), .separator(),
                   item("Split Vertically", #selector(TermView.splitVertically), "d"), item("Split Horizontally", #selector(TermView.splitHorizontally), "D")]),
    menu("Edit", [item("Copy", #selector(TermView.copy(_:)), "c"), item("Paste", #selector(TermView.paste), "v"),
                  item("Select All", #selector(TermView.selectAll), "a")]),
    menu("Window", [item("Minimize", #selector(NSWindow.performMiniaturize), "m"), machinesItem, .separator(),
                    item("Previous Tab", #selector(TermView.prevTab), "{"), item("Next Tab", #selector(TermView.nextTab), "}")]),
] { app.mainMenu!.addItem(m) }

let monitor = Monitor()
TermView.restore()
app.activate(ignoringOtherApps: true)
app.run()
