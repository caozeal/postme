// 用法: make icon
// 各尺寸从同一矢量图形重绘，小尺寸为纸飞机留出更多空间。
import CoreGraphics
import Foundation
import ImageIO

private let canvas: CGFloat = 1024
private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

private func color(_ hex: UInt32, opacity: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: opacity)
}

private func linearGradient(_ colors: [CGColor], from start: CGPoint, to end: CGPoint, in ctx: CGContext) {
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: start, end: end,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

private func drawTrail(in ctx: CGContext) {
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(color(0xCFC0FF, opacity: 0.62))
    ctx.setLineWidth(9)
    ctx.setLineDash(phase: 0, lengths: [11, 18])
    ctx.move(to: CGPoint(x: 438, y: 625))
    ctx.addQuadCurve(to: CGPoint(x: 362, y: 721), control: CGPoint(x: 388, y: 665))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    ctx.setStrokeColor(color(0xCFC0FF))
    ctx.setLineWidth(13)
    ctx.move(to: CGPoint(x: 255, y: 732))
    ctx.addLine(to: CGPoint(x: 224, y: 750))
    ctx.addLine(to: CGPoint(x: 255, y: 768))
    ctx.move(to: CGPoint(x: 298, y: 723))
    ctx.addLine(to: CGPoint(x: 275, y: 777))
    ctx.move(to: CGPoint(x: 318, y: 732))
    ctx.addLine(to: CGPoint(x: 349, y: 750))
    ctx.addLine(to: CGPoint(x: 318, y: 768))
    ctx.strokePath()
}

private func drawIcon(in ctx: CGContext, size: Int) {
    let showsTrail = size >= 128
    let scale = CGFloat(size) / canvas
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: scale, y: -scale)

    let tile = CGRect(x: 92, y: 92, width: 840, height: 840)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 192, cornerHeight: 192, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -11 * scale), blur: 26 * scale,
                  color: color(0x090719, opacity: 0.36))
    ctx.setFillColor(color(0x161334))
    ctx.addPath(tilePath)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.addPath(tilePath)
    ctx.clip()
    linearGradient([color(0x2B285B), color(0x161334)],
                   from: CGPoint(x: tile.minX, y: tile.minY),
                   to: CGPoint(x: tile.midX, y: tile.maxY), in: ctx)
    let glowColors = [color(0x7861DE, opacity: 0.32), color(0x7861DE, opacity: 0)]
    let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors as CFArray, locations: nil)!
    let glowCenter = CGPoint(x: 663, y: 334)
    ctx.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0,
                           endCenter: glowCenter, endRadius: 500, options: [])
    ctx.setStrokeColor(color(0xB4A6FA, opacity: 0.34))
    ctx.setLineWidth(4)
    ctx.addPath(tilePath)
    ctx.strokePath()

    if showsTrail {
        drawTrail(in: ctx)
    }

    let plane = showsTrail
        ? CGRect(x: 229, y: 177, width: 606, height: 606)
        : CGRect(x: 194, y: 189, width: 640, height: 640)
    let wings = PostmePlane.wings(in: plane)
    let tail = CGPoint(x: plane.minX + plane.width * 0.26, y: plane.maxY)
    let nose = CGPoint(x: plane.maxX, y: plane.minY)

    ctx.saveGState()
    ctx.addPath(wings.upper)
    ctx.clip()
    linearGradient([color(0xAE87FF), color(0xF08BAA), color(0xFFB273)],
                   from: tail, to: nose, in: ctx)
    ctx.restoreGState()

    ctx.addPath(wings.lower)
    ctx.clip()
    linearGradient([color(0x8864F2), color(0xC575C5), color(0xFFAD73)],
                   from: tail, to: nose, in: ctx)
}

private func renderPNG(size: Int, to url: URL) {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("无法创建位图上下文") }

    drawIcon(in: ctx, size: size)
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { fatalError("无法写出 \(url.path)") }

    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("写出失败 \(url.path)") }
}

@main
enum RenderIcon {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let iconset = root.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        for points in [16, 32, 128, 256, 512] {
            renderPNG(size: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
            renderPNG(size: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
        }

        renderPNG(size: 1024, to: root.appendingPathComponent("docs/app-icon.png"))
        print("已生成 \(iconset.path) 与 docs/app-icon.png")
    }
}
