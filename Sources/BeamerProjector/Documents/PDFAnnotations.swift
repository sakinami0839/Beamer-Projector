import Foundation
import CoreGraphics

struct ImportedMarks {
    var byPage: [Int: [Mark]] = [:]
    var names: [Int: Set<String>] = [:]
}

private func nativePDFError(_ pointer: UnsafeMutablePointer<CChar>?) -> ProjectError {
    guard let pointer else { return ProjectError("无法处理 PDF。") }
    defer { bp_free(pointer) }
    return ProjectError(String(cString: pointer))
}

final class NativePDF {
    private let pointer: OpaquePointer

    init(_ data: Data) throws {
        guard !data.isEmpty else { throw ProjectError("PDF 文件为空。") }
        var error: UnsafeMutablePointer<CChar>?
        let opened = data.withUnsafeBytes { buffer in
            bp_pdf_open(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &error)
        }
        guard let opened else { throw nativePDFError(error) }
        pointer = opened
    }

    deinit { bp_pdf_close(pointer) }

    func readMarks() throws -> ImportedMarks {
        var imported = ImportedMarks()
        var error: UnsafeMutablePointer<CChar>?
        let success = withUnsafeMutablePointer(to: &imported) { context in
            bp_pdf_visit(pointer, UnsafeMutableRawPointer(context), { context, page, name, value in
                guard let context, let name, let value,
                      let data = Data(base64Encoded: String(cString: value)),
                      let mark = try? JSONDecoder().decode(Mark.self, from: data), mark.isValid,
                      String(cString: name) == mark.id.uuidString else { return 0 }
                let marks = context.assumingMemoryBound(to: ImportedMarks.self)
                marks.pointee.byPage[Int(page), default: []].append(mark)
                marks.pointee.names[Int(page), default: []].insert(mark.id.uuidString)
                return 1
            }, &error)
        }
        guard success != 0 else { throw nativePDFError(error) }
        return imported
    }

    func removeMarks(_ names: [Int: Set<String>]) throws {
        guard !names.isEmpty else { return }
        var names = names
        var error: UnsafeMutablePointer<CChar>?
        let success = withUnsafeMutablePointer(to: &names) { context in
            bp_pdf_remove(pointer, UnsafeMutableRawPointer(context), { context, page, name, _ in
                guard let context, let name else { return 0 }
                let names = context.assumingMemoryBound(to: [Int: Set<String>].self).pointee
                return names[Int(page), default: []].contains(String(cString: name)) ? 1 : 0
            }, &error)
        }
        guard success != 0 else { throw nativePDFError(error) }
    }

    func append(_ mark: Mark, page index: Int, geometry: PageGeometry) throws {
        let viewport = CGRect(origin: .zero, size: geometry.size)
        let topToPage = geometry.transform(to: viewport).inverted()
        var transform = topToPage
        // Sample at UHD precision for both the vector appearance and InkList.
        let pixelScale = max(1, 2160 / min(viewport.width, viewport.height))
        let shape = mark.path(in: viewport, pixelScale: pixelScale)
        guard !shape.isEmpty, let pagePath = shape.copy(using: &transform) else { return }
        let rect = pagePath.boundingBoxOfPath.insetBy(dx: -0.25, dy: -0.25).intersection(geometry.crop)
        guard !rect.isNull, !rect.isEmpty else { return }

        let lineWidth = mark.width * min(viewport.width, viewport.height)
        let color = [mark.color.red, mark.color.green, mark.color.blue].map(pdfNumber).joined(separator: " ")
        let subtype: String
        var extra = ""
        switch mark.kind {
        case .pen, .fountainPen, .highlighter:
            subtype = "Ink"
            let lists = mark.smoothedInkPaths(in: viewport, pixelScale: pixelScale).filter { !$0.isEmpty }.map { path in
                let samples = path.count == 1 ? path + path : path
                let points = samples.map { pdfPoint($0.inRect(viewport).applying(topToPage)) }
                return "[" + points.joined(separator: " ") + "]"
            }
            extra = "/InkList [\(lists.joined(separator: " "))]"
        case .line, .arrow:
            subtype = "Line"
            guard let first = mark.paths.first?.first, let last = mark.paths.first?.last else { return }
            extra = "/L [\(pdfPoint(first.inRect(viewport).applying(topToPage))) \(pdfPoint(last.inRect(viewport).applying(topToPage)))]"
            if mark.kind == .arrow { extra += " /LE [/None /OpenArrow]" }
        case .rectangle, .ellipse:
            subtype = mark.kind == .rectangle ? "Square" : "Circle"
        case .text:
            subtype = "FreeText"
            let unicode = "FEFF" + mark.text.utf16.map { String(format: "%04X", Int($0)) }.joined()
            extra = "/Contents <\(unicode)> /DA (/Helvetica \(pdfNumber(lineWidth)) Tf \(color) rg)"
        }
        let box = [rect.minX, rect.minY, rect.maxX, rect.maxY].map(pdfNumber).joined(separator: " ")
        let dictionary = """
            << /Type /Annot /Subtype /\(subtype) /Rect [\(box)] /F 4 /NM (\(mark.id.uuidString))
            /C [\(color)] /CA \(pdfNumber(mark.color.opacity)) /BS << /W \(pdfNumber(lineWidth)) /S /S >>
            \(extra) >>
            """
        let appearance = "q /InkOpacity gs \(color) rg\n" +
            pdfPath(pagePath, origin: rect.origin) + "f Q\n"
        let payload = try JSONEncoder().encode(mark).base64EncodedString()
        var error: UnsafeMutablePointer<CChar>?
        guard bp_pdf_add(pointer, Int32(index), dictionary, payload, appearance,
                         rect.width, rect.height, mark.color.opacity, &error) != 0 else {
            throw nativePDFError(error)
        }
    }

    func data() throws -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        var size = 0
        var error: UnsafeMutablePointer<CChar>?
        guard bp_pdf_bytes(pointer, &bytes, &size, &error) != 0, let bytes else {
            throw nativePDFError(error)
        }
        return Data(bytesNoCopy: bytes, count: size, deallocator: .custom { memory, _ in bp_free(memory) })
    }
}

private func pdfNumber(_ value: Double) -> String {
    String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
}

private func pdfPoint(_ point: CGPoint) -> String { "\(pdfNumber(point.x)) \(pdfNumber(point.y))" }

private func pdfPath(_ path: CGPath, origin: CGPoint) -> String {
    var output = ""
    var start = CGPoint.zero
    var current = CGPoint.zero
    func position(_ point: CGPoint) -> String {
        pdfPoint(CGPoint(x: point.x - origin.x, y: point.y - origin.y))
    }
    path.applyWithBlock { element in
        let points = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint:
            current = points[0]
            start = current
            output += position(current) + " m\n"
        case .addLineToPoint:
            current = points[0]
            output += position(current) + " l\n"
        case .addQuadCurveToPoint:
            let control = points[0]
            let end = points[1]
            let control1 = CGPoint(x: current.x + (control.x - current.x) * 2 / 3,
                                   y: current.y + (control.y - current.y) * 2 / 3)
            let control2 = CGPoint(x: end.x + (control.x - end.x) * 2 / 3,
                                   y: end.y + (control.y - end.y) * 2 / 3)
            output += "\(position(control1)) \(position(control2)) \(position(end)) c\n"
            current = end
        case .addCurveToPoint:
            current = points[2]
            output += "\(position(points[0])) \(position(points[1])) \(position(current)) c\n"
        case .closeSubpath:
            current = start
            output += "h\n"
        @unknown default: break
        }
    }
    return output
}
