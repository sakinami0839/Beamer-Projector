import AppKit
import Combine

struct ProjectError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class Session: ObservableObject {
    static let frameDidChange = Notification.Name("BeamerProjector.FrameChanged")

    @Published private(set) var source: PDFSource?
    @Published private(set) var index = 0
    @Published private var marks: [Int: [Mark]] = [:] {
        didSet { baseMarksRevision &+= 1 }
    }
    @Published private var savedMarks: [Int: [Mark]] = [:]
    @Published private var annotationHistory = AnnotationHistory()
    @Published private(set) var tool: Tool = .mark(.pen)
    let annotationPreferences = AnnotationPreferences()
    private(set) var tabletEraser: Tool = .eraseStroke
    @Published var selection: Set<UUID> = []
    @Published var textRequest: TextRequest?
    @Published var lastError: String?
    @Published private(set) var output = OutputSettings()
    @Published private(set) var localPresentation: LocalPresentation = .off
    @Published private(set) var obsActive = false
    @Published private(set) var obsConnected = false
    @Published var showsInspector = true

    private(set) var revision = 0
    private(set) var baseMarksRevision = 0
    private(set) var draft: Mark?
    private var workingMarks: [Mark]? {
        didSet {
            if oldValue != nil || workingMarks != nil { baseMarksRevision &+= 1 }
        }
    }
    private var projector: ProjectorWindow?
    private var syphon: SyphonOutput?
    private let recovery: AnnotationRecovery
    let shortcuts: ShortcutBindings

    struct TextRequest: Identifiable {
        let group: Int
        var mark: Mark
        var id: UUID { mark.id }
    }

    init(recoveryDirectory: URL = URL.applicationSupportDirectory.appending(path: "Beamer Projector/Recovery"),
         shortcuts: ShortcutBindings? = nil) {
        self.recovery = AnnotationRecovery(directory: recoveryDirectory)
        self.shortcuts = shortcuts ?? ShortcutBindings()
        if let data = UserDefaults.standard.data(forKey: "OutputSettings"),
           let saved = try? JSONDecoder().decode(OutputSettings.self, from: data), saved.isValid {
            output = saved
        }
    }

    var projectorOpen: Bool { localPresentation != .off }
    var title: String { source?.url.deletingPathExtension().lastPathComponent ?? "Beamer Projector" }
    var currentGroup: Int { source?.groups[index] ?? 0 }
    var currentMarks: [Mark] { marks[currentGroup, default: []] }
    var canUndo: Bool { annotationHistory.canUndo }
    var canRedo: Bool { annotationHistory.canRedo }
    var baseMarks: [Mark] { workingMarks ?? currentMarks }
    var visibleMarks: [Mark] {
        draft.map { baseMarks + [$0] } ?? baseMarks
    }
    var hasUnsavedChanges: Bool {
        if marks != savedMarks { return true }
        guard let request = textRequest else { return false }
        let original = marks[request.group]?.first { $0.id == request.id }
        if request.mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return original != nil }
        return request.mark != original
    }

    func marks(for page: Int) -> [Mark] { source.map { marks[$0.groups[page], default: []] } ?? [] }

}

// MARK: - Document lifecycle

extension Session {
    func open(_ url: URL) {
        if url.standardizedFileURL.resolvingSymlinksInPath() == source?.url.standardizedFileURL.resolvingSymlinksInPath() {
            return
        }
        do {
            let loaded = try PDFSource(url: url)
            guard confirmLeavingDocument() else { return }
            source = loaded
            index = 0
            savedMarks = loaded.embeddedMarks
            marks = recovery.load(for: loaded) ?? savedMarks
            resetEditingState()
            projector?.updateTitle()
            refresh()
        } catch {
            report(error)
        }
    }

    func pickPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func exportPDF() {
        guard let source else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = source.url.deletingPathExtension().lastPathComponent + "-批注.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        finishGesture()
        finishText()
        do { try source.export(marks: marks, to: url) }
        catch { report(error) }
    }

    @discardableResult
    func savePDF() -> Bool {
        finishGesture()
        finishText()
        guard let source, hasUnsavedChanges else { return true }
        let previousRecoveryLocation = recovery.location(for: source)
        do {
            try source.save(marks: marks)
        } catch {
            report(error)
            return false
        }
        savedMarks = marks
        do { try recovery.remove(at: previousRecoveryLocation) }
        catch { report(error) }
        return true
    }

