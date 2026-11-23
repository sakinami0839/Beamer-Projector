import SwiftUI

struct ProjectorSettings: View {
    let shortcuts: ShortcutBindings

    var body: some View {
        TabView {
            ShortcutSettingsPane(shortcuts: shortcuts)
                .tabItem { Label("快捷键", systemImage: "keyboard") }
            AboutSettingsPane()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 495, height: 400)
    }
}

private struct ShortcutSettingsPane: View {
    @ObservedObject var shortcuts: ShortcutBindings
    @State private var recording: ShortcutAction?
    @State private var monitor: Any?
    @State private var recordingWindowNumber: Int?
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("放映") { ForEach(ShortcutAction.presentation) { row($0) } }
                Section("文件") { ForEach(ShortcutAction.file) { row($0) } }
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: 12) {
                Text(problem ?? (recording == nil ? "点击按键可重新绑定。左右方向键也可翻页。" : "按下新快捷键，或按 Esc 取消。"))
                    .font(.callout)
                    .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("恢复默认") {
                    stopRecording()
                    shortcuts.reset()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(minHeight: 59)
        }
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window.windowNumber == recordingWindowNumber {
                stopRecording()
            }
        }
    }

    private func row(_ action: ShortcutAction) -> some View {
        LabeledContent(action.title) {
            Button(recording == action ? "按下快捷键…" : shortcuts[action].display) {
                if recording == action { stopRecording() }
                else { record(action) }
            }
            .font(.callout.monospaced())
            .frame(width: 118, alignment: .trailing)
            .accessibilityLabel("绑定" + action.title)
            .accessibilityValue(recording == action ? "正在录入" : shortcuts[action].display)
        }
    }

    private func record(_ action: ShortcutAction) {
        stopRecording()
        guard let window = NSApp.keyWindow else { return }
        recording = action
        recordingWindowNumber = window.windowNumber
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, event.window === window else { return event }
            if event.keyCode == 53 {
                stopRecording()
            } else if !event.isARepeat {
                if let shortcut = AppShortcut(event: event) {
                    problem = shortcuts.assign(shortcut, to: action)
                    if problem == nil { stopRecording() }
                } else {
                    problem = "请使用字母、数字或方向及翻页键。"
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingWindowNumber = nil
        recording = nil
        problem = nil
    }
}

private struct AboutSettingsPane: View {
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    private var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().antialiased(true).aspectRatio(contentMode: .fit)
                .frame(width: 86, height: 86)
                .accessibilityHidden(true)
            Text("Beamer Projector").font(.title2.weight(.semibold))
            Text("版本 \(version)（\(build)）")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            Text("在 macOS 上放映和批注 Beamer PDF，并通过 Syphon 将观众画面送入 OBS。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
