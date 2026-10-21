import SwiftUI

/// 新建 / 编辑页：仿 Raycast 表单——左侧右对齐的字段名，右侧带边框的输入框
struct PromptEditorView: View {
    @Environment(AppModel.self) private var model
    let target: EditorTarget

    private enum Field: Hashable { case title, key, content, tags }
    @FocusState private var focus: Field?
    @State private var tagInput = ""

    private static let labelWidth: CGFloat = 150
    private static let fieldWidth: CGFloat = 364

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private var draft: PromptDraft { model.draft ?? PromptDraft(target: target) }

    /// 关键词实时校验（格式、重复）
    private var liveKeyError: String? {
        Snippet.keyError(draft.key, others: model.prompts.filter { $0.id != draft.editingID })
    }

    /// 标题留空时，占位文字实时显示将自动生成的标题
    private var titlePlaceholder: String {
        let auto = PromptValidation.autoTitle(from: draft.content)
        return auto.isEmpty ? L("选填，留空将根据内容自动生成", "Optional — generated from content if empty") : auto
    }

    private func bind<T>(_ kp: WritableKeyPath<PromptDraft, T>) -> Binding<T> {
        Binding(
            get: { draft[keyPath: kp] },
            set: { model.draft?[keyPath: kp] = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BackButton { model.editor = nil }
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 55)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 22) {
                        row(L("标题", "Title")) {
                            BorderedField(focused: focus == .title, error: draft.attempted ? draft.titleError : nil) {
                                TextField("", text: bind(\.title), prompt: Text(titlePlaceholder))
                                    .textFieldStyle(.plain)
                                    .focused($focus, equals: .title)
                                    .padding(.horizontal, 10)
                                    .frame(height: 32)
                            }
                        }

                        row(L("关键词", "Key")) {
                            BorderedField(focused: focus == .key, error: liveKeyError) {
                                HStack(spacing: 2) {
                                    Text(model.snippetTrigger)
                                        .foregroundStyle(.secondary)
                                    TextField("", text: bind(\.key), prompt: Text(L("选填，如 de：在任意应用输入 \(model.snippetTrigger)de 回车插入", "Optional, e.g. de — type \(model.snippetTrigger)de anywhere and press Enter")))
                                        .textFieldStyle(.plain)
                                        .focused($focus, equals: .key)
                                }
                                .font(.system(size: 14, design: .monospaced))
                                .padding(.horizontal, 10)
                                .frame(height: 32)
                            }
                        }

                        row(L("提示词内容", "Prompt Content")) {
                            BorderedField(focused: focus == .content, error: draft.attempted ? draft.contentError : nil) {
                                GrowingTextEditor(text: bind(\.content), placeholder: L("在这里输入提示词…", "Enter your prompt here..."))
                                    .focused($focus, equals: .content)
                            }
                        }

                        row(L("标签", "Tags")) {
                            TagInput(
                                tags: bind(\.tags),
                                input: $tagInput,
                                focused: focus == .tags,
                                usedTags: model.allTags,
                                error: draft.tagsError
                            )
                            .focused($focus, equals: .tags)
                        }

                        row(L("收藏", "Favorite"), baseline: false) {
                            Toggle(L("加入收藏", "Add to Favorites"), isOn: bind(\.isFavorite))
                                .toggleStyle(.checkbox)
                        }

                        row(L("置顶", "Pin"), baseline: false) {
                            Toggle(L("固定在列表最前面", "Keep at the top of the list"), isOn: bind(\.isPinned))
                                .toggleStyle(.checkbox)
                        }

                        row(L("说明", "About")) {
                            Text(isNew
                                 ? L("新建的提示词会保存到你的收藏库中。添加相关标签，方便以后查找。", "Create a new prompt that will be stored in your collection. Add relevant tags to easily find it later.")
                                 : L("修改后按 ⌘↵ 保存，按 Esc 放弃修改并返回。", "Press ⌘↵ to save your changes, or Esc to discard and go back."))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 18)

                    Divider()

                    row(L("提示", "Tips")) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach([L("标题可留空，会用内容第一行自动生成", "Title is optional — the first line of content is used"), L("添加相关标签便于整理", "Add relevant tags for better organization"), L("常用的标记为收藏或置顶", "Mark frequently used prompts as favorite or pinned"), L("内容支持 Markdown", "Markdown is supported in the content"), L("内容里写 %%cursor%% 可指定插入后光标的位置", "Put %%cursor%% in the content to set the cursor position after inserting")], id: \.self) {
                                Text("•  \($0)")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 18)
                }
                .font(.system(size: 14))
            }

