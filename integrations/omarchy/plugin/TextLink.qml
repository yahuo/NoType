import QtQuick
import qs.Commons

// Borderless text button (`.buttonStyle(.plain)` in the macOS popover).
Item {
  id: root

  property string text: ""
  property string iconText: ""
  property color foreground: Color.popups.text
  property real fontSize: Style.font.bodySmall

  signal clicked()

  implicitWidth: row.implicitWidth
  implicitHeight: row.implicitHeight + Style.spacing.xs * 2

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.spacing.sm

    Text {
      visible: root.iconText !== ""
      textFormat: Text.PlainText
      text: root.iconText
      color: label.color
      font.family: Style.font.family
      font.pixelSize: root.fontSize
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: label
      textFormat: Text.PlainText
      text: root.text
      color: mouse.containsMouse && root.enabled ? Color.accent : root.foreground
      font.family: Style.font.family
      font.pixelSize: root.fontSize
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    enabled: root.enabled
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
