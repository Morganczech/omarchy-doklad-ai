import QtQuick
import qs.Commons
import qs.Ui

// Segmented choice wired to the keyboard cursor. A Flow, so long translated
// labels wrap onto a second line instead of running out of the panel.
Flow {
  id: root

  required property var ctx
  property var options: []
  property string value: ""
  property string stop: ""
  // Position of the first chip inside the stop, for groups that share one with other controls.
  property int stopRow: 0
  property int stopColOffset: 0
  property real fontSize: Style.font.caption

  signal changed(string value)

  spacing: Style.space(6)

  Repeater {
    model: root.options

    Button {
      required property var modelData
      required property int index

      text: String(modelData.label)
      iconText: modelData.icon ? String(modelData.icon) : ""
      tooltipText: modelData.tooltip ? String(modelData.tooltip) : ""
      selected: String(modelData.value) === root.value
      hasCursor: root.stop !== "" && root.ctx.cursorOn(root.stop, root.stopRow, root.stopColOffset + index)
      bordered: true
      focusable: false
      foreground: root.ctx.foreground
      accent: root.ctx.accent
      fontFamily: root.ctx.fontFamily
      fontSize: root.fontSize
      opacity: root.enabled ? 1.0 : 0.45
      onClicked: root.changed(String(modelData.value))
      onHovered: function(on) { if (on && root.stop !== "") root.ctx.pointTo(root.stop, root.stopRow, root.stopColOffset + index) }
    }
  }
}
