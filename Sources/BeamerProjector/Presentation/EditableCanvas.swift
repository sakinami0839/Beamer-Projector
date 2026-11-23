import SwiftUI

private struct PresenterCanvas: NSViewRepresentable {
    let session: Session
    func makeNSView(context: Context) -> SlideView { SlideView(session: session, audience: false) }
    func updateNSView(_ view: SlideView, context: Context) { view.needsDisplay = true }
}

struct EditableCanvas: View {
    @ObservedObject var session: Session

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                PresenterCanvas(session: session)
                if let request = session.textRequest, let source = session.source {
                    let layout = OutputLayout(settings: session.output, pageSize: source.geometries[session.index].size,
                                              bounds: presenterBounds(CGRect(origin: .zero, size: geometry.size)))
                    InlineTextEditor(session: session, request: request, page: layout.page)
                        .id(request.id)
                }
            }
        }
    }
}

private struct InlineTextEditor: View {
    @ObservedObject var session: Session
    let request: Session.TextRequest
    let page: CGRect
    @FocusState private var focused: Bool
    @State private var initialMark: Mark?

    private var box: CGRect {
        (request.mark.textBox ?? TextBoxSize(width: 0.36, height: 0.19)).rect(at: request.mark.textAnchor, in: page)
    }

    var body: some View {
        TextEditor(text: Binding(get: { request.mark.text }, set: { text in
            update { $0.text = text }
        }))
        .textEditorStyle(.plain)
        .scrollContentBackground(.hidden)
        .font(.system(size: max(1, request.mark.width * min(page.width, page.height))))
        .foregroundStyle(Color(cgColor: request.mark.color.cgColor))
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .padding(-3)
        .focused($focused)
        .accessibilityLabel("画布文字批注")
        .frame(width: box.width, height: box.height)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5)))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 19, height: 19)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: .rect(cornerRadius: 5))
                .offset(x: 5, y: 5)
                .gesture(drag(resizing: true))
                .help("拖动调整文本框大小")
                .accessibilityLabel("调整文本框大小")
                .accessibilityAdjustableAction { direction in
                    let change = direction == .increment ? 0.035 : -0.035
                    update { mark in
                        guard let size = mark.textBox else { return }
                        mark.textBox = TextBoxSize(width: size.width + change, height: size.height + change)
                            .clamped(at: mark.textAnchor)
                    }
                }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .gesture(drag(resizing: false))
                    .help("拖动移动文本框")
                    .accessibilityLabel("移动文本框")
                Button { session.cancelText() } label: { Image(systemName: "xmark") }
                    .help("取消 · Esc")
                    .accessibilityLabel("取消文字编辑")
                    .keyboardShortcut(.cancelAction)
                Button { session.finishText() } label: { Image(systemName: "checkmark") }
                    .help("完成 · ⌘↩")
                    .accessibilityLabel("保存文字批注")
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7)
            .glassEffect(.regular, in: .capsule)
            .fixedSize()
            .offset(y: box.minY >= 31 ? -29 : 0)
        }
        .position(x: box.midX, y: box.midY)
        .onAppear { focused = true }
    }

    private func update(_ edit: (inout Mark) -> Void) {
        guard var current = session.textRequest, current.id == request.id else { return }
        edit(&current.mark)
        session.textRequest = current
    }

    private func drag(resizing: Bool) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                guard page.width > 0, page.height > 0, let size = request.mark.textBox else { return }
                if initialMark == nil { initialMark = request.mark }
                guard let initial = initialMark, let initialSize = initial.textBox else { return }
                let anchor = initial.textAnchor
                let dx = value.translation.width / page.width
                let dy = value.translation.height / page.height
                update { mark in
                    if resizing {
                        mark.textBox = TextBoxSize(width: initialSize.width + dx,
                                                   height: initialSize.height + dy).clamped(at: anchor)
                    } else {
                        mark.paths = [[InkPoint(x: min(1 - size.width, max(0, anchor.x + dx)),
                                                y: min(1 - size.height, max(0, anchor.y + dy)))]]
                    }
                }
            }
            .onEnded { _ in initialMark = nil }
    }
}
