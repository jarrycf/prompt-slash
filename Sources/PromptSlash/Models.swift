import Foundation

// MARK: - Prompt

struct Prompt: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var content: String
    var tags: [String]
    var isFavorite: Bool
    /// 新增：斜杠片段关键词，如 "de" → 在任意应用输入 /de 回车插入
    var key: String?
    /// 新增：置顶。置顶的提示词永远排在列表最前面。
    var isPinned: Bool
    var pinnedAt: Date?
    var createdAt: Date
    var updatedAt: Date?
    /// 新增：最近的使用时间（每次复制记一次，最多保留 30 条），用于「最近」排序
    var useHistory: [Date] = []
    /// 新增：累计使用次数
    var useCount: Int = 0

    init(
        id: String = Prompt.makeID(),
        title: String,
        content: String,
        tags: [String] = [],
        isFavorite: Bool = false,
        key: String? = nil,
        isPinned: Bool = false,
        pinnedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.isFavorite = isFavorite
        self.key = key
        self.isPinned = isPinned
        self.pinnedAt = pinnedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 与 Raycast 版一致：毫秒时间戳字符串
    static func makeID() -> String {
        String(Int64(Date().timeIntervalSince1970 * 1000))
    }

    enum CodingKeys: String, CodingKey {
        case id, title, content, tags, isFavorite, key, isPinned, pinnedAt, createdAt, updatedAt, useHistory, useCount
    }

    // 必填字段与 Raycast 版 isValidPrompt 一致；其余字段宽松解析，兼容 Raycast 导出的文件
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        content = try c.decode(String.self, forKey: .content)
        tags = try c.decode([String].self, forKey: .tags)
        isFavorite = try c.decode(Bool.self, forKey: .isFavorite)
        key = ((try? c.decodeIfPresent(String.self, forKey: .key)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        isPinned = (try? c.decodeIfPresent(Bool.self, forKey: .isPinned)) ?? false
        pinnedAt = try? c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        createdAt = ((try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil) ?? Date()
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        useHistory = ((try? c.decodeIfPresent([Date].self, forKey: .useHistory)) ?? nil) ?? []
        useCount = ((try? c.decodeIfPresent(Int.self, forKey: .useCount)) ?? nil) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(content, forKey: .content)
        try c.encode(tags, forKey: .tags)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encodeIfPresent(key, forKey: .key)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encodeIfPresent(pinnedAt, forKey: .pinnedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        if !useHistory.isEmpty { try c.encode(useHistory, forKey: .useHistory) }
        if useCount > 0 { try c.encode(useCount, forKey: .useCount) }
    }

    static let historyLimit = 30
    /// 半衰期 7 天：一周前的一次使用只算半次
    static let halfLifeDays = 7.0

    /// 「最近」排序分数：每次使用按时间衰减后相加，同时体现最近程度和使用频率
    func frecency(now: Date = Date()) -> Double {
        useHistory.reduce(0) { sum, date in
            let days = max(0, now.timeIntervalSince(date)) / 86_400
            return sum + pow(0.5, days / Prompt.halfLifeDays)
        }
    }

    mutating func recordUse(at date: Date = Date()) {
        useHistory.append(date)
        if useHistory.count > Prompt.historyLimit {
            useHistory.removeFirst(useHistory.count - Prompt.historyLimit)
        }
        useCount += 1
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        if title.localizedCaseInsensitiveContains(q) || content.localizedCaseInsensitiveContains(q)
            || (key?.localizedCaseInsensitiveContains(q) ?? false) {
            return true
        }
        return tags.contains { tag in
            let d = TagDef.def(for: tag)
            return tag.localizedCaseInsensitiveContains(q)
                || d.zh.localizedCaseInsensitiveContains(q)
                || d.en.localizedCaseInsensitiveContains(q)
        }
    }
}

// MARK: - Tags（与 Raycast 版 config.ts 相同）

struct TagDef: Hashable, Identifiable {
    let value: String
    let zh: String
    let en: String
    var id: String { value }
    var title: String { L(zh, en) }

    /// 与 Raycast 版 config.ts 相同的标签值（导入导出互通），显示名改为中英双语
    static let predefined: [TagDef] = [
        TagDef(value: "chatgpt", zh: "ChatGPT", en: "ChatGPT"),
        TagDef(value: "writing", zh: "写作", en: "Writing"),
        TagDef(value: "code", zh: "代码", en: "Code"),
        TagDef(value: "research", zh: "研究", en: "Research"),
        TagDef(value: "creative", zh: "创意", en: "Creative"),
        TagDef(value: "quick", zh: "快速", en: "Quick"),
        TagDef(value: "detailed", zh: "详细", en: "Detailed"),
        TagDef(value: "education", zh: "教育", en: "Education"),
        TagDef(value: "business", zh: "商务", en: "Business"),
        TagDef(value: "marketing", zh: "营销", en: "Marketing"),
        TagDef(value: "analysis", zh: "分析", en: "Analysis"),
        TagDef(value: "translation", zh: "翻译", en: "Translation"),
        TagDef(value: "productivity", zh: "效率", en: "Productivity"),
        TagDef(value: "social-media", zh: "社交媒体", en: "Social Media"),
        TagDef(value: "seo", zh: "SEO", en: "SEO"),
        TagDef(value: "email", zh: "邮件", en: "Email"),
        TagDef(value: "story", zh: "故事", en: "Story"),
        TagDef(value: "academic", zh: "学术", en: "Academic"),
        TagDef(value: "technical", zh: "技术", en: "Technical"),
    ]

    static func def(for value: String) -> TagDef {
        predefined.first { $0.value == value } ?? TagDef(value: value, zh: value, en: value)
    }
}

// MARK: - Validation（沿用 Raycast 版的上限；标题最少字数放宽为 1，方便中文短标题）

enum PromptValidation {
    static let titleMax = 100
    static let contentMax = 18000
    static let tagsMax = 10

    /// 标题选填：留空时保存会用内容自动生成
    static func title(_ v: String) -> String? {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > titleMax { return L("标题最多 \(titleMax) 个字符", "Title must be at most \(titleMax) characters") }
        return nil
    }

    /// 由内容生成标题：第一行非空文字，去掉常见 Markdown 前缀，最多 40 个字
    static func autoTitle(from content: String) -> String {
        let markdownPrefix = CharacterSet(charactersIn: "#>-*+`~|=_ \t")
        for raw in content.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: markdownPrefix)
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            return line.count > 40 ? String(line.prefix(40)) : line
        }
        return ""
    }

    static func content(_ v: String) -> String? {
        if v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L("内容不能为空", "Prompt content is required") }
        if v.count > contentMax { return L("内容最多 \(contentMax) 个字符", "Content must be at most \(contentMax) characters") }
        return nil
    }

    static func tags(_ v: [String]) -> String? {
        v.count > tagsMax ? L("最多 \(tagsMax) 个标签", "Maximum \(tagsMax) tags allowed") : nil
    }
}

