import AppKit
import QuartzCore

@MainActor
private final class SidebarMorphPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // The transparent area for the shadow can extend beyond a display edge.
        frameRect
    }
}

@MainActor
final class SidebarMorph {
    struct Shape {
        var rect: CGRect
        var radius: CGFloat
        var fill: NSColor
        var stroke: NSColor
        var countOpacity: Float
        var shadowOpacity: Float
    }

    static let geometryAnimationKey = "relayMorphGeometry"
    static let openingEasing = CAMediaTimingFunction(controlPoints: 0.24, 0.64, 0.32, 1)
    private static let retractionEasing = CAMediaTimingFunction(controlPoints: 0.22, 0.82, 0.26, 1)
    private static let appearanceAnimationKey = "relayMorphAppearance"
    private static let countPositionKey = "relayMorphCountPosition"
    private static let countOpacityKey = "relayMorphCountOpacity"
    private static let shadowPadding: CGFloat = 28

    let window: NSPanel
    private let shell = CALayer()
    private let countLayer = CATextLayer()
    private var previousStart: Shape?
    private var previousTarget: Shape?

    var presentedFrame: CGRect? {
        shell.presentation()?.frame.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
    }

    init() {
        let panel = SidebarMorphPanel(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Relay transition"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        window = panel

        shell.anchorPoint = CGPoint(x: 1, y: 0.5)
        shell.borderWidth = 1
        shell.cornerCurve = .continuous
        shell.shadowColor = NSColor.black.cgColor
        shell.shadowRadius = 11
        shell.shadowOffset = CGSize(width: 0, height: -4)

        countLayer.alignmentMode = .center
        let host = NSView()
        host.wantsLayer = true
        host.layer?.addSublayer(shell)
        host.layer?.addSublayer(countLayer)
        window.contentView = host
    }

    @discardableResult
    func transition(from initial: Shape, to target: Shape, count: String?, countColor: NSColor,
                    duration: TimeInterval, easing: CAMediaTimingFunction? = nil) -> Shape {
        let easing = easing ?? Self.retractionEasing
        let start = presentedShape(fallback: initial)
        let extent = duration > 0 ? initial.rect.union(target.rect) : target.rect
        let area = extent.insetBy(dx: -Self.shadowPadding, dy: -Self.shadowPadding)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if window.frame != area { window.setFrame(area, display: false) }
        let origin = window.frame.origin
        let localStart = start.rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let localTarget = target.rect.offsetBy(dx: -origin.x, dy: -origin.y)
        Self.animateGeometry(of: shell, from: localStart, to: localTarget,
                             fromRadius: start.radius, toRadius: target.radius, duration: duration, easing: easing)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            animateAppearance(from: start, to: target, duration: duration, easing: easing)
            animateCount(count, color: countColor, from: localStart, to: localTarget,
                         fromOpacity: start.countOpacity, toOpacity: target.countOpacity,
                         duration: duration, easing: easing)
        }
        CATransaction.commit()
        previousStart = start
        previousTarget = target
        return start
    }

    func hide() {
        window.orderOut(nil)
        shell.removeAllAnimations()
        countLayer.removeAllAnimations()
        previousStart = nil
        previousTarget = nil
    }

    static func animateGeometry(of layer: CALayer, from start: CGRect, to target: CGRect,
                                fromRadius: CGFloat, toRadius: CGFloat, duration: TimeInterval,
                                easing: CAMediaTimingFunction) {
        let startBounds = CGRect(origin: .zero, size: start.size)
        let targetBounds = CGRect(origin: .zero, size: target.size)
        let startPosition = position(of: start, anchor: layer.anchorPoint)
        let targetPosition = position(of: target, anchor: layer.anchorPoint)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = targetBounds
        layer.position = targetPosition
        layer.cornerRadius = toRadius
        if duration > 0 {
            addGroup([
                animation("bounds", from: NSValue(rect: startBounds), to: NSValue(rect: targetBounds), duration: duration),
                animation("position", from: NSValue(point: startPosition), to: NSValue(point: targetPosition), duration: duration),
                animation("cornerRadius", from: fromRadius, to: toRadius, duration: duration)
            ], to: layer, forKey: geometryAnimationKey, duration: duration, easing: easing)
        } else {
            layer.removeAnimation(forKey: geometryAnimationKey)
        }
        CATransaction.commit()
    }

