# NoType for Omarchy

NoType 的 Linux 版本，面向 Omarchy（Arch Linux + Hyprland 0.56 Lua 配置 + Omarchy quickshell 桌面壳）。由三部分组成：

- `notype daemon`：Rust 守护进程（`linux/`），以 systemd 用户服务运行，负责录音、转写、改写、翻译、粘贴和 Agent / 浏览器桥接。
- Hyprland 快捷键：调用 `notype <command>`，通过 `$XDG_RUNTIME_DIR/notype/control.sock` 控制守护进程。
- Omarchy 桌面壳插件（`plugin/`）：读取 `notype status --follow`，显示录音 HUD、状态和划词中文翻译面板。

## 功能

| 快捷键 | 命令 | 作用 |
| --- | --- | --- |
| `Alt + Space` | `notype record toggle` | 开始 / 结束语音输入；转写中再按一次取消 |
| `Alt + Shift + Space` | `notype translate` | 有选中文字时把它翻译成英文并替换；否则说中文，粘贴英文 |
| `Alt + Escape` | `notype cancel` | 取消当前录音或转写 |
| `Alt + Ctrl + Space` | `notype selection-chinese` | 把选中文字翻译成中文，显示在浮动面板，不修改原文 |
| `Alt + Shift + T` | `notype agent-translate` | 把 Claude Code / Codex 输入框里的草稿翻译成英文（需安装 agent editor 集成） |

- 转写：默认 Codex（使用 Codex CLI 登录态 `~/.codex/auth.json`）；可切换豆包流式识别，并可开启 AI 改写。
- 粘贴：写入剪贴板后，用 Hyprland 向当前窗口发送 `Ctrl+V`（终端为 `Shift+Insert`），再恢复原剪贴板。无法粘贴时保留在剪贴板，HUD 提示“已复制”。
- Pi 扩展、浏览器双语翻译和 agent editor 走同一个桥接 socket：`$XDG_RUNTIME_DIR/notype/bridge.sock`。

## 安装

依赖：`rust`（`mise use -g rust@stable`）、`pipewire`（`pw-record`）、`wl-clipboard`、`hyprland`；使用豆包时建议安装 `libsecret`（`secret-tool`）。

```bash
integrations/omarchy/install.sh
```

脚本会：

1. `cargo build --release --locked`，复制到 `~/.local/bin/notype`（已构建时可加 `--no-build`）。
2. 安装并启动 `~/.config/systemd/user/notype.service`。
3. 复制快捷键到 `~/.config/notype/hyprland.lua`；首次安装时写入示例 `~/.config/notype/config.toml`。
4. 复制桌面壳插件到 `~/.config/omarchy/plugins/notype`。

脚本不会修改 Hyprland 配置，也不会启用插件。安装后：

```bash
# 1. 在 ~/.config/hypr/bindings.lua 中加入：
#    require("notype.hyprland")

# 2. 加载插件
omarchy-shell shell rescanPlugins && omarchy plugin enable notype

# 3. 检查环境
notype doctor
```

插件不受沙箱限制，QML 出错会影响桌面壳。启用前请确认 `notype doctor` 通过；出现问题时运行 `omarchy plugin disable notype`。

## 配置

`~/.config/notype/config.toml`，每次开始录音时重新读取，无需重启守护进程。可以在状态栏菜单的设置窗口里修改，也可以直接编辑：

```toml
speech_provider = "codex"   # 或 "doubao"
language = "zh-CN"          # zh-CN、en-US、zh-TW、ja-JP、ko-KR
ai_rewrite = false          # 仅对豆包生效

[doubao]
app_id = ""
resource_id = "volc.seedasr.sauc.duration"
```

豆包 Access Token 优先保存在密钥环：

```bash
secret-tool store --label='NoType Doubao' application notype account doubao.access-token
```

没有 Secret Service 时，可以在 `[doubao]` 中填写 `access_token`，并保持文件权限为 `0600`。

## 可选集成

- Claude Code / Codex 草稿翻译：`integrations/agent-editor/install.sh`，按提示在 shell 配置中 `source ~/.config/notype/agent-editor.sh`。
- Pi 扩展：`integrations/omarchy/install.sh --pi` 把 `integrations/pi/notype.ts` 安装为 `~/.pi/agent/extensions/notype/index.ts`（遵循 `PI_CODING_AGENT_DIR`），之后在 Pi 中执行 `/reload`。草稿非空时一秒内连按三次空格，翻译成英文后替换草稿；Linux 上自动连接 `$XDG_RUNTIME_DIR/notype/bridge.sock`。
- 浏览器双语翻译：`integrations/omarchy/install.sh --browser` 执行 `python3 integrations/browser/install.py`，把扩展复制到 `~/.local/share/notype/browser/extension`，为 Chrome、Chromium、Edge 和 Brave 写入连接程序清单，并打印扩展 ID。之后在 `chrome://extensions` 开启开发者模式，“加载已解压的扩展程序”选择该目录。详见 `integrations/browser/README.md`。
- 两个选项可与 `--no-build` 组合，例如 `integrations/omarchy/install.sh --no-build --pi --browser`。不加选项时不写入 `~/.pi` 和浏览器目录。

## 排错

- 查看日志：`journalctl --user -u notype -f`。
- `notype doctor` 提示守护进程缺少 `WAYLAND_DISPLAY` 或 `HYPRLAND_INSTANCE_SIGNATURE`：服务启动时会话环境尚未导入。运行 `systemctl --user import-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE`，再 `systemctl --user restart notype`。
- 翻译选中文字依赖向窗口发送 `Ctrl+C` 读取选区。VS Code 等编辑器在没有选区时会复制整行，此时会把当前行当成选中文字；macOS 版本有同样的限制。
- 终端窗口按 Omarchy 的 `terminal` 标签识别（`default/hypr/apps/terminals.lua`），终端里不会尝试读取选区。

## 卸载

```bash
systemctl --user disable --now notype.service
omarchy plugin disable notype
rm -f ~/.local/bin/notype ~/.config/systemd/user/notype.service
rm -rf ~/.config/omarchy/plugins/notype
# 从 ~/.config/hypr/bindings.lua 删除 require("notype.hyprland")；~/.config/notype 保存配置，可按需删除。
```