// MARK: - Filter

enum Filter: Hashable {
    case recent
    case all
    case pinned
    case favorites
    case tag(String)

    var title: String {
        switch self {
        case .recent: return L("最近", "Recent")
        case .all: return L("全部", "All")
        case .pinned: return L("置顶", "Pinned")
        case .favorites: return L("收藏", "Favorites")
        case .tag(let v): return TagDef.def(for: v).title
        }
    }

    func includes(_ p: Prompt) -> Bool {
        switch self {
        case .recent, .all: return true
        case .pinned: return p.isPinned
        case .favorites: return p.isFavorite
        case .tag(let v): return p.tags.contains(v)
        }
    }
}

enum EditorTarget: Identifiable {
    case new(prefill: String?)
    case edit(Prompt)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let p): return "edit-\(p.id)"
        }
    }
}

// MARK: - 斜杠片段

enum Snippet {
    /// 与 slash-snippets 插件相同的光标标记
    static let cursorMarker = "%%cursor%%"
    static let keyMax = 20

    /// 去掉光标标记，返回要插入的文本，以及插入后光标需要左移的字符数
    static func prepare(_ content: String) -> (text: String, moveLeft: Int) {
        guard let r = content.range(of: cursorMarker) else { return (content, 0) }
        var text = content
        let tail = content[r.upperBound...].replacingOccurrences(of: cursorMarker, with: "")
        text.removeSubrange(r)
        text = text.replacingOccurrences(of: cursorMarker, with: "")
        return (text, tail.count)
    }

