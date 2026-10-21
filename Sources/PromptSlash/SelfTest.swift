import Carbon.HIToolbox
import Foundation

/// `PromptSlash --self-test`：不启动界面，校验数据逻辑后退出
@MainActor
enum SelfTest {
    private static var failures = 0

    private static func check(_ cond: Bool, _ name: String) {
        print(cond ? "✅ \(name)" : "❌ \(name)")
        if !cond { failures += 1 }
    }

    static func run() -> Int32 {
        // 1. Raycast 导出格式（Date 为 JS toJSON 字符串，无 isPinned 字段）
        let raycast = """
        {"$schema":"prompt-stash-export","version":1,"exportedAt":"2025-06-01T10:00:00.000Z","count":3,
         "prompts":[
          {"id":"1","title":"翻译","content":"把下面内容翻译成英文","tags":["translation"],"isFavorite":true,"createdAt":"2025-01-01T00:00:00.000Z"},
          {"id":"2","title":"Code review","content":"Review this code","tags":["code","custom-tag"],"isFavorite":false,"createdAt":"2025-02-01T00:00:00.000Z","updatedAt":"2025-03-01T08:30:00.123Z"},
          {"id":"2","title":"dup","content":"dup","tags":[],"isFavorite":false},
          {"id":"bad","title":"缺 tags","content":"x","isFavorite":false}
         ]}
        """
        do {
            let prompts = try Transfer.parse(Data(raycast.utf8))
            check(prompts.count == 2, "解析 Raycast 导出：去重并跳过无效条目")
            check(prompts.allSatisfy { !$0.isPinned }, "旧数据缺少 isPinned 时默认为未置顶")
            check(prompts[1].updatedAt != nil, "解析带毫秒的 updatedAt")
        } catch {
            check(false, "解析 Raycast 导出：\(error)")
        }

        // 2. 裸数组旧格式 & 错误格式
        check((try? Transfer.parse(Data(#"[{"id":"a","title":"t","content":"c","tags":[],"isFavorite":false}]"#.utf8)))?.count == 1,
              "接受裸数组格式")
        check((try? Transfer.parse(Data(#"{"$schema":"other"}"#.utf8))) == nil, "拒绝非 Prompt Stash 文件")
        check((try? Transfer.parse(Data("not json".utf8))) == nil, "拒绝非法 JSON")

        // 3. 导出 → 再导入（往返）
        let a = Prompt(id: "a", title: "A", content: "aaa", tags: ["code"], isPinned: true, pinnedAt: Date())
        let b = Prompt(id: "b", title: "B", content: "bbb")
        if let data = try? Transfer.buildExport([a, b]),
           let json = String(data: data, encoding: .utf8),
           let back = try? Transfer.parse(data) {
            check(json.contains("\"$schema\" : \"prompt-stash-export\""), "导出文件带 $schema")
            check(back.first?.isPinned == true, "导出往返保留置顶状态")
        } else {
            check(false, "导出往返")
        }

        // 4. 合并策略
        let existing = [Prompt(id: "1", title: "old", content: "old")]
        let incoming = [Prompt(id: "1", title: "new", content: "new"), Prompt(id: "9", title: "n", content: "n")]
        let skip = Transfer.merge(existing: existing, imported: incoming, strategy: .skip)
        check(skip.1 == .init(added: 1, replaced: 0, skipped: 1) && skip.0.count == 2, "合并：跳过重复")
        let rep = Transfer.merge(existing: existing, imported: incoming, strategy: .replace)
        check(rep.1.replaced == 1 && rep.0.first?.title == "new", "合并：替换已有")
        let dup = Transfer.merge(existing: existing, imported: incoming, strategy: .duplicate)
        check(dup.0.count == 3 && Set(dup.0.map(\.id)).count == 3, "合并：作为新条目导入")

        // 5. 置顶排序 + 持久化
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("promptslash-selftest-\(UUID().uuidString)/prompts.json")
        let model = AppModel(fileURL: tmp)
        let old = Prompt(id: "old", title: "老的", content: "x", createdAt: Date(timeIntervalSinceNow: -1000))
        let mid = Prompt(id: "mid", title: "中间", content: "x", createdAt: Date(timeIntervalSinceNow: -500))
        let new = Prompt(id: "new", title: "新的", content: "x", createdAt: Date())
        model.add(old); model.add(mid); model.add(new)
        check(model.sortedPrompts.map(\.id) == ["new", "mid", "old"], "默认按时间倒序")
        model.togglePin(old)
        check(model.sortedPrompts.map(\.id) == ["old", "new", "mid"], "置顶后排到最前")
        model.togglePin(mid)
        check(model.sortedPrompts.map(\.id) == ["mid", "old", "new"], "最近置顶的在最上面")
        model.filter = .pinned
        check(model.visiblePrompts.count == 2, "「置顶」筛选")
        model.filter = .all
        model.search = "老"
        check(model.visiblePrompts.map(\.id) == ["old"], "搜索")
        model.togglePin(mid)
        model.search = ""
        check(model.sortedPrompts.map(\.id) == ["old", "new", "mid"], "取消置顶后回到原位")

        // 6. 迁移来的 Raycast 数据（无 updatedAt）保持原顺序，新建的排最前
        let tmp2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("promptslash-selftest-\(UUID().uuidString)/prompts.json")
        try? FileManager.default.createDirectory(at: tmp2.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = #"[{"id":"x","title":"X","content":"x","tags":[],"isFavorite":false,"createdAt":"2025-01-01T00:00:00.000Z"},{"id":"y","title":"Y","content":"y","tags":[],"isFavorite":false,"createdAt":"2025-09-01T00:00:00.000Z"},{"id":"z","title":"Z","content":"z","tags":[],"isFavorite":false,"createdAt":"2025-05-01T00:00:00.000Z"}]"#
        try? Data(legacy.utf8).write(to: tmp2)
        let m2 = AppModel(fileURL: tmp2)
        check(m2.sortedPrompts.map(\.id) == ["x", "y", "z"], "Raycast 数据保持原顺序")
        m2.add(Prompt(id: "n", title: "N", content: "n"))
        check(m2.sortedPrompts.first?.id == "n", "新建的排在最前")
        m2.togglePin(m2.prompts.first { $0.id == "z" }!)
        check(m2.sortedPrompts.map(\.id) == ["z", "n", "x", "y"], "置顶优先于一切")
        m2.selection = "z"; m2.moveSelection(1)
        check(m2.selection == "n", "↓ 移动选中")
        try? FileManager.default.removeItem(at: tmp2.deletingLastPathComponent())

        let reloaded = AppModel(fileURL: tmp)
        check(reloaded.prompts.count == 3 && reloaded.prompts.first { $0.id == "old" }?.isPinned == true,
              "重新加载后数据与置顶状态仍在")
        try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())

        // 7. 标题自动生成
        check(PromptValidation.autoTitle(from: "\n\n## 翻译助手\n把下面内容翻译成英文") == "翻译助手", "标题取内容第一行并去掉 Markdown 符号")
        check(PromptValidation.autoTitle(from: String(repeating: "字", count: 60)).count == 40, "自动标题最多 40 字")
        check(PromptValidation.title("") == nil, "标题可以留空")

        // 9. 「最近」：按最近使用 + 频率排序
        let now = Date()
        var hot = Prompt(id: "hot", title: "hot", content: "x")
        for _ in 0..<3 { hot.recordUse(at: now) }
        var stale = Prompt(id: "stale", title: "stale", content: "x")
        for _ in 0..<5 { stale.recordUse(at: now.addingTimeInterval(-30 * 86_400)) }
        check(hot.frecency(now: now) > stale.frecency(now: now), "最近常用的排在很久前常用的前面")
        var many = Prompt(id: "many", title: "many", content: "x")
        for _ in 0..<40 { many.recordUse(at: now) }
        check(many.useHistory.count == Prompt.historyLimit && many.useCount == 40, "使用记录最多保留 30 条，累计次数照算")

        let tmp3 = FileManager.default.temporaryDirectory
            .appendingPathComponent("promptslash-selftest-\(UUID().uuidString)/prompts.json")
        try? FileManager.default.createDirectory(at: tmp3.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(legacy.utf8).write(to: tmp3) // x, y, z 都没用过
        let m3 = AppModel(fileURL: tmp3)
        check(m3.filter == .recent, "默认视图是「最近」")
        check(m3.visiblePrompts.map(\.id) == ["x", "y", "z"], "都没用过时「最近」保持原顺序")
        m3.markUsed(m3.prompts.first { $0.id == "z" }!)
        m3.markUsed(m3.prompts.first { $0.id == "y" }!)
        m3.markUsed(m3.prompts.first { $0.id == "y" }!)
        check(m3.visiblePrompts.map(\.id) == ["y", "z", "x"], "复制后按使用频率排到前面")
        check(AppModel(fileURL: tmp3).prompts.first { $0.id == "y" }?.useCount == 2, "使用次数会保存")
        m3.filter = .all
        check(m3.visiblePrompts.map(\.id) == ["x", "y", "z"], "「全部」仍是原顺序")

        // 10. 在标签视图下新建，自动带上该标签
        m3.filter = .tag("code")
        m3.editor = .new(prefill: nil)
        check(m3.draft?.tags == ["code"], "在标签下新建自动添加该标签")
        m3.filter = .pinned
        m3.editor = nil
        m3.editor = .new(prefill: nil)
        check(m3.draft?.isPinned == true, "在置顶下新建自动置顶")
        m3.editor = nil
        try? FileManager.default.removeItem(at: tmp3.deletingLastPathComponent())

        // 11. 标签显示名
        check(TagDef.def(for: "translation").zh == "翻译" && TagDef.def(for: "translation").en == "Translation", "标签有中英文名")
        check(TagDef.def(for: "我的标签").title == "我的标签", "自定义标签原样显示")

        // 12. 斜杠片段
        let prep = Snippet.prepare("你好，%%cursor%%！再见")
        check(prep.text == "你好，！再见" && prep.moveLeft == 3, "%%cursor%% 被移除并算出光标左移字符数")
        check(Snippet.prepare("没有标记").moveLeft == 0, "没有光标标记时光标停在末尾")
        check(Snippet.prepare("a%%cursor%%b%%cursor%%c").text == "abc", "多余的光标标记也会被移除")
        check(Snippet.keyError("de", others: []) == nil, "关键词 de 合法")
        check(Snippet.keyError("d e", others: []) != nil && Snippet.keyError("中文", others: []) != nil, "关键词不能含空格或中文")
        let withKey = Prompt(id: "k1", title: "深度", content: "x", key: "de")
        check(Snippet.keyError("DE", others: [withKey]) != nil, "关键词不能重复（不区分大小写）")
        check(Snippet.keyError("", others: [withKey]) == nil, "关键词可以留空")
        var docker = Prompt(id: "k2", title: "Docker 延迟", content: "x", key: "docker")
        let delta = Prompt(id: "k3", title: "Delta", content: "x", key: "delta")
        let nokey = Prompt(id: "k4", title: "无关键词", content: "x")
        let pool = [withKey, docker, delta, nokey]
        check(Snippet.candidates(pool, query: "").count == 3, "没设关键词的不出现在候选里")
        check(Snippet.candidates(pool, query: "de").map(\.id) == ["k1", "k3", "k2"], "完全匹配 > 前缀匹配 > 模糊匹配")
        check(Snippet.candidates(pool, query: "dk").map(\.id) == ["k2"], "模糊匹配：字母按顺序出现即可")
        docker.recordUse(); docker.recordUse()
        check(Snippet.candidates([withKey, docker, delta], query: "").first?.id == "k2", "空查询时最近常用的排前面")
        if let data = try? Transfer.encoder().encode([withKey]),
           let back = try? Transfer.decoder().decode([Prompt].self, from: data) {
            check(back.first?.key == "de", "关键词会被保存")
        } else { check(false, "关键词会被保存") }
        check((try? Transfer.decoder().decode([Prompt].self, from: Data(legacy.utf8)))?.first?.key == nil, "旧数据没有关键词也能读取")

        // 13. 剪贴板（仅内存、最多 3 条）
        var clipList: [ClipItem] = []
        for t in ["一", "二", "三", "四"] { clipList = ClipboardPolicy.inserting(t, into: clipList) }
        check(clipList.map(\.text) == ["四", "三", "二"], "最多保留 3 条，新的挤掉最旧的")
        clipList = ClipboardPolicy.inserting("二", into: clipList)
        check(clipList.map(\.text) == ["二", "四", "三"], "重复内容只移到最前，不新增")
        check(ClipboardPolicy.inserting("   \n ", into: clipList).count == 3, "空白内容不记录")

        let tmp4 = FileManager.default.temporaryDirectory
            .appendingPathComponent("promptslash-selftest-\(UUID().uuidString)/prompts.json")
        try? FileManager.default.createDirectory(at: tmp4.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(legacy.utf8).write(to: tmp4)
        let m4 = AppModel(fileURL: tmp4)
        m4.addClip("## 剪贴板标题\n正文内容")
        m4.addClip("第二条")
        check(m4.visibleClips.count == 2, "「最近」里显示剪贴板条目")
        check(m4.navigationIDs.first == m4.clips.first?.id, "上下键顺序：剪贴板在前")
        check(m4.defaultSelectionID == "x", "默认仍选中第一条提示词")
        m4.filter = .all
        check(m4.visibleClips.isEmpty, "其他视图不显示剪贴板")
        m4.filter = .recent
        m4.search = "第二"
        check(m4.visibleClips.map(\.text) == ["第二条"], "搜索也会筛选剪贴板")
        m4.search = ""
        let toPromote = m4.clips.first { $0.text.hasPrefix("##") }!
        m4.promoteClip(toPromote)
        let promoted = m4.prompts.first { $0.content == toPromote.text }
        check(promoted?.title == "剪贴板标题" && promoted?.tags.isEmpty == true, "设为提示词：自动标题、无标签")
        check(!m4.clips.contains { $0.id == toPromote.id }, "设为提示词后从剪贴板分组移除")
        check(!((try? String(contentsOf: tmp4, encoding: .utf8)) ?? "").contains("第二条"), "剪贴板内容不会写入磁盘")
        try? FileManager.default.removeItem(at: tmp4.deletingLastPathComponent())

        // 14. 触发字符串 //
        func fires(_ input: String, trigger: String = "//") -> Bool {
            var t = TriggerTracker(); t.trigger = trigger
            var hit = false
            for c in input { if t.type(String(c)) { hit = true } }
            return hit
        }
        check(fires("//"), "行首输入 // 触发")
        check(fires("你好 //"), "空格后输入 // 触发")
        check(!fires("/"), "单个 / 不触发")
        check(!fires("https://"), "网址里的 // 不触发")
        check(!fires("a//"), "词中间的 // 不触发")
        var tt = TriggerTracker(); tt.trigger = "//"
        _ = tt.type("a"); tt.backspace()
        check(tt.type("/") == false && tt.type("/") == true, "删掉前面的字后再输入 // 触发")
        check(fires("x ;;", trigger: ";;"), "触发字符串可以自定义")

        // 15. 标签管理（测试后恢复用户的标签设置）
        let savedTagList = UserDefaults.standard.object(forKey: "tagList")
        let savedHidden = UserDefaults.standard.object(forKey: "hiddenViews")
        let tmp5 = FileManager.default.temporaryDirectory
            .appendingPathComponent("promptslash-selftest-\(UUID().uuidString)/prompts.json")
        try? FileManager.default.createDirectory(at: tmp5.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(#"[{"id":"t1","title":"T","content":"c","tags":["code","writing"],"isFavorite":false}]"#.utf8).write(to: tmp5)
        let m5 = AppModel(fileURL: tmp5)
        m5.restoreDefaultTags()
        check(m5.addTag("我的标签") == nil && m5.allTags.contains { $0.value == "我的标签" }, "可以添加自定义标签")
        check(m5.addTag("代码") != nil && m5.addTag("code") != nil, "不能添加重名标签")
        m5.filter = .tag("code")
        m5.deleteTag("code", confirm: false)
        check(!m5.allTags.contains { $0.value == "code" }, "可以删除预设标签")
        check(m5.prompts.first?.tags == ["writing"], "删除标签会从提示词上移除")
        check(m5.filter == .recent, "删除当前所在的标签后回到「最近」")
        m5.hideView(.pinned)
        m5.hideView(.all); m5.hideView(.recent)
        check(m5.viewFilters == [.recent, .all, .favorites], "置顶可删除，最近 / 全部不可删除")
        m5.restoreDefaultTags()
        check(m5.viewFilters.count == 4 && m5.tagDefs.count == TagDef.predefined.count, "恢复默认")
        UserDefaults.standard.set(savedTagList, forKey: "tagList")
        UserDefaults.standard.set(savedHidden, forKey: "hiddenViews")
        try? FileManager.default.removeItem(at: tmp5.deletingLastPathComponent())

        // 8. 全局快捷键
        check(KeyCombo.default.display == "⌥R", "默认快捷键为 ⌥R")
        check(KeyCombo(keyCode: 49, modifiers: UInt32(controlKey | shiftKey), key: "Space").display == "⌃⇧Space", "快捷键显示文字")
        check(KeyCombo.default.menuModifierMask == [.option] && KeyCombo.default.menuKeyEquivalent == "r", "菜单栏显示 ⌥R")
        let hk = HotKey(combo: .default) {}
        check(hk.isRegistered, "⌥R 可以注册为全局快捷键")

        print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
        return failures == 0 ? 0 : 1
    }
}
