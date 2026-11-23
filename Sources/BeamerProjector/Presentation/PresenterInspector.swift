import SwiftUI

struct PresenterInspector: View {
    @ObservedObject var session: Session
    let source: PDFSource

    private var notes: [Mark] {
        var notes = session.currentMarks.filter { $0.kind == .text }
        if let draft = session.textRequest?.mark {
            if let index = notes.firstIndex(where: { $0.id == draft.id }) { notes[index] = draft }
            else { notes.append(draft) }
        }
        return notes
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                nearbyPage("上一页", index: session.index - 1)
                nearbyPage("下一页", index: session.index + 1)
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("文字批注").font(.headline)
                        Spacer()
                        Button {
                            session.activate(.mark(.text))
                            session.requestText(at: InkPoint(x: 0.15, y: min(0.78, 0.18 + 0.075 * Double(notes.count))))
                        } label: {
                            Image(systemName: "plus").accessibilityLabel("添加文字批注")
                        }
                        .buttonStyle(.borderless)
                        .help("在画布上添加文字批注")
                    }
                    if notes.isEmpty {
                        Text("本页暂无文字批注")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(notes) { note in
                        noteRow(note)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .inspectorColumnWidth(min: 195, ideal: 248, max: 350)
    }

    private func nearbyPage(_ title: String, index: Int) -> some View {
        let available = source.geometries.indices.contains(index)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(available ? "第 \(index + 1) 页" : (index < 0 ? "已是首页" : "已是末页"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.04))
                if available {
                    Button {
                        session.navigate(to: index)
                    } label: {
                        OutputPreview(source: source, index: index, marks: session.marks(for: index), settings: session.output)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("跳到第 \(index + 1) 页")
                    .help("跳到第 \(index + 1) 页")
                } else {
                    AdjacentPagePlaceholder(canvasSize: session.output.size)
                }
            }
            .frame(height: 126)
            .clipShape(.rect(cornerRadius: 5))
        }
    }

    private func noteRow(_ mark: Mark) -> some View {
        let editing = session.textRequest?.id == mark.id
        return HStack(spacing: 8) {
            Button {
                session.editText(mark.id)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(Color(cgColor: mark.color.cgColor)).frame(width: 8, height: 8).padding(.top, 4)
                    Text(mark.text.isEmpty ? "正在输入…" : mark.text)
                        .lineLimit(3)
                        .foregroundStyle(mark.text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("在画布中编辑")
            .accessibilityLabel(mark.text.isEmpty ? "正在输入的文字批注" : "编辑批注：\(mark.text)")
            .disabled(editing)
            Menu {
                Button("删除文字批注", role: .destructive) { session.deleteText(mark.id) }
            } label: {
                Image(systemName: "ellipsis").accessibilityLabel("批注操作")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.callout)
        .padding(7)
        .background(editing ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.035), in: .rect(cornerRadius: 7))
    }
}

private struct AdjacentPagePlaceholder: View {
    let canvasSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            let card = CGRect(origin: .zero, size: geometry.size)
            let page = aspectFit(canvasSize, in: card.insetBy(dx: 10, dy: 10))
            VStack(alignment: .leading, spacing: min(7, page.height * 0.08)) {
                Capsule().fill(.primary.opacity(0.15)).frame(width: page.width * 0.38)
                Capsule().fill(.primary.opacity(0.075)).frame(width: page.width * 0.71)
                Capsule().fill(.primary.opacity(0.075)).frame(width: page.width * 0.54)
            }
            .frame(height: min(26, page.height * 0.38))
            .frame(width: page.width, height: page.height)
            .background(.primary.opacity(0.045), in: .rect(cornerRadius: 4))
            .position(x: page.midX, y: page.midY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
