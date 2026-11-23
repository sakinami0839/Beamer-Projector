import SwiftUI

enum LocalPresentation: Equatable {
    case off, window, fullScreen
}

@MainActor
final class AudienceWindow: NSWindow {
    var fillsScreen = false
    var pointerMoved: ((Bool) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { !fillsScreen }

    override func sendEvent(_ event: NSEvent) {
        if fillsScreen {
            if event.type == .keyDown, event.keyCode == 53 {
                close()
                return
            }
            if event.type == .mouseMoved {
                pointerMoved?(event.locationInWindow.y >= frame.height - 72)
            }
        }
        super.sendEvent(event)
    }

}

private struct FullScreenTitle: View {
    let title: String
    let exit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title).lineLimit(1).font(.callout.weight(.semibold)).frame(maxWidth: 280)
            Divider().frame(height: 15)
            Button(action: exit) {
                Label("退出全屏", systemImage: "arrow.down.right.and.arrow.up.left")
                Text("esc").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("退出全屏放映 · Esc")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
    }
}

@MainActor
final class ProjectorWindow: NSWindowController, NSWindowDelegate {
    private weak var session: Session?
    private let controls = NSHostingView(rootView: FullScreenTitle(title: "", exit: {}))
    private var pendingHide: DispatchWorkItem?

    init(session: Session, screen: NSScreen?) {
        self.session = session
        let window = AudienceWindow(contentRect: CGRect(x: 100, y: 100, width: 960, height: 540),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.acceptsMouseMovedEvents = true
        let view = NSView()
        let slide = SlideView(session: session, audience: true)
        slide.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(slide)
        view.addSubview(controls)
        NSLayoutConstraint.activate([
            slide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            slide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            slide.topAnchor.constraint(equalTo: view.topAnchor),
            slide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controls.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controls.topAnchor.constraint(equalTo: view.topAnchor, constant: 13),
        ])
        window.contentView = view
        super.init(window: window)
        window.delegate = self
        window.pointerMoved = { [weak self] nearTop in self?.showControls(nearTop, briefly: false) }
        updateTitle()
        show(on: screen)
    }

    required init?(coder: NSCoder) { nil }

    func updateTitle() {
        guard let window, let session else { return }
        window.title = "观众窗口 — " + session.title
        controls.rootView = FullScreenTitle(title: session.title, exit: { [weak self] in self?.window?.close() })
    }

    func show(on screen: NSScreen?) {
        guard let window = window as? AudienceWindow else { return }
        let wasFullScreen = window.fillsScreen
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.fillsScreen = screen != nil
        if let screen {
            window.styleMask = [.borderless]
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window)
            showControls(true, briefly: true)
        } else {
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.level = .normal
            window.minSize = CGSize(width: 320, height: 200)
            if !window.isVisible || wasFullScreen {
                let bounds = NSScreen.main?.visibleFrame ?? CGRect(x: 100, y: 100, width: 960, height: 540)
                let ideal = session?.output.size ?? CGSize(width: 1920, height: 1080)
                let size = aspectFit(ideal, in: CGRect(x: 0, y: 0, width: bounds.width * 0.58, height: bounds.height * 0.62)).size
                window.setContentSize(CGSize(width: max(320, size.width), height: max(200, size.height)))
                window.setFrameTopLeftPoint(CGPoint(x: bounds.maxX - window.frame.width - 18, y: bounds.maxY - 18))
            }
            window.orderFront(nil)
            showControls(false, briefly: false)
        }
    }

    private func showControls(_ show: Bool, briefly: Bool) {
        pendingHide?.cancel()
        controls.isHidden = !show
        guard briefly else { return }
        let hide = DispatchWorkItem { [weak self] in self?.controls.isHidden = true }
        pendingHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: hide)
    }

    func windowWillClose(_ notification: Notification) { session?.projectorDidClose() }
}
