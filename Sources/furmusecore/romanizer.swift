import Foundation
import NaturalLanguage

enum LyricLanguage { case japanese, chinese, korean, other }

// romanization for lyrics. the language is decided once per song (from all of its text), japanese goes through CFStringTokenizer
// for contextual hepburn readings, everything else through the system latin transform. results are cached on the doc by
// LyricsStore (LyricLine.roman / LyricWord.roman), so no view ever calls this while drawing.
enum LyricRomanizer {
    // MARK: scripts

    static func isnonlatin(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        guard v >= 0x0370 else { return false }                         // latin, latin extended, ipa, combining marks
        if v >= 0x1E00 && v <= 0x1EFF { return false }                  // latin extended additional (vietnamese)
        if v >= 0x2000 && v <= 0x2BFF { return false }                  // punctuation, symbols, arrows
        if v >= 0x3000 && v <= 0x303F { return false }                  // cjk punctuation
        if v >= 0xFF00 && v <= 0xFF65 { return false }                  // fullwidth latin and punctuation
        if v >= 0x1F000 { return false }                                // emoji
        return CharacterSet.letters.contains(u)
    }

    static func needsroman(_ s: String) -> Bool { s.unicodeScalars.contains(where: isnonlatin) }

    static func language(of text: String) -> LyricLanguage {
        var kana = 0, hangul = 0, han = 0
        for u in text.unicodeScalars {
            switch u.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: han += 1
            default: break
            }
        }
        if hangul > 0, hangul >= kana { return .korean }
        if kana > 0 { return .japanese }
        if han > 0 {
            let r = NLLanguageRecognizer()
            r.processString(String(text.prefix(4000)))
            return r.dominantLanguage == .japanese ? .japanese : .chinese
        }
        return .other
    }

    // MARK: text

    private static func clean(_ s: String) -> String {
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformStripCombiningMarks, false)
        var r = m as String
        r = r.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        r = r.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func generic(_ s: String) -> String {
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformToLatin, false)
        return clean(m as String)
    }

    // contextual japanese readings: one entry per token, text outside tokens (punctuation) kept as its own entry
    private static func jatokens(_ s: String) -> [(range: NSRange, text: String)] {
        let ns = s as NSString
        let tok = CFStringTokenizerCreate(kCFAllocatorDefault, s as CFString, CFRangeMake(0, ns.length),
                                          kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja_JP") as CFLocale)
        var out: [(range: NSRange, text: String)] = []
        var covered = 0
        func gap(to end: Int) {
            guard end > covered else { return }
            let g = ns.substring(with: NSRange(location: covered, length: end - covered)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !g.isEmpty { out.append((NSRange(location: covered, length: end - covered), g)) }
        }
        while CFStringTokenizerAdvanceToNextToken(tok) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            let nr = NSRange(location: r.location, length: r.length)
            guard nr.location >= covered, nr.location + nr.length <= ns.length else { continue }
            gap(to: nr.location)
            let original = ns.substring(with: nr)
            var latin = original
            if let a = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String, !a.isEmpty { latin = a }
            // standalone particles are read as they are spoken
            if original == "は" { latin = "wa" } else if original == "を" { latin = "o" } else if original == "へ" { latin = "e" }
            out.append((nr, latin))
            covered = nr.location + nr.length
        }
        gap(to: ns.length)
        return out
    }

    // one line of text. latin-only text comes back unchanged
    static func line(_ s: String, _ lang: LyricLanguage) -> String {
        guard needsroman(s) else { return s }
        let r: String
        if lang == .japanese { r = clean(jatokens(s).map { $0.text }.joined(separator: " ")) }
        else { r = generic(s) }
        return r.isEmpty ? s : r
    }

    // per-word romanization for a timed line. japanese: tokenize the whole line (context), then give each word the tokens that start
    // inside it. anything that can't be aligned falls back to romanizing each word with the song's language
    private static func wordroman(_ words: [LyricWord], linetext: String, _ lang: LyricLanguage) -> [LyricWord] {
        guard !words.isEmpty else { return words }
        var parts: [String]?
        if lang == .japanese {
            let ns = linetext as NSString
            let tokens = jatokens(linetext)
            var cursor = 0
            var ranges: [NSRange] = []
            var ok = true
            for w in words {
                let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { ranges.append(NSRange(location: cursor, length: 0)); continue }
                let r = ns.range(of: t, options: [], range: NSRange(location: cursor, length: ns.length - cursor))
                if r.location == NSNotFound { ok = false; break }
                ranges.append(r)
                cursor = r.location + r.length
            }
            if ok {
                parts = ranges.map { r in
                    clean(tokens.filter { $0.range.location >= r.location && $0.range.location < r.location + r.length }.map { $0.text }.joined(separator: " "))
                }
            }
        }
        let romans = parts ?? words.map { line($0.text.trimmingCharacters(in: .whitespacesAndNewlines), lang) }
        var out = words
        for i in out.indices {
            let r = romans[i].trimmingCharacters(in: .whitespacesAndNewlines)
            let base = r.isEmpty ? out[i].text.trimmingCharacters(in: .whitespacesAndNewlines) : r
            out[i].roman = i + 1 < out.count ? base + " " : base          // romanized words always get a space between them
        }
        return out
    }

    // fills roman on every line (and word, and ad-lib line) that has non-latin script. nil when the song is latin only
    static func annotate(_ doc: LyricsDoc) -> LyricsDoc? {
        var sample = ""
        for l in doc.lines { sample += l.text + "\n"; if let b = l.background { sample += b + "\n" } }
        guard needsroman(sample) else { return nil }
        let lang = language(of: sample)
        var out = doc
        for i in out.lines.indices {
            var l = out.lines[i]
            if needsroman(l.text) {
                let r = line(l.text, lang)
                if r != l.text {
                    l.roman = r
                    l.words = wordroman(l.words, linetext: l.text, lang)
                }
            }
            if let b = l.background, needsroman(b) { l.backgroundroman = line(b, lang) }
            out.lines[i] = l
        }
        return out
    }
}
