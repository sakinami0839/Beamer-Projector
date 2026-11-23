import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import BeamerProjector

private enum SmokeFailure: Error { case failed(String) }

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SmokeFailure.failed(message) }
}

final class PDFTests: XCTestCase {
    @MainActor
    func testPageShortcutsAndCustomBindings() throws {
        let domain = "BeamerProjector.ShortcutsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let bindings = ShortcutBindings(defaults: defaults)
        let session = Session(shortcuts: bindings)
        let pdf = try PDFFixture.temporaryPresentation()
        defer { try? FileManager.default.removeItem(at: pdf) }
        session.open(pdf)

        func key(_ equivalent: KeyEquivalent, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let characters = String(equivalent.character)
            return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                 timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                                 charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
        }

        XCTAssertTrue(session.handlePageShortcut(try key(.pageDown, modifiers: [.function, .numericPad])))
        XCTAssertEqual(session.index, 1)
        XCTAssertTrue(session.handlePageShortcut(try key(.pageUp)))
        XCTAssertEqual(session.index, 0)

        XCTAssertNotNil(bindings.assign(bindings[.openPDF], to: .nextPage))
        XCTAssertNotNil(bindings.assign(AppShortcut("q", modifiers: .command), to: .nextPage))
        XCTAssertNotNil(bindings.assign(AppShortcut("j"), to: .nextPage))
        let custom = AppShortcut("j", modifiers: .control)
        XCTAssertNil(bindings.assign(custom, to: .nextPage))
        XCTAssertEqual(ShortcutBindings(defaults: defaults)[.nextPage], custom)
        XCTAssertFalse(session.handlePageShortcut(try key(.pageDown)))
        XCTAssertTrue(session.handlePageShortcut(try key("j", modifiers: .control)))
        XCTAssertTrue(session.handlePageShortcut(try key(.rightArrow)))
        XCTAssertEqual(session.index, 2)

        session.requestText(at: InkPoint(x: 0.3, y: 0.3))
        XCTAssertFalse(session.handlePageShortcut(try key(.rightArrow)))
        XCTAssertEqual(session.index, 2)
        bindings.reset()
        XCTAssertEqual(ShortcutBindings(defaults: defaults)[.nextPage], ShortcutAction.nextPage.defaultShortcut)
    }

    @MainActor
    func testBrushSettingsDoNotInvalidatePagePreviews() throws {
        let session = Session()
        let fixture = try PDFFixture.temporaryPresentation()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = try PDFSource(url: fixture)
        let preview = PreviewSurface(frame: CGRect(x: 0, y: 0, width: 220, height: 126))
        let settings = OutputSettings()
        XCTAssertTrue(preview.update(source: source, index: 1, marks: [], settings: settings))

        var sessionUpdates = 0
        var preferenceUpdates = 0
        let sessionObserver = session.objectWillChange.sink { sessionUpdates += 1 }
        let preferenceObserver = session.annotationPreferences.objectWillChange.sink { preferenceUpdates += 1 }
        defer {
            sessionObserver.cancel()
            preferenceObserver.cancel()
        }

        var style = session.style(for: .fountainPen)
        style.width = 0.026
        session.setStyle(style, for: .fountainPen)
        style.color.opacity = 0.65
        session.setStyle(style, for: .fountainPen)
        session.annotationPreferences.eraserRadius = 0.03
        XCTAssertEqual(sessionUpdates, 0)
        XCTAssertEqual(preferenceUpdates, 3)
        XCTAssertEqual(session.style(for: .fountainPen), style)

        XCTAssertFalse(preview.update(source: source, index: 1, marks: [], settings: settings))
        XCTAssertTrue(preview.update(source: source, index: 2, marks: [], settings: settings))
    }