            Divider()

            BottomBar(
                primaryTitle: isNew ? L("保存提示词", "Save Prompt") : L("更新提示词", "Update Prompt"),
                primaryKeys: ["⌘", "↵"],
                showsActions: true,
                primaryShortcut: KeyboardShortcut(.return, modifiers: .command)
            ) {
                model.saveDraft()
            }
        }
        .background {
            // ⌥⌘R 清空 / 重置表单
            Button("") { model.resetDraft() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .hidden()
        }
        .onAppear { focus = .title }
    }

    @ViewBuilder
    private func row<Content: View>(_ label: String, baseline: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Text(label)
                .fontWeight(.semibold)
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: Self.labelWidth, alignment: .trailing)
                .padding(.top, baseline ? 7 : 1)
            content()
                .frame(width: Self.fieldWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 组件

struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.left")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("返回（Esc）", "Back (Esc)"))
    }
}

/// Raycast 风格的带边框输入框：聚焦时高亮，出错时红框 + 提示
private struct BorderedField<Content: View>: View {
    let focused: Bool
    var error: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: focused ? 1.5 : 1)
                )
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
    }

    private var borderColor: Color {
        if error != nil { return .red.opacity(0.85) }
        return focused ? Color.primary.opacity(0.85) : Color.primary.opacity(0.2)
    }
}

/// 随内容自动增高的多行输入框（最小 64pt，最大 240pt，超出后内部滚动）
private struct GrowingTextEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 用隐藏的 Text 撑出高度
            Text(text.isEmpty ? " " : text + "\n")
                .font(.system(size: 14))
                .lineSpacing(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(0)
                .accessibilityHidden(true)

            TextEditor(text: $text)
                .font(.system(size: 14))
                .lineSpacing(2)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .padding(.horizontal, 5)
                .padding(.vertical, 8)

            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 64, maxHeight: 240)
    }
}

/// 仿 Raycast TagPicker：框内显示已选标签，输入可筛选已有标签或回车创建新标签
private struct TagInput: View {
    @Binding var tags: [String]
    @Binding var input: String
    let focused: Bool
    let usedTags: [TagDef]
    var error: String?

    private var suggestions: [TagDef] {
        let all = usedTags
        let q = input.trimmingCharacters(in: .whitespaces)
        return all.filter { t in
            !tags.contains(t.value) &&
            (q.isEmpty || t.title.localizedCaseInsensitiveContains(q) || t.value.localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 5) {
                ForEach(tags, id: \.self) { value in
                    let d = TagDef.def(for: value)
                    HStack(spacing: 4) {
                        Text(d.title)
                        Button {
                            tags.removeAll { $0 == value }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                }
                TextField("", text: $input, prompt: Text(tags.isEmpty ? L("选择已有标签，或输入新标签后回车", "Select existing or type to create new tags") : ""))
                    .textFieldStyle(.plain)
                    .frame(minWidth: tags.isEmpty ? 330 : 80)
                    .onSubmit(commit)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 32, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(error != nil ? Color.red.opacity(0.85) : (focused ? Color.primary.opacity(0.85) : Color.primary.opacity(0.2)),
                                  lineWidth: focused ? 1.5 : 1)
            )

            if focused, !suggestions.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(suggestions) { t in
                        Button {
                            tags.append(t.value)
                            input = ""
                        } label: {
                            Text(t.title)
                                .font(.system(size: 12))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
    }

    private func commit() {
        let t = input.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        // 输入与已有标签名匹配时用已有标签，否则创建新标签
        let value = suggestions.first { $0.title.caseInsensitiveCompare(t) == .orderedSame || $0.value == t }?.value
            ?? (suggestions.count == 1 ? suggestions[0].value : t)
        if !tags.contains(value) { tags.append(value) }
        input = ""
    }
}
