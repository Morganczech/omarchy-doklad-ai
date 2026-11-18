import QtQuick
import qs.Commons
import qs.Ui

// One figure of the overview: caption, big value, a quieter second line.
BorderSurface {
  id: root

  required property var ctx
  property string label: ""
  property string value: ""
  property string detail: ""
  property string trend: ""
  property bool trendPositive: true
  property color tint: ctx.foreground
  property bool emphasized: false
  property bool clickable: false
  property bool hasCursor: false

  signal clicked()

  implicitHeight: column.implicitHeight + Style.space(20)
  radius: Style.cornerRadius
  color: hover.hovered && clickable || hasCursor
    ? ctx.hoverFill
    : Qt.rgba(tint.r, tint.g, tint.b, emphasized ? 0.10 : 0.045)
  borderSpec: Border.flat(Qt.rgba(tint.r, tint.g, tint.b, emphasized ? 0.38 : 0.12), 1)

  HoverHandler {
    id: hover
    cursorShape: root.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
  }

  TapHandler {
    enabled: root.clickable
    onTapped: root.clicked()
  }

  Column {
    id: column
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: root.label
      color: root.ctx.dim
      font.family: root.ctx.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: root.value
      color: root.emphasized ? root.tint : root.ctx.foreground
      font.family: root.ctx.fontFamily
      font.pixelSize: Style.font.heading
      font.bold: true
      elide: Text.ElideRight
    }

    Row {
      width: parent.width
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        visible: root.trend !== ""
        text: root.trend
        color: root.trendPositive ? root.ctx.positive : root.ctx.urgent
        font.family: root.ctx.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width - (root.trend !== "" ? x : 0)
        text: root.detail
        color: root.ctx.dim
        font.family: root.ctx.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}
