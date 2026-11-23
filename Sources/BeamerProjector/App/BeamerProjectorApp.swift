import SwiftUI

@main
struct BeamerProjectorApp: App {
    @StateObject private var session: Session
    @StateObject private var shortcuts: ShortcutBindings
    @NSApplicationDelegateAdaptor(PresenterApplicationDelegate.self) private var applicationDelegate

    init() {
        let shortcuts = ShortcutBindings()
        _shortcuts = StateObject(wrappedValue: shortcuts)
        _session = StateObject(wrappedValue: Session(shortcuts: shortcuts))
    }

    var body: some Scene {
        Window("Beamer Projector", id: "presenter") {
            Presenter(session: session)
                .frame(minWidth: 860, minHeight: 500)
                .onOpenURL { session.open($0) }
                .task {
                    applicationDelegate.session = session
                    if session.source == nil,
                       let path = CommandLine.arguments.dropFirst().first(where: { $0.lowercased().hasSuffix(".pdf") }) {
                        session.open(URL(fileURLWithPath: path))
                    }
                }
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开 PDF…") { session.pickPDF() }
                    .keyboardShortcut(shortcuts[.openPDF].keyboardShortcut)
                Divider()
                Button("保存批注") { session.savePDF() }
                    .keyboardShortcut(shortcuts[.saveAnnotations].keyboardShortcut)
                    .disabled(!session.hasUnsavedChanges)
                Button("导出批注 PDF…") { session.exportPDF() }
                    .keyboardShortcut(shortcuts[.exportAnnotations].keyboardShortcut)
                    .disabled(session.source == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") {
                    if session.textRequest == nil { session.undo() }
                    else { NSApp.keyWindow?.firstResponder?.undoManager?.undo() }
                }
                .keyboardShortcut("z").disabled(session.textRequest == nil && !session.canUndo)
                Button("重做") {
                    if session.textRequest == nil { session.redo() }
                    else { NSApp.keyWindow?.firstResponder?.undoManager?.redo() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(session.textRequest == nil && !session.canRedo)
            }
            CommandMenu("放映") {
                Button("上一页") { session.navigate(to: session.index - 1) }
                    .disabled(session.index == 0 || session.textRequest != nil)
                Button("下一页") { session.navigate(to: session.index + 1) }
                    .disabled((session.source?.count ?? 0) <= session.index + 1 || session.textRequest != nil)
                Divider()
                Button(session.projectorOpen ? "结束本地放映" : "打开观众窗口") {
                    if session.projectorOpen { session.closeProjector() } else { session.showProjector(on: nil) }
                }
                .keyboardShortcut(shortcuts[.audienceWindow].keyboardShortcut)
                .disabled(session.source == nil)
                Button(session.localPresentation == .fullScreen ? "退出全屏放映" : "开始全屏放映") {
                    session.toggleFullScreen()
                }
                .keyboardShortcut(shortcuts[.fullScreen].keyboardShortcut)
                .disabled(session.source == nil)
                Button(session.obsActive ? "停止 OBS 输出" : "启用 OBS 输出") { session.toggleOBS() }
                    .disabled(session.source == nil)
            }
        }

        Settings {
            ProjectorSettings(shortcuts: shortcuts)
        }
    }
}
