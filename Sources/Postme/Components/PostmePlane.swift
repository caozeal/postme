import CoreGraphics

/// 纸飞机的两片折翼。应用图标与发送按钮共用坐标，原点在左上角。
enum PostmePlane {
    static func wings(in rect: CGRect) -> (upper: CGPath, lower: CGPath) {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }

        func wing(tail: CGPoint, fold: CGPoint) -> CGPath {
            let path = CGMutablePath()
            path.move(to: point(0.98, 0.04))
            path.addLine(to: tail)
            path.addLine(to: fold)
            path.closeSubpath()
            return path
        }

        return (
            upper: wing(tail: point(0.04, 0.59), fold: point(0.36, 0.66)),
            lower: wing(tail: point(0.59, 0.97), fold: point(0.42, 0.70))
        )
    }
}
