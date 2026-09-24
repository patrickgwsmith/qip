import CoreGraphics
import CoreText
import Foundation

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let defaultFontPath = repositoryRoot
    .appendingPathComponent("fixtures/inter-4.1/InterVariable.ttf")
    .path
let fontPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultFontPath
let outputPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "gui/inter_18_ascii_bitmap.zig"
let fontURL = URL(fileURLWithPath: fontPath)

guard let provider = CGDataProvider(url: fontURL as CFURL),
      let cgFont = CGFont(provider) else {
    fatalError("failed to load font at \(fontPath)")
}

let fontSize: CGFloat = 18
let font = CTFontCreateWithGraphicsFont(cgFont, fontSize, nil, nil)
let start = 0x20
let end = 0x5A
let glyphW = 22
let glyphH = 25
let bytesPerGlyph = (glyphW * glyphH + 1) / 2
let ascent = CTFontGetAscent(font)
let baseline = Int(ceil(ascent)) + 2

var advances: [Int] = []
var glyphBytes: [[UInt8]] = []

for scalarValue in start...end {
    let scalar = UnicodeScalar(scalarValue)!
    let str = String(Character(scalar)) as CFString
    var uni = UniChar(scalarValue)
    var glyph = CGGlyph()
    CTFontGetGlyphsForCharacters(font, &uni, &glyph, 1)

    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
    advances.append(max(4, min(255, Int(ceil(advance.width)))))

    var pixels = [UInt8](repeating: 0, count: glyphW * glyphH)
    pixels.withUnsafeMutableBytes { ptr in
        guard let base = ptr.baseAddress else { return }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: base,
            width: glyphW,
            height: glyphH,
            bitsPerComponent: 8,
            bytesPerRow: glyphW,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return }
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: glyphW, height: glyphH))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.textMatrix = .identity

        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: str as String,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        ))
        ctx.textPosition = CGPoint(x: 1, y: baseline)
        CTLineDraw(line, ctx)
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

var out = ""
out += "// Generated from InterVariable.ttf using tools/generate-inter-bitmap.swift\n"
out += "// Coverage: U+0020..U+005A. Pixels are packed as 4-bit alpha nibbles.\n\n"
out += "pub const GLYPH_W: u32 = \(glyphW);\n"
out += "pub const GLYPH_H: u32 = \(glyphH);\n"
out += "pub const ASCII_START: u32 = 0x20;\n"
out += "pub const ASCII_END: u32 = 0x5A;\n"
out += "pub const GLYPH_COUNT: usize = \(end - start + 1);\n"
out += "pub const BYTES_PER_GLYPH: usize = \(bytesPerGlyph);\n"
out += "pub const advances = [_]u8{"
out += advances.map { String($0) }.joined(separator: ", ")
out += "};\n\n"
out += "pub const glyph_alpha4 = [_][BYTES_PER_GLYPH]u8{\n"
for bytes in glyphBytes {
    out += "    .{"
    out += bytes.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
    out += "},\n"
}
out += "};\n"

try out.write(toFile: outputPath, atomically: true, encoding: .utf8)
