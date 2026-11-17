import CoreGraphics

enum RailPlacement {
    static let screenInset: CGFloat = 8
    private static let rightInset: CGFloat = 3

    static func railFrame(in visible: CGRect, size: CGSize, fraction: Double?) -> CGRect {
        let centers = centerRange(for: size.height, in: visible)
        let centerY: CGFloat
        if let fraction, fraction.isFinite {
            let progress = CGFloat(min(1, max(0, fraction)))
            centerY = centers.lowerBound + progress * (centers.upperBound - centers.lowerBound)
        } else {
            let top = visible.maxY - min(190, max(72, visible.height * 0.20), visible.height / 3)
            centerY = min(centers.upperBound, max(centers.lowerBound, top - size.height / 2))
        }
        return CGRect(x: visible.maxX - rightInset - size.width, y: centerY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func fraction(forCenterY y: CGFloat, in visible: CGRect, size: CGSize) -> Double {
        let centers = centerRange(for: size.height, in: visible)
        let travel = centers.upperBound - centers.lowerBound
        guard travel > 0, y.isFinite else { return 0.5 }
        let centerY = min(centers.upperBound, max(centers.lowerBound, y))
        return Double((centerY - centers.lowerBound) / travel)
    }

    static func panelTop(for height: CGFloat, near anchor: CGFloat, in visible: CGRect) -> CGFloat {
        let inset = min(screenInset, max(0, (visible.height - height) / 2))
        let maxTop = visible.maxY - inset
        let minTop = min(maxTop, visible.minY + inset + height)
        return min(maxTop, max(minTop, anchor))
    }

    private static func centerRange(for height: CGFloat, in visible: CGRect) -> ClosedRange<CGFloat> {
        let halfTravel = max(0, (visible.height - height) / 2 - screenInset)
        return (visible.midY - halfTravel)...(visible.midY + halfTravel)
    }
}
