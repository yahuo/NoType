import QtQuick
import qs.Commons

// Status colors of the macOS app. Omarchy themes have no green or orange, so
// the pair is picked by how dark the surface is.
QtObject {
  property color surface: Color.popups.background

  readonly property bool dark: surface.hslLightness < 0.5
  readonly property color ok: dark ? Qt.rgba(0.55, 0.86, 0.65, 1) : Qt.rgba(0.21, 0.47, 0.31, 1)
  readonly property color warn: dark ? "#ff9f0a" : "#c56a00"
  readonly property color error: Color.urgent

  readonly property string glyphMic: String.fromCodePoint(0xF036C)
  readonly property string glyphMicOff: String.fromCodePoint(0xF036D)
  readonly property string glyphTranslate: String.fromCodePoint(0xF05CA)
  readonly property string glyphSelection: String.fromCodePoint(0xF036A)
  readonly property string glyphCog: String.fromCodePoint(0xF0493)
  readonly property string glyphPower: String.fromCodePoint(0xF0425)
  readonly property string glyphPlay: String.fromCodePoint(0xF040A)
  readonly property string glyphAlert: String.fromCodePoint(0xF0026)
  readonly property string glyphCheck: String.fromCodePoint(0xF012C)
  readonly property string glyphCheckCircle: String.fromCodePoint(0xF05E0)
  readonly property string glyphCloseCircle: String.fromCodePoint(0xF0159)
  readonly property string glyphCircle: String.fromCodePoint(0xF0130)
  readonly property string glyphChevron: String.fromCodePoint(0xF0140)
  readonly property string glyphKey: String.fromCodePoint(0xF0306)
  readonly property string glyphKeyboard: String.fromCodePoint(0xF030C)
  readonly property string glyphChip: String.fromCodePoint(0xF061A)
  readonly property string glyphConsole: String.fromCodePoint(0xF018D)
  readonly property string glyphLink: String.fromCodePoint(0xF0337)
  readonly property string glyphWand: String.fromCodePoint(0xF0068)
  readonly property string glyphLoading: String.fromCodePoint(0xF0772)
  readonly property string glyphRefresh: String.fromCodePoint(0xF0450)

  readonly property var languages: [
    { value: "zh-CN", label: "简体中文" },
    { value: "en-US", label: "English" },
    { value: "zh-TW", label: "繁體中文" },
    { value: "ja-JP", label: "日本語" },
    { value: "ko-KR", label: "한국어" }
  ]

  function languageName(code) {
    for (var i = 0; i < languages.length; i++)
      if (languages[i].value === code) return languages[i].label
    return String(code || "")
  }
}
