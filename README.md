<p align="center">
  <img src="./packaging/assets/icon-concepts/notype-icon-concept.png" alt="NoType app icon" width="160">
</p>

<h1 align="center">NoType</h1>

<p align="center">
  一个面向 macOS 的菜单栏语音输入应用。<br>
  按下快捷键，说话，文字回到你当前聚焦的输入框里。
</p>

<p align="center">
  基于 SwiftUI、AppKit、Doubao Streaming ASR 和可选 AI Rewrite 构建。
</p>

## NoType 是什么

NoType 想解决的是一件很具体的事：当你已经在写代码、回消息、记笔记、填表单时，不想切到另一个转写工具，也不想手动复制粘贴，只想按一下快捷键就开始说话，然后让文字回到你原本正在操作的地方。

它不是一个“大而全”的输入法，也不是一个重型会议纪要系统，而是一个更轻、更近、更适合桌面工作流的语音输入工具。

## 为什么值得用

- 菜单栏常驻，不抢桌面主场景
- 全局快捷键启动，默认 `Option + Space`
- Doubao 流式转写，HUD 会实时显示正在识别的文本
- 可选 `AI Rewrite`，把口语稿整理成更适合直接发送或交给 AI 执行的文字
- 统一走剪贴板 + `Cmd + V` 注入，对非原生编辑器更稳
- 粘贴前会在 CJK 输入法下临时切到 ASCII，粘贴后恢复输入法和原剪贴板
- 配置、打包、调试链路都在仓库里，适合继续二开

## 当前已经支持

- 仅菜单栏运行的 macOS 14+ 应用，带 `Setup`、`Settings` 和底部悬浮 HUD
- Carbon 全局热键，默认 `Option + Space`
- 同一主热键按一次开始录音，再按一次结束；`Option + Esc` 可取消
- Doubao Streaming ASR 主链，支持 `English`、`简体中文`、`繁體中文`、`日本語`、`한국어`
- `AI Rewrite` 可选开关：
  - 关闭时走 `Literal`，直接使用 ASR 最终文本
  - 打开且配置完整时走 `Writing`，先进行轻量改写再插入
- HUD 在录音和转写阶段显示实时文本，在 `AI Rewrite` 阶段显示流式改写结果
- 文本注入统一走剪贴板 + 模拟 `Cmd + V`
- 如果没有可编辑焦点，则不会强行注入，而是把结果保留到剪贴板供手动粘贴
- 在中文、日文、韩文输入法下粘贴前会临时切到 `ABC/US`，完成后恢复

## 适合谁

- 希望在 macOS 上做“按键即说话”的轻量语音输入用户
- 已经在用火山引擎 Doubao ASR，希望接入桌面工作流的人
- 想研究菜单栏应用、全局热键、Accessibility 文本注入、Doubao ASR 和 LLM Rewrite 的开发者
- 想把现有 MVP 继续打磨成可分发产品的开源贡献者

## 项目状态

NoType 目前处于早期可用阶段：

- 主路径已经可跑通
- 适合自用、调试和持续迭代
- 还没有把安装、签名、分发、兼容性打磨到“普通用户无脑即用”的程度

如果你想要一个可修改、可验证、可继续演进的基础版本，这个仓库已经足够开始。

## 技术栈

- Swift 6
- SwiftUI + AppKit
- macOS Accessibility / Carbon Hotkey / AVFoundation / Text Input Sources
- Doubao Streaming ASR WebSocket 协议
- OpenAI-compatible Chat Completions + SSE streaming

## 系统要求

- macOS 14+
- 已开通的 Doubao 流式语音识别资源
- 如果启用 `AI Rewrite`，还需要一个支持 OpenAI-compatible 接口的 LLM 服务
- 允许应用访问：
  - Microphone
  - Accessibility

## 快速开始

### 直接运行

```bash
swift run NoType
```

应用启动后会出现在菜单栏。第一次使用时，先打开 `Setup` 完成权限授权，再到 `Settings` 配置 Doubao 凭证。

### 构建并安装到 `/Applications`

```bash
make install
```

如果只想产出签名后的 `.app` bundle：

```bash
make build
```

构建脚本会：

- 以 `release` 模式构建可执行文件
- 生成应用图标
- 组装 `.app` bundle
- 使用 ad-hoc 签名
- 输出到 `dist/NoType.app`

直接预览最新包：

```bash
make run
```

### 在 Xcode 中开发

先生成工程：

```bash
ruby scripts/generate_xcodeproj.rb
open NoType.xcodeproj
```

然后在 Xcode 中：