    private func presentedShape(fallback: Shape) -> Shape {
        guard window.isVisible, let previousTarget else { return fallback }
        guard let rendered = shell.presentation() else {
            if shell.animation(forKey: Self.geometryAnimationKey) != nil, let previousStart { return previousStart }
            return previousTarget
        }
        let origin = window.frame.origin
        return Shape(rect: rendered.frame.offsetBy(dx: origin.x, dy: origin.y), radius: rendered.cornerRadius,
                     fill: rendered.backgroundColor.flatMap(NSColor.init(cgColor:)) ?? previousTarget.fill,
                     stroke: rendered.borderColor.flatMap(NSColor.init(cgColor:)) ?? previousTarget.stroke,
                     countOpacity: countLayer.presentation()?.opacity ?? countLayer.opacity,
                     shadowOpacity: rendered.shadowOpacity)
    }

    private func animateAppearance(from start: Shape, to target: Shape, duration: TimeInterval,
                                   easing: CAMediaTimingFunction) {
        let startFill = Self.cgColor(start.fill)
        let targetFill = Self.cgColor(target.fill)
        let startStroke = Self.cgColor(start.stroke)
        let targetStroke = Self.cgColor(target.stroke)
        shell.backgroundColor = targetFill
        shell.borderColor = targetStroke
        shell.shadowOpacity = target.shadowOpacity
        guard duration > 0 else {
            shell.removeAnimation(forKey: Self.appearanceAnimationKey)
            return
        }
        Self.addGroup([
            Self.animation("backgroundColor", from: startFill, to: targetFill, duration: duration),
            Self.animation("borderColor", from: startStroke, to: targetStroke, duration: duration),
            Self.animation("shadowOpacity", from: start.shadowOpacity, to: target.shadowOpacity, duration: duration)
        ], to: shell, forKey: Self.appearanceAnimationKey, duration: duration, easing: easing)
    }

    private func animateCount(_ count: String?, color: NSColor, from start: CGRect, to target: CGRect,
                              fromOpacity: Float, toOpacity: Float, duration: TimeInterval,
                              easing: CAMediaTimingFunction) {
        let startPosition = CGPoint(x: start.midX, y: start.midY)
        let targetPosition = CGPoint(x: target.midX, y: target.midY)
        if let count {
            let font = NSFont.monospacedDigitSystemFont(ofSize: count.count > 2 ? 10 : 12, weight: .semibold)
            let text = NSAttributedString(string: count, attributes: [.font: font, .foregroundColor: color])
            let size = text.size()
            countLayer.bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + 2, height: ceil(size.height))
            countLayer.contentsScale = window.backingScaleFactor
            countLayer.string = text
        } else {
            countLayer.string = nil
        }
        countLayer.position = targetPosition
        countLayer.opacity = toOpacity
        guard duration > 0, count != nil else {
            countLayer.removeAnimation(forKey: Self.countPositionKey)
            countLayer.removeAnimation(forKey: Self.countOpacityKey)
            return
        }

        let movement = Self.animation("position", from: NSValue(point: startPosition),
                                      to: NSValue(point: targetPosition), duration: duration)
        movement.timingFunction = easing
        countLayer.add(movement, forKey: Self.countPositionKey)

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.duration = duration
        if fromOpacity > toOpacity {
            opacity.values = [fromOpacity, toOpacity, toOpacity]
            opacity.keyTimes = [0, 0.32, 1]
            opacity.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear)]
        } else {
            opacity.values = [fromOpacity, fromOpacity, toOpacity]
            opacity.keyTimes = [0, 0.68, 1]
            opacity.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeIn)]
        }
        countLayer.add(opacity, forKey: Self.countOpacityKey)
    }

    private static func cgColor(_ color: NSColor) -> CGColor {
        (color.usingColorSpace(.deviceRGB) ?? color).cgColor
    }

    private static func position(of rect: CGRect, anchor: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * anchor.x, y: rect.minY + rect.height * anchor.y)
    }

    private static func animation(_ keyPath: String, from start: Any, to target: Any,
                                  duration: TimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = start
        animation.toValue = target
        animation.duration = duration
        return animation
    }

    private static func addGroup(_ animations: [CAAnimation], to layer: CALayer, forKey key: String,
                                 duration: TimeInterval, easing: CAMediaTimingFunction) {
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.timingFunction = easing
        layer.add(group, forKey: key)
    }
}