    @MainActor
    func testSaveUpdatesOriginalAndUndoTracksSavedState() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "original.pdf")
        let original = PDFFixture.repeatedLabels()
        try original.write(to: url)
        let session = Session(recoveryDirectory: directory.appending(path: "Recovery"))
        session.open(url)
        XCTAssertFalse(session.hasUnsavedChanges)

        let pen = Mark(kind: .pen, width: 0.025, color: .red, paths: [[InkPoint(x: 0.25, y: 0.25)]])
        session.setDraft(pen)
        session.finishGesture()
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: url), original)
        session.undo()
        XCTAssertFalse(session.hasUnsavedChanges)
        session.redo()
        XCTAssertTrue(session.savePDF())
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(try PDFSource(url: url).embeddedMarks[0], [pen])

        session.undo()
        XCTAssertTrue(session.hasUnsavedChanges)
        session.redo()
        XCTAssertFalse(session.hasUnsavedChanges)
        session.undo()
        XCTAssertTrue(session.savePDF())
        XCTAssertTrue(try PDFSource(url: url).embeddedMarks.isEmpty)

        var external = try Data(contentsOf: url)
        external.append(contentsOf: "\n% Other editor\n".utf8)
        try external.write(to: url, options: .atomic)
        session.redo()
        XCTAssertFalse(session.savePDF())
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    @MainActor
    func testInkStopsOutsidePageAndResumesWithoutBridge() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "boundary.pdf")
        try PDFFixture.repeatedLabels().write(to: url)
        let session = Session(recoveryDirectory: directory.appending(path: "Recovery"))
        session.open(url)
        session.updateOutput(OutputSettings(), persist: false)
        let size = CGSize(width: 800, height: 620)
        let view = SlideView(session: session, audience: false)
        view.frame = CGRect(origin: .zero, size: size)
        let page = OutputLayout(settings: session.output, pageSize: try XCTUnwrap(session.source).geometries[0].size,
                                bounds: view.bounds.insetBy(dx: 16, dy: 16)).page

        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                            clickCount: 1, pressure: 1))
        }
        let first = InkPoint(x: 0.25, y: 0.20).inRect(page)
        let resume = InkPoint(x: 0.75, y: 0.20).inRect(page)
        view.mouseDown(with: try event(.leftMouseDown, at: first))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: first.x, y: page.minY - 12)))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: resume.x, y: page.minY - 12)))
        XCTAssertEqual(session.draft?.paths.map(\.count), [1])
        view.mouseDragged(with: try event(.leftMouseDragged, at: resume))
        view.mouseUp(with: try event(.leftMouseUp, at: resume))
        let mark = try XCTUnwrap(session.currentMarks.first)
        XCTAssertEqual(mark.paths.map(\.count), [1, 1])
        XCTAssertFalse(mark.path(in: page).contains(CGPoint(x: page.midX, y: first.y)))
    }

    @MainActor
    func testShiftConstrainsShapesToRegularGeometry() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "shapes.pdf")
        try PDFFixture.repeatedLabels().write(to: url)
        let session = Session(recoveryDirectory: directory.appending(path: "Recovery"))
        session.open(url)
        session.updateOutput(OutputSettings(), persist: false)
        let view = SlideView(session: session, audience: false)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 620)
        let page = OutputLayout(settings: session.output, pageSize: try XCTUnwrap(session.source).geometries[0].size,
                                bounds: view.bounds.insetBy(dx: 16, dy: 16)).page
        XCTAssertNotEqual(page.width, page.height, accuracy: 10)

        func mouse(_ type: NSEvent.EventType, at point: CGPoint, shift: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                                             modifierFlags: shift ? [.shift] : [],
                                             timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1))
        }
        func shiftEvent(down: Bool) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                                           modifierFlags: down ? [.shift] : [],
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56))
        }

        // Rectangle becomes 1:1 square on a non-square page, even when toggled mid-drag.
        let origin = CGPoint(x: page.minX + 120, y: page.minY + 110)
        let freeDrag = CGPoint(x: origin.x + 140, y: origin.y + 70)
        session.activate(.mark(.rectangle))
        view.mouseDown(with: try mouse(.leftMouseDown, at: origin))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: freeDrag, shift: false))
        let unconstrained = try XCTUnwrap(session.draft)
        let freeStart = unconstrained.paths[0][0].inRect(page)
        let freeEnd = unconstrained.paths[0][1].inRect(page)
        XCTAssertEqual(abs(freeEnd.x - freeStart.x), 140, accuracy: 0.5)
        XCTAssertEqual(abs(freeEnd.y - freeStart.y), 70, accuracy: 0.5)

        view.flagsChanged(with: try shiftEvent(down: true))
        let constrained = try XCTUnwrap(session.draft)
        let sqStart = constrained.paths[0][0].inRect(page)
        let sqEnd = constrained.paths[0][1].inRect(page)
        XCTAssertEqual(abs(sqEnd.x - sqStart.x), 140, accuracy: 0.5)
        XCTAssertEqual(abs(sqEnd.y - sqStart.y), 140, accuracy: 0.5)

        // Dragging past the page edge stays strictly 1:1 within page bounds.
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: page.maxX + 200, y: page.maxY + 50), shift: true))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: page.maxX + 200, y: page.maxY + 50), shift: true))
        let savedSquare = try XCTUnwrap(session.currentMarks.last)
        let squareEnd = savedSquare.paths[0][1].inRect(page)
        XCTAssertEqual(abs(squareEnd.x - origin.x), abs(squareEnd.y - origin.y), accuracy: 0.5)
        XCTAssertTrue(savedSquare.isValid)

        // Circle uses (origin, cursor) as its diameter, and releasing Shift restores the original origin.
        let diameterEnd = CGPoint(x: origin.x + 60, y: origin.y + 80) // length = 100, center = origin + (30, 40)
        session.activate(.mark(.ellipse))
        view.mouseDown(with: try mouse(.leftMouseDown, at: origin))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: diameterEnd, shift: true))
        let circleDraft = try XCTUnwrap(session.draft)
        let c0 = circleDraft.paths[0][0].inRect(page)
        let c1 = circleDraft.paths[0][1].inRect(page)
        let circleBox = CGRect(x: min(c0.x, c1.x), y: min(c0.y, c1.y), width: abs(c1.x - c0.x), height: abs(c1.y - c0.y))
        XCTAssertEqual(circleBox.width, 100, accuracy: 0.5)
        XCTAssertEqual(circleBox.height, 100, accuracy: 0.5)
        XCTAssertEqual(circleBox.midX, (origin.x + diameterEnd.x) / 2, accuracy: 0.5)
        XCTAssertEqual(circleBox.midY, (origin.y + diameterEnd.y) / 2, accuracy: 0.5)

        view.flagsChanged(with: try shiftEvent(down: false))
        let restoredEllipse = try XCTUnwrap(session.draft)
        let e0 = restoredEllipse.paths[0][0].inRect(page)
        let e1 = restoredEllipse.paths[0][1].inRect(page)
        XCTAssertEqual(e0.x, origin.x, accuracy: 0.5)
        XCTAssertEqual(e0.y, origin.y, accuracy: 0.5)
        XCTAssertEqual(e1.x, diameterEnd.x, accuracy: 0.5)
        XCTAssertEqual(e1.y, diameterEnd.y, accuracy: 0.5)

        // Clamping past the page edge preserves a circle whose circumference still passes through origin.
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: page.maxX + 200, y: origin.y + 120), shift: true))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: page.maxX + 200, y: origin.y + 120), shift: true))
        let savedCircle = try XCTUnwrap(session.currentMarks.last)
        let sc0 = savedCircle.paths[0][0].inRect(page)
        let sc1 = savedCircle.paths[0][1].inRect(page)
        let savedBox = CGRect(x: min(sc0.x, sc1.x), y: min(sc0.y, sc1.y), width: abs(sc1.x - sc0.x), height: abs(sc1.y - sc0.y))
        XCTAssertEqual(savedBox.width, savedBox.height, accuracy: 0.5)
        XCTAssertEqual(hypot(origin.x - savedBox.midX, origin.y - savedBox.midY), savedBox.width / 2, accuracy: 0.5)
        XCTAssertTrue(savedCircle.isValid)

        // Line and arrow snap to 0° / 45° / 90° and keep exact 45° when clamped by the page edge.
        for kind in [MarkKind.line, .arrow] {
            session.activate(.mark(kind))
            view.mouseDown(with: try mouse(.leftMouseDown, at: origin))
            view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: origin.x + 150, y: origin.y + 20), shift: true))
            var end = try XCTUnwrap(session.draft).paths[0][1].inRect(page)
            XCTAssertEqual(end.y, origin.y, accuracy: 0.5)

            view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: origin.x + 12, y: origin.y + 130), shift: true))
            end = try XCTUnwrap(session.draft).paths[0][1].inRect(page)
            XCTAssertEqual(end.x, origin.x, accuracy: 0.5)

            view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: page.maxX + 300, y: page.maxY + 300), shift: true))
            view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: page.maxX + 300, y: page.maxY + 300), shift: true))
            let saved = try XCTUnwrap(session.currentMarks.last)
            end = saved.paths[0][1].inRect(page)
            XCTAssertEqual(abs(end.x - origin.x), abs(end.y - origin.y), accuracy: 0.5)
            XCTAssertTrue(saved.isValid)
        }
    }

    func testInkSubdivisionUsesOutputResolution() {
        let first = InkPoint(x: 0.2, y: 0.35, pressure: 0.2)
        let bend = InkPoint(x: 0.5, y: 0.35, pressure: 0.9)
        let last = InkPoint(x: 0.8, y: 0.6, pressure: 0.5)
        var pen = Mark(kind: .pen, width: 0.018, color: .red, paths: [[first, bend, last]])
        let hd = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let uhd = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        let curve = pen.smoothedInkPaths(in: uhd, pixelScale: 1)[0]

        XCTAssertGreaterThan(curve.count, pen.smoothedInkPaths(in: hd, pixelScale: 1)[0].count)
        XCTAssertEqual(curve, pen.smoothedInkPaths(in: hd, pixelScale: 2)[0])
        XCTAssertEqual(curve.first, first)
        XCTAssertEqual(curve.last, last)
        XCTAssertFalse(curve.contains(bend))
        XCTAssertTrue(curve.dropFirst().dropLast().allSatisfy { $0.pressure > 0.2 && $0.pressure < 0.9 })

        pen.paths[0][2].x = bend.x
        XCTAssertEqual(pen.smoothedInkPaths(in: uhd, pixelScale: 1), pen.paths)
    }

    func testFountainPenVariesWithStrokeDirection() {
        let page = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let center = CGPoint(x: page.midX, y: page.midY)
        let alongNib = CGVector(dx: cos(.pi / 6), dy: -0.5)
        let acrossNib = CGVector(dx: 0.5, dy: cos(.pi / 6))
        func stroke(in direction: CGVector) -> Mark {
            let samples = [-150.0, 150.0].map { distance in
                InkPoint.from(CGPoint(x: center.x + distance * direction.dx, y: center.y + distance * direction.dy),
                              in: page)
            }
            return Mark(kind: .fountainPen, width: 0.05, color: .red, paths: [samples])
        }

        let thin = stroke(in: alongNib)
        let thick = stroke(in: acrossNib)
        let thinEdge = CGPoint(x: center.x + 12 * acrossNib.dx, y: center.y + 12 * acrossNib.dy)
        let thickEdge = CGPoint(x: center.x + 12 * alongNib.dx, y: center.y + 12 * alongNib.dy)
        XCTAssertTrue(thin.path(in: page).contains(center))
        XCTAssertFalse(thin.path(in: page).contains(thinEdge))
        XCTAssertTrue(thick.path(in: page).contains(thickEdge))
        XCTAssertEqual(thick.erasing(at: center, radius: 10, in: page)?.paths.count, 2)
    }

    func testPDFRoundTripAndOutputLayout() throws {
        let pdf = try PDFFixture.temporaryPresentation()
        defer { try? FileManager.default.removeItem(at: pdf) }
        let build = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: build) }
        let source = try PDFSource(url: pdf)
        try check(source.count == 22, "Original page count")
        try check(source.outline.compactMap(\.page) == [1, 5, 8, 15, 21], "Outline destinations")
        try check(source.navigation.first?.page == 0 && source.navigation[1].children.map(\.page) == [1, 2, 3, 4],
                  "Page groups beneath a flat Beamer outline")
        let nested = NavigationEntry.tree(from: [
            OutlineEntry(id: ".0", title: "Section", page: 0),
            OutlineEntry(id: ".0.0", title: "Topic", page: 1),
            OutlineEntry(id: ".0.0.0", title: "Detail", page: 2),
            OutlineEntry(id: ".1", title: "Another section", page: 3),
        ], pageCount: 4)
        try check(nested.first?.children.first?.children.first?.title == "Detail", "Real PDF outline hierarchy")

        let links = (0..<source.count).reduce(0) { $0 + (source.pdf.page(at: $1)?.annotations.count ?? 0) }
        try check(links == 480, "Original annotations")
        let link = source.pdf.page(at: 1)!.annotations.first { $0.destination?.page != nil || $0.action is PDFActionGoTo }!
        let rect = CGRect(x: 0, y: 0, width: 1440, height: 810)
        let point = CGPoint(x: link.bounds.midX, y: link.bounds.midY)
            .applying(source.geometries[1].transform(to: rect))
        try check(source.link(at: point, in: rect, page: 1) != nil, "Link hit test")

        let first = InkPoint(x: 0.15, y: 0.24, pressure: 0.06)
        let middle = InkPoint(x: 0.54, y: 0.24, pressure: 0.7)
        let last = InkPoint(x: 0.65, y: 0.28, pressure: 1)
        let pen = Mark(kind: .pen, width: 0.036, color: .red, paths: [[first, middle, last]])
        let text = Mark(kind: .text, width: 0.095, color: .red,
                        paths: [[InkPoint(x: 0.19, y: 0.36)]], text: "批注中文")
        let rectangle = Mark(kind: .rectangle, width: 0.012, color: .red,
                             paths: [[InkPoint(x: 0.18, y: 0.60), InkPoint(x: 0.52, y: 0.76)]])
        let highlighter = Mark(kind: .highlighter, width: 0.045, color: .yellow,
                               paths: [[InkPoint(x: 0.24, y: 0.55), InkPoint(x: 0.55, y: 0.55)]])
        let fountain = Mark(kind: .fountainPen, width: 0.020,
                            color: InkColor(red: 0.14, green: 0.45, blue: 0.90, opacity: 0.73),
                            paths: [[InkPoint(x: 0.65, y: 0.51, pressure: 0.3), InkPoint(x: 0.73, y: 0.43),
                                     InkPoint(x: 0.78, y: 0.60, pressure: 0.8)]])
        let annotations = [pen, text, rectangle, highlighter, fountain]
        try check(pen.diameter(at: first, in: rect) < pen.diameter(at: last, in: rect) * 0.5, "Pressure response")
        let erased = pen.erasing(at: CGPoint(x: 0.4 * rect.width, y: 0.24 * rect.height), radius: 20, in: rect)
        try check(erased?.paths.count == 2 && erased?.id == pen.id, "Split stroke by eraser")

        let out = build.appending(path: "smoke-annotated.pdf")
        try source.export(marks: [1: annotations], to: out)
        let exported = try PDFSource(url: out)
        try check(exported.count == 22 && exported.outline.compactMap(\.page) == source.outline.compactMap(\.page),
                  "Preserve pages and outline")
        try check(exported.embeddedMarks[1] == annotations, "Editable PDF round-trip")
        let external = PDFDocument(url: out)!
        let originalTypes = (0..<source.count).flatMap { external.page(at: $0)!.annotations }.compactMap(\.type)
        try check(originalTypes.filter { $0 == "Link" }.count == 480, "Preserve 480 foreign links")
        try check(originalTypes.filter { $0 != "Link" }.sorted() == ["FreeText", "Ink", "Ink", "Ink", "Square"],
                  "Standard annotation types")
        let edited = build.appending(path: "smoke-edited.pdf")
        try exported.export(marks: [1: [text]], to: edited)
        let reopened = try PDFSource(url: edited)
        try check(reopened.embeddedMarks[1] == [text], "Remove and re-export embedded marks")
        var boxed = text
        boxed.width = 0.047
        boxed.text = "文字批注测试 · 一二三四五六七八九十 · 窄框自动换行"
        boxed.textBox = TextBoxSize(width: 0.215, height: 0.25)
        let boxedBounds = boxed.path(in: rect).boundingBoxOfPath
        let textRect = boxed.textBox!.rect(at: boxed.textAnchor, in: rect)
        try check(textRect.contains(boxedBounds) && boxedBounds.height > boxed.width * rect.height,
                  "Editable box wraps text within the resized bounds")
        let boxedPDF = build.appending(path: "smoke-editable-box.pdf")
        try source.export(marks: [1: [boxed]], to: boxedPDF)
        let restoredBox = try PDFSource(url: boxedPDF)
        try check(restoredBox.embeddedMarks[1] == [boxed], "Editable text-box dimensions survive a PDF round-trip")


        let repeatPath = build.appending(path: "smoke-repeated.pdf")
        try PDFFixture.repeatedLabels().write(to: repeatPath)
        let repeated = try PDFSource(url: repeatPath)
        try check(repeated.labels == ["重", "重", "3"] && repeated.groups == [0, 0, 2], "Equal adjacent PDF page labels")
        let rotatedSize = repeated.geometries[1].size
        try check(rotatedSize == CGSize(width: 140, height: 220), "Rotated crop dimensions")
        let rotated = build.appending(path: "smoke-rotated-annotated.pdf")
        try repeated.export(marks: [0: [pen]], to: rotated)
        let shared = try PDFSource(url: rotated)
        try check(shared.embeddedMarks[0] == [pen] && shared.embeddedMarks.count == 1, "Restore one shared edit")
        let view = PDFDocument(url: rotated)!
        try check(view.page(at: 0)!.annotations.count == 1 && view.page(at: 1)!.annotations.count == 1 &&
                  view.page(at: 2)!.annotations.isEmpty, "Standard per-page annotations on shared pages only")
        let repeatedRect = CGRect(origin: .zero, size: rotatedSize)
        let firstInPDF = first.inRect(repeatedRect).applying(repeated.geometries[1].transform(to: repeatedRect).inverted())
        try check(view.page(at: 1)!.annotations[0].bounds.contains(firstInPDF), "Export rotation and crop transform")

        let output = OutputSettings(width: 1440, height: 1080, left: 20, right: 60, top: 12, bottom: 24)
        let fitted = output.pageRect(for: CGSize(width: 1600, height: 900))
        try check(output.isValid && fitted == CGRect(x: 20, y: 151.5, width: 1360, height: 765),
                  "4:3 output and asymmetric margins")
        let layout = OutputLayout(settings: output, pageSize: CGSize(width: 1600, height: 900),
                                  bounds: CGRect(x: 10, y: 20, width: 600, height: 540))
        try check(layout.canvas == CGRect(x: 10, y: 65, width: 600, height: 450) &&
                  abs(layout.page.minY - 128.125) < 0.001, "Scaled preview is vertically centered and preserves margins")
        try check(OutputSettings().size == CGSize(width: 1920, height: 1080) && OutputSettings().fps == 60,
                  "1080p60 defaults")
        print("PDF smoke checks passed")
    }
}
