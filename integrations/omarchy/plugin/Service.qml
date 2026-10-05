import QtQuick
import Quickshell
import Quickshell.Io

// Owns the single `notype status --follow` process. The overlay and the bar
// widget only read the properties below and call the command helpers.
Item {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  property bool online: false

  property string phase: "idle"
  property string mode: "dictation"
  property string provider: "codex"
  property string transcript: ""
  property real level: 0
  property string error: ""
  property string warning: ""

  property string selectionState: "hidden"
  property string selectionSource: ""
  property string selectionTranslation: ""
  property string selectionError: ""

  readonly property bool recording: phase === "recording"
  readonly property bool busy: phase === "transcribing" || phase === "refining"
  readonly property bool hudVisible: online && phase !== "idle"
  readonly property bool selectionVisible: online && selectionState !== "hidden"

  property bool _stopping: false

  // `sh` always starts, so a missing binary exits 127 instead of failing to
  // spawn. Arguments are positional parameters and never re-parsed.
  function argv(args) {
    return ["sh", "-c", "exec notype \"$@\"", "notype"].concat(args || [])
  }

  function run(args) {
    Quickshell.execDetached(root.argv(args))
  }

  function toggleRecording() { root.run(["record", "toggle"]) }
  function cancel() { root.run(["cancel"]) }
  function hideSelection() { root.run(["selection-hide"]) }
  // The daemon copies its finished translation through its serialized clipboard writer.
  function copySelection() { root.run(["selection-copy"]) }

  function str(value, fallback) {
    return value === undefined || value === null ? fallback : String(value)
  }

  function resetState() {
    root.phase = "idle"
    root.transcript = ""
    root.level = 0
    root.error = ""
    root.warning = ""
    root.selectionState = "hidden"
    root.selectionSource = ""
    root.selectionTranslation = ""
    root.selectionError = ""
  }

  function applyStatus(data) {
    root.phase = root.str(data.phase, "idle")
    root.mode = root.str(data.mode, "dictation")
    root.provider = root.str(data.provider, "")
    root.transcript = root.str(data.transcript, "")
    var n = Number(data.level)
    root.level = isFinite(n) ? Math.max(0, Math.min(1, n)) : 0
    root.error = root.str(data.error, "")
    root.warning = root.str(data.warning, "")
  }

  function applySelection(data) {
    root.selectionState = root.str(data.state, "hidden")
    root.selectionSource = root.str(data.source, "")
    root.selectionTranslation = root.str(data.translation, "")
    root.selectionError = root.str(data.error, "")
  }

  function handleLine(raw) {
    var line = String(raw || "").trim()
    if (line === "") return
    var data = null
    try {
      data = JSON.parse(line)
    } catch (e) {
      return
    }
    if (!data || typeof data !== "object") return
    if (data.type === "status") root.applyStatus(data)
    else if (data.type === "selection") root.applySelection(data)
    else return
    root.online = true
  }

  Process {
    id: follower
    command: root.argv(["status", "--follow"])
    running: true
    stdout: SplitParser {
      onRead: function(data) { root.handleLine(data) }
    }
    onRunningChanged: {
      if (follower.running || root._stopping) return
      root.online = false
      root.resetState()
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 2000
    repeat: false
    onTriggered: {
      if (!root._stopping && !follower.running) follower.running = true
    }
  }

  Component.onDestruction: {
    root._stopping = true
    restartTimer.stop()
  }
}
