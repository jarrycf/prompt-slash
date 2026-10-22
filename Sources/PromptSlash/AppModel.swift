import AppKit
import Observation
import UniformTypeIdentifiers

/// ⌘K 操作面板里的一项
struct LauncherAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    var keys: [String] = []
    var destructive = false
    let run: () -> Void
}

/// 编辑页表单草稿
struct PromptDraft: Equatable {
    var editingID: String?
    var key = ""
    var title = ""
    var content = ""
    var tags: [String] = []
    var isFavorite = false
    var isPinned = false
    var attempted = false

    init(target: EditorTarget) {
        switch target {
        case .new(let prefill):
            content = prefill ?? ""
        case .edit(let p):
            editingID = p.id
            key = p.key ?? ""
            title = p.title
            content = p.content
            tags = p.tags
            isFavorite = p.isFavorite
            isPinned = p.isPinned
        }
    }

    var titleError: String? { PromptValidation.title(title) }
    /// 实际保存的标题：填了用填的，留空用内容自动生成
    var effectiveTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? PromptValidation.autoTitle(from: content) : t
    }
    var contentError: String? { PromptValidation.content(content) }
    var tagsError: String? { PromptValidation.tags(tags) }
    var keyError: String?
    var isValid: Bool { titleError == nil && contentError == nil && tagsError == nil && keyError == nil }
}

@MainActor
@Observable
final class AppModel {
    // MARK: 数据
    private(set) var prompts: [Prompt] = []

    // MARK: 界面状态
    /// 默认视图为「最近」
    var filter: Filter = .recent
    var search = ""
    var selection: Prompt.ID?
    var editor: EditorTarget? {
        didSet {
            draft = editor.map(PromptDraft.init(target:))
            // 在某个标签 / 置顶 / 收藏视图下新建时，自动带上对应属性
            if case .new = editor {
                switch filter {
                case .tag(let v): draft?.tags = [v]
                case .pinned: draft?.isPinned = true
                case .favorites: draft?.isFavorite = true
                case .recent, .all: break
                }
            }
            showActions = false
            if editor == nil { focusTick += 1 }
        }
    }
    var draft: PromptDraft?
    var toast: String?
    /// 最近复制 / 剪切的纯文本（仅内存，最多 3 条）
    var clips: [ClipItem] = []
    var showActions = false { didSet { if showActions { actionIndex = 0 } } }
    var actionIndex = 0
    /// 每次呼出窗口 +1，用于把焦点放回搜索框
    var focusTick = 0

    // MARK: 设置（持久化到 UserDefaults）
    var alwaysOnTop: Bool { didSet { save(alwaysOnTop, Keys.alwaysOnTop) } }
    var hideAfterCopy: Bool { didSet { save(hideAfterCopy, Keys.hideAfterCopy) } }
    var hideOnDeactivate: Bool { didSet { save(hideOnDeactivate, Keys.hideOnDeactivate) } }
    var showMenuBarIcon: Bool { didSet { save(showMenuBarIcon, Keys.showMenuBarIcon) } }
    var globalHotKey: Bool { didSet { save(globalHotKey, Keys.globalHotKey) } }
    var hotKeyCombo: KeyCombo {
        didSet {
            let d = UserDefaults.standard
            d.set(Int(hotKeyCombo.keyCode), forKey: Keys.hotKeyCode)
            d.set(Int(hotKeyCombo.modifiers), forKey: Keys.hotKeyModifiers)
            d.set(hotKeyCombo.key, forKey: Keys.hotKeyLabel)
            onSettingsChanged?()
        }
    }
    /// 斜杠片段：在任意应用输入「触发字符 + 关键词」后回车插入
    var snippetsEnabled: Bool { didSet { save(snippetsEnabled, Keys.snippetsEnabled) } }
    var snippetTrigger: String {
        didSet {
            UserDefaults.standard.set(snippetTrigger, forKey: Keys.snippetTrigger)
            onSettingsChanged?()
        }
    }
    /// 筛选下拉 / 编辑页里可选的标签（可在设置里增删，默认是 19 个预设标签）
    var tagDefs: [TagDef] {
        didSet {
            UserDefaults.standard.set(tagDefs.map { ["value": $0.value, "zh": $0.zh, "en": $0.en] }, forKey: Keys.tagList)
        }
    }
    /// 是否已获得辅助功能权限（运行时状态）
    var snippetPermission = false

