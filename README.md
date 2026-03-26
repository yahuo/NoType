# NoType

NoType is a macOS menu bar dictation app built with SwiftUI, AppKit, SwiftData, and Doubao streaming ASR.

## Current MVP

- Menu bar utility with setup, settings, history, and floating HUD
- Global hotkey dictation with `Option + Space` by default
- Microphone capture with 16 kHz mono PCM chunking
- Direct Doubao WebSocket ASR integration using 2.0 `X-Api-*` headers
- Accessibility-first text insertion with clipboard paste fallback
- Local-only history storage through SwiftData
- Retry-once flow when the ASR request fails

## Run

```bash
swift run NoType
```

## Open In Xcode

Generate a native Xcode project:

```bash
ruby scripts/generate_xcodeproj.rb
open NoType.xcodeproj
```

Then in Xcode:

1. Select the `NoType` target.
2. Open `Signing & Capabilities`.
3. Enable `Automatically manage signing`.
4. Choose your Apple Developer `Team`.
5. Run or Archive from Xcode.

For local development, `Apple Development` signing is enough. For external distribution, use `Developer ID` and notarization.

## Configure Doubao

Open `Settings` from the menu bar app and provide:

- `App ID`
- `Resource ID`
- `Access Token`

For Doubao streaming ASR 2.0:

- Hour pack: `volc.seedasr.sauc.duration`
- Concurrency pack: `volc.seedasr.sauc.concurrent`

The token is stored in macOS Keychain. Other settings are stored in `UserDefaults`.

## Required macOS Permissions

- `Microphone`
- `Accessibility`

If dictation cannot start, open the `Setup` window and request both permissions again.

## Verify

```bash
swift build
swift test
```

## Known MVP Limits

- The default hotkey is a stable combo key, not bare `Fn`
- Doubao responses are expected to use uncompressed payloads in this build
- The retry flow replays the locally buffered PCM recording from disk
