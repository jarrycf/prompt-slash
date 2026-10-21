# Prompt Slash

一款原生 macOS 提示词管理器：Raycast 风格的启动器窗口，外加**在任意应用里输入 `//关键词` 回车即可插入提示词**的斜杠片段功能。

最初由 Raycast 扩展 [Prompt Stash](https://github.com/raycast/extensions/tree/main/extensions/prompt-stash) 改写而来，用 SwiftUI + AppKit 重新实现，不依赖 Raycast。

> English summary: a native macOS prompt manager with a Raycast-style launcher window, plus system-wide slash snippets — type `//key` in any app and press Enter to insert a prompt. Rewritten from the Raycast extension *Prompt Stash*. The UI supports Chinese and English (switch in Settings).

## 功能

- **启动器窗口**（750×475，仿 Raycast）：顶部搜索 + 筛选下拉，左侧列表、右侧预览，底部「复制 ↵ / 操作 ⌘K」
- **全局快捷键**呼出 / 隐藏窗口（默认 `⌥R`，可在设置里录制修改）
- **斜杠片段**：给提示词设置「关键词」（如 `de`），在任意应用输入 `//de` 弹出候选，回车插入；内容中的 `%%cursor%%` 决定插入后光标位置
- **最近**视图（默认）：按「最近使用 × 使用频率」排序，顶部显示最近 3 条剪贴板纯文本（仅保存在内存中），右键可设为提示词
- **置顶** / **收藏** / **标签**筛选；标签可在设置里自定义、删除
- 新建 / 编辑在同一窗口内完成；标题可留空，自动用内容第一行生成
- **导入 / 导出** JSON，与 Raycast 版 Prompt Stash 的导出格式互通
- 菜单栏图标、窗口置顶、登录时自动启动、中英文界面切换

## 安装

### 下载

在 [Releases](../../releases) 下载 `Prompt-Slash.zip`，解压后把 `Prompt Slash.app` 拖进「应用程序」。

应用使用临时签名（未经 Apple 公证），首次打开如果被系统拦截，在终端执行：

```bash
xattr -dr com.apple.quarantine "/Applications/Prompt Slash.app"
```

### 从源码构建

只需要 Xcode Command Line Tools（macOS 14+）：

```bash
./scripts/build_app.sh
```

生成的应用在 `build/Prompt Slash.app`。

运行自检（不启动界面，校验数据逻辑）：

```bash
swift build && .build/debug/PromptSlash --self-test
```

## 权限说明

| 功能 | 需要的权限 |
| --- | --- |
| 斜杠片段（监听按键、模拟粘贴、读取光标位置） | 系统设置 › 隐私与安全性 › **辅助功能** |
| 其他功能 | 无 |

- 在密码输入框中，macOS 会自动屏蔽按键监听。
- 由于是临时签名，**每次重新构建后需要在「辅助功能」里把 Prompt Slash 关掉再打开**一次。

## 数据与隐私

- 提示词保存在本机 `~/Library/Application Support/PromptSlash/prompts.json`，不上传任何地方。
- 剪贴板记录只保存在内存中（最多 3 条），退出即清除；不会记录本应用自己写入的内容、密码管理器标记为隐藏的内容，以及复制的文件。

## 快捷键

| 按键 | 作用 |
| --- | --- |
| `⌥R`（可改） | 呼出 / 隐藏窗口 |
| `↑` `↓` / `↵` | 选择 / 复制 |
| `⌘K` | 操作面板 |
| `⌘N` / `⌘E` | 新建 / 编辑 |
| `⌘P` / `⌘D` | 置顶 / 收藏 |
| `⌃X` | 删除 |
| `⌥⌘T` | 窗口置顶 |
| `Esc` | 关闭面板 → 清空搜索 → 隐藏窗口 |

## 许可

MIT，见 [LICENSE](LICENSE)。