    /// 设置页正在录制新快捷键（期间暂停全局快捷键）
    var isRecordingHotKey = false { didSet { onSettingsChanged?() } }
    /// 快捷键注册失败时的提示
    var hotKeyError: String?

    @ObservationIgnored let fileURL: URL
    /// 设置变化时由 AppDelegate 应用到窗口、菜单栏、快捷键
    @ObservationIgnored var onSettingsChanged: (() -> Void)?
    @ObservationIgnored var hideWindow: () -> Void = { NSApp.hide(nil) }
    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored var requestSnippetPermission: () -> Void = {}

    private enum Keys {
        static let alwaysOnTop = "alwaysOnTop"
        static let hideAfterCopy = "hideAfterCopy"
        static let hideOnDeactivate = "hideOnDeactivate"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let globalHotKey = "globalHotKey"
        static let tagList = "tagList"
        static let snippetsEnabled = "snippetsEnabled"
        static let snippetTrigger = "snippetTrigger"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyLabel = "hotKeyLabel"
    }

    /// 本应用原名 Prompt Stash：首次以 Prompt Slash 启动时，复制旧数据文件（旧文件保留作备份）并迁移设置
    static func migrateFromPromptStash(to fileURL: URL) {
        let fm = FileManager.default
        let d = UserDefaults.standard
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacyFile = base.appendingPathComponent("PromptStash/prompts.json")
        if !fm.fileExists(atPath: fileURL.path), fm.fileExists(atPath: legacyFile.path) {
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: legacyFile, to: fileURL)
        }

