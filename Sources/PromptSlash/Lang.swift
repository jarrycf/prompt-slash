import AppKit
import Observation

enum AppLanguage: String, CaseIterable, Identifiable {
    case zh, en
    var id: String { rawValue }
    var displayName: String { self == .zh ? "简体中文" : "English" }
}

/// 界面语言（默认中文）。可观察：SwiftUI 界面读到 `L(...)` 后会随切换自动刷新
@Observable
final class LanguageStore {
    static let shared = LanguageStore()

    var language: AppLanguage {
        didSet {
            let d = UserDefaults.standard
            d.set(language.rawValue, forKey: "language")
            // 让系统自带菜单（关于、隐藏、退出等）在下次启动时也用对应语言
            d.set([language == .zh ? "zh-Hans" : "en"], forKey: "AppleLanguages")
        }
    }

    /// 本次启动时的语言，用来判断是否需要重启才能完全生效
    let launchLanguage: AppLanguage

    private init() {
        let saved = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .zh
        language = saved
        launchLanguage = saved
    }

    /// 重启应用（系统菜单的语言需要重启才会变）
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// 双语文案：L("中文", "English")
func L(_ zh: String, _ en: String) -> String {
    LanguageStore.shared.language == .zh ? zh : en
}
