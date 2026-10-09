import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Panel entry, kept loaded for the plugin's lifetime. Hosts the dictation HUD
// and the selection translation card, which follow the service state and never
// take keyboard focus when they appear, and the Settings and Setup windows,
// which `shell summon notype '{"page":"settings"}'` (or "setup") opens.
Item {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null
  property var service: null
  property bool settingsOpen: false
  property bool setupOpen: false
  property bool closingFromHost: false
  readonly property bool opened: settingsOpen || setupOpen

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "notype"

  readonly property bool online: !!service && service.online === true
  readonly property string phase: service ? String(service.phase || "idle") : "idle"
  readonly property string mode: service ? String(service.mode || "dictation") : "dictation"
  readonly property string transcript: service ? String(service.transcript || "") : ""
  readonly property real level: service ? Math.max(0, Math.min(1, Number(service.level) || 0)) : 0
  readonly property string errorText: service ? String(service.error || "") : ""
  readonly property string warningText: service ? String(service.warning || "") : ""
  readonly property string selectionState: service ? String(service.selectionState || "hidden") : "hidden"
  readonly property string selectionSource: service ? String(service.selectionSource || "") : ""
  readonly property string selectionTranslation: service ? String(service.selectionTranslation || "") : ""
  readonly property string selectionError: service ? String(service.selectionError || "") : ""

  readonly property bool recording: phase === "recording"
  readonly property bool busy: phase === "transcribing" || phase === "refining"
  readonly property bool failed: phase === "failed"
  readonly property bool translationMode: mode === "translation"

  readonly property bool hudWanted: online && phase !== "idle"
  readonly property bool selectionWanted: online && selectionState !== "hidden"

  // Screens are latched when a window appears so a focus change elsewhere
  // does not remap a visible surface.
  property var hudScreen: null
  property bool hudShown: false
  property var selectionScreen: null
  property bool selectionShown: false

  // The selection card maps with no keyboard focus. A click primes Exclusive
  // briefly and then settles on OnDemand, as Ui/KeyboardPanel does.
  property bool selectionFocusRequested: false
  property bool selectionFocusPrimed: false
  property bool selectionCopied: false

  readonly property string glyphLoading: String.fromCodePoint(0xF0772)
  readonly property string glyphCheck: String.fromCodePoint(0xF012C)
  readonly property string glyphCopy: String.fromCodePoint(0xF018F)
  readonly property string glyphAlert: String.fromCodePoint(0xF0026)
  readonly property string glyphClose: String.fromCodePoint(0xF0156)
  readonly property string glyphTranslate: String.fromCodePoint(0xF05CA)

  readonly property var barBaseHeights: [6, 9, 12, 16, 14, 18, 13, 16, 10, 7]

  readonly property string phaseLabel: {
    switch (root.phase) {
    case "recording": return "Listening"
    case "transcribing": return "Transcribing"
    case "refining": return root.translationMode ? "Translating" : "Refining"
    case "inserted": return "Inserted"
    case "copied_to_clipboard": return "Copied to clipboard"
    case "failed": return root.translationMode ? "Translation failed" : "Dictation failed"
    default: return root.phase
    }
  }

  readonly property string phaseGlyph: {
    if (root.phase === "inserted" || root.phase === "copied_to_clipboard") return root.glyphCheck
    if (root.failed) return root.glyphAlert
    return ""
  }

  readonly property bool hudShowsTranscript: root.transcript !== "" && !root.failed
  readonly property bool hudShowsError: root.failed && root.errorText !== ""
  readonly property bool hudShowsWarning: root.warningText !== ""
  readonly property bool hudHasBody: root.hudShowsTranscript || root.hudShowsError || root.hudShowsWarning

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(String(payloadJson || "{}")) || {} } catch (e) {}
    if (payload.page === "setup") root.setupOpen = true
    else root.settingsOpen = true
    if (root.service) root.service.refreshSnapshot()
  }

  // Host-initiated close (`shell hide`); the host already knows.
  function close() {
    root.closingFromHost = true
    root.settingsOpen = false
    root.setupOpen = false
    root.closingFromHost = false
  }

  // The user closed a window. Once none is left, tell the shell so its open
  // state stays in sync and the next summon opens a window again.
  function windowClosed(page) {
    if (root.closingFromHost) return
    Qt.callLater(function() {
      if (page === "setup") root.setupOpen = false
      else root.settingsOpen = false
      if (!root.opened && root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    })
  }

  function lookupService() {
    if (root.service) return
    if (!root.shell || typeof root.shell.serviceFor !== "function") return
    var found = root.shell.serviceFor(root.pluginId)
    if (found) root.service = found
  }

  function run(args) {
    if (root.service && typeof root.service.run === "function") root.service.run(args)
    else Quickshell.execDetached(["sh", "-c", "exec notype \"$@\"", "notype"].concat(args))
  }

  function hideSelection() { root.run(["selection-hide"]) }

  function copySelection() {
    if (root.selectionState !== "done" || root.selectionTranslation === "") return
    root.run(["selection-copy"])
    root.selectionCopied = true
    copiedTimer.restart()
  }

  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++) {
      if (screens[i] && String(screens[i].name || "") === name) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  function syncHud() {
    if (root.hudWanted && !root.hudShown) root.hudScreen = root.focusedScreen()
    root.hudShown = root.hudWanted
  }

  function resetSelectionFocus() {
    focusPrimeTimer.stop()
    root.selectionFocusRequested = false
    root.selectionFocusPrimed = false
  }

  function syncSelection() {
    if (root.selectionWanted && !root.selectionShown) {
      root.selectionScreen = root.focusedScreen()
      root.selectionCopied = false
    }
    if (!root.selectionWanted) root.resetSelectionFocus()
    root.selectionShown = root.selectionWanted
  }

  function requestSelectionFocus() {
    if (!root.selectionShown || keyCatcher.activeFocus) return
    root.selectionFocusRequested = true
    root.selectionFocusPrimed = false
    keyCatcher.forceActiveFocus()
    focusPrimeTimer.restart()
  }

  function focusKeyCatcher() {
    if (root.selectionShown && root.selectionFocusRequested) keyCatcher.forceActiveFocus()
  }

  onHudWantedChanged: root.syncHud()
  onSelectionWantedChanged: root.syncSelection()
  onSelectionTranslationChanged: root.selectionCopied = false
  Component.onCompleted: {
    root.lookupService()
    root.syncHud()
    root.syncSelection()
  }

  // The loader injects `service` once; retry while the service is not ready.
  Timer {
    interval: 1000
    repeat: true
    running: !root.service
    onTriggered: root.lookupService()
  }

  Timer {
    id: focusPrimeTimer
    interval: 75
    repeat: false
    onTriggered: {
      if (!root.selectionShown || !root.selectionFocusRequested) return
      root.selectionFocusPrimed = true
      Qt.callLater(root.focusKeyCatcher)
    }
  }

  Timer {
    id: copiedTimer
    interval: 1500
    repeat: false
    onTriggered: root.selectionCopied = false
  }

  // Dictation HUD: visual only, empty input region, never focused.
  PanelWindow {
    id: hudWindow
    screen: root.hudScreen
    visible: root.hudShown
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "notype-hud"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region {}

    BorderSurface {
      id: hudCard

      readonly property int pad: Style.space(14)
      readonly property int innerWidth: root.hudHasBody
        ? Math.max(hudHeader.implicitWidth, Math.min(Style.space(360), hudWindow.width - Style.space(64)))
        : hudHeader.implicitWidth

      width: hudCard.borderLeft + hudCard.pad + hudCard.innerWidth + hudCard.pad + hudCard.borderRight
      height: hudCard.borderTop + hudCard.pad + hudColumn.implicitHeight + hudCard.pad + hudCard.borderBottom
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(140)
      color: Util.alpha(Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius

      Column {
        id: hudColumn
        x: hudCard.borderLeft + hudCard.pad
        y: hudCard.borderTop + hudCard.pad
        width: hudCard.innerWidth
        spacing: Style.spacing.lg

        Row {
          id: hudHeader
          spacing: Style.spacing.lg
          height: Math.max(Style.space(20), phaseText.implicitHeight)

          Row {
            id: levelBars
            visible: root.recording
            spacing: Style.space(2)
            anchors.verticalCenter: parent.verticalCenter

            Repeater {
              model: root.barBaseHeights.length

              Rectangle {
                required property int index
                readonly property real base: root.barBaseHeights[index]
                width: Style.space(3)
                height: Style.space(Math.min(20, Math.max(4, base * (0.35 + root.level * 1.3))))
                radius: width / 2
                anchors.verticalCenter: parent.verticalCenter
                color: index === 4 || index === 5 ? Color.accent : Color.popups.text

                Behavior on height { NumberAnimation { duration: 80 } }
              }
            }
          }

          Text {
            id: spinner
            visible: root.busy
            textFormat: Text.PlainText
            text: root.glyphLoading
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.iconLarge
            anchors.verticalCenter: parent.verticalCenter
            transformOrigin: Item.Center

            RotationAnimation on rotation {
              from: 0
              to: 360
              duration: 900
              loops: Animation.Infinite
              running: root.busy && root.hudShown
            }
          }

          Text {
            visible: root.phaseGlyph !== ""
            textFormat: Text.PlainText
            text: root.phaseGlyph
            color: root.failed ? Color.urgent : Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.iconLarge
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: phaseText
            textFormat: Text.PlainText
            text: root.phaseLabel
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }

          Rectangle {
            visible: root.translationMode
            width: modeText.implicitWidth + Style.spacing.md * 2
            height: modeText.implicitHeight + Style.spacing.xs * 2
            radius: Style.cornerRadius
            color: Util.alpha(Color.accent, 0.18)
            border.width: 1
            border.color: Util.alpha(Color.accent, 0.6)
            anchors.verticalCenter: parent.verticalCenter

            Text {
              id: modeText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: "Translate"
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        // Shows the newest three lines of the live transcript.
        Item {
          id: transcriptBox
          visible: root.hudShowsTranscript
          width: parent.width
          readonly property real lineHeight: transcriptText.lineCount > 0
            ? transcriptText.implicitHeight / transcriptText.lineCount
            : transcriptText.font.pixelSize
          height: visible ? Math.min(transcriptText.implicitHeight, Math.ceil(lineHeight * 3)) : 0
          clip: true

          Text {
            id: transcriptText
            width: parent.width
            anchors.bottom: parent.bottom
            textFormat: Text.PlainText
            text: root.transcript
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            color: Util.alpha(Color.popups.text, 0.85)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        Text {
          visible: root.hudShowsError
          width: parent.width
          textFormat: Text.PlainText
          text: root.errorText
          wrapMode: Text.WrapAtWordBoundaryOrAnywhere
          maximumLineCount: 3
          elide: Text.ElideRight
          color: Util.alpha(Color.popups.text, 0.85)
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Text {
          visible: root.hudShowsWarning
          width: parent.width
          textFormat: Text.PlainText
          text: root.warningText
          wrapMode: Text.WrapAtWordBoundaryOrAnywhere
          maximumLineCount: 2
          elide: Text.ElideRight
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // Selection translation card. Only the card accepts input.
  PanelWindow {
    id: selectionWindow
    screen: root.selectionScreen
    visible: root.selectionShown
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "notype-selection"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.selectionFocusRequested
      ? (root.selectionFocusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
      : WlrKeyboardFocus.None
    mask: Region { item: selectionCard }

    BorderSurface {
      id: selectionCard

      readonly property int pad: Style.spacing.popupPadding
      readonly property int innerWidth: Math.max(Style.space(200),
        Math.min(Style.space(480), selectionWindow.width - Style.space(64)) - selectionCard.pad * 2)
      readonly property real maxBodyHeight: Math.max(Style.space(120), selectionWindow.height * 0.55)

      width: selectionCard.borderLeft + selectionCard.pad + selectionCard.innerWidth + selectionCard.pad + selectionCard.borderRight
      height: selectionCard.borderTop + selectionCard.pad + selectionColumn.implicitHeight + selectionCard.pad + selectionCard.borderBottom
      anchors.centerIn: parent
      color: Util.alpha(Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius

      Item {
        id: keyCatcher
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.hideSelection()
            event.accepted = true
          } else if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier)) {
            root.copySelection()
            event.accepted = true
          }
        }
      }

      Column {
        id: selectionColumn
        x: selectionCard.borderLeft + selectionCard.pad
        y: selectionCard.borderTop + selectionCard.pad
        width: selectionCard.innerWidth
        spacing: Style.spacing.xl

        Item {
          width: parent.width
          height: Math.max(titleRow.implicitHeight, actions.implicitHeight)

          Row {
            id: titleRow
            spacing: Style.spacing.md
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Text {
              textFormat: Text.PlainText
              text: root.glyphTranslate
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.iconLarge
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: "简体中文"
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              visible: root.selectionState === "translating"
              textFormat: Text.PlainText
              text: root.glyphLoading
              color: Util.alpha(Color.popups.text, 0.7)
              font.family: Style.font.family
              font.pixelSize: Style.font.icon
              anchors.verticalCenter: parent.verticalCenter
              transformOrigin: Item.Center

              RotationAnimation on rotation {
                from: 0
                to: 360
                duration: 900
                loops: Animation.Infinite
                running: root.selectionShown && root.selectionState === "translating"
              }
            }

            Text {
              visible: root.selectionState === "translating"
              textFormat: Text.PlainText
              text: "翻译中…"
              color: Util.alpha(Color.popups.text, 0.7)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Row {
            id: actions
            spacing: Style.spacing.sm
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            PanelActionButton {
              iconText: root.selectionCopied ? root.glyphCheck : root.glyphCopy
              tooltipText: root.selectionCopied ? "已复制" : "复制译文"
              foreground: Color.popups.text
              fontFamily: Style.font.family
              enabled: root.selectionState === "done" && root.selectionTranslation !== ""
              onClicked: root.copySelection()
            }

            PanelActionButton {
              iconText: root.glyphClose
              tooltipText: "关闭"
              foreground: Color.popups.text
              hoverColor: Color.urgent
              fontFamily: Style.font.family
              onClicked: root.hideSelection()
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Math.max(1, Style.spacing.hairline)
          color: Util.alpha(Color.popups.text, 0.15)
        }

        Flickable {
          id: body
          width: parent.width
          height: Math.min(bodyColumn.implicitHeight, selectionCard.maxBodyHeight)
          contentWidth: width
          contentHeight: bodyColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: bodyColumn
            width: body.width
            spacing: Style.spacing.xl

            Text {
              visible: root.selectionState === "failed"
              width: parent.width
              textFormat: Text.PlainText
              text: root.glyphAlert + "  " + (root.selectionError !== "" ? root.selectionError : "翻译失败")
              wrapMode: Text.WrapAtWordBoundaryOrAnywhere
              color: Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
            }

            Text {
              visible: root.selectionState !== "failed" && root.selectionTranslation !== ""
              width: parent.width
              textFormat: Text.PlainText
              text: root.selectionTranslation
              wrapMode: Text.WrapAtWordBoundaryOrAnywhere
              lineHeight: 1.25
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
            }

            Text {
              visible: root.selectionState === "translating" && root.selectionTranslation === ""
              width: parent.width
              textFormat: Text.PlainText
              text: "正在读取并翻译选中文字…"
              wrapMode: Text.WrapAtWordBoundaryOrAnywhere
              color: Util.alpha(Color.popups.text, 0.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
            }

            Column {
              visible: root.selectionSource !== ""
              width: parent.width
              spacing: Style.spacing.sm

              Text {
                textFormat: Text.PlainText
                text: "原文"
                color: Util.alpha(Color.popups.text, 0.55)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.selectionSource
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                color: Util.alpha(Color.popups.text, 0.7)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: keyCatcher.activeFocus ? "Esc 关闭 · Ctrl+C 复制" : "Alt + Esc 关闭"
          color: Util.alpha(Color.popups.text, 0.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      // Notices presses for click-to-focus and lets them through to the
      // buttons and the scroll area underneath.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onPressed: function(mouse) {
          root.requestSelectionFocus()
          mouse.accepted = false
        }
      }
    }
  }

  LazyLoader {
    active: root.settingsOpen

    SettingsWindow {
      service: root.service
      onVisibleChanged: if (!visible) root.windowClosed("settings")
    }
  }

  LazyLoader {
    active: root.setupOpen

    SetupWindow {
      service: root.service
      onVisibleChanged: if (!visible) root.windowClosed("setup")
    }
  }
}
