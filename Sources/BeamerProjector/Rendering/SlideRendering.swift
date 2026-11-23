import SwiftUI

@MainActor
func paintOutput(source: PDFSource?, index: Int, marks: [Mark], settings: OutputSettings,
                 in context: CGContext, bounds: CGRect, scale: CGFloat) {
    guard settings.isValid else { return }
    let layout = OutputLayout(settings: settings, pageSize: source?.geometries[index].size ?? .zero, bounds: bounds)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(layout.canvas)
    let page = layout.page
    guard !page.isEmpty, let image = source?.image(at: index,
                size: CGSize(width: min(4096, page.width * scale), height: min(4096, page.height * scale))) else { return }
    context.saveGState()
    context.translateBy(x: page.minX, y: page.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: page.size))
    context.restoreGState()
    drawMarks(marks, in: context, rect: page, pixelScale: scale)
}

@MainActor
func paintScene(session: Session, in context: CGContext, canvas: CGRect, bitmapScale: CGFloat,
                audience: Bool) {
    if audience {
        context.setFillColor(CGColor(gray: 0, alpha: 1))
    } else {
        context.setFillColor(NSColor.underPageBackgroundColor.cgColor)
    }
    context.fill(canvas)
    var marks = session.visibleMarks
    if !audience, let edited = session.textRequest?.id {
        marks = marks.filter { $0.id != edited }
    }
    paintOutput(source: session.source, index: session.index, marks: marks, settings: session.output,
                in: context, bounds: audience ? canvas : presenterBounds(canvas), scale: bitmapScale)
}

struct OutputPreview: NSViewRepresentable {
    let source: PDFSource
    let index: Int
    let marks: [Mark]
    let settings: OutputSettings

    func makeNSView(context: Context) -> PreviewSurface { PreviewSurface() }

    func updateNSView(_ view: PreviewSurface, context: Context) {
        view.update(source: source, index: index, marks: marks, settings: settings)
    }
}

@MainActor
final class PreviewSurface: NSView {
    private var source: PDFSource?
    private var index = 0
    private var marks: [Mark] = []
    private var settings = OutputSettings()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @discardableResult
    func update(source: PDFSource, index: Int, marks: [Mark], settings: OutputSettings) -> Bool {
        guard self.source !== source || self.index != index || self.marks != marks || self.settings != settings else {
            return false
        }
        self.source = source
        self.index = index
        self.marks = marks
        self.settings = settings
        needsDisplay = true
        return true
    }

    override func draw(_ dirtyRect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        paintOutput(source: source, index: index, marks: marks, settings: settings,
                    in: context, bounds: bounds, scale: window?.backingScaleFactor ?? 1)
    }
}

private func drawMarks(_ marks: [Mark], in context: CGContext, rect: CGRect, pixelScale: CGFloat) {
    context.saveGState()
    context.clip(to: rect)
    for mark in marks {
        context.addPath(mark.path(in: rect, pixelScale: pixelScale))
        context.setFillColor(mark.color.cgColor)
        context.fillPath()
    }
    context.restoreGState()
}
