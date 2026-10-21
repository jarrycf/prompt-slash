import AppKit
import ApplicationServices
import Observation
import SwiftUI

/// 全局斜杠片段（参考 Obsidian slash-snippets 插件）：
/// 在任意应用输入「/」+ 关键词，光标旁弹出候选，回车后替换为提示词内容，并把光标放到 %%cursor%% 处。
/// 需要「辅助功能」权限（监听按键、模拟粘贴、读取光标位置）。
@MainActor
final class SnippetEngine {
    private let model: AppModel
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private let panel = SnippetPanel()
    private var appObserver: Any?

    /// 自己发出的模拟按键带这个标记，监听时跳过
    nonisolated static let eventMarker: Int64 = 0x5053_5348

    // 当前输入状态
    private var active = false
    private var query = ""
    /// 记录自上一个空白 / 行首以来输入的字符，用来识别「行首或空格后输入触发字符串」
    private var tracker = TriggerTracker()
    /// 候选面板打开后用户是否按过 ↑↓（没输入关键词时，只有主动选过才允许回车插入）
    private var navigated = false

    init(model: AppModel) {
        self.model = model
        panel.onPick = { [weak self] index in self?.accept(index: index) }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancel()
                self?.tracker.reset()
            }
        }
    }

    // MARK: 启停

    func update() {
        if model.snippetsEnabled { start() } else { stop() }
    }

    private func start() {
        guard tap == nil else { return }
        let trusted = AXIsProcessTrusted()
        model.snippetPermission = trusted
        guard trusted else {
            scheduleRetry()
            return
        }
        retryTimer?.invalidate()
        retryTimer = nil

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: snippetTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            model.snippetPermission = false
            scheduleRetry()
            return
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        cancel()
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    /// 还没授权时每 2 秒检查一次，授权后自动开始工作
    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.retryTimer?.invalidate()
                    self.retryTimer = nil
                    self.start()
                }
            }
        }
    }

    /// 弹出系统授权提示并打开「辅助功能」设置
    func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        scheduleRetry()
    }

    // MARK: 按键处理（在主线程的事件回调里调用，必须快速返回）

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventMarker { return pass }

        if type == .leftMouseDown || type == .rightMouseDown {
            // 点在候选面板上交给面板处理，点别处则取消
            if !panel.contains(cgPoint: event.location) {
                cancel()
                tracker.reset()
            }
            return pass
        }
        guard type == .keyDown else { return pass }

        // 在本应用里打字（搜索框、编辑页）不触发
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            if active { cancel() }
            return pass
        }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let chars = Self.characters(of: event)
        let shortcut = flags.contains(.maskCommand) || flags.contains(.maskControl)

        if !active {
            tracker.trigger = model.snippetTrigger
            if shortcut { tracker.reset(); return pass }
            switch keyCode {
            case 51: tracker.backspace()
            case 36, 76, 48, 53, 123, 124, 125, 126, 115, 119, 116, 121, 117: tracker.reset()
            default:
                if tracker.type(chars), model.hasSnippetKeys { begin() }
            }
            return pass
        }

        // —— 候选面板打开时 ——
        if shortcut { cancel(); return pass }
        switch keyCode {
        case 36, 76, 48: // Return / Enter / Tab：插入
            // 刚输入触发字符串、还没输关键词也没主动选择时，回车照常换行（避免在代码注释 // 后误插入）
            guard !panel.state.items.isEmpty, !query.isEmpty || navigated else {
                cancel()
                tracker.reset()
                return pass
            }
            let index = panel.state.selected
            DispatchQueue.main.async { [weak self] in self?.accept(index: index) }
            return nil
        case 53: // Esc
            cancel()
            tracker.markWord()
            return nil
        case 125: // ↓
            panel.state.move(1)
            navigated = true
            return nil
        case 126: // ↑
            panel.state.move(-1)
            navigated = true
            return nil
        case 51: // Backspace
            if query.isEmpty {
                cancel() // 删掉了触发字符串的最后一个字符
                tracker.restore(String(model.snippetTrigger.dropLast()))
            } else {
                query.removeLast()
                refresh()
            }
            return pass
        case 123, 124, 115, 119, 116, 121, 117: // ←→ Home End PageUp PageDown ⌦
            cancel()
            tracker.reset()
            return pass
        default:
            guard !chars.isEmpty, !chars.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                cancel()
                tracker.reset()
                return pass
            }
            query += chars
            refresh()
            if panel.state.items.isEmpty {
                cancel() // 没有匹配，当作普通输入
                tracker.markWord()
            }
            return pass
        }
    }

    private func begin() {
        active = true
        navigated = false
        query = ""
        refresh()
        // 读取光标位置较慢，放到下一轮，避免阻塞按键回调
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active else { return }
            self.panel.show(near: Self.caretRect() ?? Self.mouseRect())
        }
    }

    private func refresh() {
        panel.state.query = query
        panel.state.trigger = model.snippetTrigger
        panel.state.items = Snippet.candidates(model.prompts, query: query)
        panel.state.selected = 0
        if active, panel.isVisible { panel.resize() }
    }

    func cancel() {
        guard active else { return }
        active = false
        query = ""
        panel.hide()
    }

    // MARK: 插入

    private func accept(index: Int) {
        let items = panel.state.items
        guard items.indices.contains(index) else { cancel(); return }
        let prompt = items[index]
        let typed = model.snippetTrigger.count + query.count // 触发字符串 + 关键词
        cancel()
        tracker.markWord()
        expand(prompt, deleting: typed)
    }

    private func expand(_ prompt: Prompt, deleting typed: Int) {
        let (text, moveLeft) = Snippet.prepare(prompt.content)
        let src = CGEventSource(stateID: .privateState)

        // 1. 删除已输入的「/关键词」
        for _ in 0..<typed { Self.tapKey(51, source: src) }

        // 2. 借剪贴板粘贴（长文本也很快），稍后恢复原剪贴板
        let pb = NSPasteboard.general
        let saved = Self.snapshot(pb)
        ClipboardPolicy.write(text, to: pb)
        let ourChange = pb.changeCount
        Self.tapKey(9, flags: .maskCommand, source: src) // ⌘V

        // 3. 把光标移到 %%cursor%% 处
        if moveLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                for _ in 0..<min(moveLeft, 5000) { Self.tapKey(123, source: src) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if pb.changeCount == ourChange { Self.restore(pb, saved) }
        }
        model.markUsed(prompt)
    }

    // MARK: 工具

    nonisolated private static func tapKey(_ code: CGKeyCode, flags: CGEventFlags = [], source: CGEventSource?) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            e.post(tap: .cghidEventTap)
        }
    }

    nonisolated private static func characters(of event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
        let s = String(utf16CodeUnits: buffer, count: length)
        // 功能键会给出私有区字符，过滤掉
        return s.unicodeScalars.contains { (0xF700...0xF8FF).contains($0.value) || $0.value < 0x20 } ? "" : s
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { dict[t] = d } }
            return dict
        }
    }

    private static func restore(_ pb: NSPasteboard, _ items: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let objs: [NSPasteboardItem] = items.map { dict in
            let item = NSPasteboardItem()
            for (t, d) in dict { item.setData(d, forType: t) }
            return item
        }
        // 恢复的是用户原来的内容，标记一下，免得剪贴板记录把它当成新复制的
        objs.first?.setData(Data(), forType: ClipboardPolicy.internalType)
        pb.writeObjects(objs)
    }

    /// 通过辅助功能读取当前输入光标在屏幕上的位置（Cocoa 坐标）
    private static func caretRect() -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement

        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.origin != .zero || rect.size != .zero else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: max(rect.width, 1), height: max(rect.height, 16))
    }

    private static func mouseRect() -> NSRect {
        let p = NSEvent.mouseLocation
        return NSRect(x: p.x, y: p.y - 10, width: 1, height: 20)
    }
}

