import SwiftUI
import Combine
import NaturalLanguage
import UIKit

// MARK: text helpers

// small helpers shared by the sync editor, the paste sheet and the lyrics file importer
enum LyricsText {
    static func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    // [mm:ss], [mm:ss.xx] and [mm:ss:xx] line tags
    static func hastimestamps(_ s: String) -> Bool {
        guard let tag = try? NSRegularExpression(pattern: "\\[\\d+:\\d+(?:[.:]\\d+)?\\]") else { return false }
        return tag.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    // the words only: line tags, <mm:ss.xx> word tags and [ar:...] / [offset:...] header lines are removed, gaps are kept
    static func stripped(_ s: String) -> String {
        let timetag = try? NSRegularExpression(pattern: "\\[\\d+:\\d+(?:[.:]\\d+)?\\]|<\\d+:\\d+(?:[.:]\\d+)?>")
        let header = try? NSRegularExpression(pattern: "^\\s*\\[[A-Za-z]+:[^\\]]*\\]\\s*$")
        var out: [String] = []
        for raw in normalized(s).components(separatedBy: "\n") {
            let full = NSRange(location: 0, length: (raw as NSString).length)
            if header?.firstMatch(in: raw, range: full) != nil { continue }
            let line = (timetag?.stringByReplacingMatches(in: raw, range: full, withTemplate: "") ?? raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty, out.last?.isEmpty != false { continue }       // no leading or doubled gaps
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    // the file type to save: ttml when the file name or the content says so, lrc otherwise (plain words are read as unsynced lrc)
    static func ext(for text: String, filename: String) -> String {
        if ["ttml", "xml", "dfxp"].contains(filename.lowercased()) { return "ttml" }
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300).lowercased()
        if head.hasPrefix("<?xml") || head.hasPrefix("<tt ") || head.hasPrefix("<tt>") { return "ttml" }
        return "lrc"
    }

    static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if let s = String(data: data, encoding: .utf8) { return normalized(s) }
        var converted: NSString?
        let found = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil)
        if found != 0, let s = converted as String? { return normalized(s) }
        return nil
    }

    static func notify(lyricson: Bool) {
        ToastCenter.shared.show(lyricson ? "lyrics saved" : "lyrics saved. they are off right now, turn them on in settings to see them")
    }

    // MARK: clocks

    static func clock(_ t: Double) -> String {
        let cs = max(0, Int((t * 100).rounded()))
        return String(format: "%d:%02d.%02d", cs / 6000, (cs % 6000) / 100, cs % 100)
    }
    static func lrcstamp(_ t: Double) -> String {
        let cs = max(0, Int((t * 100).rounded()))
        return String(format: "%02d:%02d.%02d", cs / 6000, (cs % 6000) / 100, cs % 100)
    }
    static func ttmlclock(_ t: Double) -> String {
        let ms = max(0, Int((t * 1000).rounded()))
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    // MARK: words

    // scripts written without spaces between words need a dictionary tokenizer to be stampable word by word
    private static func needsdictionary(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            switch u.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,      // kana
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,      // han
                 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF:      // thai / lao, myanmar, khmer
                return true
            default: return false
            }
        }
    }

    // the stampable words of one line. every token keeps the spaces and punctuation after it, so the tokens always join back
    // into the original line (leading punctuation rides on the first token).
    static func tokens(_ line: String, language: LyricLanguage) -> [String] {
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return [] }
        if needsdictionary(s) {
            let tk = NLTokenizer(unit: .word)
            tk.string = s
            switch language {
            case .japanese: tk.setLanguage(.japanese)
            case .chinese: tk.setLanguage(.simplifiedChinese)
            default: break
            }
            var ranges: [Range<String.Index>] = []
            tk.enumerateTokens(in: s.startIndex..<s.endIndex) { r, _ in ranges.append(r); return true }
            guard !ranges.isEmpty else { return [s] }
            return ranges.enumerated().map { i, r in
                let from = i == 0 ? s.startIndex : r.lowerBound
                let to = i + 1 < ranges.count ? ranges[i + 1].lowerBound : s.endIndex
                return String(s[from..<to])
            }
        }
        let parts = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return parts.enumerated().map { i, p in i + 1 < parts.count ? p + " " : p }
    }
}

