// The terminal parser's self-test, run by scripts/parser-selftest.sh.
//
// The script glues this to the front of itherm.swift (everything up to the Monitor, which wants the running app)
// and runs the result as one file: in one file an extension may use Term's private members, which is how these
// tests feed escape sequences straight into the parser and look at the grid afterwards.
//
// Note: the OSC 52 case writes to your clipboard.

import AppKit

extension Term {
    func feed(_ s: String) { for b in Array(s.utf8) { byte(b) } }
    func frameEnds() -> Bool { frameEnd() }
    var penCopy: Cell { pen }
    var cellAt: Cell { g[cy][max(0, cx - 1)] }  // the cell just written
}

var failed = 0
func check(_ what: String, _ got: Any?, _ want: Any?) {
    let (g, w) = (String(describing: got), String(describing: want))
    if g != w { print("FAIL \(what): got \(g), want \(w)"); failed += 1 } else { print("ok   \(what)") }
}

setlocale(LC_CTYPE, "en_US.UTF-8")  // the app does this at startup; wcwidth needs it
let t = Term(cols: 20, rows: 5)
let E = "\u{1b}"

func sgr(_ s: String) { t.feed(E + "[\(s)m"); t.feed("x") }
func penReset() { t.feed(E + "[0m") }

// colors: 16, 256 and 24-bit, in the semicolon and the colon spelling
penReset(); sgr("38;2;10;20;30"); check("38;2;r;g;b", t.cellAt.fg, 0x0a141e)
penReset(); sgr("38:2::10:20:30"); check("38:2::r:g:b", t.cellAt.fg, 0x0a141e)
penReset(); sgr("38:2:10:20:30"); check("38:2:r:g:b", t.cellAt.fg, 0x0a141e)
penReset(); sgr("38:2:0:20:30"); check("a red channel of 0 is not a color id", t.cellAt.fg, 0x00141e)
penReset(); sgr("48;2;1;2;3"); check("48;2 sets the background", t.cellAt.bg, 0x010203)
penReset(); sgr("38;2;0;0;0"); check("truecolor black", t.cellAt.fg, 0x000000)
penReset(); sgr("38;2;0;0;0;1"); check("truecolor black, then bold: color", t.cellAt.fg, 0x000000); check("truecolor black, then bold: bold", t.cellAt.bold, true)
penReset(); sgr("38;2;0;20;30;1"); check("a red of 0, then bold: color", t.cellAt.fg, 0x00141e); check("a red of 0, then bold: bold", t.cellAt.bold, true)
penReset(); sgr("38:2::0:20:30"); check("38:2::r:g:b with a red of 0", t.cellAt.fg, 0x00141e)
penReset(); sgr("38;5;196"); check("38;5;196", t.cellAt.fg, 0x400_0000 | 196)
penReset(); sgr("38:5:196"); check("38:5:196", t.cellAt.fg, 0x400_0000 | 196)
penReset(); sgr("31"); check("red", t.cellAt.fg, 0x400_0000 | 1)
penReset(); sgr("91"); check("bright red", t.cellAt.fg, 0x400_0000 | 9)
penReset(); sgr("101"); check("bright red background", t.cellAt.bg, 0x400_0000 | 9)
penReset(); sgr("31;39"); check("39 back to the default foreground", t.cellAt.fg, 0x100_0000)
penReset(); sgr("48;2;1;2;3;49"); check("49 back to the default background", t.cellAt.bg, 0x200_0000)
penReset(); sgr("38;2;255;0;0;48;5;4;1m"); let two = t.cellAt
check("two colors and an attribute in one SGR, fg", two.fg, 0xff0000)
check("two colors and an attribute in one SGR, bg", two.bg, 0x400_0000 | 4)
check("two colors and an attribute in one SGR, bold", two.bold, true)
t.feed(E + "[H" + E + "[2J"); penReset(); sgr("31"); t.feed(E + "[m"); t.feed("y"); check("a bare CSI m resets", t.cellAt.fg, 0x100_0000)

// attributes
penReset(); sgr("1;2;3;4;9;7"); let c = t.penCopy
check("bold", c.bold, true); check("faint", c.faint, true); check("italic", c.italic, true)
check("underline", c.ul, 1); check("strike", c.strike, true); check("inverse", c.inverse, true)
penReset(); sgr("1;3;9;22;23;29"); let d = t.penCopy
check("22 clears bold", d.bold, false); check("23 clears italic", d.italic, false); check("29 clears strike", d.strike, false)
penReset(); sgr("2;22"); check("22 clears faint too", t.penCopy.faint, false)
penReset(); sgr("24"); check("24 clears the underline", t.penCopy.ul, 0)
penReset(); sgr("4;0"); check("0 clears the underline with everything else", t.penCopy.ul, 0)