    func confirmLeavingDocument() -> Bool {
        if draft != nil || workingMarks != nil { finishGesture() }
        guard hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.messageText = "要保存对「\(title)」的批注吗？"
        alert.informativeText = "保存会将批注写入原 PDF。丢弃会清除本次未保存的修改。"
        let discard = alert.addButton(withTitle: "丢弃批注")
        let save = alert.addButton(withTitle: "保存到原 PDF")
        let cancel = alert.addButton(withTitle: "取消")
        discard.keyEquivalent = "\r"
        save.keyEquivalent = ""
        cancel.keyEquivalent = "\u{1b}"
        alert.window.defaultButtonCell = discard.cell as? NSButtonCell
        switch alert.runModal() {
        case .alertFirstButtonReturn: return discardChanges()
        case .alertSecondButtonReturn: return savePDF()
        default: return false
        }
    }

    private func discardChanges() -> Bool {
        guard let source else { return true }
        do { try recovery.remove(at: recovery.location(for: source)) }
        catch {
            report(error)
            return false
        }
        marks = savedMarks
        resetEditingState()
        refresh()
        return true
    }

    func closeDocument() {
        closeProjector()
        if obsActive { toggleOBS() }
        source = nil
        index = 0
        marks = [:]
        savedMarks = [:]
        resetEditingState()
        refresh()
    }

    private func resetEditingState() {
        annotationHistory = AnnotationHistory()
        selection = []
        textRequest = nil
        draft = nil
        workingMarks = nil
    }

}

// MARK: - Navigation and frame updates

extension Session {
    func navigate(to target: Int) {
        guard let source, source.geometries.indices.contains(target), target != index else { return }
        finishGesture()
        finishText()
        index = target
        selection = []
        refresh()
    }

    func handlePageShortcut(_ event: NSEvent) -> Bool {
        guard source != nil, textRequest == nil, let offset = shortcuts.pageOffset(for: event) else { return false }
        navigate(to: index + offset)
        return true
    }

    private func refresh() {
        revision &+= 1
        NotificationCenter.default.post(name: Self.frameDidChange, object: self)
    }

}

// MARK: - Annotation editing and undo

extension Session {
    var styleTarget: StyleTarget {
        switch tool {
        case .mark(.fountainPen): .fountainPen
        case .mark(.highlighter): .highlighter
        case .mark(.text): .text
        case .mark(.line), .mark(.arrow), .mark(.rectangle), .mark(.ellipse): .shape
        default: .pen
        }
    }

    func style(for target: StyleTarget) -> AnnotationStyle {
        if target == .text, let text = textRequest {
            return AnnotationStyle(color: text.mark.color, width: text.mark.width)
        }
        return annotationPreferences.styles[target] ?? AnnotationStyle(color: .red, width: 0.009)
    }

    func setStyle(_ style: AnnotationStyle, for target: StyleTarget) {
        if annotationPreferences.styles[target] != style { annotationPreferences.styles[target] = style }
        if target == .text, var text = textRequest,
           AnnotationStyle(color: text.mark.color, width: text.mark.width) != style {
            text.mark.color = style.color
            text.mark.width = style.width
            textRequest = text
        }
    }

    func activate(_ tool: Tool) {
        if tool != .mark(.text) { finishText() }
        if tool == .eraseStroke || tool == .erasePart { tabletEraser = tool }
        self.tool = tool
        if tool != .lasso { selection = []; refresh() }
    }

    func setDraft(_ mark: Mark?) {
        draft = mark
        refresh()
    }

    func setWorking(_ marks: [Mark]) {
        workingMarks = marks
        refresh()
    }

    func cancelGesture() {
        draft = nil
        workingMarks = nil
        refresh()
    }

    func finishGesture() {
        let proposed = visibleMarks
        let changed = draft != nil || workingMarks != nil
        draft = nil
        workingMarks = nil
        if changed { commit(proposed, group: currentGroup) }
        refresh()
    }

    func requestText(at point: InkPoint) {
        finishText()
        let anchor = InkPoint(x: min(point.x, 0.82), y: min(point.y, 0.87))
        let style = style(for: .text)
        let mark = Mark(kind: .text, width: style.width, color: style.color, paths: [[anchor]],
                        textBox: TextBoxSize(width: 0.36, height: 0.19).clamped(at: anchor))
        textRequest = TextRequest(group: currentGroup, mark: mark)
        selection = []
    }

