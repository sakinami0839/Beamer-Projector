import AppKit

@MainActor
final class SlideView: NSView {
    let session: Session
    let audience: Bool
    private var pointingEraser = false
    private var gesture: Tool?
    private var gesturePage: Int?
    private var gestureSource: String?
    private var start: CGPoint?
    private var shapeOrigin: InkPoint?
    private var previous: CGPoint?
    private var mark: Mark?
    private var original: [Mark] = []
    private var editing: [Mark] = []
    private var lasso: [CGPoint] = []
    private var moving = false

    init(session: Session, audience: Bool) {
        self.session = session
        self.audience = audience
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(self, selector: #selector(frameChanged),
                                              name: Session.frameDidChange, object: session)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !audience }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { !audience }
    @objc private func frameChanged() {
        if gesture != nil && (gesturePage != session.index || gestureSource != session.source?.fingerprint) {
            reset()
        }
        needsDisplay = true
    }

    private var pageRect: CGRect {
        guard let source = session.source else { return .zero }
        return OutputLayout(settings: session.output, pageSize: source.geometries[session.index].size,
                            bounds: presenterBounds(bounds)).page
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        paintScene(session: session, in: context, canvas: bounds,
                   bitmapScale: window?.backingScaleFactor ?? 1, audience: audience)
        guard !audience else { return }
        context.saveGState()
        context.clip(to: pageRect)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [4, 3])
        for selected in session.visibleMarks where session.selection.contains(selected.id) {
            let box = selected.path(in: pageRect).boundingBoxOfPath
            if !box.isNull { context.stroke(box.insetBy(dx: -4, dy: -4)) }
        }
        if let first = lasso.first, !moving {
            context.beginPath()
            context.move(to: first)
            for position in lasso.dropFirst() { context.addLine(to: position) }
            context.closePath()
            context.strokePath()
        }
        context.restoreGState()
    }

    override func tabletProximity(with event: NSEvent) {
        pointingEraser = event.isEnteringProximity && event.pointingDeviceType == .eraser
    }

    private func pressure(_ event: NSEvent) -> Double {
        if event.type == .tabletPoint || event.subtype == .tabletPoint { return Double(event.pressure) }
        return 1
    }

    override func mouseDown(with event: NSEvent) {
        guard !audience, let source = session.source else { return }
        let position = convert(event.locationInWindow, from: nil)
        let rect = pageRect
        guard rect.contains(position) else { return }
        window?.makeFirstResponder(self)
        let tool = pointingEraser ? session.tabletEraser : session.tool
        if tool == .navigate {
            if let target = source.link(at: position, in: rect, page: session.index) { session.navigate(to: target) }
            return
        }
        let sample = InkPoint.from(position, in: rect, pressure: pressure(event))
        if tool == .mark(.text) {
            if let text = session.currentMarks.reversed().first(where: {
                $0.kind == .text && $0.path(in: rect).boundingBoxOfPath.insetBy(dx: -4, dy: -4).contains(position)
            }) {
                session.editText(text.id)
            } else {
                session.requestText(at: sample)
            }
            return
        }
        gesture = tool
        gesturePage = session.index
        gestureSource = source.fingerprint
        start = position
        previous = position
        original = session.currentMarks
        editing = original
        switch tool {
        case .mark(let kind):
            session.selection = []
            shapeOrigin = sample
            let style = session.style(for: session.styleTarget)
            let candidate = Mark(kind: kind, width: style.width, color: style.color, paths: [[sample]])
            mark = candidate
            if kind.isInk { session.setDraft(candidate) }
        case .eraseStroke, .erasePart:
            session.selection = []
            erase(at: position, rect: rect, part: tool == .erasePart)
        case .lasso:
            moving = original.contains { item in
                session.selection.contains(item.id) &&
                    item.path(in: rect).boundingBoxOfPath.insetBy(dx: -6, dy: -6).contains(position)
            }
            if !moving {
                session.selection = []
                lasso = [position]
            }
        case .navigate: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        updateGesture(at: convert(event.locationInWindow, from: nil), pressure: pressure(event),
                      constrain: event.modifierFlags.contains(.shift))
    }

    override func flagsChanged(with event: NSEvent) {
        if case .mark(let kind) = gesture, !kind.isInk, session.draft != nil, let position = previous {
            updateGesture(at: position, pressure: 1, constrain: event.modifierFlags.contains(.shift))
        }
        super.flagsChanged(with: event)
    }

    override func tabletPoint(with event: NSEvent) {
        guard case .mark(let kind) = gesture, kind.isInk else { return }
        updateGesture(at: convert(event.locationInWindow, from: nil), pressure: pressure(event))
    }

    private func updateGesture(at position: CGPoint, pressure: Double, constrain: Bool = false) {
        guard let gesture, let start else { return }
        let rect = pageRect
        guard !rect.isEmpty else { return }
        switch gesture {
        case .mark(let kind):
            guard var candidate = mark else { return }
            if kind.isInk {
                guard rect.contains(position) else {
                    previous = nil
                    return
                }
                let point = InkPoint.from(position, in: rect, pressure: pressure)
                let lastPath = candidate.paths.count - 1
                if previous == nil {
                    candidate.paths.append([point])
                } else if candidate.paths[lastPath].last != point {
                    candidate.paths[lastPath].append(point)
                } else {
                    return
                }
            } else {
                let originPoint = shapeOrigin ?? candidate.paths[0][0]
                if constrain {
                    let (first, second) = constrainedShapePoints(for: kind, from: originPoint.inRect(rect),
                                                                 to: position, in: rect)
                    candidate.paths[0] = [InkPoint.from(first, in: rect, pressure: pressure),
                                          InkPoint.from(second, in: rect, pressure: pressure)]
                } else {
                    candidate.paths[0] = [originPoint, InkPoint.from(position, in: rect, pressure: pressure)]
                }
            }
            mark = candidate
            session.setDraft(candidate)
        case .eraseStroke, .erasePart:
            erase(at: position, rect: rect, part: gesture == .erasePart)
        case .lasso:
            if moving {
                let selected = original.filter { session.selection.contains($0.id) }
                let points = selected.flatMap { mark in
                    var points = mark.paths.flatMap { $0 }
                    if let box = mark.textBox {
                        let anchor = mark.textAnchor
                        points.append(InkPoint(x: anchor.x + box.width, y: anchor.y + box.height))
                    }
                    return points
                }
                guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                      let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
                let dx = min(1 - maxX, max(-minX, (position.x - start.x) / rect.width))
                let dy = min(1 - maxY, max(-minY, (position.y - start.y) / rect.height))
                session.setWorking(original.map { session.selection.contains($0.id) ? $0.moved(dx: dx, dy: dy) : $0 })
            } else {
                lasso.append(position)
                needsDisplay = true
            }
        case .navigate: break
        }
        previous = position
    }

    override func mouseUp(with event: NSEvent) {
        guard let gesture else { return }
        if gesture == .lasso, !moving, let first = lasso.first {
            let path = CGMutablePath()
            path.move(to: first)
            for point in lasso.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
            let position = convert(event.locationInWindow, from: nil)
            let rect = pageRect
            if lasso.count < 3 {
                if let hit = original.reversed().first(where: {
                    $0.path(in: rect).boundingBoxOfPath.insetBy(dx: -5, dy: -5).contains(position)
                }) { session.selection = [hit.id] }
            } else {
                session.selection = Set(original.filter { item in
                    let bounds = item.path(in: rect).boundingBoxOfPath
                    return item.paths.joined().contains { path.contains($0.inRect(rect)) } ||
                        (!bounds.isNull && path.contains(CGPoint(x: bounds.midX, y: bounds.midY)))
                }.map(\.id))
            }
        }
        reset()
        session.finishGesture()
    }

    private func erase(at position: CGPoint, rect: CGRect, part: Bool) {
        let radius = max(2, session.annotationPreferences.eraserRadius * min(rect.width, rect.height))
        let a = previous ?? position
        let distance = hypot(position.x - a.x, position.y - a.y)
        let steps = max(1, Int(ceil(distance / max(2, radius * 0.5))))
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            let sample = CGPoint(x: a.x + (position.x - a.x) * fraction, y: a.y + (position.y - a.y) * fraction)
            let area = CGRect(x: sample.x - radius, y: sample.y - radius, width: 2 * radius, height: 2 * radius)
            editing = editing.compactMap { item in
                let path = item.path(in: rect)
                guard path.boundingBoxOfPath.intersects(area) else { return item }
                if part, item.kind.isInk { return item.erasing(at: sample, radius: radius, in: rect) }
                let edge = path.copy(strokingWithWidth: radius * 2, lineCap: .round,
                                     lineJoin: .round, miterLimit: 4)
                let hit = path.contains(sample) || edge.contains(sample)
                return hit ? nil : item
            }
        }
        session.setWorking(editing)
    }

    private func reset() {
        gesture = nil
        gesturePage = nil
        gestureSource = nil
        start = nil
        shapeOrigin = nil
        previous = nil
        mark = nil
        original = []
        editing = []
        lasso = []
        moving = false
    }

    override func cancelOperation(_ sender: Any?) {
        if gesture != nil { reset(); session.cancelGesture() }
        else if session.textRequest != nil { session.cancelText() }
        else if session.localPresentation == .fullScreen { session.closeProjector() }
        else { session.selection = []; needsDisplay = true }
    }
}
