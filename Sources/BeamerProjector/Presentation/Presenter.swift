import SwiftUI

struct PresenterMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animation: Animation? { reduceMotion ? nil : .smooth(duration: 0.22) }
    var fade: Animation? { reduceMotion ? nil : .easeOut(duration: 0.16) }
}


struct Presenter: View {
    @ObservedObject var session: Session
    private var motion = PresenterMotion()
    @State private var showSettings = false
    @State private var confirmingClear = false
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var displays: [NSScreen] = NSScreen.screens

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Group {
                if let source = session.source {
                    NavigatorPanel(session: session, source: source)
                        .id(source.fingerprint)
                } else {
                    ContentUnavailableView("暂无课件", systemImage: "sidebar.left",
                                           description: Text("打开 PDF 后即可按目录或页面导航。"))
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 227, max: 390)
        } detail: {
            detail
                .inspector(isPresented: $session.showsInspector) {
                    if let source = session.source {
                        PresenterInspector(session: session, source: source)
                    }
                }
        }
        .navigationTitle(session.hasUnsavedChanges ? session.title + " •" : session.title)
        .background(PresenterWindowBridge(session: session, edited: session.hasUnsavedChanges))
        .toolbar { toolbar }
        .sheet(isPresented: $showSettings) { OutputSettingsSheet(session: session, draft: session.output) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = NSScreen.screens
        }
        .onExitCommand {
            if session.textRequest != nil { session.cancelText() }
            else if session.localPresentation == .fullScreen { session.closeProjector() }
        }
        .onDisappear { session.finishText() }
        .alert("无法完成操作", isPresented: Binding(get: { session.lastError != nil }, set: { if !$0 { session.lastError = nil } })) {
            Button("好") { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
        }
        .confirmationDialog("清除本页的全部批注？", isPresented: $confirmingClear) {
            Button("清除批注", role: .destructive) { session.clearPage() }
        } message: {
            Text("此操作可撤销。共享页标签的逐步揭示页也会更新。")
        }
    }

    private var detail: some View {
        Group {
            if let source = session.source {
                VStack(spacing: 0) {
                    EditableCanvas(session: session)
                        .frame(minHeight: 235)
                    AnnotationTools(session: session) { confirmingClear = true }
                        .padding(.vertical, 10)
                    status(source)
                        .padding(.horizontal, 15)
                        .padding(.bottom, 8)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
            } else {
                ContentUnavailableView {
                    Label("打开 PDF 课件", systemImage: "play.rectangle")
                } description: {
                    Text("在演讲者窗口批注，将课件放映到观众窗口或 OBS。")
                } actions: {
                    Button("打开 PDF…") { session.pickPDF() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func status(_ source: PDFSource) -> some View {
        HStack(spacing: 7) {
            pageArrow("上一页", "chevron.left", destination: session.index - 1)
                .disabled(session.index == 0)
            Text("\(session.index + 1) / \(source.count)").monospacedDigit()
                .accessibilityLabel("第 \(session.index + 1) 页，共 \(source.count) 页")
            pageArrow("下一页", "chevron.right", destination: session.index + 1)
                .disabled(session.index + 1 == source.count)
            Spacer()
            if session.projectorOpen {
                Image(systemName: "display")
                    .help(session.localPresentation == .fullScreen ? "正在全屏放映" : "观众窗口打开")
            }
            if session.obsActive {
                Label(session.obsConnected ? "OBS 已连接" : "等待 OBS",
                      systemImage: session.obsConnected ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(session.obsConnected ? Color.green : Color.secondary)
            }
            Button {
                showSettings = true
            } label: {
                Text("\(String(session.output.width)) × \(String(session.output.height)) · \(session.output.fps) fps")
                    .monospacedDigit()
            }
            .buttonStyle(.plain)
            .help("输出画布设置")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func pageArrow(_ title: String, _ symbol: String, destination: Int) -> some View {
        Button { session.navigate(to: destination) } label: {
            Image(systemName: symbol)
                .frame(width: 23, height: 23)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { session.pickPDF() } label: { Label("打开 PDF", systemImage: "folder") }
            Button { session.exportPDF() } label: { Label("导出批注", systemImage: "square.and.arrow.up") }
                .disabled(session.source == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(session.localPresentation == .window ? "显示观众窗口" : "窗口放映") {
                    session.showProjector(on: nil)
                }
                Menu("全屏放映到") {
                    ForEach(Array(displays.enumerated()), id: \.offset) { index, screen in
                        let label = displays.filter { $0.localizedName == screen.localizedName }.count > 1
                            ? "\(screen.localizedName)（\(index + 1)）" : screen.localizedName
                        Button(label) { session.showProjector(on: screen) }
                    }
                }
                if session.projectorOpen {
                    Divider()
                    Button("结束本地放映") { session.closeProjector() }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "display")
                    Text("本地放映")
                }
            }
            .disabled(session.source == nil)
            .help("打开窗口或在指定显示器全屏放映")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(session.obsActive ? "停止 OBS 输出" : "启用 OBS 输出") { session.toggleOBS() }
                Button("仅通过 OBS 放映") { session.startHeadless() }
                    .disabled(session.obsActive && !session.projectorOpen)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: session.obsActive ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                    Text("OBS 输出")
                }
            }
            .disabled(session.source == nil)
            .help("管理 Syphon 画面输出")
        }
        ToolbarItemGroup(placement: .automatic) {
            Button { showSettings = true } label: { Label("输出设置", systemImage: "slider.horizontal.3") }
            Button {
                withAnimation(motion.animation) { session.showsInspector.toggle() }
            } label: { Label("演讲者检查器", systemImage: "sidebar.right") }
                .disabled(session.source == nil)
        }
    }
}
