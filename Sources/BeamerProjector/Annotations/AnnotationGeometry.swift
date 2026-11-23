import AppKit
import CoreText

extension Mark {
    func diameter(at point: InkPoint, in rect: CGRect) -> CGFloat {
        let factor = switch kind {
        case .pen: 0.22 + 0.78 * pow(point.pressure, 0.72)
        case .fountainPen: 0.65 + 0.35 * sqrt(point.pressure)
        default: 1.0
        }
        return width * min(rect.width, rect.height) * factor
    }

    // Build the stroke with circular stamps in nib coordinates, then flatten and rotate the nib.
    private static let fountainNib: CGAffineTransform = {
        let angle = -CGFloat.pi / 6
        let aspect: CGFloat = 0.30
        return CGAffineTransform(a: cos(angle), b: sin(angle), c: -aspect * sin(angle),
                                 d: aspect * cos(angle), tx: 0, ty: 0)
    }()

    func path(in rect: CGRect, pixelScale: CGFloat = 1) -> CGPath {
        let result = CGMutablePath()
        if kind.isInk {
            var nibToPage = kind == .fountainPen ? Self.fountainNib : .identity
            let pageToNib = nibToPage.inverted()
            for path in smoothedInkPaths(in: rect, pixelScale: pixelScale) {
                var previous: (center: CGPoint, radius: CGFloat)?
                for sample in path {
                    let center = sample.inRect(rect).applying(pageToNib)
                    let radius = diameter(at: sample, in: rect) / 2
                    // Every subpath has the same winding, so a translucent stroke fills once.
                    result.move(to: CGPoint(x: center.x + radius, y: center.y))
                    result.addRelativeArc(center: center, radius: radius, startAngle: 0, delta: .pi * 2)
                    result.closeSubpath()
                    if let previous {
                        connectInkDiscs(in: result, from: previous.center, radius: previous.radius,
                                        to: center, radius: radius)
                    }
                    previous = (center, radius)
                }
            }
            if nibToPage.isIdentity { return result }
            return result.copy(using: &nibToPage) ?? result
        }
        guard let samples = paths.first, let first = samples.first, let last = samples.last else { return result }
        let start = first.inRect(rect)
        let end = last.inRect(rect)
        let strokeWidth = width * min(rect.width, rect.height)
        if kind == .text {
            if let textBox {
                return boxedText(in: textBox.rect(at: first, in: rect), fontSize: strokeWidth)
            }
            return textOutline(at: start, size: strokeWidth)
        }
        if kind == .rectangle || kind == .ellipse {
            let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                             width: abs(start.x - end.x), height: abs(start.y - end.y))
            if kind == .rectangle { result.addRect(box) } else { result.addEllipse(in: box) }
        } else {
            result.move(to: start)
            result.addLine(to: end)
            if kind == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let head = min(hypot(end.x - start.x, end.y - start.y) * 0.42, strokeWidth * 6)
                for offset in [-0.48, 0.48] {
                    result.move(to: end)
                    result.addLine(to: CGPoint(x: end.x - head * cos(angle + offset),
                                              y: end.y - head * sin(angle + offset)))
                }
            }
        }
        return result.copy(strokingWithWidth: strokeWidth, lineCap: .round, lineJoin: .round, miterLimit: 4)
    }

    func smoothedInkPaths(in rect: CGRect, pixelScale: CGFloat) -> [[InkPoint]] {
        let cornerLimit = min(rect.width, rect.height) * 0.018
        let maximumRadius = width * min(rect.width, rect.height) * 0.5

        return paths.map { samples in
            guard samples.count > 2, cornerLimit > 0 else { return samples }
            var result = [samples[0]]
            for i in 1..<(samples.count - 1) {
                let previous = samples[i - 1]
                let corner = samples[i]
                let next = samples[i + 1]
                let a = previous.inRect(rect)
                let b = corner.inRect(rect)
                let c = next.inRect(rect)
                let incoming = CGPoint(x: b.x - a.x, y: b.y - a.y)
                let outgoing = CGPoint(x: c.x - b.x, y: c.y - b.y)
                let inLength = hypot(incoming.x, incoming.y)
                let outLength = hypot(outgoing.x, outgoing.y)
                // Keep deliberate sharp turns and stationary pressure samples.
                let dot = incoming.x * outgoing.x + incoming.y * outgoing.y
                guard inLength > 0, outLength > 0, dot > 0.1 * inLength * outLength else {
                    result.append(corner)
                    continue
                }
                let first = corner.interpolating(to: previous, fraction: min(0.45, cornerLimit / inLength))
                let last = corner.interpolating(to: next, fraction: min(0.45, cornerLimit / outLength))
                let firstPoint = first.inRect(rect)
                let lastPoint = last.inRect(rect)
                let bend = hypot(firstPoint.x - 2 * b.x + lastPoint.x, firstPoint.y - 2 * b.y + lastPoint.y)
                let widthBend = abs(first.pressure - 2 * corner.pressure + last.pressure) * maximumRadius
                // The maximum chord error of a quadratic falls with the square of its subdivisions.
                let steps = max(1, Int(ceil(sqrt((bend + widthBend) * pixelScale))))
                if steps == 1 {
                    result.append(corner)
                    continue
                }
                result.append(first)
                for step in 1..<steps {
                    let t = Double(step) / Double(steps)
                    let left = first.interpolating(to: corner, fraction: t)
                    let right = corner.interpolating(to: last, fraction: t)
                    result.append(left.interpolating(to: right, fraction: t))
                }
                result.append(last)
            }
            result.append(samples[samples.count - 1])
            return result
        }
    }

    private func connectInkDiscs(in path: CGMutablePath, from start: CGPoint, radius startRadius: CGFloat,
                                 to end: CGPoint, radius endRadius: CGFloat) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance > abs(startRadius - endRadius), distance > 0.0001 else { return }
        let tangent = (startRadius - endRadius) / distance
        let perpendicular = sqrt(1 - tangent * tangent)
        let ux = dx / distance
        let uy = dy / distance
        let left = CGPoint(x: ux * tangent - uy * perpendicular, y: uy * tangent + ux * perpendicular)
        let right = CGPoint(x: ux * tangent + uy * perpendicular, y: uy * tangent - ux * perpendicular)
        path.move(to: CGPoint(x: start.x + left.x * startRadius, y: start.y + left.y * startRadius))
        path.addLine(to: CGPoint(x: start.x + right.x * startRadius, y: start.y + right.y * startRadius))
        path.addLine(to: CGPoint(x: end.x + right.x * endRadius, y: end.y + right.y * endRadius))
        path.addLine(to: CGPoint(x: end.x + left.x * endRadius, y: end.y + left.y * endRadius))
        path.closeSubpath()
    }

    private func textOutline(at origin: CGPoint, size: CGFloat) -> CGPath {
        let outline = CGMutablePath()
        let font = NSFont.systemFont(ofSize: max(1, size))
        for (lineIndex, string) in text.components(separatedBy: .newlines).enumerated() {
            let richText = NSAttributedString(string: string, attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(richText)
            addGlyphs(of: line, baseline: CGPoint(x: origin.x, y: origin.y + size * (1 + CGFloat(lineIndex) * 1.25)),
                      to: outline)
        }
        return outline
    }

    private func boxedText(in box: CGRect, fontSize: CGFloat) -> CGPath {
        let outline = CGMutablePath()
        let richText = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: max(1, fontSize))])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(richText), CFRange(),
            CGPath(rect: CGRect(origin: .zero, size: box.size), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)
        for (line, origin) in zip(lines, origins) {
            addGlyphs(of: line, baseline: CGPoint(x: box.minX + origin.x, y: box.maxY - origin.y), to: outline)
        }
        return outline
    }

    private func addGlyphs(of line: CTLine, baseline: CGPoint, to outline: CGMutablePath) {
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let font = attributes[kCTFontAttributeName] else { continue }
            let runFont = font as! CTFont
            for index in 0..<CTRunGetGlyphCount(run) {
                var glyph: CGGlyph = 0
                var position = CGPoint.zero
                let range = CFRange(location: index, length: 1)
                CTRunGetGlyphs(run, range, &glyph)
                CTRunGetPositions(run, range, &position)
                var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                    tx: baseline.x + position.x, ty: baseline.y - position.y)
                if let path = CTFontCreatePathForGlyph(runFont, glyph, &transform) { outline.addPath(path) }
            }
        }
    }

    func erasing(at position: CGPoint, radius: CGFloat, in rect: CGRect) -> Self? {
        guard kind.isInk else { return self }
        var updated = self
        updated.paths = zip(paths, smoothedInkPaths(in: rect, pixelScale: 1)).flatMap { original, samples -> [[InkPoint]] in
            guard let first = samples.first else { return [] }
            var dense = [first]
            for (previous, next) in zip(samples, samples.dropFirst()) {
                let a = previous.inRect(rect)
                let b = next.inRect(rect)
                let steps = max(1, Int(ceil(hypot(a.x - b.x, a.y - b.y) / max(1, radius / 3))))
                for step in 1...steps {
                    dense.append(previous.interpolating(to: next, fraction: Double(step) / Double(steps)))
                }
            }
            var fragments: [[InkPoint]] = []
            var current: [InkPoint] = []
            var hit = false
            for sample in dense {
                let point = sample.inRect(rect)
                if hypot(point.x - position.x, point.y - position.y) <= radius + diameter(at: sample, in: rect) / 2 {
                    hit = true
                    if !current.isEmpty { fragments.append(current); current = [] }
                } else {
                    current.append(sample)
                }
            }
            if !hit { return [original] }
            if !current.isEmpty { fragments.append(current) }
            return fragments
        }
        return updated.paths.isEmpty ? nil : updated
    }
}

