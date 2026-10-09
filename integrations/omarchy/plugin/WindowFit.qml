import QtQuick
import Quickshell

// Hyprland keeps the size a window was mapped with, so a window whose content
// height changes (tab, provider, snapshot) asks the compositor to follow it.
// Restart it from the window's onImplicitHeightChanged.
Timer {
  id: root

  property var window: null

  interval: 30

  onTriggered: {
    var w = root.window
    if (!w || !w.visible || Math.abs(w.height - w.implicitHeight) < 1) return
    Quickshell.execDetached(["hyprctl", "dispatch",
      "hl.dsp.window.resize({ x = " + Math.round(w.width) + ", y = " + Math.round(w.implicitHeight)
        + ", window = \"title:^" + w.title + "$\" })"])
  }
}
