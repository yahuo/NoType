# NoType Local Bridge

NoType exposes a local Unix domain socket while the menu bar app is running. Terminal integrations can send draft text to NoType, reuse its Codex login state and translation model, and receive the English translation without using Accessibility screen scraping.

## Runtime endpoint

Default socket path:

```text
$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)/com.opensource.notype/bridge.sock
```

On macOS, clients query the current user's temporary directory rather than trusting an inherited `TMPDIR`, which may be stale. Clients may override it with `NOTYPE_BRIDGE_SOCKET`. NoType creates the runtime directory with mode `0700` and the socket with mode `0600`.

The bridge starts from `NoTypeAppModel.bootstrap()` and stops during application termination. A lock file prevents a second NoType process from unlinking the active socket. If NoType is not running, clients must preserve the user's draft.

## Protocol

By default, each connection carries one request and one final response, then closes. Browser clients may set `client: "browser"` and `keepAlive: true` on each request to keep the socket open after the final response and send the next request. Requests on one socket are sequential; pipelining is rejected. The `translate_chinese_batch` method additionally emits zero or more progress frames before that final response. A frame consists of:

1. Four-byte unsigned big-endian JSON payload length.
2. UTF-8 JSON payload.

The maximum JSON payload is 1 MiB.

Translation request:

```json
{
  "version": 1,
  "id": "client-generated-request-id",
  "method": "translate",
  "client": "pi",
  "text": "需要翻译的内容"
}
```

Success response:

```json
{
  "version": 1,
  "id": "client-generated-request-id",
  "ok": true,
  "text": "The content to translate"
}
```

Failure response:

```json
{
  "version": 1,
  "id": "client-generated-request-id",
  "ok": false,
  "error": {
    "code": "missing_codex_auth",
    "message": "Translation requires Codex login. Run `codex login` first."
  }
}
```

The `ping` method returns `pong` in the response `text` field.

## 浏览器网页双语翻译

`translate_chinese` 使用同一请求/响应结构，把 `text` 翻译为中文；原来的 `translate` 和 `translate_editor` 仍翻译为英文。中文方法复用 `AIRewriteService.translateToChinese` 的登录态、模型与 180 秒总超时，不操作剪贴板或当前选区。

Chrome / Edge 使用 `translate_chinese_batch`，请求包含 `items: [{"id":"p0","text":"Hello"}]`，无需 `text` 字段。每批 1–4 段，段落 ID 唯一，总长度最多 6000 UTF-16 字符；若每条均不超过 100 UTF-16 字符，则允许最多 12 条（总计最多 1200 字符）；单段可独立请求至 12000 字符。扩展 0.3.3 使用扩大的短文本批次，需要同步更新 NoType 和浏览器连接程序。

批次复用模型请求方法、现有登录态和 180 秒总时限。响应均有相同 `version`、请求 `id` 和 `ok`；`partial: true` 的进度帧在 `text` 中携带累计 JSON Lines 输出。最终成功帧包含完整的 `items`，按输入 ID 对齐；失败沿用 `error`。客户端不能把进度帧当成最终成功，断开 socket 会取消处理任务。

Native Messaging 连接程序只转发中文单段/批次方法，并设置 `client: "browser"`。它在本机字节序和 socket 大端长度前缀之间转换，逐帧输出、复用进程和 socket。扩展 0.4.0 的所有标签页共享两个工作槽位，每个槽位复用一条 Native Messaging 连接和一个 socket；连接内仍逐批请求，最终响应只结束本批次。NoType 同时接纳最多两个 `client: "browser"` 的批次，其他桥接翻译操作仍独占通道，因此 0.4.0 需同步更新应用，0.3.3 连接程序可继续复用。关闭翻译或标签页时取消其任务，其他标签页继续；池内全部任务处理完后释放连接，应用退出时关闭全部连接。桥接器最多保留 16 个同时存活的连接，关闭后释放名额，不限制累计连接次数。0.4.1 将模型错误限制在对应批次，连接不可用等通道错误仍停止当前标签页；不自动重发结果未知的请求。安装与边界见 [浏览器集成说明](../integrations/browser/README.md)。

## Claude Code and Codex CLI integration

Claude Code and Codex CLI both support editing their current draft through `$VISUAL`/`$EDITOR` (`Ctrl+G`; Claude also supports `Ctrl+X Ctrl+E`). NoType bundles a transparent proxy at:

```text
/Applications/NoType.app/Contents/Helpers/notype-editor
```

Quit any running NoType process, build and install the current app, reopen it, then install the proxy:

