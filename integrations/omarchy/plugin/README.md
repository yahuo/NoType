# NoType Omarchy 插件

Omarchy 桌面壳（quickshell）插件，id 为 `notype`。插件只读取 `notype status --follow` 的输出，并调用 `notype` 子命令，不直接录音或翻译。

| 文件 | 类型 | 作用 |
| --- | --- | --- |
| `Service.qml` | service | 唯一的 `notype status --follow` 进程；守护进程退出后约 2 秒重连，期间视为离线 |
| `Overlay.qml` | panel | 底部居中的听写 HUD（不接收输入、不抢焦点）、划词中文翻译卡片，以及按需创建的设置窗口和环境检查窗口 |
| `BarWidget.qml` | bar-widget | 状态栏麦克风图标：左键打开菜单，中键 `notype record toggle`，右键 `notype cancel` |
| `SettingsWindow.qml` | 窗口 | 对应 macOS 设置窗口的 Speech 和 AI Rewrite 两页，读写 `notype settings` |
| `SetupWindow.qml` | 窗口 | 对应 macOS 引导页，列出 `notype doctor` 的环境检查 |

`Tones.qml`、`MenuLink.qml`、`TextLink.qml`、`WindowFit.qml` 是上述文件共用的配色、菜单、文字按钮和窗口高度辅助组件。

`manifest.json` 设置了 `keepLoaded: true`，HUD 无需 summon，常驻加载。

## 安装

依赖：`notype` 在桌面壳的 `PATH` 中（Omarchy 默认包含 `~/.local/bin`），且守护进程已运行。

```bash
# 复制（或用 ln -s 链接）到插件目录，manifest.json 必须位于目录根部
mkdir -p ~/.config/omarchy/plugins
cp -R integrations/omarchy/plugin ~/.config/omarchy/plugins/notype
# 或：ln -s "$PWD/integrations/omarchy/plugin" ~/.config/omarchy/plugins/notype

omarchy-shell shell rescanPlugins
omarchy plugin enable notype
```

`integrations/omarchy/install.sh` 也会复制插件，但不会启用。插件不受沙箱限制，QML 出错会影响桌面壳；出问题时运行 `omarchy plugin disable notype`。

## 状态栏图标

`omarchy plugin enable notype` 会把图标放到 `shell.json` 的 `bar.layout.right`。需要调整位置时：

```bash
omarchy bar move notype --section left
```

或手动编辑 `~/.config/omarchy/shell.json`：

```json
"bar": { "layout": { "right": [ { "id": "notype", "hideWhenIdle": false } ] } }
```

`hideWhenIdle: true` 在空闲和离线时隐藏图标，默认只是变暗。也可以用命令设置：`omarchy bar set notype hideWhenIdle true --json`。

插件是否启用取决于 `shell.json` 中是否引用了 `notype`。把图标从状态栏移除会同时停用 HUD 和翻译卡片。只想要 HUD、不要图标时，删掉 `bar.layout` 里的条目，并在顶层 `plugins` 中加入：

```json
"plugins": [ { "id": "notype" } ]
```

## 更新

`~/.config/omarchy/plugins/` 下的文件变化后，桌面壳会提示重新加载插件，但会沿用已缓存的 QML 组件，`keepLoaded` 的 service 也会跨重载保留。更新任何 QML 文件后都要重启桌面壳：

```bash
omarchy-restart-shell
```

## 行为

- HUD：`phase` 不为 `idle` 时出现在当前聚焦的显示器上。显示阶段（Listening / Transcribing / Refining / Inserted / Copied to clipboard / 失败原因）、翻译模式标记、实时转写的最后 3 行，录音时显示音量条。鼠标点击会穿透 HUD。
- 翻译卡片：`selection.state` 不为 `hidden` 时出现在屏幕中央，显示中文译文（`translating` 时流式更新）、原文和错误信息。出现时不抢焦点；点击卡片后可按 `Esc` 关闭、`Ctrl+C` 复制。关闭按钮执行 `notype selection-hide`，复制按钮执行 `notype selection-copy`。未聚焦时用 `Alt + Esc`（`notype cancel`）关闭。
- 状态栏菜单：对应 macOS 菜单栏弹窗。显示运行状态、环境或语音服务未就绪时的提示、三个快捷键、界面语言、AI 改写开关（仅豆包；Codex 显示“直接输入”）、版本号，以及启动 / 退出守护进程。齿轮按钮打开设置窗口。
- 设置窗口：Speech 页切换语音服务、填写豆包 App ID / Resource ID / Access Token、修改语言；AI Rewrite 页开关 AI 改写、查看 Agent 翻译快捷键和端点。修改后点 Save（`Ctrl+S`）写入 `config.toml`，Access Token 写入密钥环。Test 按钮执行 `notype settings test speech` 或 `test ai-rewrite`。快捷键只读，在 `notype.hyprland` 中修改。
- 环境检查窗口：列出必需和可选检查项，可刷新状态、启动守护进程。
- 两个窗口的高度随内容变化，超过屏幕 85% 时才滚动。也可以用命令打开：`omarchy-shell shell summon notype '{"page":"settings"}'`（或 `"setup"`），`omarchy-shell shell hide notype` 关闭。
- 守护进程未运行时 HUD 和卡片不显示，状态栏图标显示为离线。

## 卸载

```bash
omarchy plugin disable notype
rm -rf ~/.config/omarchy/plugins/notype
omarchy-shell shell rescanPlugins
```

service 常驻，如果卸载后仍有 `notype status --follow` 进程，运行 `omarchy-restart-shell`。
