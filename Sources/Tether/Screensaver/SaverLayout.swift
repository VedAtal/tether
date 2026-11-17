import CoreGraphics

/// Where the screens sit in the picture. Scene units have y up, and one unit is the height of the
/// band every screen shares, so anything within y ±0.5 shows on all of them. x 0 is the middle of
/// the most central screen. Scenes carry on past that in every direction.
struct SaverLayout {
    private let center: CGPoint
    private let unitsPerPoint: CGFloat

    /// `screens` are the screens' frames in the desktop's coordinates.
    init(screens: [CGRect]) {
        let desktop = screens.reduce(CGRect.null) { $0.union($1) }
        let central = screens.min { abs($0.midX - desktop.midX) < abs($1.midX - desktop.midX) } ?? desktop
        var band = (low: screens.map(\.minY).max() ?? 0, high: screens.map(\.maxY).min() ?? 1)
        // Screens stacked on top of each other share no band, so the central one stands in.
        if band.high - band.low < central.height / 4 { band = (central.minY, central.maxY) }
        center = CGPoint(x: central.midX, y: (band.low + band.high) / 2)
        unitsPerPoint = 1 / (band.high - band.low)
    }

    /// `frame`, in the desktop's coordinates, in scene units.
    func rect(of frame: CGRect) -> CGRect {
        CGRect(x: (frame.minX - center.x) * unitsPerPoint, y: (frame.minY - center.y) * unitsPerPoint,
               width: frame.width * unitsPerPoint, height: frame.height * unitsPerPoint)
    }
}
