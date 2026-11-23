struct AnnotationHistory {
    struct Edit {
        let group: Int
        let before: [Mark]
        let after: [Mark]
    }

    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func record(group: Int, before: [Mark], after: [Mark]) {
        undoStack.append(Edit(group: group, before: before, after: after))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    mutating func undo() -> Edit? {
        guard let edit = undoStack.popLast() else { return nil }
        redoStack.append(edit)
        return edit
    }

    mutating func redo() -> Edit? {
        guard let edit = redoStack.popLast() else { return nil }
        undoStack.append(edit)
        return edit
    }
}
