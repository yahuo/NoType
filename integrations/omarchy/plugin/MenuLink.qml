import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Plain text with a chevron that opens a small menu, like the borderless
// `Menu` buttons in the macOS popover. Items are {label, icon}; an empty icon
// keeps the column aligned.
Item {
  id: root

  property string text: ""
  property var items: []
  property color foreground: Color.popups.text
  property real fontSize: Style.font.bodySmall
  property string chevron: String.fromCodePoint(0xF0140)

  readonly property bool popupOpen: menu.opened

  signal triggered(int index)

  implicitWidth: label.implicitWidth
  implicitHeight: label.implicitHeight + Style.spacing.xs * 2

  Text {
    id: label
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.text + " " + root.chevron
    color: mouse.containsMouse ? Color.accent : root.foreground
    font.family: Style.font.family
    font.pixelSize: root.fontSize
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: menu.opened ? menu.close() : menu.open()
  }

  Popup {
    id: menu
    y: root.height + Style.spacing.xxs
    padding: Style.spacing.xs
    focus: true

    background: BorderSurface {
      color: Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Style.normalBorderWidth)
      radius: Style.cornerRadius
    }

    contentItem: Column {
      Repeater {
        model: root.items

        Rectangle {
          id: entry
          required property var modelData
          required property int index

          width: Math.max(Style.space(150), entryRow.implicitWidth + Style.spacing.lg * 2)
          height: Style.spacing.popupRowHeight
          radius: Style.cornerRadius
          color: entryMouse.containsMouse ? Util.alpha(Color.popups.text, 0.1) : "transparent"

          Row {
            id: entryRow
            anchors.verticalCenter: parent.verticalCenter
            x: Style.spacing.lg
            spacing: Style.spacing.md

            Text {
              width: Style.font.icon
              textFormat: Text.PlainText
              text: String(entry.modelData.icon || "")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: String(entry.modelData.label || "")
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            id: entryMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              menu.close()
              root.triggered(entry.index)
            }
          }
        }
      }
    }
  }
}