    static func normalizeKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 关键词校验：可留空；只能用字母、数字、- _ .；不能与其他提示词重复
    static func keyError(_ raw: String, others: [Prompt]) -> String? {
        let k = normalizeKey(raw)
        if k.isEmpty { return nil }
        if k.count > keyMax { return L("关键词最多 \(keyMax) 个字符", "Key must be at most \(keyMax) characters") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        if k.unicodeScalars.contains(where: { !allowed.contains($0) || !$0.isASCII }) {
            return L("只能使用英文字母、数字和 - _ .", "Only letters, digits and - _ . are allowed")
        }
        if let dup = others.first(where: { $0.key?.caseInsensitiveCompare(k) == .orderedSame }) {
            return L("已被「\(dup.title)」使用", "Already used by “\(dup.title)”")
        }
        return nil
    }

    /// 字母按顺序出现即匹配（如 "dk" 匹配 "docker"）
    static func fuzzy(_ text: String, _ query: String) -> Bool {
        var it = text.lowercased().makeIterator()
        for qc in query.lowercased() {
            var found = false
            while let c = it.next() { if c == qc { found = true; break } }
            if !found { return false }
        }
        return true
    }

    /// 候选排序：完全匹配 > 前缀 > 模糊匹配关键词 > 标题包含；同分按最近使用
    static func candidates(_ prompts: [Prompt], query: String, now: Date = Date()) -> [Prompt] {
        let q = query.lowercased()
        let scored: [(Prompt, Double)] = prompts.compactMap { p in
            guard let key = p.key?.lowercased(), !key.isEmpty else { return nil }
            let score: Double
            if q.isEmpty { score = 0 }
            else if key == q { score = 4 }
            else if key.hasPrefix(q) { score = 3 }
            else if fuzzy(key, q) { score = 2 }
            else if p.title.localizedCaseInsensitiveContains(q) { score = 1 }
            else { return nil }
            return (p, score)
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            let fa = a.0.frecency(now: now), fb = b.0.frecency(now: now)
            if fa != fb { return fa > fb }
            return (a.0.key ?? "") < (b.0.key ?? "")
        }.map(\.0)
    }
}

/// 识别触发字符串：只有在行首 / 空白之后完整输入触发字符串（如 "//"）才算触发，
/// 所以 "https://"、"a//b" 不会触发
struct TriggerTracker {
    var trigger = "//"
    /// 自上一个空白 / 行首以来输入的字符
    private(set) var buffer = ""

    /// 回到「行首 / 空白之后」的状态
    mutating func reset() { buffer = "" }

    /// 标记为「正处在一个词中间」，下一个触发字符串不会生效
    mutating func markWord() { buffer = "\u{1}" }

    mutating func restore(_ text: String) { buffer = text }

    mutating func backspace() {
        if !buffer.isEmpty { buffer.removeLast() }
    }

    /// 输入字符；刚好完成触发字符串时返回 true
    mutating func type(_ chars: String) -> Bool {
        guard !chars.isEmpty else { return false }
        for c in chars {
            if c.isWhitespace || c.isNewline { buffer = "" } else { buffer.append(c) }
        }
        if buffer.count > 64 { buffer = "\u{1}" }
        return !trigger.isEmpty && buffer == trigger
    }
}

