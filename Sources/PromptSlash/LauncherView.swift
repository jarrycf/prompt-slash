import SwiftUI

/// Raycast 风格的启动器窗口：750×475，搜索栏 + 列表 + 预览 + 底部操作栏
struct LauncherView: View {
    @Environment(AppModel.self) private var model

    static let size = CGSize(width: 750, height: 475)

    var body: some View {
        ZStack {
            if let target = model.editor {
                PromptEditorView(target: target)
                    .id(target.id)
            } else {
                ListScreen()
            }

            if model.showActions {
                ActionsOverlay()
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            ZStack {
                VisualEffect(material: .popover)
                Color(nsColor: .windowBackgroundColor).opacity(0.55)
            }
            .ignoresSafeArea()
        )
        .ignoresSafeArea()
    }
}

// MARK: - 列表页

private struct ListScreen: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                BackButton { model.hideWindow() }
                TextField("", text: $model.search, prompt: Text(L("搜索提示词…", "Search prompts...")))
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($searchFocused)
                FilterDropdown()
            }
            .padding(.horizontal, 18)
            .frame(height: 55)

            Divider()

            HStack(spacing: 0) {
                PromptList()
                    .frame(width: 285)
                Divider()
                Group {
                    if let clip = model.selectedClip {
                        ClipPreview(clip: clip)
                    } else {
                        PromptPreview(prompt: model.selectedPrompt)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            BottomBar(
                primaryTitle: model.selectedClip != nil ? L("复制", "Copy")
                    : model.selectedPrompt == nil ? L("新建提示词", "Create Prompt") : L("复制提示词", "Copy Prompt"),
                primaryKeys: model.selectedClip == nil && model.selectedPrompt == nil ? ["⌘", "N"] : ["↵"],
                showsActions: true
            ) {
                if let c = model.selectedClip {
                    model.copyClip(c)
                } else if let p = model.selectedPrompt {
                    model.copy(p)
                } else {
                    model.editor = .new(prefill: nil)
                }
            }
        }
        .onAppear {
            searchFocused = true
            model.keepSelectionValid()
        }
        .onChange(of: model.focusTick) { _, _ in searchFocused = true }
        .onChange(of: model.search) { _, _ in
            // 和 Raycast 一样，搜索变化后选中第一条
            model.selection = model.defaultSelectionID
        }
        .onChange(of: model.filter) { _, _ in
            model.selection = model.defaultSelectionID
        }
        .onChange(of: model.prompts) { _, _ in model.keepSelectionValid() }
        .onChange(of: model.clips) { _, _ in model.keepSelectionValid() }
    }
}

