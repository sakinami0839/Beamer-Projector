import Foundation
import CoreGraphics

struct InkPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var pressure: Double = 1

    func inRect(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }

    static func from(_ point: CGPoint, in rect: CGRect, pressure: Double = 1) -> Self {
        Self(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
             y: min(1, max(0, (point.y - rect.minY) / rect.height)),
             pressure: min(1, max(0, pressure)))
    }

    func interpolating(to other: Self, fraction t: Double) -> Self {
        Self(x: x + (other.x - x) * t, y: y + (other.y - y) * t,
             pressure: pressure + (other.pressure - pressure) * t)
    }
}

struct InkColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double = 1

    static let red = Self(red: 0.86, green: 0.12, blue: 0.23)
    static let yellow = Self(red: 1, green: 0.83, blue: 0.16, opacity: 0.42)

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }
}

struct TextBoxSize: Codable, Equatable {
    var width: Double
    var height: Double

    var isValid: Bool { width > 0 && width <= 1 && height > 0 && height <= 1 }

    func rect(at point: InkPoint, in page: CGRect) -> CGRect {
        CGRect(origin: point.inRect(page), size: CGSize(width: width * page.width, height: height * page.height))
    }

    func clamped(at point: InkPoint) -> Self {
        Self(width: min(1 - point.x, max(0.12, width)), height: min(1 - point.y, max(0.08, height)))
    }
}

enum MarkKind: String, Codable {
    case pen, fountainPen, highlighter, line, arrow, rectangle, ellipse, text

    var isInk: Bool { self == .pen || self == .fountainPen || self == .highlighter }

    var title: String {
        switch self {
        case .pen: "画笔"
        case .fountainPen: "钢笔"
        case .highlighter: "高亮"
        case .line: "直线"
        case .arrow: "箭头"
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .text: "文字"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .fountainPen: "pencil.and.scribble"
        case .highlighter: "highlighter"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .text: "textformat"
        }
    }
}

struct Mark: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: MarkKind
    // Width and font size are relative to the shorter edge of the visible PDF page.
    var width: Double
    var color: InkColor
    var paths: [[InkPoint]]
    var text: String = ""
    var textBox: TextBoxSize?

    var isValid: Bool {
        width.isFinite && width > 0 && width <= 1 &&
        [color.red, color.green, color.blue, color.opacity].allSatisfy { (0...1).contains($0) } &&
        (textBox?.isValid ?? true) &&
        paths.contains { !$0.isEmpty } &&
        paths.joined().allSatisfy {
            (0...1).contains($0.x) && (0...1).contains($0.y) && (0...1).contains($0.pressure)
        }
    }

    func moved(dx: Double, dy: Double) -> Self {
        var mark = self
        mark.paths = paths.map { path in
            path.map { InkPoint(x: $0.x + dx, y: $0.y + dy, pressure: $0.pressure) }
        }
        return mark
    }

    var textAnchor: InkPoint { paths.first?.first ?? InkPoint(x: 0, y: 0) }

}
