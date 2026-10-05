# NoType Omarchy 插件

Omarchy 桌面壳（quickshell）插件，id 为 `notype`。插件只读取 `notype status --follow` 的输出，并调用 `notype` 子命令，不直接录音或翻译。

| 文件 | 类型 | 作用 |
| --- | --- | --- |
| `Service.qml` | service | 唯一的 `notype status --follow` 进程；守护进程退出后约 2 秒重连，期间视为离线 |
| `Overlay.qml` | panel | 底部居中的听写 HUD（不接收输入、不抢焦点）和划词中文翻译卡片 |
| `BarWidget.qml` | bar-widget | 状态栏麦克风图标：左键 `notype record toggle`，右键 `notype cancel` |

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

`~/.config/omarchy/plugins/` 下的文件保存后，桌面壳会自动重新加载插件。但 `keepLoaded` 的 service 会跨重载保留，修改 `Service.qml` 后需要：

```bash
omarchy-restart-shell
```

## 行为

- HUD：`phase` 不为 `idle` 时出现在当前聚焦的显示器上。显示阶段（Listening / Transcribing / Refining / Inserted / Copied to clipboard / 失败原因）、翻译模式标记、实时转写的最后 3 行，录音时显示音量条。鼠标点击会穿透 HUD。
- 翻译卡片：`selection.state` 不为 `hidden` 时出现在屏幕中央，显示中文译文（`translating` 时流式更新）、原文和错误信息。出现时不抢焦点；点击卡片后可按 `Esc` 关闭、`Ctrl+C` 复制。关闭按钮执行 `notype selection-hide`，复制按钮执行 `notype selection-copy`。未聚焦时用 `Alt + Esc`（`notype cancel`）关闭。
- 守护进程未运行时 HUD 和卡片不显示，状态栏图标显示为离线。

## 卸载

```bash
omarchy plugin disable notype
rm -rf ~/.config/omarchy/plugins/notype
omarchy-shell shell rescanPlugins
```

service 常驻，如果卸载后仍有 `notype status --follow` 进程，运行 `omarchy-restart-shell`。
