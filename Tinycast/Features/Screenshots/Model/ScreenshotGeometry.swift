import CoreGraphics

nonisolated enum ScreenshotGeometry {
    static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    static func captureRectangle(_ rectangle: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rectangle.minX, y: primaryTop - rectangle.maxY,
               width: rectangle.width, height: rectangle.height)
    }
}
