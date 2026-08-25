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

## Pi integration

The native Pi extension is at [`integrations/pi/notype.ts`](../integrations/pi/notype.ts). It listens to terminal input without replacing Pi's editor component, so it remains compatible with custom Pi editors.

Install it globally for development:

```bash
mkdir -p ~/.pi/agent/extensions/notype
cp integrations/pi/notype.ts ~/.pi/agent/extensions/notype/index.ts
```

Then run `/reload` in Pi. With NoType running and Codex logged in, enter a non-empty draft and press Space three times within one second. The extension removes only the trigger spaces, asks NoType to translate, and replaces the draft only if it has not changed while the request was running.

The Pi adapter does not use or remap `Ctrl+G`.

## Current boundary

The bridge server and Pi adapter are implemented. Claude Code and Codex CLI will use the same bridge protocol through an external-editor adapter; that adapter is not installed automatically and remains a separate integration step.
