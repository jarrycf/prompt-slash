import AppKit

/// 演示截图模式（制作宣传视频用）：`PromptSlash -demoCapture <输出目录> -dataFile <演示数据>`
/// 自动切换各个界面并把本应用的窗口截成 PNG，然后退出。不读剪贴板、不注册快捷键、不监听键盘。
@MainActor
enum DemoCapture {
    static var outputDir: URL? {
        guard let path = UserDefaults.standard.string(forKey: "demoCapture"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func capture(_ window: NSWindow?, _ name: String, to dir: URL) {
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }

    static func run(model: AppModel, launcher: NSWindow, openSettings: @escaping () -> NSWindow?, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let panel = SnippetPanel()
        var steps: [() -> Void] = []
        func step(_ f: @escaping () -> Void) { steps.append(f) }
        func shot(_ name: String) { step { capture(launcher, name, to: dir) } }

        // 演示用的剪贴板内容（直接放进内存，不读写系统剪贴板）
        step {
            model.filter = .recent
            for t in ["把这段需求整理成用户故事和验收标准", "今天的待办：修复登录页样式、回复设计稿评论", "下周三下午两点开产品评审会"] {
                model.addClip(t)
            }
            model.selection = model.defaultSelectionID
        }
        shot("01_list")
        step { model.search = "翻" }
        shot("02_search1")
        step { model.search = "翻译" }
        shot("03_search2")
        step { model.search = ""; model.selection = model.defaultSelectionID }
        step { model.showActions = true }
        shot("04_actions")
        step { model.showActions = false; model.selection = model.clips.first?.id }
        shot("05_clip")
        step {
            model.selection = model.visiblePrompts.first { $0.key == "zb" }?.id
            if let p = model.selectedPrompt { model.togglePin(p) }
        }
        shot("06_pin")
        step { model.toast = nil; model.filter = .tag("code") }
        shot("07_tag")
        step {
            model.filter = .recent
            if let p = model.prompts.first(where: { $0.key == "fy" }) { model.editor = .edit(p) }
        }
        shot("08_editor")
        step { model.editor = nil }
        var settingsWindow: NSWindow?
        step { settingsWindow = openSettings() }
        step { capture(settingsWindow, "09_settings", to: dir); settingsWindow?.orderOut(nil) }

        // 斜杠片段候选面板：输入 //、//f、//fy 时的样子
        for (i, q) in ["", "f", "fy"].enumerated() {
            step {
                panel.state.trigger = model.snippetTrigger
                panel.state.query = q
                panel.state.items = Snippet.candidates(model.prompts, query: q)
                panel.state.selected = 0
                panel.show(near: NSRect(x: 200, y: 600, width: 1, height: 18))
            }
            step { capture(panel.window, "10_panel_\(i)", to: dir) }
        }
        step { panel.hide() }
        step { NSApp.terminate(nil) }

        // 每步之间留时间让界面完成布局
        for (i, f) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 0.6, execute: f)
        }
    }
}
