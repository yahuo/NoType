import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

// The macOS Settings window: Speech and AI Rewrite tabs over a draft that
// `notype settings set` saves. Values come from `notype settings get`.
FloatingWindow {
  id: root

  property var service: null

  readonly property var snapshot: service && service.snapshot ? service.snapshot : null
  readonly property string savedProvider: snapshot ? String(snapshot.speech_provider || "codex") : "codex"
  readonly property bool codexLoggedIn: !!snapshot && snapshot.codex_logged_in === true
  readonly property var hotkeys: snapshot && snapshot.hotkeys ? snapshot.hotkeys : ({})
  readonly property color fg: Color.foreground
  readonly property color secondary: Util.alpha(Color.foreground, 0.6)

  property string tab: "speech"
  property string draftProvider: "codex"
  property string draftLanguage: "zh-CN"
  property string draftAppId: ""
  property string draftResourceId: ""
  property string draftToken: ""
  property bool tokenEdited: false
  property bool dirty: false
  property bool busy: false
  property string message: ""
  property string warning: ""
  property string error: ""

  // Callbacks of calls still running when the window closes must not touch it.
  property var alive: ({ value: true })

  function loadDraft() {
    if (!root.snapshot || root.dirty) return
    root.draftProvider = root.savedProvider
    root.draftLanguage = String(root.snapshot.language || "zh-CN")
    root.draftAppId = String(root.snapshot.app_id || "")
    root.draftResourceId = String(root.snapshot.resource_id || "")
    root.draftToken = ""
    root.tokenEdited = false
  }

  function edit(apply) {
    apply()
    root.dirty = true
  }

  function clearMessages() {
    root.message = ""
    root.warning = ""
    root.error = ""
  }

  function showOutcome(outcome) {
    root.message = outcome.ok ? String(outcome.message || "") : ""
    root.warning = String(outcome.warning || "")
    root.error = outcome.ok ? "" : String(outcome.error || "")
  }

  // Only what differs from the saved settings, so a save leaves the rest of
  // config.toml alone. The token is sent only after it was edited.
  function changes() {
    var saved = root.snapshot || {}
    var draft = {}
    if (root.draftProvider !== String(saved.speech_provider || "")) draft.speech_provider = root.draftProvider
    if (root.draftLanguage !== String(saved.language || "")) draft.language = root.draftLanguage
    if (root.draftAppId.trim() !== String(saved.app_id || "")) draft.app_id = root.draftAppId.trim()
    if (root.draftResourceId.trim() !== String(saved.resource_id || "")) draft.resource_id = root.draftResourceId.trim()
    if (root.tokenEdited) draft.access_token = root.draftToken.trim()
    return draft
  }

  function call(args, input, onOk) {
    if (root.busy || !root.service) return
    var alive = root.alive
    root.clearMessages()
    root.busy = true
    root.service.settingsCall(args, input, function(outcome) {
      if (!alive.value) return
      root.busy = false
      root.showOutcome(outcome)
      if (outcome.ok && onOk) onOk()
      if (root.service) root.service.refreshSnapshot()
    })
  }

  function save() {
    root.call(["set"], JSON.stringify(root.changes()), function() {
      root.draftToken = ""
      root.tokenEdited = false
      root.dirty = false
    })
  }

  function runTest() {
    if (root.tab === "speech") root.call(["test", "speech"], JSON.stringify(root.changes()), null)
    else root.call(["test", "ai-rewrite"], "", null)
  }

  function setAiRewrite(enabled) {
    root.call(["set"], JSON.stringify({ ai_rewrite: enabled }), null)
  }

  function hotkeyText(name) {
    var value = root.hotkeys[name]
    return value ? String(value) : "未绑定"
  }

  // Fit the current tab, like the macOS window; scroll only past 85% of the screen.
  readonly property real fittedHeight: Style.space(14) + tabs.implicitHeight + Style.space(14)
    + form.implicitHeight + Style.space(16) + bottomBar.height

  title: "NoType Settings"
  color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
  implicitWidth: Style.space(580)
  implicitHeight: Math.round(Math.min(root.fittedHeight, root.screen ? root.screen.height * 0.85 : Style.space(720)))
  minimumSize: Qt.size(Style.space(520), Style.space(240))
  onImplicitHeightChanged: fit.restart()

  onSnapshotChanged: root.loadDraft()
  Component.onCompleted: root.loadDraft()
  Component.onDestruction: root.alive.value = false

  Tones { id: tones; surface: Color.background }
  WindowFit { id: fit; window: root }

  // macOS grouped Form: a captioned header and rows in a tinted box.
  component FormSection: Column {
    id: section

    property string title: ""
    property string icon: ""
    default property alias rows: box.data

    width: parent ? parent.width : 0
    spacing: Style.space(6)

    Text {
      visible: section.title !== ""
      textFormat: Text.PlainText
      text: section.icon + "  " + section.title
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      font.weight: Font.DemiBold
    }

    Rectangle {
      width: parent.width
      height: box.implicitHeight + Style.space(8)
      radius: Style.cornerRadius
      color: Util.alpha(Color.foreground, 0.04)
      border.width: 1
      border.color: Util.alpha(Color.foreground, 0.1)

      Column {
        id: box
        x: Style.space(12)
        y: Style.space(4)
        width: parent.width - Style.space(24)
      }
    }
  }

  // Label on the left, control or value on the right.
  component FormRow: Item {
    id: formRow

    property string label: ""
    property bool first: false
    default property alias control: slot.data

    width: parent ? parent.width : 0
    implicitHeight: Math.max(Style.space(36), rowLabel.implicitHeight, slot.childrenRect.height) + Style.space(8)

    Rectangle {
      visible: !formRow.first
      width: parent.width
      height: 1
      color: Util.alpha(Color.foreground, 0.08)
    }

    Text {
      id: rowLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: formRow.label
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
    }

    Item {
      id: slot
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: childrenRect.width
      height: childrenRect.height
    }
  }

  component ValueText: Text {
    textFormat: Text.PlainText
    color: Util.alpha(Color.foreground, 0.6)
    font.family: Style.font.family
    font.pixelSize: Style.font.subtitle
    horizontalAlignment: Text.AlignRight
  }

  FocusScope {
    id: scope
    anchors.fill: parent
    focus: true

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        root.visible = false
        event.accepted = true
      } else if (event.key === Qt.Key_S && (event.modifiers & Qt.ControlModifier)) {
        root.save()
        event.accepted = true
      }
    }

    // Clicking empty space takes focus away from a text field.
    MouseArea {
      anchors.fill: parent
      onPressed: function(mouse) {
        scope.forceActiveFocus()
        mouse.accepted = false
      }
    }

    ButtonGroup {
      id: tabs
      anchors.top: parent.top
      anchors.topMargin: Style.space(14)
      anchors.horizontalCenter: parent.horizontalCenter
      focusable: false
      foreground: root.fg
      background: Color.background
      value: root.tab
      options: [
        { value: "speech", label: "Speech", icon: tones.glyphMic },
        { value: "rewrite", label: "AI Rewrite", icon: tones.glyphWand }
      ]
      onChanged: function(value) {
        root.tab = value
        root.clearMessages()
      }
    }

    Flickable {
      id: flick
      anchors.top: tabs.bottom
      anchors.topMargin: Style.space(14)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: bottomBar.top
      contentWidth: width
      contentHeight: form.implicitHeight + Style.space(16)
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: form
        x: Style.space(20)
        width: flick.width - Style.space(40)
        spacing: Style.space(18)

        Text {
          width: parent.width
          visible: !!root.snapshot && !!root.snapshot.config_error
          textFormat: Text.PlainText
          text: root.snapshot && root.snapshot.config_error
            ? "config.toml 无法读取，保存会按默认值重写：" + root.snapshot.config_error : ""
          wrapMode: Text.Wrap
          color: tones.error
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          width: parent.width
          visible: !root.snapshot
          textFormat: Text.PlainText
          text: "正在读取设置…"
          color: root.secondary
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
        }

        // Speech tab
        Column {
          width: parent.width
          spacing: Style.space(18)
          visible: root.tab === "speech" && !!root.snapshot

          FormSection {
            FormRow {
              label: "Speech Provider"
              first: true

              Dropdown {
                width: Style.space(200)
                showLabel: false
                foreground: root.fg
                value: root.draftProvider
                options: [{ value: "codex", label: "Codex" }, { value: "doubao", label: "Doubao" }]
                onChanged: function(value) {
                  root.edit(function() { root.draftProvider = value })
                  root.clearMessages()
                }
              }
            }
          }

          FormSection {
            visible: root.draftProvider === "codex"
            title: "Codex Dictation"
            icon: tones.glyphMic

            FormRow {
              label: "Status"
              first: true

              ValueText {
                text: root.codexLoggedIn ? tones.glyphCheckCircle + "  Logged in" : "Run `codex login` first"
                color: root.codexLoggedIn ? tones.ok : tones.warn
              }
            }
          }

          FormSection {
            visible: root.draftProvider === "doubao"
            title: "Doubao Credentials"
            icon: tones.glyphKey

            FormRow {
              label: "App ID"
              first: true

              TextField {
                width: Style.space(260)
                foreground: root.fg
                text: root.draftAppId
                onTextEdited: root.edit(function() { root.draftAppId = text })
              }
            }

            FormRow {
              label: "Resource ID"

              TextField {
                width: Style.space(260)
                foreground: root.fg
                text: root.draftResourceId
                onTextEdited: root.edit(function() { root.draftResourceId = text })
              }
            }

            FormRow {
              label: "Access Token"

              TextField {
                width: Style.space(260)
                foreground: root.fg
                password: true
                text: root.draftToken
                placeholderText: {
                  if (root.tokenEdited) return "Leave empty to remove"
                  var source = root.snapshot ? String(root.snapshot.access_token || "none") : "none"
                  if (source === "keyring") return "Saved in keyring"
                  if (source === "config") return "Saved in config.toml"
                  return "Required"
                }
                onTextEdited: root.edit(function() {
                  root.draftToken = text
                  root.tokenEdited = true
                })
              }
            }
          }

          FormSection {
            title: "Input"
            icon: tones.glyphKeyboard

            FormRow {
              label: "Dictation Hotkey"
              first: true
              ValueText { text: root.hotkeyText("dictation") }
            }

            FormRow {
              label: "Translate Hotkey"
              ValueText { text: root.hotkeyText("translation") }
            }

            FormRow {
              label: "选词译为中文"
              ValueText { text: root.hotkeyText("selection") }
            }

            FormRow {
              label: root.draftProvider === "codex" ? "Interface Language" : "Language"

              Dropdown {
                width: Style.space(200)
                showLabel: false
                foreground: root.fg
                value: root.draftLanguage
                options: tones.languages
                onChanged: function(value) { root.edit(function() { root.draftLanguage = value }) }
              }
            }
          }
        }

        // AI Rewrite tab
        Column {
          width: parent.width
          spacing: Style.space(18)
          visible: root.tab === "rewrite" && !!root.snapshot

          FormSection {
            title: "General"
            icon: tones.glyphChip

            Item {
              width: parent.width
              height: visible ? rewriteToggle.implicitHeight + Style.space(8) : 0
              visible: root.savedProvider === "doubao"

              Toggle {
                id: rewriteToggle
                y: Style.space(4)
                width: parent.width
                foreground: root.fg
                label: "Enable AI Rewrite"
                checked: !!root.snapshot && root.snapshot.ai_rewrite === true
                enabled: !root.busy
                onClicked: root.setAiRewrite(!checked)
              }
            }

            FormRow {
              label: "Provider"
              first: root.savedProvider !== "doubao"
              ValueText { text: "Codex OAuth" }
            }

            FormRow {
              label: "Status"

              ValueText {
                text: root.codexLoggedIn ? tones.glyphCheckCircle + "  Logged in" : "Run `codex login` first"
                color: root.codexLoggedIn ? tones.ok : tones.warn
              }
            }
          }

          FormSection {
            title: "Agent TUI Translation"
            icon: tones.glyphConsole

            FormRow {
              label: "Hotkey"
              first: true
              ValueText { text: root.hotkeyText("agent") }
            }
          }

          FormSection {
            title: "Connection"
            icon: tones.glyphLink

            FormRow {
              label: "Endpoint"
              first: true
              ValueText { text: "chatgpt.com/backend-api/codex" }
            }
          }
        }
      }
    }

    // Bottom bar
    Item {
      id: bottomBar
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Math.max(testButton.implicitHeight, saveButton.implicitHeight, messages.implicitHeight) + Style.space(24)

      PanelSeparator {
        anchors.top: parent.top
        foreground: root.fg
      }

      Button {
        id: testButton
        anchors.left: parent.left
        anchors.leftMargin: Style.space(20)
        anchors.verticalCenter: parent.verticalCenter
        bordered: true
        foreground: root.fg
        enabled: !root.busy && !!root.snapshot
        iconText: root.busy ? tones.glyphLoading : ""
        iconSpinning: root.busy
        text: {
          if (root.busy) return "Testing…"
          if (root.tab === "rewrite") return "Test AI Rewrite"
          return root.draftProvider === "codex" ? "Check Codex Login" : "Test Speech"
        }
        onClicked: root.runTest()
      }

      Column {
        id: messages
        anchors.left: testButton.right
        anchors.leftMargin: Style.space(12)
        anchors.right: saveButton.left
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          width: parent.width
          visible: text !== ""
          textFormat: Text.PlainText
          text: root.error !== "" ? root.error : root.message
          color: root.error !== "" ? tones.error : tones.ok
          wrapMode: Text.Wrap
          maximumLineCount: 3
          elide: Text.ElideRight
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          width: parent.width
          visible: text !== ""
          textFormat: Text.PlainText
          text: root.warning
          color: tones.warn
          wrapMode: Text.Wrap
          maximumLineCount: 3
          elide: Text.ElideRight
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }

      Button {
        id: saveButton
        anchors.right: parent.right
        anchors.rightMargin: Style.space(20)
        anchors.verticalCenter: parent.verticalCenter
        bordered: true
        selected: true
        foreground: root.fg
        enabled: !root.busy && !!root.snapshot
        text: "Save"
        tooltipText: "Ctrl+S"
        onClicked: root.save()
      }
    }
  }
}