1. 选择 `NoType` target。
2. 打开 `Signing & Capabilities`。
3. 启用 `Automatically manage signing`。
4. 选择你的开发团队。
5. Run 或 Archive。

本地开发通常使用 `Apple Development` 签名即可；如果要分发给其他机器，需要补全 `Developer ID` 和 notarization 流程。

## 配置 Doubao ASR

在应用的 `Settings` 中填写：

- `App ID`
- `Resource ID`
- `Access Token`

当前界面里给出了 1.0 和 2.0 资源示例：

- 1.0 小时版：`volc.bigasr.sauc.duration`
- 1.0 并发版：`volc.bigasr.sauc.concurrent`
- 2.0 小时版：`volc.seedasr.sauc.duration`
- 2.0 并发版：`volc.seedasr.sauc.concurrent`

存储方式：

- `Access Token` 存在 macOS Keychain
- 其他设置存到本地 `UserDefaults`

## 配置 AI Rewrite

在 `Settings -> AI Rewrite` 中可以配置：

- `Enable AI Rewrite`
- `API Base URL`
- `API Key`
- `Model`

当前语义：

- `AI Rewrite Off`：直接插入 Doubao ASR 的最终结果
- `AI Rewrite On` 且配置完整：先调用 LLM 改写，再插入最终文本
- `AI Rewrite On` 但配置不完整：不阻塞主链，继续使用原始转写

`AI Rewrite` 的目标不是重度润色，而是把口语稿整理成更适合发送和更适合 AI 执行的文本：

- 去掉 filler words、即时重复和改口
- 保留约束、限制条件、交付项和技术术语
- 对任务、需求、验收要求优先整理成更利于 AI 执行的结构
- 普通聊天则保持自然段，不强行列表化

## 使用流程

1. 打开菜单栏应用，完成麦克风和辅助功能授权。
2. 在 `Settings` 中配置 Doubao 凭证。
3. 按需配置 `AI Rewrite` 的 `Base URL`、`API Key` 和 `Model`。
4. 选择快捷键和识别语言。
5. 在任意输入框聚焦后，按快捷键开始录音。
6. 再按一次快捷键结束录音，或按 `Option + Esc` 取消。
7. Doubao 返回最终转写后：
   - 若 `AI Rewrite` 关闭，直接进入插入
   - 若 `AI Rewrite` 开启且配置完整，HUD 会先显示 `Rewriting…`，等 LLM 返回后再插入
8. 如果检测到可编辑焦点，文本会通过剪贴板 + `Cmd + V` 注入当前输入框。
9. 如果没有可编辑焦点，结果会保留在剪贴板里，供你手动粘贴到任意位置。

## 验证

```bash
swift test
make build
```

## 项目结构

```text
Sources/NoType/App         应用状态、生命周期和主流程
Sources/NoType/Models      配置、状态和数据模型
Sources/NoType/Services    音频采集、热键、ASR、AI Rewrite、权限、文本插入等服务
Sources/NoType/Views       菜单栏、设置、HUD、引导界面
Sources/NoType/Support     PCM 与转写文本处理辅助工具
scripts/                   构建、图标、Xcode 工程生成脚本
packaging/                 App bundle 资源与图标
Tests/NoTypeTests          测试
```

## Roadmap

- [x] 菜单栏主流程、快捷键、录音、转写、文本插入
- [x] Doubao 主链与基础设置
- [x] 可选 AI Rewrite
- [x] 跨输入法的剪贴板注入与恢复
- [ ] 更完整的安装与分发流程
- [ ] 更稳定的跨应用文本插入兼容性
- [ ] 更细的 AI Rewrite 风格和强度控制
- [ ] 更清晰的产品级 onboarding 和错误提示
- [ ] 自动更新、发布产物和更完整的 CI

## 参与共建

欢迎提 issue、提 PR，或者直接把它 fork 成更适合你自己的版本。

如果你准备参与修改，比较值得先看的目录是：

- `Sources/NoType/App`
- `Sources/NoType/Services`
- `Sources/NoType/Views`
- `scripts/`

## 当前边界

- 当前目标平台只有 macOS。
- 全局快捷键使用稳定组合键，不支持裸 `Fn`。
- 文本插入统一依赖 Accessibility + 模拟粘贴，不再走 AX 直写优先。
- `AI Rewrite` 依赖外部 LLM 服务，速度和质量取决于你配置的模型。
- Doubao 协议兼容性以当前仓库实现为准，升级资源协议时需要重新核对字段和握手行为。
- 它已经是一个能工作的 MVP，但还不是面向普通用户大规模分发的最终形态。