```bash
make install
open /Applications/NoType.app
./integrations/agent-editor/install.sh
```

The installer creates `~/.local/bin/notype-editor` and `~/.config/notype/agent-editor.sh`, but deliberately does not edit shell startup files. Add this line to `~/.zshrc` **after** any existing `VISUAL`/`EDITOR` exports:

```bash
source "$HOME/.config/notype/agent-editor.sh"
```

Start a new shell, restart Claude/Codex from that shell, and enable **Claude/Codex Triple-Space** in **NoType Settings → AI Rewrite**.

The shell environment saves the prior `$VISUAL` and `$EDITOR` as `$NOTYPE_REAL_VISUAL` and `$NOTYPE_REAL_EDITOR`. A normal manual external-editor shortcut therefore delegates to the original editor. It defaults to `/usr/bin/vi` only when neither original variable was configured.

For an automatic translation, NoType does the following:

1. Detects triple-Space in a supported terminal without reading or selecting the terminal's rendered `AXValue`.
2. Writes a private, single-use trigger token with a five-second lifetime and synthesizes `Ctrl+G`.
3. The proxy accepts only a user-owned Claude/Codex Markdown temp buffer from an inherited user-owned TTY, verifies that its editable draft ends in three spaces, and sends the draft plus token to NoType.
4. On success, the proxy replaces only the draft and exits, returning control to the TUI without submitting it.

Claude temporarily switches to its external-editor screen while translation is running. The proxy shows progress there, and Claude redraws its TUI after the helper exits. Codex remains silent because terminal output can otherwise linger beside its draft.

Claude's optional `externalEditorContext` block is preserved. The proxy recognizes Claude's `# ─── Write your reply below this line` marker and translates only the reply below it. If the token, path, TTY, translation, or socket validation fails, the original temp file remains unchanged.

## Pi integration

The native Pi extension is at [`integrations/pi/notype.ts`](../integrations/pi/notype.ts). It listens to terminal input without replacing Pi's editor component, so it remains compatible with custom Pi editors.

Install it globally for development:

```bash
mkdir -p ~/.pi/agent/extensions/notype
cp integrations/pi/notype.ts ~/.pi/agent/extensions/notype/index.ts
```

Then run `/reload` in Pi. With NoType running and Codex logged in, enter a non-empty draft and press Space three times within one second. The extension removes only the trigger spaces, asks NoType to translate, and replaces the draft only if it has not changed while the request was running.

The Pi adapter does not use or remap `Ctrl+G`.

If Pi reports `ENOENT` or `ECONNREFUSED`, first check that NoType is running locally. Update the extension and run `/reload` if the error points to an old temporary directory. An explicit `NOTYPE_BRIDGE_SOCKET` takes priority; if it is stale, correct or unset it before restarting Pi.

Run the adapter regression tests with Node.js 22.6+:

```bash
node --experimental-strip-types --test integrations/pi/tests/*.test.mjs
```

## Editor-only bridge request

The bundled proxy uses the `translate_editor` method. In addition to the normal request fields it sends the short-lived token, helper/parent PIDs, TTY path, and `trigger: "triple-space"`. NoType accepts the token once only, while the terminal that generated it remains focused. This method is internal to the bundled proxy; third-party clients should use `translate`.

## Current boundary

Pi, Claude Code, and Codex CLI are supported for local TUI sessions. Remote SSH sessions cannot reach the Mac-local Unix socket unless the socket is explicitly forwarded or another transport is added.

## 浏览器连接诊断

连接程序记录在 `~/Library/Logs/NoType/browser-bridge.log`，每个文件最多 1 MiB，保留两份轮转备份。日志包含进程、请求 ID、段数、UTF-16 字符数、首帧/总耗时、取消及失败类型；不记录正文、译文或凭据。NoType 的统一日志提供连接 ID、请求 ID、首个进度帧、完成状态和关闭原因：

```sh
/usr/bin/log show --last 10m --style compact --info --predicate 'subsystem == "com.opensource.notype" AND category == "BrowserBridge"'
```

首个进度帧可能只有 JSON 前缀，不等同于首个可显示中文字。页面分别显示等待模型响应、接收译文和完成状态；0.4.0 全部已识别段落提前排队，无需等待滚动。0.4.1 的模型翻译错误只标记对应批次失败，其余继续，主页面可统一重试失败段落；连接不可用、缺少登录态和 busy 仍停止当前标签页。模型网络等待/总时限仍为 60/180 秒，连接程序和扩展分别以 190/195 秒作为外层等待上限。