// MARK: paste lyrics

struct LyricPasteSheet: View {
    let track: Track
    @EnvironmentObject var lyrics: LyricsStore
    @EnvironmentObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""

    private var blank: Bool { pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $pasted).padding(8)
                Text("plain words are saved as unsynced lyrics. lrc or ttml text keeps its timing.")
                    .font(.footnote).foregroundColor(.secondary).padding(.horizontal)
                Button("save") {
                    let text = LyricsText.normalized(pasted)
                    Task { @MainActor in
                        await lyrics.save(text, ext: LyricsText.ext(for: text, filename: ""), for: track)
                        LyricsText.notify(lyricson: settings.lyricson)
                        dismiss()
                    }
                }
                .disabled(blank)
                .frame(maxWidth: .infinity).padding()
            }
            .themed().navigationTitle("paste lyrics").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("cancel") { dismiss() } } }
        }.navigationViewStyle(.stack)
    }
}

// MARK: sync editor

private struct SyncUnit {
    var line: Int          // index into the editor's rows
    var text: String       // a whole line (line mode) or one word with the spaces after it (word mode)
    var key: String        // what must stay the same for an old stamp to still apply
}

// song position and transport controls. a separate view so the clock ticking does not redraw the whole editor
private struct SyncTransport: View {
    @ObservedObject var engine: PlaybackEngine
    @State private var pos = 0.0
    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text(LyricsText.clock(pos)).font(.system(size: 36, weight: .semibold, design: .monospaced))
                if engine.duration > 0 { Text("of \(fmttime(engine.duration))").font(.caption).foregroundColor(.secondary) }
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 40) {
                Spacer()
                Button { engine.seek(engine.livepos() - 5) } label: { Image(systemName: "gobackward.5") }
                    .accessibilityLabel("back 5 seconds")
                Button { engine.toggle() } label: { Image(systemName: engine.isplaying ? "pause.fill" : "play.fill").font(.system(size: 30)) }
                    .accessibilityLabel(engine.isplaying ? "pause" : "play")
                Button { engine.seek(engine.livepos() + 5) } label: { Image(systemName: "goforward.5") }
                    .accessibilityLabel("forward 5 seconds")
                Spacer()
            }
            .font(.title)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .onAppear { pos = engine.livepos() }
        .onReceive(ticker) { _ in pos = engine.livepos() }
    }
}

// a recording desk for lyrics made by the listener: paste the words, then stamp each line or word while the song plays.
// it writes ordinary lrc (enhanced lrc for words) or ttml, so the result stays portable.
struct LyricSyncEditor: View {
    let track: Track
    let engine: PlaybackEngine                 // not observed here on purpose: SyncTransport does that, this form stays still
    @EnvironmentObject var lyrics: LyricsStore
    @EnvironmentObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0                // 0 = text, 1 = stamping
    @State private var text = ""
    @State private var seeded = false
    @State private var format = "lrc"
    @State private var mode = "line"
    @State private var rows: [String] = []     // the lyric lines, "" = a gap between stanzas
    @State private var units: [SyncUnit] = []
    @State private var builtmode = ""
    @State private var stamps: [Double] = []   // one time per stamped unit, in order; the cursor is stamps.count
    @State private var pressed = false
    @State private var askimport = false
    @State private var askrestart = false
    @State private var askdiscard = false

