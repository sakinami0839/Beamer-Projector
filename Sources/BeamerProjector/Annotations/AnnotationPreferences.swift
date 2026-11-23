import Combine

enum Tool: Equatable {
    case navigate, mark(MarkKind), eraseStroke, erasePart, lasso
}

enum StyleTarget: Hashable {
    case pen, fountainPen, highlighter, shape, text

    var isBrush: Bool { self == .pen || self == .fountainPen || self == .highlighter }

    var title: String {
        switch self {
        case .pen: "压感笔"
        case .fountainPen: "钢笔"
        case .highlighter: "高亮笔"
        case .shape: "形状"
        case .text: "文字"
        }
    }
}

struct AnnotationStyle: Equatable {
    var color: InkColor
    var width: Double
}

@MainActor
final class AnnotationPreferences: ObservableObject {
    @Published var styles: [StyleTarget: AnnotationStyle] = [
        .pen: AnnotationStyle(color: .red, width: 0.009),
        .fountainPen: AnnotationStyle(color: InkColor(red: 0.14, green: 0.45, blue: 0.90), width: 0.012),
        .highlighter: AnnotationStyle(color: .yellow, width: 0.028),
        .shape: AnnotationStyle(color: .red, width: 0.009),
        .text: AnnotationStyle(color: .red, width: 0.036),
    ]
    @Published var eraserRadius = 0.025
}
