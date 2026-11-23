import SwiftUI

struct AnnotationTools: View {
    @ObservedObject var session: Session
    @ObservedObject private var preferences: AnnotationPreferences
    let confirmClear: () -> Void
    private var motion = PresenterMotion()
    @State private var styleAnchor: StyleAnchor?
    @State private var colorPage = ColorPage.presets
    @State private var showsStrokeEraser = false
    @State private var showsPartialEraser = false
    @State private var showsShapes = false

    init(session: Session, confirmClear: @escaping () -> Void) {
        self.session = session
        self.preferences = session.annotationPreferences
        self.confirmClear = confirmClear
    }

    var body: some View {
        HStack(spacing: 4) {
            tool("导航", "cursorarrow", .navigate)
            brush(.pen, target: .pen)
            brush(.fountainPen, target: .fountainPen)
            brush(.highlighter, target: .highlighter)
            eraser("整笔橡皮", "eraser", .eraseStroke, settings: $showsStrokeEraser)
            eraser("局部橡皮", "eraser.line.dashed", .erasePart, settings: $showsPartialEraser)
            tool("套索", "lasso", .lasso)
            tool("文字", "character.textbox", .mark(.text))
            shapes
            Divider().frame(height: 18)
            styleButton
            Divider().frame(height: 18)
            action("撤销", "arrow.uturn.backward", session.undo).disabled(!session.canUndo)
            action("重做", "arrow.uturn.forward", session.redo).disabled(!session.canRedo)
            Menu {
                Button("编辑所选文字", action: session.editSelectedText)
                    .disabled(!session.currentMarks.contains { session.selection.contains($0.id) && $0.kind == .text })
                Button("删除选中的批注", action: session.removeSelection).disabled(session.selection.isEmpty)
                Button("清除本页…", role: .destructive, action: confirmClear).disabled(session.currentMarks.isEmpty)
            } label: {
                Image(systemName: "ellipsis").accessibilityLabel("更多批注操作")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    private func tool(_ name: String, _ symbol: String, _ tool: Tool) -> some View {
        let selected = session.tool == tool
        return Button { session.activate(tool) } label: { icon(symbol, selected: selected) }
            .buttonStyle(.plain)
            .help(name)
            .accessibilityLabel(name)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func brush(_ kind: MarkKind, target: StyleTarget) -> some View {
        let tool = Tool.mark(kind)
        let selected = session.tool == tool
        let anchor = StyleAnchor.brush(kind)
        return Button {
            if selected { toggleStyle(at: anchor) }
            else { session.activate(tool) }
        } label: {
            icon(kind.symbol, selected: selected)
        }
        .buttonStyle(.plain)
        .help(selected ? target.title + "设置" : target.title)
        .accessibilityLabel(target.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .popover(isPresented: presentsStyle(at: anchor), arrowEdge: .bottom) {
            AnnotationStyleCard(session: session, target: target, page: $colorPage)
        }
    }

    private func action(_ name: String, _ symbol: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) { icon(symbol, selected: false) }
            .buttonStyle(.plain)
            .help(name)
            .accessibilityLabel(name)
    }

    private func icon(_ symbol: String, selected: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .animation(motion.fade, value: selected)
            .frame(width: 27, height: 27)
            .contentShape(Rectangle())
    }

    private func eraser(_ name: String, _ symbol: String, _ tool: Tool, settings: Binding<Bool>) -> some View {
        let selected = session.tool == tool
        return Button {
            if selected { settings.wrappedValue.toggle() }
            else { session.activate(tool) }
        } label: {
            icon(symbol, selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(selected ? name + "设置" : name)
        .popover(isPresented: settings, arrowEdge: .bottom) {
            AnnotationCard {
                Text(name + "设置").font(.headline)
                AnnotationSliderRow(title: "大小", valueLabel: Text(preferences.eraserRadius,
                                    format: .percent.precision(.fractionLength(1))),
                                    value: $preferences.eraserRadius, range: 0.008...0.08)
            }
        }
    }

    private var shapes: some View {
        let kinds: [MarkKind] = [.line, .arrow, .rectangle, .ellipse]
        let current = kinds.first { session.tool == .mark($0) }
        return Button { showsShapes.toggle() } label: {
            icon(current?.symbol ?? "square.on.circle", selected: current != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("形状")
        .help("形状")
        .popover(isPresented: $showsShapes, arrowEdge: .bottom) {
            AnnotationCard {
                Text("形状").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(kinds, id: \.self) { kind in
                        Button {
                            session.activate(.mark(kind))
                            showsShapes = false
                        } label: {
                            Label(kind.title, systemImage: kind.symbol).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var styleButton: some View {
        let target = session.styleTarget
        let style = session.style(for: target)
        return Button { toggleStyle(at: .settings) } label: {
            HStack(spacing: 6) {
                Circle().fill(Color(cgColor: style.color.cgColor)).frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.23), lineWidth: 1))
                Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 5)
            .frame(height: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("颜色和笔尖设置")
        .help("颜色和笔尖设置")
        .popover(isPresented: presentsStyle(at: .settings), arrowEdge: .bottom) {
            AnnotationStyleCard(session: session, target: target, page: $colorPage).id(target)
        }
    }

    private func toggleStyle(at anchor: StyleAnchor) {
        if styleAnchor == anchor {
            styleAnchor = nil
        } else {
            colorPage = .presets
            styleAnchor = anchor
        }
    }

    private func presentsStyle(at anchor: StyleAnchor) -> Binding<Bool> {
        Binding(get: { styleAnchor == anchor }, set: { presented in
            if presented != (styleAnchor == anchor) { toggleStyle(at: anchor) }
        })
    }

    private enum StyleAnchor: Equatable {
        case brush(MarkKind), settings
    }
}

private enum ColorPage: Hashable {
    case presets, custom
}

private struct AnnotationCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(width: 232)
            .padding(16)
    }
}

private struct AnnotationSliderRow: View {
    let title: String
    let valueLabel: Text
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                valueLabel.monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: $value, in: range) { Text(title) }.labelsHidden()
        }
    }
}

private struct AnnotationStyleCard: View {
    @ObservedObject var session: Session
    @ObservedObject private var preferences: AnnotationPreferences
    let target: StyleTarget
    @Binding var page: ColorPage
    private var motion = PresenterMotion()

    init(session: Session, target: StyleTarget, page: Binding<ColorPage>) {
        self.session = session
        self.preferences = session.annotationPreferences
        self.target = target
        self._page = page
    }

    private let palette: [(String, String)] = [
        ("黑色", "141518"), ("深灰", "444952"), ("灰色", "888D96"), ("浅灰", "CDD0D5"), ("白色", "FFFFFF"),
        ("红色", "DB1F3B"), ("橙色", "ED6A27"), ("琥珀黄", "FFAE27"), ("黄色", "FFD429"), ("柠檬黄", "F7EF86"),
        ("墨绿", "126350"), ("绿色", "239A6D"), ("草绿", "86C941"), ("青绿", "33BDB3"), ("天蓝", "51B5F0"),
        ("深蓝", "1E4792"), ("蓝色", "2474E5"), ("紫色", "8B57D7"), ("玫红", "CC478F"), ("粉色", "F482A7"),
    ]

    private var style: AnnotationStyle { session.style(for: target) }
    private var visibleShortEdge: CGFloat {
        guard let source = session.source else { return 255 }
        let size = source.geometries[session.index].size
        return min(size.width, size.height)
    }

    var body: some View {
        AnnotationCard {
            HStack {
                Text(target.title + "设置").font(.headline)
                if target != .text {
                    Spacer()
                    strokeSample
                }
            }
            AnnotationSliderRow(title: target == .text ? "文字大小" : "笔尖粗细",
                                valueLabel: Text("\(style.width * visibleShortEdge, specifier: "%.1f") pt"),
                                value: Binding(get: { style.width }, set: setWidth),
                                range: target == .text ? 0.018...0.10 : 0.002...0.08)
            if target.isBrush {
                AnnotationSliderRow(title: "不透明度",
                                    valueLabel: Text(style.color.opacity, format: .percent.precision(.fractionLength(0))),
                                    value: Binding(get: { style.color.opacity }, set: setOpacity), range: 0.05...1)
            }
            Divider()
            Picker("选色方式", selection: $page) {
                Text("预设颜色").tag(ColorPage.presets)
                Text("自定义").tag(ColorPage.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .center)
            Group {
                switch page {
                case .presets: presetColors.transition(.opacity)
                case .custom: HexPalette(color: style.color, select: setColor).transition(.opacity)
                }
            }
            .frame(height: 174, alignment: .top)
            .animation(motion.fade, value: page)
        }
    }

    private var strokeSample: some View {
        Canvas { context, size in
            let kind: MarkKind = switch target {
            case .pen: .pen
            case .fountainPen: .fountainPen
            case .highlighter: .highlighter
            default: .line
            }
            let samples = target.isBrush ? [
                InkPoint(x: 0.12, y: 0.68, pressure: 0.25), InkPoint(x: 0.37, y: 0.33, pressure: 0.8),
                InkPoint(x: 0.63, y: 0.64), InkPoint(x: 0.88, y: 0.40, pressure: 0.45),
            ] : [InkPoint(x: 0.12, y: 0.50), InkPoint(x: 0.88, y: 0.50)]
            let mark = Mark(kind: kind, width: min(12, style.width * visibleShortEdge) / size.height,
                            color: style.color, paths: [samples])
            context.fill(Path(mark.path(in: CGRect(origin: .zero, size: size))), with: .color(Color(cgColor: style.color.cgColor)))
        }
        .frame(width: 76, height: 24)
        .background(.primary.opacity(0.06), in: .capsule)
        .accessibilityHidden(true)
    }

    private var presetColors: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 5), spacing: 8) {
            ForEach(palette.indices, id: \.self) { index in
                let (name, hex) = palette[index]
                let color = InkColor(hex: hex) ?? .red
                let active = style.color.hex == hex
                Button { setColor(color) } label: {
                    Circle()
                        .fill(Color(cgColor: color.cgColor))
                        .overlay(Circle().strokeBorder(.primary.opacity(0.17), lineWidth: 1))
                        .overlay {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle((color.red + color.green + color.blue) > 2 ? .black : .white)
                                .opacity(active ? 1 : 0)
                        }
                        .frame(width: 28, height: 28)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(name + " #" + hex)
                .accessibilityLabel(name)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }

    private func setWidth(_ width: Double) {
        session.setStyle(AnnotationStyle(color: style.color, width: width), for: target)
    }

    private func setColor(_ color: InkColor) {
        var color = color
        color.opacity = style.color.opacity
        session.setStyle(AnnotationStyle(color: color, width: style.width), for: target)
    }

    private func setOpacity(_ opacity: Double) {
        var updated = style
        updated.color.opacity = opacity
        session.setStyle(updated, for: target)
    }
}
