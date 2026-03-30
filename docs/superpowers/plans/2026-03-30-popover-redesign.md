# Popover Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `MenuBarContentView` from a flat, cluttered layout to a card-based design with clear visual hierarchy, compact dimensions, and icon-only footer.

**Architecture:** Single-file rewrite of `MenuBarContentView.swift`. No model/service changes — all existing `NoTypeAppModel` bindings are reused. The view is restructured into 3 zones: header row, main card (hotkey hero + settings tiles), and icon footer.

**Tech Stack:** SwiftUI, SF Symbols, macOS 14+

---

## File Structure

- **Modify:** `Sources/NoType/Views/MenuBarContentView.swift` — complete rewrite of `body` and computed properties; helper functions (`activateAndOpenWindow`, `openSettingsWindow`, `dismissMenuBarWindow`) remain unchanged.

No new files needed. No model/service changes.

---

### Task 1: Rewrite Header Row (Zone 1)

**Files:**
- Modify: `Sources/NoType/Views/MenuBarContentView.swift:9-26`

- [ ] **Step 1: Add `statusLabel` computed property**

Add a new computed property that returns a short phase label for the status dot:

```swift
private var statusLabel: String {
    switch model.phase {
    case .idle:
        "Ready"
    case .onboarding:
        "Setup"
    case .recording:
        "Recording"
    case .transcribing:
        "Transcribing"
    case .refining:
        "Refining"
    case .inserted:
        "Done"
    case .copiedToClipboard:
        "Copied"
    case .failed:
        "Error"
    }
}
```

- [ ] **Step 2: Add `statusColor` computed property**

Rename existing `iconColor` to `statusColor` (used by both header dot and mic icon):

```swift
private var statusColor: Color {
    switch model.phase {
    case .recording:
        .red
    case .transcribing, .refining:
        .orange
    case .inserted, .copiedToClipboard:
        .green
    case .failed:
        .yellow
    case .idle, .onboarding:
        .secondary
    }
}
```

- [ ] **Step 3: Replace header HStack**

Replace lines 10-26 (the old VStack + HStack header) with the new header row:

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 10) {
        // Zone 1 — Header
        HStack {
            Text("NoType")
                .font(.headline)

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
```

- [ ] **Step 4: Build and verify header renders**

Run: `swift build`
Expected: Compiles (view body incomplete — will complete in subsequent tasks)

- [ ] **Step 5: Commit**

```bash
git add Sources/NoType/Views/MenuBarContentView.swift
git commit -m "refactor(popover): replace header with compact status-dot row"
```

---

### Task 2: Build Main Card with Hotkey Hero (Zone 2 — top half)

**Files:**
- Modify: `Sources/NoType/Views/MenuBarContentView.swift`

- [ ] **Step 1: Add the card container and hotkey hero section**

After the header HStack, add the main card. Replace the old hotkey display (lines 46-52), conditional states (lines 28-66), and the two Menu dropdowns (lines 68-91) with a single card:

```swift
        // Zone 2 — Main Card
        VStack(spacing: 12) {
            // Hotkey Hero (or setup prompt)
            if !model.permissionSnapshot.ready {
                Button("Open Setup") {
                    activateAndOpenWindow(id: "onboarding")
                }
                .buttonStyle(.borderedProminent)
            } else if !model.hasASRCredentials {
                VStack(spacing: 6) {
                    Text("Missing Doubao credentials")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Button("Open Settings") {
                        openSettingsWindow()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "mic.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(statusColor)
                        .frame(width: 36, height: 36)
                        .background(Color(.controlBackgroundColor).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.statusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(model.hotkeyDisplayName)
                            .font(.subheadline.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Hotkey warning
            if let warning = model.hotkeyWarningMessage {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Error message
            if let errorMessage = model.errorMessage, model.phase == .failed {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
```

- [ ] **Step 2: Commit**

```bash
git add Sources/NoType/Views/MenuBarContentView.swift
git commit -m "refactor(popover): add card with hotkey hero and conditional states"
```

---

### Task 3: Add Settings Tiles (Zone 2 — bottom half)

**Files:**
- Modify: `Sources/NoType/Views/MenuBarContentView.swift`

- [ ] **Step 1: Add Language and LLM tiles side-by-side**

Continue inside the card VStack, after the error message conditional:

```swift
            // Settings Tiles
            HStack(spacing: 8) {
                // Language tile
                Menu {
                    ForEach(DictationLanguage.allCases) { language in
                        Button {
                            model.selectLanguage(language)
                        } label: {
                            Label(
                                language.displayName,
                                systemImage: model.settings.language == language ? "checkmark" : ""
                            )
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LANGUAGE")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("\(model.settings.language.displayName) ▾")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                // LLM tile
                Menu {
                    Button {
                        model.setLLMRefinementEnabled(!model.llmRefinementEnabled)
                    } label: {
                        Label(
                            model.llmRefinementEnabled ? "Enabled" : "Disabled",
                            systemImage: model.llmRefinementEnabled ? "checkmark.circle.fill" : "circle"
                        )
                    }
                    Button("Settings…") {
                        openSettingsWindow()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LLM")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(model.llmRefinementEnabled ? Color.green : Color.secondary)
                                .frame(width: 6, height: 6)
                            Text("\(model.llmRefinementEnabled ? "On" : "Off") ▾")
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
```

- [ ] **Step 2: Commit**

```bash
git add Sources/NoType/Views/MenuBarContentView.swift
git commit -m "refactor(popover): add side-by-side language and LLM tiles"
```

---

### Task 4: Add Icon Footer (Zone 3) and Finalize Layout

**Files:**
- Modify: `Sources/NoType/Views/MenuBarContentView.swift`

- [ ] **Step 1: Replace old footer with icon buttons**

Remove the old Divider + HStack (Settings…/Quit text buttons) and add:

```swift
        // Zone 3 — Icon Footer
        HStack {
            Button {
                openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color(.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color(.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }
    .padding(14)
    .frame(width: 280)
}
```

- [ ] **Step 2: Remove old `iconColor` property**

Delete the old `iconColor` computed property (it was renamed to `statusColor` in Task 1).

- [ ] **Step 3: Build and verify**

Run: `swift build`
Expected: Compiles with no errors. The entire `MenuBarContentView` body is now the new 3-zone layout.

- [ ] **Step 4: Commit**

```bash
git add Sources/NoType/Views/MenuBarContentView.swift
git commit -m "refactor(popover): add icon footer and finalize card-based layout"
```

---

### Task 5: Visual QA and Polish

**Files:**
- Modify: `Sources/NoType/Views/MenuBarContentView.swift` (if adjustments needed)

- [ ] **Step 1: Run the app and verify all states**

Run: `swift build && open .build/debug/NoType.app` (or build via Xcode)

Verify visually:
1. Header shows "NoType" + colored status dot
2. Card shows mic icon + hotkey name + status caption
3. Language and LLM tiles are side-by-side, menus open correctly
4. Settings gear icon opens the settings window
5. Power icon quits the app
6. Width is ~280pt (noticeably narrower than before)

- [ ] **Step 2: Verify conditional states**

Test each conditional path:
1. Permissions not ready → "Open Setup" button appears in card
2. Missing ASR credentials → orange warning + "Open Settings" in card
3. Hotkey warning → orange caption below hotkey
4. Error state → red error text in card

- [ ] **Step 3: Adjust spacing/colors if needed and commit**

```bash
git add Sources/NoType/Views/MenuBarContentView.swift
git commit -m "style(popover): visual QA adjustments"
```

(Skip this commit if no adjustments needed.)
