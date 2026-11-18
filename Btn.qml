import QtQuick
import qs.Commons
import qs.Ui

// Kit button in the panel's colors. `stop` and `stopCol` tie it to the
// keyboard cursor so hover and keyboard highlight stay in sync.
Button {
  id: root

  required property var ctx
  property string stop: ""
  property int stopRow: 0
  property int stopCol: 0

  foreground: ctx.foreground
  accent: ctx.accent
  fontFamily: ctx.fontFamily
  fontSize: Style.font.bodySmall
  bordered: true
  focusable: false
  opacity: enabled ? 1.0 : 0.45
  hasCursor: stop !== "" && ctx.cursorOn(stop, stopRow, stopCol)
  onHovered: function(on) { if (on && root.stop !== "") root.ctx.pointTo(root.stop, root.stopRow, root.stopCol) }
}