    private var haslyrics: Bool { LyricsText.normalized(text).split(separator: "\n").contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    private var done: Bool { !units.isEmpty && stamps.count == units.count }

    var body: some View {
        NavigationView {
            Group {
                if step == 0 { inputstep } else { stampstep }
            }
            .navigationTitle("sync lyrics").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if step == 0 { Button("cancel") { if stamps.isEmpty { dismiss() } else { askdiscard = true } } }
                    else { Button("edit text") { step = 0 } }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if step == 1 { Button("save") { save() }.disabled(!done) }
                }
            }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(!stamps.isEmpty)
        .onAppear { seed() }
        .confirmationDialog("this text has timestamps", isPresented: $askimport, titleVisibility: .visible) {
            Button("import it as it is") { importraw() }
            Button("remove timestamps and stamp it again") { text = LyricsText.stripped(text); begin() }
            Button("cancel", role: .cancel) {}
        }
        .confirmationDialog("clear all stamps?", isPresented: $askrestart, titleVisibility: .visible) {
            Button("restart", role: .destructive) { stamps = []; engine.seek(0) }
            Button("cancel", role: .cancel) {}
        }
        .confirmationDialog("discard your stamps?", isPresented: $askdiscard, titleVisibility: .visible) {
            Button("discard", role: .destructive) { dismiss() }
            Button("keep working", role: .cancel) {}
        }
    }

    // MARK: step 1: text

    private var inputstep: some View {
        Form {
            Section(header: Text("lyrics"),
                    footer: Text("one lyric per line. a blank line leaves a gap between stanzas and is never stamped. pasted lrc text can be imported as it is.")) {
                TextEditor(text: $text).frame(minHeight: 240)
            }
            Section("how to sync") {
                Picker("sync", selection: $mode) { Text("line by line").tag("line"); Text("word by word").tag("word") }.pickerStyle(.segmented)
                Picker("save as", selection: $format) { Text("lrc").tag("lrc"); Text("ttml").tag("ttml") }.pickerStyle(.segmented)
            }
            Section(footer: Text("word by word saves enhanced lrc or ttml word timing. save without timing keeps the words as plain unsynced lyrics.")) {
                Button("start syncing") { start() }.disabled(!haslyrics)
                Button("save without timing") { saveplain() }.disabled(!haslyrics)
            }
        }
        .themed()
    }

    private func seed() {
        guard !seeded else { return }
        seeded = true
        if let doc = lyrics.doc(for: track.id), !doc.lines.isEmpty {
            text = doc.lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
        }
    }

    private func start() {
        if LyricsText.hastimestamps(text) { askimport = true; return }
        begin()
    }

