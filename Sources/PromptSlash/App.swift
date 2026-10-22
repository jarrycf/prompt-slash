import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@main
struct PromptSlashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 启动器窗口由 AppDelegate 用 AppKit 管理（固定尺寸、置顶、快捷键呼出/隐藏）
        // 设置窗口由 AppDelegate 自己管理（macOS 14 起无法从 AppKit 代码打开 SwiftUI 的 Settings 场景）
        Settings {
            EmptyView()
        }
        .commands {
            AppCommands(model: delegate.model, delegate: delegate)
        }
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    private var window: NSWindow!
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var registeredCombo: KeyCombo?
    private var keyMonitor: Any?
    private var snippets: SnippetEngine?
    private var clipboardWatcher: ClipboardWatcher?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()
        model.onSettingsChanged = { [weak self] in self?.applySettings() }
        model.hideWindow = { [weak self] in self?.hideWindow() }
        model.openSettings = { [weak self] in self?.openSettings() }
        let demoDir = DemoCapture.outputDir
        if demoDir == nil {
            clipboardWatcher = ClipboardWatcher(model: model)
        }
        let engine = SnippetEngine(model: model)
        snippets = engine
        model.requestSnippetPermission = { [weak engine] in engine?.requestPermission() }
        applySettings()
        installKeyMonitor()
        if let demoDir {
            showWindow()
            DemoCapture.run(model: model, launcher: window, openSettings: { [weak self] in
                self?.openSettings()
                return self?.settingsWindow
            }, dir: demoDir)
            return
        }
        enableLaunchAtLoginOnFirstRun()
        promptSnippetPermissionOnce()
        // 作为登录项开机启动时静默驻留（菜单栏 / 全局快捷键呼出），手动打开时才显示窗口
        if !launchedAsLoginItem {
            showWindow()
        }
    }

    /// 默认开启「登录时自动启动」：仅首次从 /Applications 运行时注册一次，之后尊重用户在设置里的选择
    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didSetupLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key),
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }

    /// 斜杠片段需要辅助功能权限：只在首次（且已有设置关键词的提示词或刚开启时）提示一次，之后在设置里授权
    private func promptSnippetPermissionOnce() {
        let key = "didPromptSnippetPermission"
        guard model.snippetsEnabled, !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: key),
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    /// ⌘Tab / 点击通知等方式切回本应用时，如果没有任何窗口可见，就把启动器显示出来
    /// （切走时窗口会被自动收起，⌘Tab 不会触发 applicationShouldHandleReopen）
    func applicationDidBecomeActive(_ notification: Notification) {
        guard window != nil, DemoCapture.outputDir == nil else { return }
        let anyVisible = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if !anyVisible { showWindow() }
    }

    /// 像 Raycast 一样：切到别的应用时自动收起（窗口置顶时不收起）
    func applicationDidResignActive(_ notification: Notification) {
        guard model.hideOnDeactivate, !model.alwaysOnTop, window.isVisible else { return }
        model.showActions = false
        window.orderOut(nil)
    }

    private func makeWindow() {
        let size = LauncherView.size
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Prompt Slash"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(b)?.isHidden = true
        }
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: LauncherView().environment(model))
        host.safeAreaRegions = []
        window.contentView = host

        if !window.setFrameUsingName("PromptSlashLauncher") {
            placeDefault()
        }
        window.setFrameAutosaveName("PromptSlashLauncher")
    }

    /// 默认位置：当前屏幕水平居中、略偏上（和 Raycast 类似）
    private func placeDefault() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { window.center(); return }
        let size = window.frame.size
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.minY + vf.height * 0.62 - size.height / 2)
        window.setFrameOrigin(origin)
    }

    /// 方向键 / 回车 / Esc 交给启动器处理，其余按键照常进入搜索框
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // 中文输入法正在组字时，回车/方向键/Esc 属于输入法
            if let tv = self.window.firstResponder as? NSTextView, tv.hasMarkedText() { return event }
            return self.model.handleKey(event) ? nil : event
        }
    }

    func showWindow() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.focusTick += 1
    }

    func hideWindow() {
        model.showActions = false
        if model.alwaysOnTop {
            window.orderOut(nil)
        }
        NSApp.hide(nil) // 隐藏后焦点回到之前的应用，方便直接粘贴
    }

    private func toggleWindow() {
        if NSApp.isActive, window.isVisible, window.isKeyWindow {
            hideWindow()
        } else {
            showWindow()
        }
    }

    private var settingsWindow: NSWindow?

    func openSettings() {
        model.showActions = false
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environment(model))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 520, height: 660))
            w.center()
            w.setFrameAutosaveName("PromptSlashSettings")
            settingsWindow = w
        }
        settingsWindow?.title = L("Prompt Slash 设置", "Prompt Slash Settings")
        // 启动器窗口置顶时，设置窗口也要在它之上
        settingsWindow?.level = window.level
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applySettings() {
        // 窗口置顶
        window.level = model.alwaysOnTop ? .floating : .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        // 菜单栏图标
        if model.showMenuBarIcon, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Prompt Slash")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if !model.showMenuBarIcon, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }

        // 斜杠片段
        snippets?.update()

        // 全局快捷键（默认 ⌥R，可在设置里修改；录制新快捷键期间暂停）
        if model.globalHotKey, !model.isRecordingHotKey {
            if registeredCombo != model.hotKeyCombo {
                hotKey = nil
                let hk = HotKey(combo: model.hotKeyCombo) { [weak self] in self?.toggleWindow() }
                hotKey = hk
                registeredCombo = model.hotKeyCombo
                model.hotKeyError = hk.isRegistered ? nil : L("「\(model.hotKeyCombo.display)」已被系统或其他应用占用，请换一个", "“\(model.hotKeyCombo.display)” is already used by the system or another app. Please choose another.")
            }
        } else {
            hotKey = nil
            registeredCombo = nil
            if !model.globalHotKey { model.hotKeyError = nil }
        }
    }

    // MARK: 菜单栏菜单：置顶 + 收藏的提示词，一键复制

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sorted = model.sortedPrompts
        let pinned = sorted.filter(\.isPinned)
        let favorites = sorted.filter { $0.isFavorite && !$0.isPinned }

        func addSection(_ title: String, _ prompts: [Prompt]) {
            guard !prompts.isEmpty else { return }
            if menu.items.count > 0 { menu.addItem(.separator()) }
            menu.addItem(NSMenuItem.sectionHeader(title: title))
            for p in prompts.prefix(15) {
                let item = NSMenuItem(title: p.title, action: #selector(copyFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = p.id
                item.toolTip = String(p.content.prefix(300))
                menu.addItem(item)
            }
        }

        addSection(L("置顶", "Pinned"), pinned)
        addSection(L("收藏", "Favorites"), favorites)
        if pinned.isEmpty, favorites.isEmpty {
            addSection(L("最近", "Recent"), Array(model.recentPrompts.prefix(10)))
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: L("还没有提示词", "No prompts yet"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: L("打开 Prompt Slash", "Open Prompt Slash"), action: #selector(openFromMenu), keyEquivalent: "")
        if model.globalHotKey {
            open.keyEquivalent = model.hotKeyCombo.menuKeyEquivalent
            open.keyEquivalentModifierMask = model.hotKeyCombo.menuModifierMask
        }
        open.target = self
        menu.addItem(open)
        let new = NSMenuItem(title: L("新建提示词…", "Create Prompt…"), action: #selector(newFromMenu), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        let settings = NSMenuItem(title: L("设置…", "Settings…"), action: #selector(settingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("退出 Prompt Slash", "Quit Prompt Slash"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func copyFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let p = model.prompts.first(where: { $0.id == id }) else { return }
        model.copy(p, hide: false)
    }

    @objc private func openFromMenu() { showWindow() }

    @objc private func newFromMenu() {
        showWindow()
        model.editor = .new(prefill: nil)
    }

    @objc private func settingsFromMenu() { openSettings() }
}

// MARK: - 菜单命令

struct AppCommands: Commands {
    let model: AppModel
    let delegate: AppDelegate

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("新建提示词", "Create Prompt")) {
                delegate.showWindow()
                model.editor = .new(prefill: nil)
            }
            .keyboardShortcut("n")

            Button(L("用剪贴板内容新建", "Create from Clipboard")) {
                delegate.showWindow()
                model.editor = .new(prefill: NSPasteboard.general.string(forType: .string))
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button(L("导入…", "Import…")) { model.runImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button(L("导出…", "Export…")) { model.runExport() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .printItem) {}

        CommandGroup(replacing: .appSettings) {
            Button(L("设置…", "Settings…")) { delegate.openSettings() }
                .keyboardShortcut(",")
        }

        CommandMenu(L("提示词", "Prompts")) {
            let p = model.editor == nil ? model.selectedPrompt : nil

            Button(L("操作…", "Actions…")) { model.showActions.toggle() }
                .keyboardShortcut("k")
            Button(L("搜索", "Search")) {
                delegate.showWindow()
            }
            .keyboardShortcut("f")

            Divider()

            Button(L("复制提示词", "Copy Prompt")) { if let p { model.copy(p) } }
                .disabled(p == nil)
            Button(L("复制但不隐藏窗口", "Copy Without Hiding")) { if let p { model.copy(p, hide: false) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(p == nil)

            Divider()

            Button(p?.isPinned == true ? L("取消置顶", "Unpin") : L("置顶", "Pin")) { if let p { model.togglePin(p) } }
                .keyboardShortcut("p")
                .disabled(p == nil)
            Button(p?.isFavorite == true ? L("取消收藏", "Unfavorite") : L("收藏", "Favorite")) { if let p { model.toggleFavorite(p) } }
                .keyboardShortcut("d")
                .disabled(p == nil)

            Divider()

            Button(L("编辑…", "Edit…")) { if let p { model.editor = .edit(p) } }
                .keyboardShortcut("e")
                .disabled(p == nil)
            Button(L("创建副本", "Duplicate")) { if let p { model.duplicate(p) } }
                .disabled(p == nil)

            Divider()

            Button(L("删除…", "Delete…")) { if let p { model.confirmDelete(p) } }
                .keyboardShortcut("x", modifiers: .control)
                .disabled(p == nil)
        }

        CommandGroup(after: .toolbar) {
            Toggle(L("窗口置顶", "Keep Window on Top"), isOn: Binding(
                get: { model.alwaysOnTop },
                set: { model.alwaysOnTop = $0 }
            ))
            .keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            LanguageSection()
            Section(L("窗口", "Window")) {
                Toggle(L("窗口置顶（始终浮在其他窗口之上，⌥⌘T）", "Keep window above other windows (⌥⌘T)"), isOn: $model.alwaysOnTop)
                Toggle(L("切换到其他应用时自动隐藏", "Hide when switching to another app"), isOn: $model.hideOnDeactivate)
                    .disabled(model.alwaysOnTop)
                Toggle(L("复制后自动隐藏窗口", "Hide window after copying"), isOn: $model.hideAfterCopy)
            }
            LaunchAtLoginSection()
            Section(L("快速访问", "Quick Access")) {
                Toggle(L("在菜单栏显示图标（列出置顶和收藏的提示词）", "Show menu bar icon (lists pinned and favorite prompts)"), isOn: $model.showMenuBarIcon)
                Toggle(L("启用全局快捷键（呼出 / 隐藏窗口）", "Enable global hotkey (show / hide window)"), isOn: $model.globalHotKey)
                LabeledContent(L("快捷键", "Hotkey")) {
                    HotKeyRecorder()
                }
                .disabled(!model.globalHotKey)
            }
            TagSettingsSection()
            SnippetSettingsSection()
            Section(L("数据", "Data")) {
                LabeledContent(L("存储位置", "Location")) {
                    Text(model.fileURL.path)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button(L("在访达中显示", "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([model.fileURL])
                    }
                    Spacer()
                    Button(L("导入…", "Import…")) { model.runImport() }
                    Button(L("导出…", "Export…")) { model.runExport() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 500)
    }
}

/// 筛选与标签：「最近」「全部」固定；置顶、收藏和所有标签都可以删除；可以添加新标签
private struct TagSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var newTag = ""
    @State private var error: String?

    var body: some View {
        Section {
            // 内置视图固定显示，不可删除
            ForEach(model.viewFilters, id: \.self) { f in
                fixedRow(f.title)
            }
            ForEach(model.allTags) { tag in
                HStack {
                    Text(tag.title)
                    let n = model.usage(ofTag: tag.value)
                    if n > 0 {
                        Text("\(n)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    deleteButton { model.deleteTag(tag.value) }
                }
            }
            HStack {
                TextField("", text: $newTag, prompt: Text(L("新标签名称", "New tag name")))
                    .onSubmit(add)
                Button(L("添加", "Add"), action: add)
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text(L("筛选与标签", "Views & Tags"))
                Spacer()
                Button(L("恢复默认", "Restore Defaults")) { model.restoreDefaultTags() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func fixedRow(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help(L("内置视图，不可删除", "Built-in view, can't be deleted"))
        }
    }

    private func deleteButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help(L("删除", "Delete"))
    }

    private func add() {
        error = model.addTag(newTag)
        if error == nil { newTag = "" }
    }
}

/// 斜杠片段设置
private struct SnippetSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section(L("斜杠片段", "Slash Snippets")) {
            Toggle(L("在任意应用输入「触发字符 + 关键词」回车插入提示词", "Type trigger + key in any app and press Enter to insert"), isOn: $model.snippetsEnabled)
            LabeledContent(L("触发字符", "Trigger")) {
                TextField("", text: Binding(
                    get: { model.snippetTrigger },
                    set: { v in
                        let t = String(v.filter { !$0.isWhitespace && !$0.isNewline }.prefix(3))
                        if !t.isEmpty { model.snippetTrigger = t }
                    }
                ))
                .multilineTextAlignment(.center)
                .font(.system(.body, design: .monospaced))
                .frame(width: 60)
                .help(L("1–3 个字符，默认 //", "1–3 characters, default //"))
            }
            .disabled(!model.snippetsEnabled)
            if model.snippetsEnabled {
                if model.snippetPermission {
                    Label(L("辅助功能权限已开启", "Accessibility permission granted"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    HStack {
                        Label(L("需要「辅助功能」权限才能监听输入和插入文字", "Accessibility permission is required"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Spacer()
                        Button(L("去授权", "Grant Access")) { model.requestSnippetPermission() }
                    }
                }
            }
            Text(L("在提示词里填写「关键词」后即可使用；内容中的 %%cursor%% 决定插入后光标的位置。",
                   "Set a key on a prompt to use it. %%cursor%% in the content sets the cursor position after inserting."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 界面语言：中文 / English（默认中文）
private struct LanguageSection: View {
    @Bindable private var store = LanguageStore.shared

    var body: some View {
        Section(L("语言", "Language")) {
            Picker(L("界面语言", "Interface language"), selection: $store.language) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            if store.language != store.launchLanguage {
                HStack {
                    Text(L("系统菜单（关于、隐藏、退出等）重启后切换", "System menus (About, Hide, Quit…) switch after restart"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("立即重启", "Restart Now")) { store.relaunch() }
                }
            }
        }
    }
}

/// 登录时自动启动（SMAppService，会出现在「系统设置 › 通用 › 登录项」里）
private struct LaunchAtLoginSection: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Section(L("启动", "Startup")) {
            Toggle(L("登录时自动启动", "Launch at login"), isOn: Binding(
                get: { status == .enabled || status == .requiresApproval },
                set: { setEnabled($0) }
            ))
            if status == .requiresApproval {
                HStack {
                    Text(L("需要在系统设置里允许", "Needs approval in System Settings")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("打开登录项设置", "Open Login Items Settings")) { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { status = SMAppService.mainApp.status }
    }

    private func setEnabled(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = L("设置失败：\(error.localizedDescription)", "Failed: \(error.localizedDescription)")
        }
        status = SMAppService.mainApp.status
    }
}
