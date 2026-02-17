import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct C {
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, a])!
    }
}

enum DetailLevel {
    case tiny
    case small
    case medium
    case large
}

struct IconRenderer {
    static func render(size: Int, to url: URL) throws {
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "CGContext failed"])
        }

        let s = CGFloat(size)
        let rect = CGRect(x: 0, y: 0, width: s, height: s)
        let detail = detailLevel(for: size)
        let iconRect = rect.insetBy(dx: s * 0.035, dy: s * 0.035)
        let corner = s * 0.19

        drawSoftShadow(ctx: ctx, rect: iconRect, corner: corner, size: s)

        let iconPath = CGPath(roundedRect: iconRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        ctx.addPath(iconPath)
        ctx.clip()

        drawNoteBody(ctx: ctx, rect: iconRect, detail: detail)
        drawTopBand(ctx: ctx, rect: iconRect, detail: detail)
        drawWave(ctx: ctx, rect: iconRect, detail: detail)

        if let image = ctx.makeImage(),
           let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else {
                throw NSError(domain: "Icon", code: 4, userInfo: [NSLocalizedDescriptionKey: "finalize failed"])
            }
        } else {
            throw NSError(domain: "Icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "image destination failed"])
        }
    }

    private static func detailLevel(for size: Int) -> DetailLevel {
        if size <= 32 { return .tiny }
        if size <= 64 { return .small }
        if size <= 256 { return .medium }
        return .large
    }

    private static func drawSoftShadow(ctx: CGContext, rect: CGRect, corner: CGFloat, size: CGFloat) {
        ctx.saveGState()
        ctx.setFillColor(C.rgb(0, 0, 0, 0.20))
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.006), blur: size * 0.03, color: C.rgb(0, 0, 0, 0.32))
        let shadowRect = rect.offsetBy(dx: 0, dy: -size * 0.01)
        let p = CGPath(roundedRect: shadowRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        ctx.addPath(p)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawNoteBody(ctx: CGContext, rect: CGRect, detail: DetailLevel) {
        let s = rect.width
        let cs = CGColorSpaceCreateDeviceRGB()

        let paperGrad = CGGradient(colorsSpace: cs, colors: [
            C.rgb(0.98, 0.94, 0.62),
            C.rgb(0.94, 0.88, 0.48)
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(
            paperGrad,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )

        let bottomLipH = s * (detail == .tiny ? 0.09 : 0.11)
        let bottomLip = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bottomLipH)
        let lipGrad = CGGradient(colorsSpace: cs, colors: [
            C.rgb(0.58, 0.52, 0.23, 1.0),
            C.rgb(0.46, 0.41, 0.18, 1.0)
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(
            lipGrad,
            start: CGPoint(x: bottomLip.minX, y: bottomLip.maxY),
            end: CGPoint(x: bottomLip.minX, y: bottomLip.minY),
            options: []
        )

        let lineAlpha: CGFloat = (detail == .tiny) ? 0.18 : 0.30
        let lineCount: Int = {
            switch detail {
            case .tiny: return 5
            case .small: return 8
            case .medium: return 11
            case .large: return 14
            }
        }()
        ctx.setStrokeColor(C.rgb(0.48, 0.64, 0.80, lineAlpha))
        ctx.setLineWidth(max(1.0, s * 0.0018))
        for i in 0..<lineCount {
            let y = rect.minY + bottomLipH + (rect.height - bottomLipH) * (CGFloat(i + 1) / CGFloat(lineCount + 2))
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        ctx.strokePath()

        if detail != .tiny {
            let marginX = rect.minX + rect.width * 0.145
            ctx.setStrokeColor(C.rgb(0.86, 0.47, 0.38, detail == .small ? 0.28 : 0.38))
            ctx.setLineWidth(max(1.0, s * 0.0022))
            ctx.move(to: CGPoint(x: marginX, y: rect.minY + bottomLipH))
            ctx.addLine(to: CGPoint(x: marginX, y: rect.maxY - s * 0.12))
            ctx.strokePath()
        }

        if detail == .large || detail == .medium {
            let textAlpha: CGFloat = detail == .medium ? 0.38 : 0.55
            let rows = detail == .medium ? 6 : 9
            let startX = rect.minX + rect.width * 0.47
            let maxW = rect.width * 0.44

            ctx.setStrokeColor(C.rgb(0.18, 0.13, 0.10, textAlpha))
            ctx.setLineCap(.round)
            ctx.setLineWidth(max(1.0, s * 0.0042))

            for i in 0..<rows {
                let y = rect.maxY - rect.height * (0.36 + CGFloat(i) * 0.074)
                let widthFactor = 0.82 + CGFloat((i + 1) % 3) * 0.08
                ctx.move(to: CGPoint(x: startX, y: y))
                ctx.addLine(to: CGPoint(x: startX + maxW * widthFactor, y: y))
            }
            ctx.strokePath()
        }
    }

    private static func drawTopBand(ctx: CGContext, rect: CGRect, detail: DetailLevel) {
        let s = rect.width
        let bandHeight = s * (detail == .tiny ? 0.20 : 0.24)
        let bandRect = CGRect(x: rect.minX, y: rect.maxY - bandHeight, width: rect.width, height: bandHeight)

        let cs = CGColorSpaceCreateDeviceRGB()
        let grad = CGGradient(colorsSpace: cs, colors: [
            C.rgb(0.99, 0.93, 0.48),
            C.rgb(0.92, 0.84, 0.30)
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: bandRect.minX, y: bandRect.maxY), end: CGPoint(x: bandRect.minX, y: bandRect.minY), options: [])

        ctx.setFillColor(C.rgb(1, 1, 1, detail == .tiny ? 0.14 : 0.20))
        ctx.fill(CGRect(x: bandRect.minX, y: bandRect.maxY - s * 0.018, width: bandRect.width, height: s * 0.012))

        ctx.setFillColor(C.rgb(0, 0, 0, detail == .tiny ? 0.12 : 0.18))
        ctx.fill(CGRect(x: bandRect.minX, y: bandRect.minY, width: bandRect.width, height: s * 0.006))
    }

    private static func drawWave(ctx: CGContext, rect: CGRect, detail: DetailLevel) {
        let s = rect.width
        let centerY = rect.midY - s * 0.01
        let leftX = rect.minX + s * 0.02
        let rightX = rect.maxX - s * 0.02

        let amplitudeScale: CGFloat = {
            switch detail {
            case .tiny: return 0.19
            case .small: return 0.22
            case .medium: return 0.24
            case .large: return 0.26
            }
        }()

        let wave = CGMutablePath()
        wave.move(to: CGPoint(x: leftX, y: centerY))

        let points: [(CGFloat, CGFloat)] = {
            switch detail {
            case .tiny:
                return [
                    (0.14, 0.10), (0.22, 0.36), (0.32, 0.68), (0.46, 0.92),
                    (0.58, 0.62), (0.70, 0.36), (0.82, 0.18), (0.92, 0.08)
                ]
            case .small:
                return [
                    (0.12, 0.08), (0.18, 0.24), (0.24, 0.52), (0.32, 0.44), (0.40, 0.88),
                    (0.48, 0.48), (0.56, 0.68), (0.64, 0.44), (0.72, 0.52), (0.80, 0.28), (0.90, 0.10)
                ]
            case .medium, .large:
                return [
                    (0.10, 0.06), (0.15, 0.22), (0.20, 0.42), (0.25, 0.20), (0.30, 0.58), (0.35, 0.34),
                    (0.40, 0.80), (0.46, 0.36), (0.52, 1.00), (0.58, 0.40), (0.64, 0.66), (0.70, 0.36),
                    (0.76, 0.52), (0.82, 0.26), (0.88, 0.14), (0.94, 0.06)
                ]
            }
        }()

        for (x, mag) in points {
            let px = rect.minX + rect.width * x
            let amp = rect.height * amplitudeScale * mag
            wave.addLine(to: CGPoint(x: px, y: centerY + amp))
            wave.addLine(to: CGPoint(x: px, y: centerY - amp))
        }
        wave.addLine(to: CGPoint(x: rightX, y: centerY))
        wave.closeSubpath()

        ctx.saveGState()
        ctx.addPath(wave)
        ctx.clip()
        let cs = CGColorSpaceCreateDeviceRGB()
        let grad = CGGradient(colorsSpace: cs, colors: [
            C.rgb(0.96, 0.35, 0.30),
            C.rgb(0.73, 0.10, 0.08)
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: rect.midX, y: centerY + rect.height * 0.24),
            end: CGPoint(x: rect.midX, y: centerY - rect.height * 0.24),
            options: []
        )
        ctx.restoreGState()

        ctx.addPath(wave)
        ctx.setStrokeColor(C.rgb(0.45, 0.06, 0.06, detail == .tiny ? 0.75 : 0.65))
        let lineWidth: CGFloat = {
            switch detail {
            case .tiny: return max(0.9, s * 0.004)
            case .small: return max(1.0, s * 0.003)
            case .medium, .large: return max(1.0, s * 0.0022)
            }
        }()
        ctx.setLineWidth(lineWidth)
        ctx.strokePath()
    }
}

let outDir = URL(fileURLWithPath: "/Users/tyamaji/Projects/voicememo_transcribe/VoiceMemoTranscriber/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in outputs {
    try IconRenderer.render(size: size, to: outDir.appendingPathComponent(name))
    print("generated \(name)")
}

let contents = """
{
  "images" : [
    { "idiom" : "mac", "size" : "16x16", "scale" : "1x", "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "size" : "16x16", "scale" : "2x", "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "size" : "32x32", "scale" : "1x", "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "size" : "32x32", "scale" : "2x", "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "1x", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "2x", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "1x", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "2x", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "1x", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "2x", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : {
    "version" : 1,
    "author" : "xcode"
  }
}
"""

try contents.data(using: .utf8)!.write(to: outDir.appendingPathComponent("Contents.json"))
print("generated Contents.json")