    // build the rows and stampable units from the text. stamps stay for the unchanged start of the text, the rest is dropped
    private func begin() {
        var r: [String] = []
        for raw in LyricsText.normalized(text).components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty, r.last?.isEmpty != false { continue }
            r.append(l)
        }
        while r.last?.isEmpty == true { r.removeLast() }
        let language = LyricRomanizer.language(of: r.joined(separator: "\n"))
        var u: [SyncUnit] = []
        for (i, row) in r.enumerated() where !row.isEmpty {
            if mode == "word" {
                for tok in LyricsText.tokens(row, language: language) { u.append(SyncUnit(line: i, text: tok, key: row + "\u{1}" + tok)) }
            } else {
                u.append(SyncUnit(line: i, text: row, key: row))
            }
        }
        guard !u.isEmpty else { return }
        var keep = 0
        if builtmode == mode {
            while keep < stamps.count, keep < u.count, keep < units.count, units[keep].key == u[keep].key { keep += 1 }
        }
        if keep < stamps.count {
            stamps = Array(stamps.prefix(keep))
            ToastCenter.shared.show("some stamps were cleared because the text changed")
        }
        rows = r; units = u; builtmode = mode
        step = 1
    }

    private func saveplain() {
        let plain = LyricsText.stripped(text)
        guard !plain.isEmpty else { return }
        Task { @MainActor in
            await lyrics.save(plain, ext: "lrc", for: track)
            LyricsText.notify(lyricson: settings.lyricson)
            dismiss()
        }
    }

    private func importraw() {
        let raw = LyricsText.normalized(text)
        Task { @MainActor in
            await lyrics.save(raw, ext: LyricsText.ext(for: raw, filename: ""), for: track)
            LyricsText.notify(lyricson: settings.lyricson)
            dismiss()
        }
    }

    // MARK: step 2: stamping

    private var stampstep: some View {
        Form {
            Section("song position") { SyncTransport(engine: engine) }
            Section(header: Text(done ? "done" : mode == "word" ? "next word" : "next line"),
                    footer: Text(mode == "word" ? "press stamp the moment each word starts." : "press stamp the moment each line starts.")) {
                upcoming
            }
            Section(footer: Text("tap a stamped item to go back to it.")) {
                HStack {
                    Button("undo last stamp") { undo() }.disabled(stamps.isEmpty)
                    Spacer()
                    Button("restart", role: .destructive) { askrestart = true }.disabled(stamps.isEmpty)
                }
                .buttonStyle(.borderless)
            }
            Section("stamped") { stampedlist }
        }
        .themed()
        .safeAreaInset(edge: .bottom) { stampbutton }
    }

    @ViewBuilder
    private var upcoming: some View {
        if stamps.count < units.count {
            let start = units[stamps.count].line
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(start..<min(rows.count, start + 7)), id: \.self) { i in
                    if rows[i].isEmpty {
                        Color.clear.frame(height: 8)
                    } else if i == start {
                        (mode == "word" ? wordtext(i) : Text(rows[i])).font(.title3.weight(.semibold))
                    } else {
                        Text(rows[i]).foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        } else {
            Text("all stamped. check the list below, then save.").foregroundColor(.secondary)
        }
    }

    // the line being stamped word by word: stamped words dim, the next word is highlighted, the rest stays normal
    private func wordtext(_ line: Int) -> Text {
        unitindices(line).reduce(Text("")) { acc, i in
            let w = Text(units[i].text)
            if i < stamps.count { return acc + w.foregroundColor(.secondary) }
            if i == stamps.count { return acc + w.foregroundColor(.accentColor).fontWeight(.bold) }
            return acc + w
        }
    }

    private func unitindices(_ line: Int) -> Range<Int> {
        guard let a = units.firstIndex(where: { $0.line == line }) else { return 0..<0 }
        var b = a
        while b < units.count, units[b].line == line { b += 1 }
        return a..<b
    }

    @ViewBuilder
    private var stampedlist: some View {
        if stamps.isEmpty {
            Text("nothing stamped yet").foregroundColor(.secondary)
        } else if mode == "line" {
            ForEach(Array(stamps.indices.reversed()), id: \.self) { i in
                Button { goback(to: i) } label: {
                    HStack {
                        Text(units[i].text).lineLimit(1)
                        Spacer()
                        Text(LyricsText.clock(stamps[i])).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    }
                }
                .foregroundColor(.primary)
            }
        } else {
            ForEach(Array(stampedlines.reversed()), id: \.self) { li in
                let range = unitindices(li)
                Button { goback(to: range.lowerBound) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rows[li]).lineLimit(1)
                            Text("\(min(stamps.count, range.upperBound) - range.lowerBound) of \(range.count) words")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(LyricsText.clock(stamps[range.lowerBound])).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    }
                }
                .foregroundColor(.primary)
            }
        }
    }

    // the rows that have at least one stamped word, in order
    private var stampedlines: [Int] {
        var seen: [Int] = []
        for i in stamps.indices where seen.last != units[i].line { seen.append(units[i].line) }
        return seen
    }

    // stamps on touch down rather than on release, so the time is the moment the finger lands
    private var stampbutton: some View {
        VStack(spacing: 2) {
            Text(done ? "all stamped" : "stamp").font(.title2.weight(.bold))
            if stamps.count < units.count {
                Text(units[stamps.count].text.trimmingCharacters(in: .whitespaces)).font(.footnote).lineLimit(1).opacity(0.85)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20)
        .foregroundColor(.white)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(done ? Color.gray : Color.accentColor).opacity(pressed ? 0.7 : 1))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !pressed { pressed = true; stamp() } }
            .onEnded { _ in pressed = false })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(done ? "all stamped" : "stamp")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { stamp() }
    }

    private func stamp() {
        guard stamps.count < units.count else { return }
        guard engine.current?.id == track.id else {
            ToastCenter.shared.show("the song changed. close this and open sync lyrics again")
            return
        }
        let now = engine.livepos()
        if let last = stamps.last, now < last - 0.001 {
            ToastCenter.shared.show("that is before the last stamp. undo it or play on")
            return
        }
        stamps.append(now)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func undo() {
        guard let t = stamps.popLast() else { return }
        engine.seek(max(0, t - 2))
    }

    // the cursor goes back to a stamped item; the song jumps a little before it so it can be stamped again
    private func goback(to i: Int) {
        guard i < stamps.count else { return }
        let t = stamps[i]
        stamps.removeLast(stamps.count - i)
        engine.seek(max(0, t - 2))
    }

    // MARK: saving

    // lines with their times. a word ends where the next word starts; the last word of a line gets a short tail (it never runs past
    // the next line); a line ends where the next line starts and the very last line gets a short fixed tail.
    private func build() -> [LyricLine] {
        let linetail = 3.0, wordtail = 1.5
        var out: [LyricLine] = []
        if mode == "word" {
            var i = 0
            while i < units.count {
                let li = units[i].line
                var j = i
                while j < units.count, units[j].line == li { j += 1 }
                let words = (i..<j).map { LyricWord(time: stamps[$0], end: stamps[$0], text: units[$0].text) }
                out.append(LyricLine(time: stamps[i], end: stamps[i], text: words.map(\.text).joined(), words: words))
                i = j
            }
        } else {
            for (i, u) in units.enumerated() { out.append(LyricLine(time: stamps[i], end: stamps[i], text: u.text, words: [])) }
        }
        out = out.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        for i in out.indices {
            let nextline: Double? = i + 1 < out.count ? out[i + 1].time : nil
            for k in out[i].words.indices {
                let start = out[i].words[k].time
                if k + 1 < out[i].words.count {
                    out[i].words[k].end = max(start, out[i].words[k + 1].time)
                } else {
                    out[i].words[k].end = max(start, nextline.map { min($0, start + wordtail) } ?? start + wordtail)
                }
            }
            out[i].end = max(out[i].time, nextline ?? (out[i].words.isEmpty ? out[i].time + linetail : (out[i].words.last?.end ?? out[i].time + linetail)))
        }
        return out
    }

    private func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private func lrctext(_ lines: [LyricLine]) -> String {
        lines.map { line in
            var s = "[\(LyricsText.lrcstamp(line.time))]"
            if line.words.isEmpty { return s + line.text }
            s += line.words.map { "<\(LyricsText.lrcstamp($0.time))>\($0.text)" }.joined()
            if let last = line.words.last { s += "<\(LyricsText.lrcstamp(last.end))>" }     // closing tag: the end of the last word
            return s
        }.joined(separator: "\n")
    }

    private func ttmltext(_ lines: [LyricLine]) -> String {
        let body = lines.map { line -> String in
            let inner = line.words.isEmpty ? xml(line.text)
                : line.words.map { "<span begin=\"\(LyricsText.ttmlclock($0.time))\" end=\"\(LyricsText.ttmlclock($0.end))\">\(xml($0.text))</span>" }.joined()
            return "<p begin=\"\(LyricsText.ttmlclock(line.time))\" end=\"\(LyricsText.ttmlclock(line.end))\">\(inner)</p>"
        }.joined(separator: "\n")
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div>\n\(body)\n</div></body></tt>"
    }

    private func save() {
        guard done else { return }
        let lines = build()
        let out = format == "ttml" ? ttmltext(lines) : lrctext(lines)
        let ext = format
        Task { @MainActor in
            await lyrics.save(out, ext: ext, for: track)
            LyricsText.notify(lyricson: settings.lyricson)
            dismiss()
        }
    }
}
