# NoType Local Bridge

NoType exposes a local Unix domain socket while the menu bar app is running. Terminal integrations can send draft text to NoType, reuse its Codex login state and translation model, and receive the English translation without using Accessibility screen scraping.

## Runtime endpoint

Default socket path:

```text
$TMPDIR/com.opensource.notype/bridge.sock
```

Clients may override it with `NOTYPE_BRIDGE_SOCKET`. NoType creates the runtime directory with mode `0700` and the socket with mode `0600`.

The bridge starts from `NoTypeAppModel.bootstrap()` and stops during application termination. A lock file prevents a second NoType process from unlinking the active socket. If NoType is not running, clients must preserve the user's draft.

## Protocol

Each connection carries one request and one response, then closes. A frame consists of:

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

## Editor-only bridge request

The bundled proxy uses the `translate_editor` method. In addition to the normal request fields it sends the short-lived token, helper/parent PIDs, TTY path, and `trigger: "triple-space"`. NoType accepts the token once only, while the terminal that generated it remains focused. This method is internal to the bundled proxy; third-party clients should use `translate`.

## Current boundary

Pi, Claude Code, and Codex CLI are supported for local TUI sessions. Remote SSH sessions cannot reach the Mac-local Unix socket unless the socket is explicitly forwarded or another transport is added.
