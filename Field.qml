import QtQuick
import qs.Commons
import qs.Ui

// Labelled single-line input used by the forms. Escape hands the keyboard back
// to the panel, Enter reports `accepted`.
Column {
  id: root

  required property var ctx
  property string label: ""
  property alias text: input.text
  property alias placeholderText: input.placeholderText
  property alias input: input
  property bool hasCursor: false
  property bool invalid: false
  property int maximumLength: 200

  signal edited(string text)
  signal accepted()

  function edit() {
    input.forceActiveFocus()
    input.selectAll()
  }

  spacing: Style.space(3)

  Text {
    textFormat: Text.PlainText
    visible: root.label !== ""
    width: parent.width
    text: root.label
    color: root.invalid ? root.ctx.urgent : root.ctx.dim
    font.family: root.ctx.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }

  TextField {
    id: input
    width: parent.width
    foreground: root.ctx.foreground
    accent: root.invalid ? root.ctx.urgent : root.ctx.accent
    font.family: root.ctx.fontFamily
    font.pixelSize: Style.font.bodySmall
    maximumLength: root.maximumLength
    hasCursor: root.hasCursor
    selectByMouse: true
    onTextEdited: root.edited(text)
    onAccepted: root.accepted()
    // The panel stops treating h/j/k/l and digits as shortcuts while a field has the keyboard.
    onActiveFocusChanged: root.ctx.editorFocus(input, activeFocus)
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        root.ctx.leaveEditor()
        event.accepted = true
      }
    }
  }
}
