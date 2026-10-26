import SwiftUI
import UIKit
import CoreImage
import AVFoundation

// what sits behind the lyrics on a lyric card
enum CardBackground: String, CaseIterable, Identifiable {
    case solid, cover, artist
    var id: String { rawValue }
    var label: String {
        switch self {
        case .solid: return "colour"
        case .cover: return "album cover"
        case .artist: return "artist photo"
        }
    }
}

// everything a card is drawn from, as plain values, so the live preview and the shared image come from the exact same code
struct LyricCardSpec {
    var title: String
    var artist: String
    var lines: [String]
    var romanlines: [String]? = nil   // romanization of each line (same order, "" for a line without one); nil = romanization off
    var romanstyle = "replace"        // replace: romanized lines instead of the originals. below: a smaller line under each original
    var background: CardBackground
    var color: UIColor            // the solid colour (also what shows if the chosen picture isn't available)
    var blur: CGFloat             // gaussian radius in points on the 1080 px card; 0 = sharp
    var shade: CGFloat            // black overlay on top of a picture, 0...1
    var lyricsize: CGFloat
    var brand: Bool
    var cover: UIImage?           // album cover: the backdrop for .cover and the small thumbnail in the header
    var artistphoto: UIImage?     // backdrop for .artist

    var backdropimage: UIImage? {
        switch background {
        case .solid: return nil
        case .cover: return cover
        case .artist: return artistphoto ?? cover
        }
    }
}

enum LyricCardRenderer {
    private static let ci = CIContext(options: [.useSoftwareRenderer: false])

