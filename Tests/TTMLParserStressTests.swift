import Foundation

@main
enum TTMLParserStressTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("TTML test failed: \(message)") }
    }

    static func active(_ doc: LyricsDoc, at time: Double) -> [LyricLine] {
        doc.lines.filter { $0.time <= time && time < $0.end }
    }

    static func main() throws {
        let fixture = CommandLine.arguments.dropFirst().first ?? "/Users/aki/test.ttml"
        let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
        guard let doc = LyricsParser.ttml(data, source: "stress fixture") else {
            fatalError("TTML test failed: fixture did not parse")
        }

        require(doc.lines.count == 11, "all eleven paragraphs must survive parsing")
        require(Set(doc.lines.compactMap(\.agent)) == ["singer1", "singer2"], "both agent ids must be retained")
        require(Set(doc.lines.compactMap(\.agentName)) == ["ARIA", "ELLA"], "agent names must resolve")
        require(active(doc, at: 2.5).count == 2, "both intro singers must be active at 2.5s")
        require(active(doc, at: 7).count == 2, "background singer must coexist with lead")
        require(active(doc, at: 12.5).count == 3, "lead, second singer and ad-lib must overlap")
        require(active(doc, at: 17).count == 2, "long paragraph must remain active beside backing vocals")
        require(active(doc, at: 20).count == 2, "simultaneous ending paragraphs must both activate")

        let long = doc.lines.first { $0.text.contains("dreams") }
        require(long?.time == 14 && long?.end == 20, "explicit long-line duration must not be clipped")
        require(long?.text == "We are the dreams that never fade", "long paragraph text must remain complete")
        require(long?.words.count == 6, "all timed spans in the long paragraph must be retained")
        require(long?.words.map(\.text).joined() == long?.text, "timed rendering must contain the complete paragraph")
        require(long?.words.last?.end == 20, "last word must retain exact end precision")
        require(active(doc, at: 19.999).contains { $0.text.contains("dreams") }, "long line must remain active until declared end")
        require(active(doc, at: 20).allSatisfy { !$0.text.contains("dreams") }, "half-open intervals must end exactly on time")

        let nested = Data("""
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
          <p begin="1s" end="5s">And <span begin="1s" end="2s">every</span> <span begin="2s" end="3s">single</span> day
            <span xmlns:ttm="http://www.w3.org/ns/ttml#metadata" ttm:role="x-bg"><span begin="1.5s" end="3.5s">Ah- ah</span></span>
          </p>
        </div></body></tt>
        """.utf8)
        let nestedDoc = LyricsParser.ttml(nested, source: "nested")
        require(nestedDoc?.lines.first?.text == "And every single day", "untimed final words must not be discarded")
        require(nestedDoc?.lines.first?.words.map(\.text).joined() == nestedDoc?.lines.first?.text,
                "active word rendering must retain text outside timed spans")
        require(nestedDoc?.lines.first?.background == "Ah- ah", "small background line must be retained")
        require(nestedDoc?.lines.first?.backgroundwords?.map(\.text).joined() == nestedDoc?.lines.first?.background,
                "small background line must retain complete independent timing")
        require(abs((LyricsParser.clock("00:00:01:15", frameRate: 30) ?? 0) - 1.5) < 0.000_001,
                "frame clock timestamps must use the declared frame rate")

        print("TTML parser stress tests passed (\(doc.lines.count) paragraphs).")
    }
}