        let flag = "migratedFromPromptStash"
        guard !d.bool(forKey: flag), let legacy = UserDefaults(suiteName: "local.promptstash.app") else { return }
        d.set(true, forKey: flag)
        let keys = [
            Keys.alwaysOnTop, Keys.hideAfterCopy, Keys.hideOnDeactivate, Keys.showMenuBarIcon, Keys.globalHotKey,
            Keys.hotKeyCode, Keys.hotKeyModifiers, Keys.hotKeyLabel, Keys.snippetsEnabled, Keys.snippetTrigger, "language",
        ]
        for key in keys where d.object(forKey: key) == nil {
            if let v = legacy.object(forKey: key) { d.set(v, forKey: key) }
        }
        if let lang = legacy.string(forKey: "language") {
            d.set([lang == "en" ? "en" : "zh-Hans"], forKey: "AppleLanguages")
        }
    }

    nonisolated static var defaultFileURL: URL {
        // 可用启动参数 `-dataFile /path/to/prompts.json` 指定数据文件（便于测试或放到同步盘）
        if let custom = UserDefaults.standard.string(forKey: "dataFile"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PromptSlash", isDirectory: true)
        return dir.appendingPathComponent("prompts.json")
    }

    init(fileURL: URL = AppModel.defaultFileURL) {
        if fileURL == AppModel.defaultFileURL {
            AppModel.migrateFromPromptStash(to: fileURL)
        }
        let d = UserDefaults.standard
        d.register(defaults: [
            Keys.alwaysOnTop: false,
            Keys.hideAfterCopy: true,
            Keys.hideOnDeactivate: true,
            Keys.showMenuBarIcon: true,
            Keys.globalHotKey: true,
            Keys.snippetsEnabled: true,
            Keys.snippetTrigger: "//",
        ])
        alwaysOnTop = d.bool(forKey: Keys.alwaysOnTop)
        hideAfterCopy = d.bool(forKey: Keys.hideAfterCopy)
        hideOnDeactivate = d.bool(forKey: Keys.hideOnDeactivate)
        showMenuBarIcon = d.bool(forKey: Keys.showMenuBarIcon)
        globalHotKey = d.bool(forKey: Keys.globalHotKey)
        if let saved = d.array(forKey: Keys.tagList) as? [[String: String]] {
            tagDefs = saved.compactMap { dict in
                guard let v = dict["value"], !v.isEmpty else { return nil }
                return TagDef(value: v, zh: dict["zh"] ?? v, en: dict["en"] ?? v)
            }
        } else {
            tagDefs = TagDef.predefined
        }
        d.removeObject(forKey: "hiddenViews") // 旧版本可隐藏置顶 / 收藏，现在它们固定显示
        snippetsEnabled = d.bool(forKey: Keys.snippetsEnabled)
        // 单个 "/" 和很多 AI 工具的斜杠命令冲突，默认改为 "//"（旧设置的 "/" 也一并升级）
        let savedTrigger = (d.string(forKey: Keys.snippetTrigger) ?? "//").trimmingCharacters(in: .whitespacesAndNewlines)
        snippetTrigger = savedTrigger.isEmpty || savedTrigger == "/" ? "//" : String(savedTrigger.prefix(3))
        if let label = d.string(forKey: Keys.hotKeyLabel), d.object(forKey: Keys.hotKeyCode) != nil {
            hotKeyCombo = KeyCombo(
                keyCode: UInt32(d.integer(forKey: Keys.hotKeyCode)),
                modifiers: UInt32(d.integer(forKey: Keys.hotKeyModifiers)),
                key: label
            )
        } else {
            hotKeyCombo = .default
        }
        self.fileURL = fileURL
        load()
    }

    private func save(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        onSettingsChanged?()
    }

    // MARK: 派生数据

    /// 排序：置顶在最前（最近置顶的更靠前）；其余沿用 Raycast 版规则——
    /// 有 updatedAt 的按其倒序，其余保持存储顺序（收藏优先）
    var sortedPrompts: [Prompt] {
        prompts.enumerated().sorted { a, b in
            let (i, p) = a, (j, q) = b
            if p.isPinned != q.isPinned { return p.isPinned }
            if p.isPinned {
                let x = p.pinnedAt ?? .distantPast, y = q.pinnedAt ?? .distantPast
                return x != y ? x > y : i < j
            }
            switch (p.updatedAt, q.updatedAt) {
            case let (x?, y?): return x != y ? x > y : i < j
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return p.isFavorite != q.isFavorite ? p.isFavorite : i < j
            }
        }.map(\.element)
    }

    /// 「最近」排序：置顶在前；其余按使用分数（最近程度 × 使用频率）降序，没用过的保持原顺序
    var recentPrompts: [Prompt] {
        let now = Date()
        return sortedPrompts.enumerated().sorted { a, b in
            let (i, p) = a, (j, q) = b
            if p.isPinned != q.isPinned { return p.isPinned }
            if p.isPinned { return i < j }
            let x = p.frecency(now: now), y = q.frecency(now: now)
            return x != y ? x > y : i < j
        }.map(\.element)
    }

    var visiblePrompts: [Prompt] {
        let base = filter == .recent ? recentPrompts : sortedPrompts
        return base.filter { filter.includes($0) && $0.matches(search) }
    }

    var hasSnippetKeys: Bool { prompts.contains { !($0.key ?? "").isEmpty } }

    /// 「最近」视图里显示的剪贴板条目（搜索时一起筛选）
    var visibleClips: [ClipItem] {
        guard filter == .recent else { return [] }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? clips : clips.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var selectedClip: ClipItem? {
        guard let id = selection else { return nil }
        return visibleClips.first { $0.id == id }
    }

    /// 列表的上下键顺序：剪贴板在前，提示词在后
    var navigationIDs: [String] { visibleClips.map(\.id) + visiblePrompts.map(\.id) }

    /// 默认选中第一条提示词；没有提示词时选第一条剪贴板
    var defaultSelectionID: String? { visiblePrompts.first?.id ?? visibleClips.first?.id }

    var selectedPrompt: Prompt? {
        guard let id = selection else { return nil }
        return prompts.first { $0.id == id }
    }

    /// 被使用过的标签（预设顺序在前，自定义在后）
    var usedTags: [TagDef] {
        let used = Set(prompts.flatMap(\.tags))
        let predefined = TagDef.predefined.filter { used.contains($0.value) }
        let custom = used.filter { v in !TagDef.predefined.contains { $0.value == v } }
            .sorted()
            .map(TagDef.def(for:))
        return predefined + custom
    }

    /// 所有可选标签：设置里的标签列表 + 提示词上用到但列表里没有的（比如导入进来的）
    var allTags: [TagDef] {
        var result = tagDefs
        let known = Set(tagDefs.map(\.value))
        for t in usedTags where !known.contains(t.value) { result.append(t) }
        return result
    }

    var filterTags: [TagDef] { allTags }

    /// 筛选下拉里的内置视图：最近、全部、置顶、收藏，固定存在、不可删除
    let viewFilters: [Filter] = [.recent, .all, .pinned, .favorites]

    func usage(ofTag value: String) -> Int { prompts.filter { $0.tags.contains(value) }.count }

    // MARK: 标签管理

    /// 添加标签；返回错误信息（成功时为 nil）
    @discardableResult
    func addTag(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return L("请输入标签名称", "Please enter a tag name") }
        if name.count > 20 { return L("标签名称最多 20 个字符", "Tag name must be at most 20 characters") }
        let exists = allTags.contains {
            $0.value.caseInsensitiveCompare(name) == .orderedSame
                || $0.zh.caseInsensitiveCompare(name) == .orderedSame
                || $0.en.caseInsensitiveCompare(name) == .orderedSame
        }
        if exists { return L("已有同名标签", "A tag with this name already exists") }
        tagDefs.append(TagDef(value: name, zh: name, en: name))
        return nil
    }

    /// 删除标签：有提示词在用时先确认，确认后从这些提示词上一并移除
    func deleteTag(_ value: String, confirm: Bool = true) {
        let used = usage(ofTag: value)
        if confirm, used > 0 {
            let alert = NSAlert()
            alert.messageText = L("删除标签「\(TagDef.def(for: value).title)」？", "Delete tag “\(TagDef.def(for: value).title)”?")
            alert.informativeText = L("有 \(used) 条提示词使用了这个标签，删除后会从这些提示词上移除（提示词本身不会删除）。",
                                      "\(used) prompts use this tag. It will be removed from them (the prompts themselves are kept).")
            alert.addButton(withTitle: L("删除", "Delete")).hasDestructiveAction = true
            alert.addButton(withTitle: L("取消", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if used > 0 {
            for i in prompts.indices { prompts[i].tags.removeAll { $0 == value } }
            persist()
        }
        tagDefs.removeAll { $0.value == value }
        if filter == .tag(value) { filter = .recent }
    }

    func restoreDefaultTags() {
        tagDefs = TagDef.predefined
    }

    // MARK: 存储

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            prompts = try Transfer.decoder().decode([Prompt].self, from: data)
        } catch {
            // 文件损坏时先备份，避免下一次保存把它覆盖掉
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            showError(L("读取数据失败", "Failed to load data"), L("原文件已备份到：\(backup.path)\n\n\(error.localizedDescription)", "The original file was backed up to: \(backup.path)\n\n\(error.localizedDescription)"))
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Transfer.encoder().encode(prompts)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            showError(L("保存失败", "Failed to save"), error.localizedDescription)
        }
    }

    // MARK: 增删改

    func add(_ prompt: Prompt) {
        var p = prompt
        // 新建的排在非置顶区最前面
        if p.updatedAt == nil { p.updatedAt = p.createdAt }
        if p.useHistory.isEmpty { p.recordUse(at: p.createdAt) } // 新建的在「最近」里靠前
        prompts.append(p)
        persist()
        selection = p.id
        flash(L("已保存「\(p.title)」", "Saved “\(p.title)”"))
    }

    func update(_ prompt: Prompt) {
        guard let idx = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        var p = prompt
        p.updatedAt = Date()
        prompts[idx] = p
        persist()
        flash(L("已更新「\(p.title)」", "Updated “\(p.title)”"))
    }

    func delete(_ prompt: Prompt) {
        let visible = visiblePrompts
        let nextID: Prompt.ID? = {
            guard let i = visible.firstIndex(where: { $0.id == prompt.id }) else { return nil }
            if i + 1 < visible.count { return visible[i + 1].id }
            return i > 0 ? visible[i - 1].id : nil
        }()
        prompts.removeAll { $0.id == prompt.id }
        persist()
        if selection == prompt.id { selection = nextID }
        flash(L("已删除", "Deleted"))
    }

    func confirmDelete(_ prompt: Prompt) {
        let alert = NSAlert()
        alert.messageText = L("删除「\(prompt.title)」？", "Delete “\(prompt.title)”?")
        alert.informativeText = L("此操作无法撤销。", "This action cannot be undone.")
        alert.addButton(withTitle: L("删除", "Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: L("取消", "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            delete(prompt)
        }
    }

    func duplicate(_ prompt: Prompt) {
        add(Prompt(
            title: prompt.title + L(" 副本", " Copy"),
            content: prompt.content,
            tags: prompt.tags,
            isFavorite: prompt.isFavorite
        ))
    }

    /// 置顶 / 取消置顶（不改变 updatedAt，取消置顶后回到原来的位置）
    func togglePin(_ prompt: Prompt) {
        guard let idx = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        prompts[idx].isPinned.toggle()
        prompts[idx].pinnedAt = prompts[idx].isPinned ? Date() : nil
        persist()
        flash(prompts[idx].isPinned ? L("已置顶", "Pinned") : L("已取消置顶", "Unpinned"))
    }

    func toggleFavorite(_ prompt: Prompt) {
        guard let idx = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        prompts[idx].isFavorite.toggle()
        persist()
        flash(prompts[idx].isFavorite ? L("已收藏", "Added to Favorites") : L("已取消收藏", "Removed from Favorites"))
    }

    // MARK: 复制

    func copy(_ prompt: Prompt, hide: Bool? = nil) {
        ClipboardPolicy.write(prompt.content)
        markUsed(prompt)
        flash(L("已复制「\(prompt.title)」", "Copied “\(prompt.title)”"))
        if hide ?? hideAfterCopy {
            hideWindow()
        }
    }

    /// 记一次使用（用于「最近」排序）
    func markUsed(_ prompt: Prompt) {
        guard let idx = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        prompts[idx].recordUse()
        persist()
    }

    func flash(_ message: String) {
        toast = message
    }

    // MARK: 启动器交互

    func keepSelectionValid() {
        if let s = selection, navigationIDs.contains(s) { return }
        selection = defaultSelectionID
    }

    func moveSelection(_ delta: Int) {
        let ids = navigationIDs
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex { $0 == selection } ?? -1
        let next = min(max(current + delta, 0), ids.count - 1)
        selection = ids[next]
    }

    // MARK: 剪贴板

    func addClip(_ text: String) {
        clips = ClipboardPolicy.inserting(text, into: clips)
    }

    func copyClip(_ clip: ClipItem, hide: Bool? = nil) {
        ClipboardPolicy.write(clip.text)
        flash(L("已复制", "Copied"))
        if hide ?? hideAfterCopy { hideWindow() }
    }

    /// 剪贴板条目设为提示词：自动生成标题，不带任何标签（只出现在「全部」里）
    func promoteClip(_ clip: ClipItem) {
        let title = PromptValidation.autoTitle(from: clip.text)
        let prompt = Prompt(title: title.isEmpty ? L("剪贴板内容", "Clipboard Text") : title, content: clip.text)
        clips.removeAll { $0.id == clip.id }
        add(prompt)
    }

    var actions: [LauncherAction] {
        if let target = editor {
            var isNew = false
            if case .new = target { isNew = true }
            return [
                LauncherAction(id: "save", title: isNew ? L("保存提示词", "Save Prompt") : L("更新提示词", "Update Prompt"), icon: "square.and.arrow.down", keys: ["⌘", "↵"]) { [unowned self] in saveDraft() },
                LauncherAction(id: "reset", title: isNew ? L("清空表单", "Clear Form") : L("重置表单", "Reset Form"), icon: "arrow.counterclockwise", keys: ["⌥", "⌘", "R"]) { [unowned self] in resetDraft() },
                LauncherAction(id: "back", title: L("返回", "Back"), icon: "arrow.left", keys: ["esc"]) { [unowned self] in editor = nil },
            ]
        }
        var list: [LauncherAction] = []
        if let c = selectedClip {
            list += [
                LauncherAction(id: "copyClip", title: L("复制", "Copy"), icon: "doc.on.doc", keys: ["↵"]) { [unowned self] in copyClip(c) },
                LauncherAction(id: "promote", title: L("设为提示词", "Save as Prompt"), icon: "text.badge.plus") { [unowned self] in promoteClip(c) },
            ]
        }
        if let p = selectedPrompt {
            list += [
                LauncherAction(id: "copy", title: L("复制提示词", "Copy Prompt"), icon: "doc.on.doc", keys: ["↵"]) { [unowned self] in copy(p) },
                LauncherAction(id: "copyStay", title: L("复制但不隐藏窗口", "Copy Without Hiding"), icon: "doc.on.clipboard", keys: ["⇧", "⌘", "C"]) { [unowned self] in copy(p, hide: false) },
                LauncherAction(id: "pin", title: p.isPinned ? L("取消置顶", "Unpin") : L("置顶", "Pin"), icon: p.isPinned ? "pin.slash" : "pin", keys: ["⌘", "P"]) { [unowned self] in togglePin(p) },
                LauncherAction(id: "fav", title: p.isFavorite ? L("取消收藏", "Unfavorite") : L("收藏", "Favorite"), icon: p.isFavorite ? "star.slash" : "star", keys: ["⌘", "D"]) { [unowned self] in toggleFavorite(p) },
                LauncherAction(id: "edit", title: L("编辑提示词", "Edit Prompt"), icon: "pencil", keys: ["⌘", "E"]) { [unowned self] in editor = .edit(p) },
                LauncherAction(id: "dup", title: L("创建副本", "Duplicate"), icon: "plus.square.on.square") { [unowned self] in duplicate(p) },
            ]
        }
        list += [
            LauncherAction(id: "new", title: L("新建提示词", "Create Prompt"), icon: "plus", keys: ["⌘", "N"]) { [unowned self] in editor = .new(prefill: nil) },
            LauncherAction(id: "import", title: L("导入…", "Import…"), icon: "square.and.arrow.down", keys: ["⇧", "⌘", "I"]) { [unowned self] in runImport() },
            LauncherAction(id: "export", title: L("导出…", "Export…"), icon: "square.and.arrow.up", keys: ["⇧", "⌘", "E"]) { [unowned self] in runExport() },
            LauncherAction(id: "settings", title: L("设置…", "Settings…"), icon: "gearshape", keys: ["⌘", ","]) { [unowned self] in openSettings() },
        ]
        if let p = selectedPrompt {
            list.append(LauncherAction(id: "delete", title: L("删除提示词", "Delete Prompt"), icon: "trash", keys: ["⌃", "X"], destructive: true) { [unowned self] in confirmDelete(p) })
        }
        return list
    }

    func saveDraft() {
        guard let target = editor, var d = draft else { return }
        d.attempted = true
        d.keyError = Snippet.keyError(d.key, others: prompts.filter { $0.id != d.editingID })
        draft = d
        guard d.isValid else { return }
        let cleanTitle = d.effectiveTitle

        switch target {
        case .new:
            let k = Snippet.normalizeKey(d.key)
            add(Prompt(
                title: cleanTitle,
                content: d.content,
                tags: d.tags,
                isFavorite: d.isFavorite,
                key: k.isEmpty ? nil : k,
                isPinned: d.isPinned,
                pinnedAt: d.isPinned ? Date() : nil
            ))
        case .edit(let original):
            var p = prompts.first { $0.id == original.id } ?? original
            p.title = cleanTitle
            let k = Snippet.normalizeKey(d.key)
            p.key = k.isEmpty ? nil : k
            p.content = d.content
            p.tags = d.tags
            p.isFavorite = d.isFavorite
            if p.isPinned != d.isPinned {
                p.isPinned = d.isPinned
                p.pinnedAt = d.isPinned ? Date() : nil
            }
            update(p)
            selection = p.id
        }
        editor = nil
    }

    func resetDraft() {
        guard let target = editor else { return }
        draft = PromptDraft(target: target)
    }

    func performAction(_ index: Int) {
        let list = actions
        guard list.indices.contains(index) else { return }
        showActions = false
        list[index].run()
    }

    /// 由窗口的按键监听调用：返回 true 表示已处理（不再传给输入框）
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 125, 126: // ↓ ↑
            guard mods.isEmpty, showActions || editor == nil else { return false }
            let delta = event.keyCode == 125 ? 1 : -1
            if showActions {
                let n = actions.count
                actionIndex = (actionIndex + delta + n) % n
            } else {
                moveSelection(delta)
            }
            return true
        case 36, 76: // Return
            guard mods.isEmpty, showActions || editor == nil else { return false }
            if showActions {
                performAction(actionIndex)
            } else if let c = selectedClip {
                copyClip(c)
            } else if let p = selectedPrompt {
                copy(p)
            }
            return true
        case 53: // Esc
            if showActions {
                showActions = false
            } else if editor != nil {
                editor = nil
            } else if !search.isEmpty {
                search = ""
            } else {
                hideWindow()
            }
            return true
        default:
            return false
        }
    }

    // MARK: 导入导出

    func runExport() {
        guard !prompts.isEmpty else {
            showError(L("没有可导出的提示词", "No prompts to export"), "")
            return
        }
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .prefix(19)
        panel.nameFieldStringValue = "prompt-slash-\(stamp).json"
        panel.allowedContentTypes = [.json]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Transfer.buildExport(sortedPrompts).write(to: url, options: .atomic)
            flash(L("已导出 \(prompts.count) 条提示词", "Exported \(prompts.count) prompts"))
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showError(L("导出失败", "Export failed"), error.localizedDescription)
        }
    }

    func runImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = L("选择本应用或 Raycast 版 Prompt Stash 导出的 JSON 文件", "Choose a JSON file exported by this app or the Raycast Prompt Stash extension")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let imported = try Transfer.parse(try Data(contentsOf: url))
            let existingIDs = Set(prompts.map(\.id))
            let conflicts = imported.filter { existingIDs.contains($0.id) }.count

            var strategy = Transfer.ImportStrategy.skip
            if conflicts > 0 {
                let alert = NSAlert()
                alert.messageText = L("导入 \(imported.count) 条提示词", "Import \(imported.count) prompts")
                alert.informativeText = L("其中 \(conflicts) 条已存在（按 ID 匹配），如何处理？", "\(conflicts) of them already exist (matched by ID). What should happen?")
                alert.addButton(withTitle: L("跳过重复", "Skip Duplicates"))
                alert.addButton(withTitle: L("替换已有", "Replace Existing"))
                alert.addButton(withTitle: L("作为新条目导入", "Import as New"))
                alert.addButton(withTitle: L("取消", "Cancel"))
                switch alert.runModal() {
                case .alertFirstButtonReturn: strategy = .skip
                case .alertSecondButtonReturn: strategy = .replace
                case .alertThirdButtonReturn: strategy = .duplicate
                default: return
                }
            }

            let (merged, result) = Transfer.merge(existing: prompts, imported: imported, strategy: strategy)
            prompts = merged
            persist()
            keepSelectionValid()
            flash(L("导入完成：新增 \(result.added) · 替换 \(result.replaced) · 跳过 \(result.skipped)", "Import complete: \(result.added) added · \(result.replaced) replaced · \(result.skipped) skipped"))
        } catch {
            showError(L("导入失败", "Import failed"), error.localizedDescription)
        }
    }

    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