    // a square card. `side` is the pixel size (1080 for sharing, smaller for the preview); the layout is designed on a 1080
    // grid and scaled, so a preview looks exactly like the final image.
    static func render(_ s: LyricCardSpec, side: CGFloat = 1080) -> UIImage {
        let k = side / 1080
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let full = CGRect(origin: .zero, size: size)

        // a picture background gets the shade; a plain colour is shown exactly as chosen
        let bg = s.backdropimage
        // text is white on pictures, and flips to black on a light solid colour so it stays readable
        var fg = UIColor.white
        if bg == nil {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            s.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            if Settings.relluminance(Double(r), Double(g), Double(b)) > 0.45 { fg = UIColor(white: 0.06, alpha: 1) }
        }

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            s.color.setFill(); cg.fill(full)
            if let bg = bg {
                backdrop(bg, radius: s.blur * k, canvas: size).draw(in: full)
                UIColor.black.withAlphaComponent(s.shade).setFill(); cg.fill(full)
            }

            // content is laid out in 1080 space
            cg.scaleBy(x: k, y: k)
            let margin: CGFloat = 76
            if let art = s.cover {
                let rect = CGRect(x: margin, y: 70, width: 126, height: 126)
                cg.saveGState()
                UIBezierPath(roundedRect: rect, cornerRadius: 18).addClip()
                art.draw(in: AVMakeRect(aspectRatio: art.size, insideRect: rect))
                cg.restoreGState()
            }
            let headerX: CGFloat = s.cover == nil ? margin : 226
            draw(s.title, in: CGRect(x: headerX, y: 78, width: 1080 - headerX - margin, height: 58), font: .systemFont(ofSize: 36, weight: .bold), color: fg)
            draw(s.artist, in: CGRect(x: headerX, y: 137, width: 1080 - headerX - margin, height: 44), font: .systemFont(ofSize: 29, weight: .medium), color: fg.withAlphaComponent(0.74))

            var fontSize: CGFloat = min(s.lyricsize, s.lines.count >= 4 ? 56 : 76)
            let lyricRect = CGRect(x: margin, y: 260, width: 1080 - margin * 2, height: 650)
            // the whole block (originals and any romanized sub-lines) is measured together, so it always fits
            let floor: CGFloat = hasbelow(s) ? 26 : 38
            while fontSize > floor {
                if block(s, size: fontSize, color: fg).boundingRect(with: lyricRect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height <= lyricRect.height { break }
                fontSize -= 2
            }
            block(s, size: fontSize, color: fg).draw(with: lyricRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            if s.brand { draw("furmuse", in: CGRect(x: margin, y: 970, width: 400, height: 50), font: .systemFont(ofSize: 28, weight: .semibold), color: fg.withAlphaComponent(0.76)) }
        }
    }

    private static func hasbelow(_ s: LyricCardSpec) -> Bool {
        s.romanstyle == "below" && (s.romanlines ?? []).contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // the lyric text as one attributed block. replace swaps in the romanized lines; below puts a smaller, dimmer romanized
    // line under each original that has one. without romanization this is the plain bold text it always was.
    private static func block(_ s: LyricCardSpec, size: CGFloat, color: UIColor) -> NSAttributedString {
        let romans = s.romanlines ?? []
        func roman(_ i: Int) -> String { i < romans.count ? romans[i].trimmingCharacters(in: .whitespaces) : "" }
        let out = NSMutableAttributedString()
        func add(_ text: String, font: UIFont, color: UIColor, after: CGFloat, last: Bool) {
            let p = paragraph(lineSpacing: 8); p.paragraphSpacing = after
            out.append(NSAttributedString(string: text + (last ? "" : "\n"), attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p]))
        }
        let main = UIFont.systemFont(ofSize: size, weight: .bold)
        let sub = UIFont.systemFont(ofSize: size * 0.58, weight: .semibold)
        for (i, line) in s.lines.enumerated() {
            let last = i == s.lines.count - 1
            let r = roman(i)
            if s.romanstyle == "below", !r.isEmpty {
                add(line, font: main, color: color, after: 2, last: false)
                add(r, font: sub, color: color.withAlphaComponent(0.7), after: last ? 0 : size * 0.3, last: last)
            } else if s.romanstyle == "replace", !r.isEmpty {
                add(r, font: main, color: color, after: 0, last: last)
            } else {
                add(line, font: main, color: color, after: 0, last: last)
            }
        }
        return out
    }

    // the picture, scaled to fill the card and then gaussian blurred. the edges are clamped before blurring, so the blur
    // never fades to transparent or dark at the border, and a radius of 0 gives the sharp picture.
    static func backdrop(_ image: UIImage, radius: CGFloat, canvas: CGSize) -> UIImage {
        let up = image.normalizedup()
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
        let filled = UIGraphicsImageRenderer(size: canvas, format: f).image { _ in
            UIColor.black.setFill(); UIRectFill(CGRect(origin: .zero, size: canvas))
            up.draw(in: aspectfill(up.size, canvas))
        }
        guard radius > 0.5, let input = CIImage(image: filled), let filter = CIFilter(name: "CIGaussianBlur") else { return filled }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let out = filter.outputImage?.cropped(to: input.extent), let result = ci.createCGImage(out, from: input.extent) else { return filled }
        return UIImage(cgImage: result)
    }

    private static func aspectfill(_ image: CGSize, _ canvas: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: canvas) }
        let scale = max(canvas.width / image.width, canvas.height / image.height)
        let result = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (canvas.width - result.width) / 2, y: (canvas.height - result.height) / 2, width: result.width, height: result.height)
    }

    private static func paragraph(lineSpacing: CGFloat) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle(); p.lineSpacing = lineSpacing; p.lineBreakMode = .byWordWrapping
        return p
    }

    private static func draw(_ string: String, in rect: CGRect, font: UIFont, color: UIColor, lineSpacing: CGFloat = 0) {
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                  attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph(lineSpacing: lineSpacing)], context: nil)
    }
}

extension UIColor {
    // "#RRGGBB" (the form lyric card colours are saved in); anything unreadable is black
    convenience init(hexstring: String) {
        var v: UInt64 = 0
        Scanner(string: hexstring.trimmingCharacters(in: CharacterSet(charactersIn: "# "))).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    var hexstring: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
