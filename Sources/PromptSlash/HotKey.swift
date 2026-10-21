import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - 快捷键组合

/// 全局快捷键：Carbon 键码 + Carbon 修饰键，外加录制时记下的按键名
struct KeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    static let `default` = KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey), key: "R")

    /// 例如「⌥R」「⌃⇧Space」
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    /// 菜单项上显示用
    var menuKeyEquivalent: String { key.count == 1 ? key.lowercased() : "" }

    var menuModifierMask: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
    ]

    private static let specialKeys: [UInt16: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    /// 由录制时的按键生成；没有 ⌘/⌥/⌃ 修饰键（F 键除外）时返回 nil，避免抢走普通打字
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }

        let code = event.keyCode
        let isFunctionKey = Self.functionKeys[code] != nil
        guard isFunctionKey || flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
            return nil
        }

        let label: String
        if let f = Self.functionKeys[code] {
            label = f
        } else if let s = Self.specialKeys[code] {
            label = s
        } else if let c = event.characters(byApplyingModifiers: []), !c.isEmpty,
                  c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            label = c.uppercased()
        } else {
            label = L("键\(code)", "Key \(code)")
        }
        self.init(keyCode: UInt32(code), modifiers: mods, key: label)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

// MARK: - 全局快捷键注册（Carbon，无需辅助功能权限）

final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    /// 注册失败通常是组合已被系统或其他应用占用
    private(set) var isRegistered = false

    init(combo: KeyCombo, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x5053_5448), id: 1) // "PSTH"
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        isRegistered = status == noErr
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

// MARK: - 设置页里的快捷键录制控件

struct HotKeyRecorder: View {
    @Environment(AppModel.self) private var model
    @State private var monitor: Any?
    @State private var hint: String?

    private var recording: Bool { monitor != nil }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Button(action: recording ? stop : start) {
                    Text(recording ? L("按下新的快捷键…", "Press new shortcut…") : model.hotKeyCombo.display)
                        .font(.system(size: 13, weight: .medium, design: recording ? .default : .rounded))
                        .foregroundStyle(recording ? Color.accentColor : .primary)
                        .frame(minWidth: 130)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.15),
                                              lineWidth: recording ? 1.5 : 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(recording ? L("按 Esc 取消", "Press Esc to cancel") : L("点击后按下新的快捷键", "Click, then press a new shortcut"))

                Button(L("恢复默认", "Reset to Default")) {
                    stop()
                    model.hotKeyCombo = .default
                }
                .disabled(model.hotKeyCombo == .default)
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.orange)
            } else if let error = model.hotKeyError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if recording {
                Text(L("需包含 ⌘ / ⌥ / ⌃ 之一（F 键除外），Esc 取消", "Must include ⌘ / ⌥ / ⌃ (except F keys). Esc to cancel")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        hint = nil
        model.isRecordingHotKey = true // 录制期间先注销旧快捷键，避免按下时触发
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53, mods.isEmpty { // Esc 取消
                stop()
                return nil
            }
            if let combo = KeyCombo(event: event) {
                hint = nil
                model.hotKeyCombo = combo
                stop()
            } else {
                hint = L("需要包含 ⌘、⌥ 或 ⌃ 修饰键", "Must include ⌘, ⌥ or ⌃")
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if model.isRecordingHotKey { model.isRecordingHotKey = false }
    }
}