func constrainedShapePoints(for kind: MarkKind, from origin: CGPoint, to target: CGPoint,
                            in rect: CGRect) -> (CGPoint, CGPoint) {
    let dx = target.x - origin.x
    let dy = target.y - origin.y
    switch kind {
    case .rectangle:
        guard dx != 0 || dy != 0 else { return (origin, origin) }
        let sx: CGFloat = dx == 0 ? (origin.x <= rect.midX ? 1 : -1) : (dx > 0 ? 1 : -1)
        let sy: CGFloat = dy == 0 ? (origin.y <= rect.midY ? 1 : -1) : (dy > 0 ? 1 : -1)
        let availX = sx > 0 ? rect.maxX - origin.x : origin.x - rect.minX
        let availY = sy > 0 ? rect.maxY - origin.y : origin.y - rect.minY
        let side = min(max(abs(dx), abs(dy)), max(0, min(availX, availY)))
        return (origin, CGPoint(x: origin.x + sx * side, y: origin.y + sy * side))
    case .ellipse:
        let length = hypot(dx, dy)
        guard length > 0 else { return (origin, origin) }
        let ux = dx / length
        let uy = dy / length
        // Treat (origin, target) as a diameter of the circle and clamp its bounding square inside rect.
        var maxDiameter = CGFloat.greatestFiniteMagnitude
        if 1 - ux > 1e-9 { maxDiameter = min(maxDiameter, 2 * (origin.x - rect.minX) / (1 - ux)) }
        if 1 + ux > 1e-9 { maxDiameter = min(maxDiameter, 2 * (rect.maxX - origin.x) / (1 + ux)) }
        if 1 - uy > 1e-9 { maxDiameter = min(maxDiameter, 2 * (origin.y - rect.minY) / (1 - uy)) }
        if 1 + uy > 1e-9 { maxDiameter = min(maxDiameter, 2 * (rect.maxY - origin.y) / (1 + uy)) }
        let radius = min(length, max(0, maxDiameter)) / 2
        let center = CGPoint(x: origin.x + ux * radius, y: origin.y + uy * radius)
        return (CGPoint(x: center.x - radius, y: center.y - radius),
                CGPoint(x: center.x + radius, y: center.y + radius))
    case .line, .arrow:
        guard dx != 0 || dy != 0 else { return (origin, origin) }
        let step = CGFloat.pi / 4
        let sector = ((Int((atan2(dy, dx) / step).rounded()) % 8) + 8) % 8
        let diag = CGFloat(0.5.squareRoot())
        let directions: [(CGFloat, CGFloat)] = [
            (1, 0), (diag, diag), (0, 1), (-diag, diag),
            (-1, 0), (-diag, -diag), (0, -1), (diag, -diag),
        ]
        let (ux, uy) = directions[sector]
        var maxDistance = CGFloat.greatestFiniteMagnitude
        if ux > 0 { maxDistance = min(maxDistance, (rect.maxX - origin.x) / ux) }
        else if ux < 0 { maxDistance = min(maxDistance, (rect.minX - origin.x) / ux) }
        if uy > 0 { maxDistance = min(maxDistance, (rect.maxY - origin.y) / uy) }
        else if uy < 0 { maxDistance = min(maxDistance, (rect.minY - origin.y) / uy) }
        let distance = min(max(0, dx * ux + dy * uy), max(0, maxDistance))
        return (origin, CGPoint(x: origin.x + ux * distance, y: origin.y + uy * distance))
    default:
        let clamped = CGPoint(x: min(rect.maxX, max(rect.minX, target.x)),
                              y: min(rect.maxY, max(rect.minY, target.y)))
        return (origin, clamped)
    }
}
