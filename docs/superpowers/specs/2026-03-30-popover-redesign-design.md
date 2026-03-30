# NoType Popover Redesign — Design Spec

## Problem

The current `MenuBarContentView` popover is cluttered:
- Flat information hierarchy — title, hotkey, dropdowns, buttons all carry equal visual weight
- Two separate dropdown menus (Language, LLM Refinement) stacked vertically take up excessive space
- Hotkey display is oversized for users who already know it
- Overall lacks macOS-native polish
- Width (360pt) is wider than necessary

## Design: Card-Based Groups

### Layout Structure (3 zones)

**Zone 1 — Header Row**
- Left: "NoType" title (`.headline` weight)
- Right: Colored status dot + status text (e.g., "● Ready")
- Status dot color follows existing `DictationPhase` mapping:
  - `.idle` / `.onboarding` → `.secondary` (gray)
  - `.recording` → `.red`
  - `.transcribing` / `.refining` → `.orange`
  - `.inserted` / `.copiedToClipboard` → `.green`
  - `.failed` → `.yellow` (matches existing behavior; differentiates from recording)
- No subtitle paragraph — status dot replaces the verbose status line
- Status text is a short label derived from phase (e.g., "Ready", "Recording", "Error"), not the full `statusLine`

**Zone 2 — Main Card** (rounded rect background, ~`Color(.systemGray6)` equivalent)
- **Top half — Hotkey Hero:**
  - Left: Mic icon in a rounded-rect container (SF Symbol `mic.circle`, 36pt)
  - Right of icon: Dynamic caption from `model.statusLine` (e.g., "Press to start", "Recording…") + hotkey display name in monospaced font
  - Icon color follows the same `DictationPhase` color mapping
- **Bottom half — Settings Tiles (side-by-side):**
  - Left tile: "LANGUAGE" uppercase label + current language name + `▾` chevron → opens `Menu` with all `DictationLanguage` cases
  - Right tile: "LLM" uppercase label + status indicator (● On / ● Off with green/gray color) + `▾` chevron → opens `Menu` with enable/disable toggle + "Settings…" submenu
  - Both tiles have rounded-rect background slightly darker than the card

**Zone 3 — Icon Footer**
- Left: Gear icon button (SF Symbol `gearshape`) → opens Settings window
- Right: Power icon button (SF Symbol `power`) → quits app
- Both are small (28pt) rounded-rect icon buttons, no text labels
- Icon color: `.secondary`

### Conditional States

- **Permissions not ready:** Replace the hotkey hero area with "Open Setup" button (`.borderedProminent`)
- **Missing ASR credentials:** Show orange warning text + "Open Settings" button inside the card, above the tiles
- **Hotkey warning:** Small orange caption below the hotkey display, inside the card
- **Error state:** Red error text inside the card area, replacing or below the hotkey hero

### Dimensions

- Width: **280pt** (down from 360pt)
- Padding: **14pt**
- Card corner radius: **10pt**
- Tile corner radius: **8pt**
- VStack spacing: **10pt** (between zones)
- Card internal spacing: **12pt**

### Visual Hierarchy

1. **Primary** — Hotkey (largest text, monospaced, prominent position)
2. **Secondary** — Language & LLM tiles (interactive, but smaller)
3. **Tertiary** — Status dot, header title
4. **Minimal** — Settings/Quit icons (always available but unobtrusive)

## Files to Modify

- `Sources/NoType/Views/MenuBarContentView.swift` — complete rewrite of the view body
- No model/service changes required — all data bindings remain the same

## Out of Scope

- Settings window redesign
- HUD panel changes
- New features or functionality
- Model/ViewModel changes
