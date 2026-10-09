import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar indicator plus the popover of the macOS menu bar item. Dim when idle
// (or hidden with `hideWhenIdle`), urgent and pulsing while recording,
// spinning while transcribing or refining. Left click opens the popover,
// middle click toggles recording, right click cancels.
Panel {
  id: root

  manageIpc: false
  ipcTarget: ""

  property var service: null
  property string actionMessage: ""
  property bool actionFailed: false

  readonly property string pluginId: moduleName !== "" ? moduleName : "notype"
  readonly property bool online: !!service && service.online === true
  readonly property string phase: online ? String(service.phase || "idle") : "idle"
  readonly property string mode: online ? String(service.mode || "dictation") : "dictation"
  readonly property string provider: online ? String(service.provider || "") : ""
  readonly property bool recording: phase === "recording"
  readonly property bool busy: phase === "transcribing" || phase === "refining"
  readonly property bool failed: phase === "failed"
  readonly property bool done: phase === "inserted" || phase === "copied_to_clipboard"
  readonly property bool idle: !online || phase === "idle"
  readonly property bool hideWhenIdle: root.setting("hideWhenIdle", false) === true

  // Settings come from `notype settings get`; until it answers, assume a
  // working setup so the popover does not flash warnings.
  readonly property var snapshot: service && service.snapshot ? service.snapshot : null
  readonly property string language: snapshot ? String(snapshot.language || "zh-CN") : "zh-CN"
  readonly property bool chinese: language.indexOf("zh") === 0
  readonly property string savedProvider: snapshot ? String(snapshot.speech_provider || "codex") : (provider || "codex")
  readonly property bool envReady: !snapshot || snapshot.ready === true
  readonly property bool speechReady: !snapshot || snapshot.speech_ready === true
  readonly property bool aiRewrite: !!snapshot && snapshot.ai_rewrite === true
  readonly property var hotkeys: snapshot && snapshot.hotkeys ? snapshot.hotkeys : ({})
  readonly property string version: snapshot ? String(snapshot.version || "") : ""

  readonly property string dictationKey: hotkeyName("dictation", "Alt + Space")
  readonly property string translationKey: hotkeyName("translation", "Alt + Shift + Space")
  readonly property string selectionKey: hotkeyName("selection", "Alt + Ctrl + Space")
  readonly property string cancelKey: hotkeyName("cancel", "Alt + Esc")

  readonly property string statusLabel: {
    if (!root.online) return "未运行"
    if (!root.envReady) return "待设置"
    if (!root.speechReady) return "待配置"
    switch (root.phase) {
    case "idle": return "已就绪"
    case "recording": return "录音中"
    case "transcribing": return "转写中"
    case "refining": return "处理中"
    case "inserted": return "已输入"
    case "copied_to_clipboard": return "已复制"
    case "failed": return "出错了"
    default: return root.phase
    }
  }

  readonly property color statusColor: {
    if (!root.online) return tones.error
    if (!root.envReady || !root.speechReady) return tones.warn
    if (root.recording || root.failed) return tones.error
    if (root.busy) return tones.warn
    return tones.ok
  }

  readonly property string failedChecks: {
    var names = []
    var checks = root.snapshot && root.snapshot.checks instanceof Array ? root.snapshot.checks : []
    for (var i = 0; i < checks.length; i++)
      if (checks[i] && checks[i].required && !checks[i].ok) names.push(String(checks[i].label))
    return names.join(root.chinese ? "、" : ", ")
  }

  readonly property string statusLine: {
    if (!root.envReady)
      return root.tr("环境检查未通过：" + root.failedChecks + "。", "Environment check failed: " + root.failedChecks + ".")
    if (!root.speechReady) {
      if (root.savedProvider === "codex")
        return root.tr("语音输入需要 Codex 登录态。请先运行 codex login。", "Dictation requires Codex login. Run codex login first.")
      return root.tr("先在 Settings 中配置豆包 App ID、Resource ID 和 Access Token。",
        "Configure the Doubao App ID, Resource ID, and Access Token in Settings first.")
    }
    switch (root.phase) {
    case "idle":
      return root.tr("准备就绪，按 " + root.dictationKey + " 语音输入，按 " + root.translationKey + " 翻译成英文。",
        "Ready. Press " + root.dictationKey + " for dictation, or " + root.translationKey + " to translate to English.")
    case "recording":
      return root.tr("正在录音，再按 " + root.dictationKey + " 结束，" + root.cancelKey + " 取消。",
        "Recording. Press " + root.dictationKey + " again to stop, or " + root.cancelKey + " to cancel.")
    case "transcribing":
      return root.tr("正在转写语音，再按 " + root.dictationKey + " 可取消。", "Transcribing. Press " + root.dictationKey + " again to cancel.")
    case "refining":
      return root.tr("正在进行 AI 处理，再按 " + root.dictationKey + " 可取消。", "AI processing is running. Press " + root.dictationKey + " again to cancel.")
    case "inserted":
      return root.tr("已完成文本注入。", "Text pasted.")
    case "copied_to_clipboard":
      return root.tr("未检测到输入焦点，已复制到剪贴板。", "No editable focus. Copied to clipboard.")
    case "failed":
      return root.service && root.service.error ? String(root.service.error) : root.tr("语音输入失败。", "Dictation failed.")
    default:
      return ""
    }
  }

  // Missing Hyprland bindings, then the daemon's own warning.
  readonly property string hotkeyWarning: {
    var parts = []
    var missing = []
    if (root.snapshot) {
      if (!root.hotkeys.dictation) missing.push("语音输入")
      if (!root.hotkeys.translation) missing.push("语音译成英文")
      if (!root.hotkeys.selection) missing.push("选词译成中文")
    }
    if (missing.length > 0)
      parts.push(root.tr("未找到 Hyprland 快捷键：" + missing.join("、") + "。请确认 bindings.lua 已加载 notype.hyprland。",
        "Hyprland bindings not found: " + missing.join(", ") + ". Make sure bindings.lua loads notype.hyprland."))
    if (root.online && root.service.warning) parts.push(String(root.service.warning))
    return parts.join("\n")
  }

  function tr(zh, en) { return root.chinese ? zh : en }

  function hotkeyName(name, fallback) {
    if (!root.snapshot) return fallback
    var value = root.hotkeys[name]
    return value ? String(value) : root.tr("未绑定", "Unbound")
  }

  function lookupService() {
    if (root.service) return
    var api = root.bar && root.bar.shell ? root.bar.shell : null
    if (!api || typeof api.serviceFor !== "function") return
    var found = api.serviceFor(root.pluginId)
    if (found) root.service = found
  }

  function run(args) {
    if (root.service && typeof root.service.run === "function") root.service.run(args)
    else Quickshell.execDetached(["sh", "-c", "exec notype \"$@\"", "notype"].concat(args))
  }

  // The windows live in the panel entry, which owns the plugin's summon state.
  function openPage(page) {
    root.close()
    var api = root.bar && root.bar.shell ? root.bar.shell : null
    if (api && typeof api.summon === "function") api.summon(root.pluginId, JSON.stringify({ page: page }))
  }

  function saveSetting(draft) {
    if (!root.service) return
    root.actionMessage = ""
    root.service.settingsCall(["set"], JSON.stringify(draft), function(outcome) {
      root.actionFailed = !outcome.ok
      root.actionMessage = outcome.ok ? String(outcome.warning || "") : String(outcome.error || "")
      if (root.service) root.service.refreshSnapshot()
    })
  }

  function keycaps(shortcut) {
    return String(shortcut || "").split(" + ")
  }

  visible: root.opened || !(root.hideWhenIdle && root.idle)
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onRecordingChanged: if (!root.recording) pulseLayer.opacity = 1
  onBusyChanged: if (!root.busy) button.textRotation = 0
  onOpenedChanged: {
    if (root.opened && root.service) root.service.refreshSnapshot()
    if (!root.opened) root.actionMessage = ""
  }

  Tones { id: tones }

  // The service is created outside the bar; look it up until it exists.
  Timer {
    interval: 1000
    repeat: true
    running: !root.service
    triggeredOnStart: true
    onTriggered: root.lookupService()
  }

  SequentialAnimation {
    running: root.recording && root.visible
    loops: Animation.Infinite
    NumberAnimation { target: pulseLayer; property: "opacity"; to: 0.5; duration: 650; easing.type: Easing.InOutSine }
    NumberAnimation { target: pulseLayer; property: "opacity"; to: 1; duration: 650; easing.type: Easing.InOutSine }
  }

  NumberAnimation {
    target: button
    property: "textRotation"
    from: 0
    to: 360
    duration: 900
    loops: Animation.Infinite
    running: root.busy && root.visible
  }

  Item {
    id: pulseLayer
    anchors.fill: parent

    BarIconButton {
      id: button
      anchors.fill: parent
      bar: root.bar
      text: !root.online ? tones.glyphMicOff
        : (root.busy ? tones.glyphLoading
        : (root.failed ? tones.glyphAlert
        : (root.done ? tones.glyphCheck : tones.glyphMic)))
      active: root.recording || root.failed
      dimmed: root.idle
      tooltipText: "NoType · " + root.statusLabel
      onPressed: function(b) {
        if (b === Qt.MiddleButton) root.run(["record", "toggle"])
        else if (b === Qt.RightButton) root.run(["cancel"])
        else root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    padding: Style.space(18)
    contentWidth: panel.fittedContentWidth(Style.space(316))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: languageMenu.popupOpen || rewriteMenu.popupOpen
      onCloseRequested: root.close()

      Column {
        id: column
        width: parent.width
        spacing: 0

        // Header
        Item {
          width: parent.width
          height: Math.max(title.implicitHeight, gear.height)

          Text {
            id: title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "NoType"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.space(18)
            font.weight: Font.DemiBold
          }

          Row {
            anchors.right: gear.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Rectangle {
              width: Style.space(7)
              height: width
              radius: width / 2
              color: root.statusColor
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: root.statusLabel
              color: Util.alpha(Color.popups.text, 0.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelActionButton {
            id: gear
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: tones.glyphCog
            tooltipText: "设置"
            foreground: Util.alpha(Color.popups.text, 0.6)
            hoverColor: Color.popups.text
            fontSize: Style.space(16)
            onClicked: root.openPage("settings")
          }
        }

        Item { width: 1; height: Style.space(16) }

        // Status notice
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !root.online || !root.envReady
          bottomPadding: Style.space(12)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.online ? root.statusLine : root.tr("NoType 后台服务未运行。", "The NoType service is not running.")
            wrapMode: Text.Wrap
            color: Util.alpha(Color.popups.text, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Button {
            text: root.online ? "完成环境设置" : "启动 NoType"
            bordered: true
            foreground: Color.popups.text
            fontSize: Style.font.caption
            onClicked: {
              if (root.online) root.openPage("setup")
              else if (root.service) root.service.startDaemon()
            }
          }
        }

        Item {
          width: parent.width
          height: visible ? Math.max(credentialLabel.implicitHeight, openSettings.implicitHeight) + Style.space(12) : 0
          visible: root.online && root.envReady && !root.speechReady

          Text {
            id: credentialLabel
            anchors.left: parent.left
            y: (openSettings.implicitHeight - implicitHeight) / 2
            textFormat: Text.PlainText
            text: tones.glyphAlert + "  " + (root.savedProvider === "codex" ? "需要登录 Codex" : "需要配置豆包语音")
            color: tones.warn
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Button {
            id: openSettings
            anchors.right: parent.right
            text: "打开设置"
            bordered: true
            foreground: Color.popups.text
            fontSize: Style.font.caption
            onClicked: root.openPage("settings")
          }
        }

        Text {
          width: parent.width
          visible: root.online && root.envReady && root.speechReady && root.phase !== "idle"
          bottomPadding: Style.space(12)
          textFormat: Text.PlainText
          text: root.statusLine
          wrapMode: Text.Wrap
          color: root.failed ? tones.error : Util.alpha(Color.popups.text, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          visible: root.actionMessage !== ""
          bottomPadding: Style.space(12)
          textFormat: Text.PlainText
          text: root.actionMessage
          wrapMode: Text.Wrap
          color: root.actionFailed ? tones.error : tones.warn
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          visible: root.hotkeyWarning !== ""
          bottomPadding: Style.space(12)
          textFormat: Text.PlainText
          text: root.hotkeyWarning
          wrapMode: Text.Wrap
          color: tones.warn
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        // Shortcuts
        Column {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: [
              { title: "语音输入", icon: tones.glyphMic, shortcut: root.dictationKey, detail: "" },
              { title: "语音译成英文", icon: tones.glyphTranslate, shortcut: root.translationKey, detail: "" },
              { title: "选词译成中文", icon: tones.glyphSelection, shortcut: root.selectionKey, detail: "浮窗查看，保留原文" }
            ]

            Item {
              id: shortcutRow
              required property var modelData

              width: parent.width
              height: Math.max(Style.space(24), rowText.implicitHeight) + Style.space(12)

              Text {
                id: rowIcon
                width: Style.space(24)
                height: Style.space(24)
                y: Style.space(6)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                textFormat: Text.PlainText
                text: shortcutRow.modelData.icon
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.space(18)
              }

              Column {
                id: rowText
                anchors.left: rowIcon.right
                anchors.leftMargin: Style.space(12)
                anchors.right: parent.right
                y: Style.space(6)
                spacing: Style.space(4)

                Item {
                  width: parent.width
                  height: Math.max(rowTitle.implicitHeight, caps.height)

                  Text {
                    id: rowTitle
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: shortcutRow.modelData.title
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.subtitle
                    font.weight: Font.Medium
                  }

                  Row {
                    id: caps
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(4)

                    Repeater {
                      model: root.keycaps(shortcutRow.modelData.shortcut)

                      Rectangle {
                        id: cap
                        required property string modelData
                        width: Math.max(Style.space(23), capText.implicitWidth + Style.space(12))
                        height: Style.space(23)
                        radius: Style.space(5)
                        color: Util.alpha(Color.popups.text, 0.05)
                        border.width: 1
                        border.color: Util.alpha(Color.popups.text, 0.12)

                        Text {
                          id: capText
                          anchors.centerIn: parent
                          textFormat: Text.PlainText
                          text: cap.modelData
                          color: Color.popups.text
                          font.family: Style.font.family
                          font.pixelSize: Style.font.bodySmall
                          font.weight: Font.Medium
                        }
                      }
                    }
                  }
                }

                Text {
                  visible: shortcutRow.modelData.detail !== ""
                  textFormat: Text.PlainText
                  text: shortcutRow.modelData.detail
                  color: Util.alpha(Color.popups.text, 0.6)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }
        }

        Item { width: 1; height: Style.space(12) }
        PanelSeparator { foreground: Color.popups.text }
        Item { width: 1; height: Style.space(12) }

        // Language and AI Rewrite
        Item {
          width: parent.width
          height: Math.max(languageMenu.implicitHeight, rewriteMenu.implicitHeight, codexLink.implicitHeight)

          MenuLink {
            id: languageMenu
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: tones.languageName(root.language)
            items: tones.languages.map(function(entry) {
              return { label: entry.label, icon: entry.value === root.language ? tones.glyphCheck : "" }
            })
            onTriggered: function(index) {
              var code = tones.languages[index].value
              if (code !== root.language) root.saveSetting({ language: code })
            }
          }

          TextLink {
            id: codexLink
            visible: root.savedProvider === "codex"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Codex · 直接输入"
            foreground: Util.alpha(Color.popups.text, 0.6)
            onClicked: root.openPage("settings")
          }

          MenuLink {
            id: rewriteMenu
            visible: root.savedProvider !== "codex"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.aiRewrite ? "AI 改写：开" : "AI 改写：关"
            foreground: Util.alpha(Color.popups.text, 0.6)
            items: [
              { label: root.aiRewrite ? "关闭 AI 改写" : "开启 AI 改写", icon: root.aiRewrite ? tones.glyphCheckCircle : tones.glyphCircle },
              { label: "设置…", icon: "" }
            ]
            onTriggered: function(index) {
              if (index === 0) root.saveSetting({ ai_rewrite: !root.aiRewrite })
              else root.openPage("settings")
            }
          }
        }

        Item { width: 1; height: Style.space(12) }
        PanelSeparator { foreground: Color.popups.text }
        Item { width: 1; height: Style.space(10) }

        // Footer
        Item {
          width: parent.width
          height: Math.max(versionText.implicitHeight, powerLink.implicitHeight)

          Text {
            id: versionText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.version !== "" ? "v" + root.version : ""
            color: Util.alpha(Color.popups.text, 0.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          TextLink {
            id: powerLink
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.online ? tones.glyphPower : tones.glyphPlay
            text: root.online ? "退出" : "启动"
            foreground: Util.alpha(Color.popups.text, 0.6)
            onClicked: {
              if (!root.service) return
              if (root.online) {
                root.close()
                root.service.stopDaemon()
              } else {
                root.service.startDaemon()
              }
            }
          }
        }
      }
    }
  }
}
