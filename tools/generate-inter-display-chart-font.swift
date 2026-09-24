import CoreGraphics
import CoreText
import Foundation

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let fontPath = repositoryRoot
    .appendingPathComponent("fixtures/inter-4.1/ttf/InterDisplay-Regular.ttf")
    .path
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "components/interactive/assets/inter_display_chart_ascii.zig"

guard let provider = CGDataProvider(url: URL(fileURLWithPath: fontPath) as CFURL),
      let cgFont = CGFont(provider) else {
    fatalError("failed to load font at \(fontPath)")
}

let font = CTFontCreateWithGraphicsFont(cgFont, 28, nil, nil)
let codepoints = Array(UInt8(0x20)...UInt8(0x7E))
let glyphW = 36
let glyphH = 36
let bytesPerGlyph = (glyphW * glyphH + 1) / 2
let baseline: CGFloat = 7

var advances: [Int] = []
var glyphBytes: [[UInt8]] = []

for codepoint in codepoints {
    var character = UniChar(codepoint)
    var glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else {
        fatalError("missing glyph for \(codepoint)")
    }

    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
    advances.append(max(1, min(255, Int(ceil(advance.width)))))

    var pixels = [UInt8](repeating: 0, count: glyphW * glyphH)
    pixels.withUnsafeMutableBytes { ptr in
        guard let base = ptr.baseAddress,
              let context = CGContext(
                  data: base,
                  width: glyphW,
                  height: glyphH,
                  bitsPerComponent: 8,
                  bytesPerRow: glyphW,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else {
            fatalError("failed to create glyph bitmap")
        }
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: glyphW, height: glyphH))
        context.setFillColor(gray: 1, alpha: 1)
        if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
            context.translateBy(x: 1, y: baseline)
            context.addPath(path)
            context.fillPath()
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
output += "// Generated from fixtures/inter-4.1/ttf/InterDisplay-Regular.ttf.\n"
output += "// Regenerate with: swift tools/generate-inter-display-chart-font.swift\n"
output += "// Inter is licensed under SIL Open Font License 1.1; see fixtures/inter-4.1/LICENSE.txt.\n\n"
output += "pub const GLYPH_W: usize = \(glyphW);\n"
output += "pub const GLYPH_H: usize = \(glyphH);\n"
output += "pub const BYTES_PER_GLYPH: usize = \(bytesPerGlyph);\n"
output += "pub const ASCII_START: u8 = 0x20;\n"
output += "pub const ASCII_END: u8 = 0x7E;\n"
output += "pub const advances = [_]u8{"
output += advances.map(String.init).joined(separator: ", ")
output += "};\n\n"
output += "pub const glyph_alpha4 = [_][BYTES_PER_GLYPH]u8{\n"
for bytes in glyphBytes {
    output += "    .{\n"
    for offset in stride(from: 0, to: bytes.count, by: 24) {
        output += "        "
        output += bytes[offset..<min(offset + 24, bytes.count)]
            .map { String(format: "0x%02X", $0) }
            .joined(separator: ", ")
        output += ",\n"
    }
    output += "    },\n"
}
output += "};\n"

try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