    func editSelectedText() {
        guard selection.count == 1,
              let id = selection.first else { return }
        editText(id)
    }

    func editText(_ id: UUID) {
        guard textRequest?.id != id else { return }
        finishText()
        guard var mark = currentMarks.first(where: { $0.id == id && $0.kind == .text }) else { return }
        if mark.textBox == nil {
            let anchor = InkPoint(x: min(mark.textAnchor.x, 0.88), y: min(mark.textAnchor.y, 0.92))
            mark.paths = [[anchor]]
            mark.textBox = TextBoxSize(width: 0.48, height: 0.24).clamped(at: anchor)
        }
        tool = .mark(.text)
        selection = []
        textRequest = TextRequest(group: currentGroup, mark: mark)
        refresh()
    }

    func finishText() {
        guard let request = textRequest else { return }
        textRequest = nil
        let mark = request.mark
        var existing = marks[request.group, default: []]
        if mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            existing.removeAll { $0.id == mark.id }
        } else if let index = existing.firstIndex(where: { $0.id == mark.id }) {
            existing[index] = mark
        } else {
            existing.append(mark)
        }
        commit(existing, group: request.group)
        refresh()
    }

    func cancelText() {
        guard textRequest != nil else { return }
        textRequest = nil
        refresh()
    }

    func deleteText(_ id: UUID) {
        if textRequest?.id == id { cancelText() }
        commit(currentMarks.filter { $0.id != id }, group: currentGroup)
    }

    func removeSelection() {
        guard !selection.isEmpty else { return }
        commit(currentMarks.filter { !selection.contains($0.id) }, group: currentGroup)
        selection = []
    }

    func clearPage() {
        cancelText()
        commit([], group: currentGroup)
        selection = []
    }

    private func commit(_ next: [Mark], group: Int) {
        let before = marks[group, default: []]
        guard next != before else { return }
        annotationHistory.record(group: group, before: before, after: next)
        apply(next, to: group)
    }

    func undo() {
        cancelText()
        guard let entry = annotationHistory.undo() else { return }
        applyHistory(entry.before, to: entry.group)
    }

    func redo() {
        cancelText()
        guard let entry = annotationHistory.redo() else { return }
        applyHistory(entry.after, to: entry.group)
    }

    private func applyHistory(_ marks: [Mark], to group: Int) {
        apply(marks, to: group)
        if currentGroup != group { navigate(to: group) }
        selection = []
    }

    private func apply(_ newMarks: [Mark], to group: Int) {
        marks[group] = newMarks.isEmpty ? nil : newMarks
        refresh()
        guard let source else { return }
        do {
            let url = recovery.location(for: source)
            if marks == savedMarks {
                try recovery.remove(at: url)
            } else {
                try recovery.write(marks, to: url)
            }
        } catch {
            report(ProjectError("批注已保留在当前会话，但自动保存失败。\n\(error.localizedDescription)"))
        }
    }

}

// MARK: - Presentation outputs

extension Session {
    func updateOutput(_ settings: OutputSettings, persist: Bool = true) {
        guard settings.isValid else { return }
        output = settings
        if persist, let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "OutputSettings")
        }
        syphon?.configure(settings)
        refresh()
    }

    func showProjector(on screen: NSScreen?) {
        guard source != nil else { return }
        if let projector {
            projector.show(on: screen)
        } else {
            projector = ProjectorWindow(session: self, screen: screen)
        }
        localPresentation = screen == nil ? .window : .fullScreen
    }

    func closeProjector() { projector?.window?.close() }

    func toggleFullScreen() {
        if localPresentation == .fullScreen {
            closeProjector()
        } else if let screen = projector?.window?.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main {
            showProjector(on: screen)
        }
    }

    func projectorDidClose() {
        projector = nil
        localPresentation = .off
    }

    func startHeadless() {
        if syphon == nil { toggleOBS() }
        if syphon != nil { closeProjector() }
    }

    func toggleOBS() {
        if syphon != nil {
            syphon?.stop()
            syphon = nil
            obsActive = false
            obsConnected = false
            return
        }
        do {
            let publisher = try SyphonOutput(session: self)
            syphon = publisher
            obsActive = true
            publisher.configure(output)
        } catch { report(error) }
    }

    func setOBSConnected(_ connected: Bool) {
        if obsConnected != connected { obsConnected = connected }
    }

    func report(_ error: Error) { lastError = error.localizedDescription }
}
