import SwiftUI

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case previousPage, nextPage, audienceWindow, fullScreen, openPDF, saveAnnotations, exportAnnotations

    static let presentation: [Self] = [.previousPage, .nextPage, .audienceWindow, .fullScreen]
    static let file: [Self] = [.openPDF, .saveAnnotations, .exportAnnotations]

    var id: Self { self }

    var title: String {
        switch self {
        case .previousPage: "上一页"
        case .nextPage: "下一页"
        case .audienceWindow: "打开或结束本地放映"
        case .fullScreen: "开始或退出全屏放映"
        case .openPDF: "打开 PDF"
        case .saveAnnotations: "保存批注"
        case .exportAnnotations: "导出批注 PDF"
        }
    }

    var defaultShortcut: AppShortcut {
        switch self {
        case .previousPage: AppShortcut(.pageUp)
        case .nextPage: AppShortcut(.pageDown)
        case .audienceWindow: AppShortcut("p", modifiers: [.command, .shift])
        case .fullScreen: AppShortcut("f", modifiers: [.command, .shift])
        case .openPDF: AppShortcut("o", modifiers: .command)
        case .saveAnnotations: AppShortcut("s", modifiers: .command)
        case .exportAnnotations: AppShortcut("e", modifiers: [.command, .shift])
        }
    }

    var acceptsUnmodifiedKeys: Bool { self == .previousPage || self == .nextPage }
}

struct AppShortcut: Codable, Equatable {
    private let key: String
    private let modifierBits: UInt

    static let leftArrow = Self(.leftArrow)
    static let rightArrow = Self(.rightArrow)
    private static let allowedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    private static let keyNames: [String: String] = [
        String(KeyEquivalent.leftArrow.character): "←", String(KeyEquivalent.rightArrow.character): "→",
        String(KeyEquivalent.upArrow.character): "↑", String(KeyEquivalent.downArrow.character): "↓",
        String(KeyEquivalent.pageUp.character): "Page Up", String(KeyEquivalent.pageDown.character): "Page Down",
        String(KeyEquivalent.home.character): "Home", String(KeyEquivalent.end.character): "End",
    ]
    private static let modifierNames: [(NSEvent.ModifierFlags, String, EventModifiers)] = [
        (.control, "⌃", .control), (.option, "⌥", .option), (.shift, "⇧", .shift), (.command, "⌘", .command),
    ]

    init(_ key: KeyEquivalent, modifiers: NSEvent.ModifierFlags = []) {
        self.key = String(key.character).lowercased()
        modifierBits = modifiers.intersection(Self.allowedModifiers).rawValue
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown, let characters = event.charactersIgnoringModifiers,
              characters.count == 1, let character = characters.first else { return nil }
        self.init(KeyEquivalent(character), modifiers: event.modifierFlags)
        guard isSupported else { return nil }
    }

    private var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierBits) }
    var isNavigationKey: Bool { Self.keyNames[key] != nil }
    var hasCommandModifier: Bool { !modifiers.intersection([.control, .option, .command]).isEmpty }

    var isSupported: Bool {
        guard modifiers.isSubset(of: Self.allowedModifiers) else { return false }
        if isNavigationKey { return true }
        guard key.utf8.count == 1, let code = key.utf8.first else { return false }
        return (97...122).contains(code) || (48...57).contains(code) || key == ","
    }

    var display: String {
        Self.modifierNames.filter { modifiers.contains($0.0) }.map(\.1).joined()
            + (Self.keyNames[key] ?? key.uppercased())
    }

    var keyboardShortcut: KeyboardShortcut {
        let swiftUIModifiers = Self.modifierNames.reduce(into: EventModifiers()) { result, item in
            if modifiers.contains(item.0) { result.insert(item.2) }
        }
        return KeyboardShortcut(KeyEquivalent(Character(key)), modifiers: swiftUIModifiers)
    }
}

@MainActor
final class ShortcutBindings: ObservableObject {
    private static let storageKey = "ShortcutBindings"
    private static let initial = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
    private static let reserved: [AppShortcut] = ["q", "w", "m", "h", ",", "z", "a", "c", "v", "x", "f"]
        .map { AppShortcut(KeyEquivalent($0), modifiers: .command) }
        + [AppShortcut("z", modifiers: [.command, .shift]), AppShortcut("h", modifiers: [.command, .option]),
           AppShortcut("f", modifiers: [.command, .control]), AppShortcut("w", modifiers: [.command, .option]),
           AppShortcut("m", modifiers: [.command, .option])]

    private let defaults: UserDefaults
    @Published private var bindings: [ShortcutAction: AppShortcut]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([ShortcutAction: AppShortcut].self, from: $0) } ?? [:]
        let candidate = Self.initial.merging(stored) { _, saved in saved }
        bindings = candidate.allSatisfy { Self.problem(with: $0.value, for: $0.key, in: candidate) == nil }
            ? candidate : Self.initial
    }

    subscript(action: ShortcutAction) -> AppShortcut { bindings[action] ?? action.defaultShortcut }

    func assign(_ shortcut: AppShortcut, to action: ShortcutAction) -> String? {
        if let problem = Self.problem(with: shortcut, for: action, in: bindings) { return problem }
        bindings[action] = shortcut
        defaults.set(try? JSONEncoder().encode(bindings), forKey: Self.storageKey)
        return nil
    }

    func reset() {
        bindings = Self.initial
        defaults.removeObject(forKey: Self.storageKey)
    }

    func pageOffset(for event: NSEvent) -> Int? {
        guard let shortcut = AppShortcut(event: event) else { return nil }
        if shortcut == self[.previousPage] || shortcut == .leftArrow { return -1 }
        if shortcut == self[.nextPage] || shortcut == .rightArrow { return 1 }
        return nil
    }

    private static func problem(with shortcut: AppShortcut, for action: ShortcutAction,
                                in bindings: [ShortcutAction: AppShortcut]) -> String? {
        if reserved.contains(shortcut) { return "这个组合键已用于 macOS 的标准操作。" }
        if shortcut == .leftArrow || shortcut == .rightArrow { return "左右方向键已经用于翻页，请选用其他按键。" }
        guard shortcut.isSupported, shortcut.hasCommandModifier || (action.acceptsUnmodifiedKeys && shortcut.isNavigationKey) else {
            return action.acceptsUnmodifiedKeys ? "请使用方向键、翻页键，或带 ⌘、⌃、⌥ 的组合键。"
                : "请使用带 ⌘、⌃ 或 ⌥ 的组合键。"
        }
        if let conflict = ShortcutAction.allCases.first(where: { $0 != action && bindings[$0] == shortcut }) {
            return "这个组合键已绑定到「\(conflict.title)」。"
        }
        return nil
    }
}