// underline styles: 4:n, where n belongs to the 4 and is not the next attribute
penReset(); sgr("4"); check("4 is a single underline", t.penCopy.ul, 1)
penReset(); sgr("4:3"); check("4:3 is a curly underline", t.penCopy.ul, 3)
penReset(); sgr("4:3"); check("4:3 is not italic as well", t.penCopy.italic, false)
penReset(); sgr("4:2"); check("4:2 is a double underline", t.penCopy.ul, 2)
penReset(); sgr("4:4"); check("4:4 is a dotted underline", t.penCopy.ul, 4)
penReset(); sgr("4:5"); check("4:5 is a dashed underline", t.penCopy.ul, 5)
penReset(); sgr("4:0"); check("4:0 clears the underline", t.penCopy.ul, 0)
penReset(); sgr("4:9"); check("a style beyond 5 is clamped to dashed", t.penCopy.ul, 5)
penReset(); sgr("21"); check("21 is xterm's double underline", t.penCopy.ul, 2)
penReset(); sgr("4:3;38:5:9"); check("a style then a color: the style", t.penCopy.ul, 3)
check("a style then a color: the color", t.penCopy.fg, 0x400_0000 | 9)
penReset(); sgr("58:5:4"); check("a colored underline (58) is skipped whole", t.penCopy.ul, 0)
penReset(); sgr("58:5:4"); check("and does not set a color either", t.penCopy.fg, 0x100_0000)
penReset(); sgr("58;5;4"); check("58;5;n in the semicolon form: the n is not an underline style", t.penCopy.ul, 0)
penReset(); sgr("58;5;1"); check("58;5;n in the semicolon form: the n is not bold", t.penCopy.bold, false)
penReset(); sgr("58;2;0;0;0;1"); check("58;2 with a zero red, then bold: bold", t.penCopy.bold, true)
penReset(); sgr("58;2;0;0;0;4"); check("58;2 with a zero red, then underline", t.penCopy.ul, 1)

// DECSCUSR: the cursor shape vim asks for per mode
t.feed(E + "[3q"); check("CSI 3q is an underline", t.cursorStyle, 3)
t.feed(E + "[6q"); check("CSI 6q is a bar", t.cursorStyle, 6)
t.feed(E + "[q"); check("CSI q is the default block", t.cursorStyle, 0)
t.feed(E + "[>0q"); check("CSI >q (XTGETTCAP) leaves the shape alone", t.cursorStyle, 0)

// OSC 4/10/11: a program recoloring the palette or the background
t.feed(E + "]4;1;#ff8000\u{7}"); check("OSC 4 #rrggbb", t.pal[1], 0xff8000 as UInt32)
t.feed(E + "]4;2;rgb:10/20/30\u{1b}\\"); check("OSC 4 rgb:rr/gg/bb", t.pal[2], 0x102030 as UInt32)
t.feed(E + "]4;4;rgb:1000/2000/3000\u{7}"); check("OSC 4 with 16-bit parts", t.pal[4], 0x102030)
t.feed(E + "]4;5;rgb:1/2/3\u{7}"); check("OSC 4 with 4-bit parts", t.pal[5], 0x112233)
t.feed(E + "]11;rgb:ff/80/00\u{7}"); check("OSC 11 sets the background", t.dbg, 0xff8000 as UInt32)
t.feed(E + "]11;?\u{7}"); check("OSC 11 ? asks, it does not reset", t.dbg, 0xff8000 as UInt32)
t.feed(E + "]111\u{7}"); check("OSC 111 gives it back", t.dbg == nil, true)
t.feed(E + "]4;3;#ffffff\u{7}"); t.feed(E + "]104\u{7}"); check("OSC 104 resets the palette", t.pal[3] == nil, true)
t.feed(E + "]0;my title\u{7}"); check("OSC 0 sets the title", t.title, "my title")

// OSC 52: how a program reached over ssh fills the clipboard
t.feed(E + "]52;c;\(Data("hello clipboard".utf8).base64EncodedString())\u{7}")
check("OSC 52 sets the clipboard", NSPasteboard.general.string(forType: .string) ?? "nil", "hello clipboard")

// 1048 saves and restores the cursor on its own
t.feed(E + "[10;10H"); t.feed(E + "[?1048h"); t.feed(E + "[1;1H")
t.feed(E + "[?1048l"); check("1048 restores the cursor", "\(t.cy),\(t.cx)", "4,9")

// 1004 focus reporting and 2026 synchronized output
t.feed(E + "[?1004h"); check("1004 asks for focus events", t.focusReport, true)
t.feed(E + "[?1004l"); check("and turning it off stops them", t.focusReport, false)
t.feed(E + "[?2026h"); check("2026 holds the frame", t.sync, true)
check("the draw is held while it is on", t.frameEnds(), false)
for _ in 0..<8 { _ = t.frameEnds() }
check("but a program that never clears it does not freeze us", t.frameEnds(), true)
t.feed(E + "[?2026l"); check("leaving 2026 ends the frame", t.frameEnds(), true)
check("and releases the hold", t.sync, false)

// and the plain path still works
penReset(); t.feed("ab\rr"); check("carriage return", "\(t.cy),\(t.cx)", "4,1")
t.feed("😀"); check("an emoji takes two cells", t.cx, 3)

print(failed == 0 ? "\nall good" : "\n\(failed) FAILED")
exit(Int32(min(failed, 200)))
