import SwiftUI

@MainActor
final class PresenterApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var session: Session? {
        didSet {
            guard pageMonitor == nil, session != nil else { return }
            pageMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let session = self?.session, let window = event.window,
                      window.delegate is PresenterWindowHook || window is AudienceWindow,
                      window.attachedSheet == nil, !(window.firstResponder is NSTextView),
                      !(window.firstResponder is NSTextField) else { return event }
                return session.handlePageShortcut(event) ? nil : event
            }
        }
    }

    private var pageMonitor: Any?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        session?.confirmLeavingDocument() == false ? .terminateCancel : .terminateNow
    }
}

struct PresenterWindowBridge: NSViewRepresentable {
    let session: Session
    let edited: Bool

    func makeNSView(context: Context) -> PresenterWindowHook { PresenterWindowHook(session: session) }

    func updateNSView(_ view: PresenterWindowHook, context: Context) {
        view.edited = edited
    }
}

@MainActor
final class PresenterWindowHook: NSView, NSWindowDelegate {
    private let session: Session
    private weak var attachedWindow: NSWindow?
    // NSObject's selector forwarding is nonisolated, while the window calls its delegate on the main thread.
    nonisolated(unsafe) private weak var originalDelegate: (any NSWindowDelegate)?
    var edited = false { didSet { window?.isDocumentEdited = edited } }

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if attachedWindow?.delegate === self { attachedWindow?.delegate = originalDelegate }
        attachedWindow = window
        originalDelegate = window?.delegate
        window?.delegate = self
        window?.isDocumentEdited = edited
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if originalDelegate?.responds(to: selector) == true { return originalDelegate }
        return super.forwardingTarget(for: selector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if originalDelegate?.windowShouldClose?(sender) == false { return false }
        return session.confirmLeavingDocument()
    }

    func windowWillClose(_ notification: Notification) {
        session.closeDocument()
        originalDelegate?.windowWillClose?(notification)
    }
}
