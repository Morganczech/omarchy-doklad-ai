import QtQuick
import qs.Commons

// Plain-text label in the panel's font. Every label in the plugin goes through
// this (or sets Text.PlainText itself), so names and notes coming from the API
// can never be interpreted as rich text.
Text {
  required property var ctx
  property bool dim: false

  textFormat: Text.PlainText
  color: dim ? ctx.dim : ctx.foreground
  font.family: ctx.fontFamily
  font.pixelSize: Style.font.bodySmall
}