private struct PromptList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.visiblePrompts
        let clips = model.visibleClips
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    if !clips.isEmpty {
                        SectionHeader(title: L("剪贴板", "Clipboard"))
                        ForEach(clips) { clip in
                            ClipRow(clip: clip, selected: clip.id == model.selection)
                                .id(clip.id)
                                .onTapGesture(count: 2) { model.copyClip(clip) }
                                .simultaneousGesture(TapGesture().onEnded { model.selection = clip.id })
                                .contextMenu {
                                    Button(L("设为提示词", "Save as Prompt")) { model.promoteClip(clip) }
                                }
                        }
                        if !items.isEmpty {
                            SectionHeader(title: L("提示词", "Prompts"))
                        }
                    }
                    ForEach(items) { prompt in
                        PromptRow(prompt: prompt, selected: prompt.id == model.selection)
                            .id(prompt.id)
                            .onTapGesture(count: 2) { model.copy(prompt) }
                            .simultaneousGesture(TapGesture().onEnded { model.selection = prompt.id })
                            .contextMenu { PromptActions(prompt: prompt) }
                    }
                }
                .padding(8)
            }
            .onChange(of: model.selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .overlay {
                if items.isEmpty && clips.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: model.search.isEmpty ? "text.badge.plus" : "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text(model.search.isEmpty ? L("还没有提示词", "No prompts yet") : L("没有匹配的提示词", "No matching prompts"))
                            .foregroundStyle(.secondary)
                        if model.search.isEmpty {
                            Text(L("⌘N 新建  ·  ⇧⌘I 导入", "⌘N Create  ·  ⇧⌘I Import"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }
}

private struct PromptRow: View {
    let prompt: Prompt
    let selected: Bool

    var body: some View {
        HStack(spacing: 7) {
            if prompt.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            Text(prompt.title.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 14.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let key = prompt.key {
                Text(key)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            }
            if prompt.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - 筛选下拉框（仿 Raycast：带边框的宽下拉框，点开是原生菜单）

private struct FilterDropdown: View {
    @Environment(AppModel.self) private var model
    @State private var frame: CGRect = .zero

    var body: some View {
        Button(action: showMenu) {
            HStack {
                Text(label(for: model.filter))
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(width: 255, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.2))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("按标签筛选", "Filter by tag"))
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { frame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in frame = f }
            }
        )
    }

    private func label(for f: Filter) -> String {
        f.title
    }

    private func showMenu() {
        guard let view = NSApp.keyWindow?.contentView ?? NSApp.windows.first(where: \.isVisible)?.contentView else { return }
        let menu = NSMenu()
        menu.minimumWidth = frame.width
        let views = model.viewFilters
        let options: [Filter] = views + model.filterTags.map { .tag($0.value) }
        for (i, f) in options.enumerated() {
            if i == views.count { menu.addItem(.separator()) }
            let item = ClosureMenuItem(title: label(for: f)) { [model] in model.filter = f }
            item.state = model.filter == f ? .on : .off
            menu.addItem(item)
        }
        let y = view.isFlipped ? frame.maxY + 4 : view.bounds.height - frame.maxY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: y), in: view)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}

// MARK: - 剪贴板条目

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

private struct ClipRow: View {
    let clip: ClipItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(clip.line)
                .font(.system(size: 14.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(clip.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
    }
}

private struct ClipPreview: View {
    let clip: ClipItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                Text(clip.text)
                    .font(.system(size: 14.5))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                Text(L("剪贴板 · 仅保存在内存中，退出即清除", "Clipboard · kept in memory only, cleared on quit"))
                Spacer()
                Text(L("\(clip.text.count) 字符", "\(clip.text.count) chars"))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 30)
        }
    }
}

// MARK: - 预览

private struct PromptPreview: View {
    let prompt: Prompt?

    var body: some View {
        if let prompt {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    Text(rendered(prompt.content))
                        .font(.system(size: 14.5))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                }
            }
        } else {
            Color.clear
        }
    }

    private func rendered(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}

/// 右键菜单
struct PromptActions: View {
    @Environment(AppModel.self) private var model
    let prompt: Prompt

    var body: some View {
        Button(L("复制提示词", "Copy Prompt")) { model.copy(prompt) }
        Button(L("复制但不隐藏窗口", "Copy Without Hiding")) { model.copy(prompt, hide: false) }
        Divider()
        Button(prompt.isPinned ? L("取消置顶", "Unpin") : L("置顶", "Pin")) { model.togglePin(prompt) }
        Button(prompt.isFavorite ? L("取消收藏", "Unfavorite") : L("收藏", "Favorite")) { model.toggleFavorite(prompt) }
        Divider()
        Button(L("编辑…", "Edit…")) { model.editor = .edit(prompt) }
        Button(L("创建副本", "Duplicate")) { model.duplicate(prompt) }
        Divider()
        Button(L("删除…", "Delete…"), role: .destructive) { model.confirmDelete(prompt) }
    }
}

// MARK: - 底部操作栏

struct BottomBar: View {
    @Environment(AppModel.self) private var model
    let primaryTitle: String
    let primaryKeys: [String]
    var showsActions = false
    var primaryShortcut: KeyboardShortcut? = nil
    let primary: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let toast = model.toast {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(toast)
                    .lineLimit(1)
            } else {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 20, height: 20)
                Text("Prompt Slash")
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button(action: primary) {
                HStack(spacing: 6) {
                    Text(primaryTitle).fontWeight(.semibold)
                    KeyCaps(keys: primaryKeys)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(primaryShortcut)

            if showsActions {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 16)
                Button {
                    model.showActions.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text(L("操作", "Actions")).foregroundStyle(.secondary)
                        KeyCaps(keys: ["⌘", "K"])
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Color.primary.opacity(0.035))
        .task(id: model.toast) {
            guard model.toast != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { model.toast = nil }
        }
    }
}

struct KeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, key.count > 1 ? 4 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.09))
                    )
            }
        }
    }
}

// MARK: - ⌘K 操作面板

private struct ActionsOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black.opacity(0.001)
                .onTapGesture { model.showActions = false }

            VStack(alignment: .leading, spacing: 1) {
                if model.editor == nil, let p = model.selectedPrompt {
                    Text(p.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                ForEach(Array(model.actions.enumerated()), id: \.element.id) { i, action in
                    HStack(spacing: 10) {
                        Image(systemName: action.icon)
                            .frame(width: 18)
                        Text(action.title)
                        Spacer()
                        KeyCaps(keys: action.keys)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(action.destructive ? Color.red : Color.primary)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(i == model.actionIndex ? Color.primary.opacity(0.11) : .clear)
                    )
                    .contentShape(Rectangle())
                    .onHover { if $0 { model.actionIndex = i } }
                    .onTapGesture { model.performAction(i) }
                }
            }
            .padding(6)
            .frame(width: 310)
            .background(VisualEffect(material: .menu))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
            .padding(.trailing, 10)
            .padding(.bottom, 48)
        }
    }
}

// MARK: - 毛玻璃背景 & 布局

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

/// 自动换行的标签布局（编辑页用）
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(i)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