/// 事件回调（C 函数）：在主线程运行，转交给 SnippetEngine
private func snippetTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<SnippetEngine>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { engine.handle(type: type, event: event) }
}

// MARK: - 候选面板

@Observable
final class SnippetPanelState {
    var items: [Prompt] = []
    var selected = 0
    var query = ""
    var trigger = "/"

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
    }
}

/// 不抢焦点的浮动面板，显示在输入光标下方
@MainActor
final class SnippetPanel {
    let state = SnippetPanelState()
    var onPick: ((Int) -> Void)?
    private let panel: NSPanel
    private var anchor: NSRect = .zero

    static let width: CGFloat = 380
    static let rowHeight: CGFloat = 44
    static let maxRows = 7

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: SnippetListView(state: state) { [weak self] i in self?.onPick?(i) })
        host.safeAreaRegions = []
        panel.contentView = host
    }

    var isVisible: Bool { panel.isVisible }

    /// 事件里的坐标是左上角原点（CG 坐标）
    func contains(cgPoint p: CGPoint) -> Bool {
        guard panel.isVisible else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return panel.frame.contains(NSPoint(x: p.x, y: primaryHeight - p.y))
    }

    func show(near caret: NSRect) {
        anchor = caret
        resize()
        panel.orderFrontRegardless()
    }

    func resize() {
        let rows = min(max(state.items.count, 1), Self.maxRows)
        let height = CGFloat(rows) * Self.rowHeight + 12 + 30
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        var x = anchor.minX - 12
        var y = anchor.minY - height - 6 // 默认在光标下方
        if y < vf.minY { y = anchor.maxY + 6 } // 下方放不下就放上方
        x = min(max(x, vf.minX + 4), vf.maxX - Self.width - 4)
        panel.setFrame(NSRect(x: x, y: y, width: Self.width, height: height), display: true)
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private struct SnippetListView: View {
    let state: SnippetPanelState
    let onPick: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(state.items.enumerated()), id: \.element.id) { i, p in
                            row(p, selected: i == state.selected)
                                .id(p.id)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(i) }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: state.selected) { _, i in
                    if state.items.indices.contains(i) { proxy.scrollTo(state.items[i].id) }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text("\(state.trigger)\(state.query)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L("↵ 插入", "↵ Insert"))
                Text(L("↑↓ 选择", "↑↓ Select"))
                Text(L("esc 取消", "esc Cancel"))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
        .background(VisualEffect(material: .menu))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }

    private func row(_ p: Prompt, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(p.key ?? "")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(selected ? Color.white : Color.accentColor)
                .frame(minWidth: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(Snippet.prepare(p.content).text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: SnippetPanel.rowHeight - 2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor : .clear)
        )
    }
}
