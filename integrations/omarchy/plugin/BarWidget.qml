import QtQuick
import Quickshell
import qs.Ui

// Bar indicator. Dim when idle (or hidden with `hideWhenIdle`), urgent and
// pulsing while recording, spinning while transcribing or refining.
// Left click toggles recording, right click cancels.
BarWidget {
  id: root

  property var service: null

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

  readonly property string glyphMic: String.fromCodePoint(0xF036C)
  readonly property string glyphMicOff: String.fromCodePoint(0xF036D)
  readonly property string glyphLoading: String.fromCodePoint(0xF0772)
  readonly property string glyphCheck: String.fromCodePoint(0xF012C)
  readonly property string glyphAlert: String.fromCodePoint(0xF0026)

  readonly property string phaseLabel: {
    if (!root.online) return "Daemon offline"
    switch (root.phase) {
    case "idle": return "Idle"
    case "recording": return "Listening"
    case "transcribing": return "Transcribing"
    case "refining": return root.mode === "translation" ? "Translating" : "Refining"
    case "inserted": return "Inserted"
    case "copied_to_clipboard": return "Copied to clipboard"
    case "failed": return "Failed"
    default: return root.phase
    }
  }

  function capitalize(value) {
    var s = String(value || "")
    return s === "" ? "" : s.charAt(0).toUpperCase() + s.slice(1)
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

  visible: !(root.hideWhenIdle && root.idle)
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onRecordingChanged: if (!root.recording) pulseLayer.opacity = 1
  onBusyChanged: if (!root.busy) button.textRotation = 0

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
      text: !root.online ? root.glyphMicOff
        : (root.busy ? root.glyphLoading
        : (root.failed ? root.glyphAlert
        : (root.done ? root.glyphCheck : root.glyphMic)))
      active: root.recording || root.failed
      dimmed: root.idle
      tooltipText: root.online
        ? "NoType: " + root.phaseLabel + "\n"
          + (root.provider !== "" ? root.capitalize(root.provider) + " · " : "") + root.capitalize(root.mode)
          + "\nLeft click: record · Right click: cancel"
        : "NoType: daemon offline"
      onPressed: function(b) {
        if (b === Qt.LeftButton) root.run(["record", "toggle"])
        else if (b === Qt.RightButton) root.run(["cancel"])
      }
    }
  }
}
