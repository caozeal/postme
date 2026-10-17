// 渲染 Postme 应用图标：深靛蓝圆角底 + 橙紫渐变纸飞机(折线即 <) + 尾迹 </>
// 用法: swift scripts/render_icon.swift
// 产物: build/AppIcon.iconset/*.png + docs/app-icon.png(1024 预览)
// 设计上所有图形按 1024 画布矢量绘制,再按各尺寸重渲染,保证小尺寸清晰。
import AppKit
import CoreText

let canvas: CGFloat = 1024

// MARK: - 配色
// 底色:深靛蓝 → 更深的蓝黑,对角渐变
let bgTop = CGColor(red: 0.165, green: 0.173, blue: 0.404, alpha: 1)      // #2A2C67
let bgBottom = CGColor(red: 0.070, green: 0.075, blue: 0.200, alpha: 1)   // #121333
// 纸飞机:机头橙(POST 的暖色) → 机尾紫,呼应「发送」与代码感
let planeNose = CGColor(red: 1.000, green: 0.690, blue: 0.360, alpha: 1)  // #FFB05C
let planeTail = CGColor(red: 0.660, green: 0.470, blue: 1.000, alpha: 1)  // #A878FF
// 尾迹 </>:浅薰衣草紫
let trailColor = CGColor(red: 0.812, green: 0.753, blue: 1.000, alpha: 1) // #CFC0FF

// MARK: - 绘制

func drawIcon(in ctx: CGContext, size: CGFloat) {
    // 小尺寸省略尾迹细节:16/32px 下 </> 只会糊成噪点,保留飞机主体保证辨识度
    let drawTrail = size >= 128
    ctx.saveGState()
    ctx.scaleBy(x: size / canvas, y: size / canvas)

    // 背景圆角矩形(macOS 图标圆角 ≈ 边长的 22.37%)
    let rect = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    let bgPath = CGPath(roundedRect: rect, cornerWidth: canvas * 0.2237,
                        cornerHeight: canvas * 0.2237, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()

    // 底色对角渐变(左上 → 右下)
    let bgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: [bgTop, bgBottom] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(bgGradient,
                           start: CGPoint(x: 0, y: canvas),
                           end: CGPoint(x: canvas, y: 0),
                           options: [])

    // 机头后方的紫色辉光,增加层次
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [planeTail.copy(alpha: 0.35)!,
                                   planeTail.copy(alpha: 0)!] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: 640, y: 660), startRadius: 0,
                           endCenter: CGPoint(x: 640, y: 660), endRadius: 520,
                           options: [])

    // ---- 纸飞机几何(1024 画布,CG 坐标 y 向上) ----
    let tip = CGPoint(x: 838, y: 786)   // 机头
    let left = CGPoint(x: 232, y: 296)  // 左后角
    let notch = CGPoint(x: 486, y: 392) // 尾翼内凹点(折痕起点)
    let right = CGPoint(x: 628, y: 234) // 右后角

    // 折痕方向(机尾 → 机头),用于渐变与折线
    let gradStart = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)

    // 左翼(亮面):tip → left → notch
    let leftWing = CGMutablePath()
    leftWing.move(to: tip)
    leftWing.addLine(to: left)
    leftWing.addLine(to: notch)
    leftWing.closeSubpath()

    // 右翼(暗面):tip → notch → right
    let rightWing = CGMutablePath()
    rightWing.move(to: tip)
    rightWing.addLine(to: notch)
    rightWing.addLine(to: right)
    rightWing.closeSubpath()

    // 亮面用正常渐变,暗面整体压暗 22%,形成折纸体积感
    let wingGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [planeTail, planeNose] as CFArray,
                                  locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(leftWing)
    ctx.clip()
    ctx.drawLinearGradient(wingGradient, start: gradStart, end: tip, options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(rightWing)
    ctx.clip()
    ctx.drawLinearGradient(wingGradient, start: gradStart, end: tip, options: [])
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0.15, alpha: 0.22))
    ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    ctx.restoreGState()

    // 折痕线:notch → tip,细白线强化「<」的折角意象
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
    ctx.setLineWidth(10)
    ctx.setLineCap(.round)
    ctx.move(to: notch)
    ctx.addLine(to: tip)
    ctx.strokePath()

    // ---- 尾迹 </> ----
    // 左下一枚 </>,加一段从机尾拖出的虚线航迹,像飞机拖出的代码
    if drawTrail {
        let trailPath = CGMutablePath()
        trailPath.move(to: CGPoint(x: 445, y: 350))
        trailPath.addQuadCurve(to: CGPoint(x: 330, y: 225),
                               control: CGPoint(x: 375, y: 285))
        ctx.setStrokeColor(trailColor.copy(alpha: 0.55)!)
        ctx.setLineWidth(14)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: [26, 24])
        ctx.addPath(trailPath)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 150, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: trailColor.copy(alpha: 0.95)!)!,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "</>",
                                                                       attributes: attrs))
        ctx.saveGState()
        ctx.textPosition = CGPoint(x: 130, y: 88)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    ctx.restoreGState()
}

// MARK: - 输出

func renderPNG(size: Int, to url: URL) {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("无法创建位图上下文") }
    drawIcon(in: ctx, size: s)
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { fatalError("无法写出 \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("写出失败 \(url.path)") }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Apple iconset 标准尺寸
let slots: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for slot in slots {
    renderPNG(size: slot.pixels, to: iconset.appendingPathComponent(slot.name))
}

// 1024 预览图供 README 使用
let docs = root.appendingPathComponent("docs", isDirectory: true)
try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
renderPNG(size: 1024, to: docs.appendingPathComponent("app-icon.png"))

print("已生成 \(iconset.path) 与 docs/app-icon.png")
