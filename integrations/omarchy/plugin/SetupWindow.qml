import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

// The macOS onboarding window. Linux has no permissions to grant, so it lists
// the environment checks that `notype doctor` runs.
FloatingWindow {
  id: root

  property var service: null

  readonly property var snapshot: service && service.snapshot ? service.snapshot : null
  readonly property bool online: !!service && service.online === true
  readonly property var checks: snapshot && snapshot.checks instanceof Array ? snapshot.checks : []
  readonly property bool ready: !!snapshot && snapshot.ready === true
  readonly property bool loading: !!service && service.snapshotLoading === true

  readonly property real fittedHeight: Style.space(28) + header.implicitHeight + Style.space(20)
    + list.implicitHeight + footer.height

  title: "NoType Setup"
  color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
  implicitWidth: Style.space(520)
  implicitHeight: Math.round(Math.min(root.fittedHeight, root.screen ? root.screen.height * 0.85 : Style.space(720)))
  minimumSize: Qt.size(Style.space(440), Style.space(240))
  onImplicitHeightChanged: fit.restart()

  Tones { id: tones; surface: Color.background }
  WindowFit { id: fit; window: root }

  FocusScope {
    anchors.fill: parent
    focus: true

    Keys.onEscapePressed: root.visible = false

    Column {
      id: header
      x: Style.space(28)
      y: Style.space(28)
      width: parent.width - Style.space(56)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: "Set up NoType"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.space(24)
        font.weight: Font.Bold
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.ready
          ? "环境已就绪。按快捷键开始语音输入。"
          : "NoType 需要以下环境才能录音、转写并把文字输入到当前窗口。修复后点击 Refresh Status。"
        wrapMode: Text.Wrap
        color: Util.alpha(Color.foreground, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
      }
    }

    Flickable {
      id: flick
      anchors.top: header.bottom
      anchors.topMargin: Style.space(20)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: footer.top
      contentWidth: width
      contentHeight: list.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: list
        x: Style.space(28)
        width: flick.width - Style.space(56)
        spacing: Style.space(14)

        Text {
          visible: !root.snapshot
          textFormat: Text.PlainText
          text: "正在检查…"
          color: Util.alpha(Color.foreground, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
        }

        Repeater {
          model: root.checks

          Item {
            id: checkRow
            required property var modelData

            readonly property bool ok: modelData.ok === true
            readonly property bool required: modelData.required === true

            width: parent.width
            height: Math.max(checkIcon.implicitHeight, checkText.implicitHeight)

            Text {
              id: checkIcon
              width: Style.space(24)
              textFormat: Text.PlainText
              text: checkRow.ok ? tones.glyphCheckCircle : (checkRow.required ? tones.glyphCloseCircle : tones.glyphAlert)
              color: checkRow.ok ? tones.ok : (checkRow.required ? tones.error : tones.warn)
              font.family: Style.font.family
              font.pixelSize: Style.space(18)
            }

            Column {
              id: checkText
              anchors.left: checkIcon.right
              anchors.leftMargin: Style.space(10)
              anchors.right: parent.right
              spacing: Style.space(2)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: String(checkRow.modelData.label || "") + (checkRow.required ? "" : "（可选）")
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.weight: Font.Medium
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                visible: text !== ""
                textFormat: Text.PlainText
                text: String(checkRow.modelData.detail || "")
                wrapMode: Text.Wrap
                color: Util.alpha(Color.foreground, 0.6)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }
      }
    }

    Item {
      id: footer
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Math.max(refreshButton.implicitHeight, closeButton.implicitHeight) + Style.space(32)

      Row {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(28)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(10)

        Button {
          id: refreshButton
          bordered: true
          foreground: Color.foreground
          iconText: tones.glyphRefresh
          iconSpinning: root.loading
          enabled: !!root.service
          text: "Refresh Status"
          onClicked: root.service.refreshSnapshot()
        }

        Button {
          visible: !root.online
          bordered: true
          foreground: Color.foreground
          iconText: tones.glyphPlay
          enabled: !!root.service
          text: "Start NoType"
          onClicked: root.service.startDaemon()
        }
      }

      Button {
        id: closeButton
        anchors.right: parent.right
        anchors.rightMargin: Style.space(28)
        anchors.verticalCenter: parent.verticalCenter
        bordered: true
        selected: root.ready
        foreground: Color.foreground
        text: root.ready ? "Done" : "Close"
        onClicked: root.visible = false
      }
    }
  }
}
