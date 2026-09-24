import CoreGraphics
import CoreText
import Foundation

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let defaultFontPath = repositoryRoot
    .appendingPathComponent("fixtures/inter-4.1/ttf/InterDisplay-Bold.ttf")
    .path
let fontPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultFontPath
let outputPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "gui/assets/inter_display_bold_chronograph_digits.zig"

guard let provider = CGDataProvider(url: URL(fileURLWithPath: fontPath) as CFURL),
      let cgFont = CGFont(provider) else {
    fatalError("failed to load font at \(fontPath)")
}

let fontSize: CGFloat = 28
let font = CTFontCreateWithGraphicsFont(cgFont, fontSize, nil, nil)
let codepoints = Array("013456".utf8)
let glyphW = 25
let glyphH = 38
let bytesPerGlyph = (glyphW * glyphH + 1) / 2
// Bitmap contexts use a bottom-left text origin. Digits rise from this baseline.
let baseline = 4

var advances: [Int] = []
var glyphBytes: [[UInt8]] = []

for codepoint in codepoints {
    var character = UniChar(codepoint)
    var glyph = CGGlyph()
    CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)

    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
    advances.append(max(1, min(255, Int(ceil(advance.width)))))

    var pixels = [UInt8](repeating: 0, count: glyphW * glyphH)
    pixels.withUnsafeMutableBytes { ptr in
        guard let base = ptr.baseAddress else { return }
        guard let context = CGContext(
            data: base,
            width: glyphW,
            height: glyphH,
            bitsPerComponent: 8,
            bytesPerRow: glyphW,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return }

        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: glyphW, height: glyphH))
        context.setFillColor(gray: 1, alpha: 1)
        if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
            context.saveGState()
            context.translateBy(x: 1, y: CGFloat(baseline))
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }
    }

    var packed = [UInt8](repeating: 0, count: bytesPerGlyph)
    for i in 0..<(glyphW * glyphH) {
        let nibble = UInt8((Int(pixels[i]) + 8) / 17)
        if (i & 1) == 0 {
            packed[i / 2] = nibble << 4
        } else {
            packed[i / 2] |= nibble
        }
    }
    glyphBytes.append(packed)
}

var output = ""
output += "// Generated from InterDisplay-Bold.ttf using tools/generate-inter-bold-chronograph-digits.swift\n"
output += "// Coverage: 0, 1, 3, 4, 5, 6. Pixels are packed as 4-bit alpha nibbles.\n\n"
output += "pub const GLYPH_W: usize = \(glyphW);\n"
output += "pub const GLYPH_H: usize = \(glyphH);\n"
output += "pub const BYTES_PER_GLYPH: usize = \(bytesPerGlyph);\n"
output += "pub const codepoints = [_]u8{"
output += codepoints.map { "'\(Character(UnicodeScalar($0)))'" }.joined(separator: ", ")
output += "};\n"
output += "pub const advances = [_]u8{"
output += advances.map(String.init).joined(separator: ", ")
output += "};\n\n"
output += "pub const glyph_alpha4 = [_][BYTES_PER_GLYPH]u8{\n"
for bytes in glyphBytes {
    output += "    .{"
    output += bytes.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
    output += "},\n"
}
output += "};\n"

try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
