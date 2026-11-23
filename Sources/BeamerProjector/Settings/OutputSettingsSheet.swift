import SwiftUI

struct OutputSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: Session
    @State var draft: OutputSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("输出画布").font(.title2.weight(.semibold))
            HStack(alignment: .center, spacing: 24) {
                Form {
                    LabeledContent("预设") {
                        Menu("常用比例") {
                            Button("1920 × 1080 · 16:9") { preset(1920, 1080) }
                            Button("1440 × 1080 · 4:3") { preset(1440, 1080) }
                            Button("1080 × 1920 · 9:16") { preset(1080, 1920) }
                        }
                    }
                    numeric("宽度（像素）", $draft.width)
                    numeric("高度（像素）", $draft.height)
                    Picker("帧率", selection: $draft.fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    Divider()
                    numeric("上边距", $draft.top)
                    numeric("下边距", $draft.bottom)
                    numeric("左边距", $draft.left)
                    numeric("右边距", $draft.right)
                }
                .frame(width: 243)
                VStack(alignment: .leading, spacing: 7) {
                    Text("观众画面预览").font(.headline)
                    ZStack {
                        RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.045))
                        if draft.isValid, let source = session.source {
                            OutputPreview(source: source, index: session.index, marks: session.currentMarks, settings: draft)
                                .padding(7)
                        } else {
                            Text(draft.isValid ? "打开课件后显示预览" : "请修正画布参数").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 290, height: 225)
                }
            }
            Text(draft.isValid ? "PDF 等比居中，四边边距和剩余区域填黑。"
                 : "宽高须为 16–4096 之间的偶数，四边边距必须留出有效的课件区域。")
                .font(.caption).foregroundStyle(draft.isValid ? Color.secondary : Color.red)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用") { session.updateOutput(draft); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!draft.isValid)
            }
        }
        .padding(23)
    }

    private func numeric(_ name: String, _ value: Binding<Int>) -> some View {
        TextField(name, value: value, format: .number.grouping(.never))
    }

    private func preset(_ width: Int, _ height: Int) {
        draft.width = width
        draft.height = height
    }
}
