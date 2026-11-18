import QtQuick
import QtQuick.Shapes
import qs.Commons
import "Model.js" as Model

// Income and expenses per month (or quarter): stacked bars for paid and unpaid
// invoices, a line for expenses. Hovering a column shows its figures, clicking
// it jumps to that period.
Item {
  id: root

  required property var ctx
  property var chart: []
  property string selectedKind: "month"
  property int selectedYear: 0
  property int selectedIndex: 0
  // True when the whole chart is the selected period (year and 12-month views).
  property bool selectAll: false

  signal bucketClicked(var entry)

  readonly property real peak: Model.chartMax(chart)
  readonly property int hoverIndex: hoverArea.containsMouse && chart.length > 0
    ? Math.max(0, Math.min(chart.length - 1, Math.floor(hoverArea.mouseX / (plot.width / chart.length))))
    : -1
  readonly property real slot: chart.length > 0 ? plot.width / chart.length : 0
  readonly property color paidColor: ctx.accent
  readonly property color unpaidColor: Qt.rgba(ctx.accent.r, ctx.accent.g, ctx.accent.b, 0.38)
  readonly property color expenseColor: ctx.warning
  readonly property color gridColor: Qt.rgba(ctx.foreground.r, ctx.foreground.g, ctx.foreground.b, 0.10)

  function isSelected(entry) {
    return !selectAll && entry.kind === selectedKind && entry.year === selectedYear && entry.index === selectedIndex
  }

  function barHeight(value) {
    return peak > 0 ? Math.round(plot.height * Math.max(0, value) / peak) : 0
  }

  function summary(entry) {
    var parts = [ctx.bucketTitle(entry)]
    parts.push(ctx.strings.t("chart.paid") + " " + ctx.money(entry.paid, "", "round"))
    if (entry.unpaid > 0) parts.push(ctx.strings.t("chart.unpaid") + " " + ctx.money(entry.unpaid, "", "round"))
    if (entry.expenses > 0) parts.push(ctx.strings.t("chart.expenses") + " " + ctx.money(entry.expenses, "", "round"))
    return parts.join("  \u00b7  ")
  }

  implicitHeight: Style.space(168)

  // Scale caption and legend
  Item {
    id: header
    width: parent.width
    height: Style.space(16)

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: root.ctx.privacy ? "" : root.ctx.strings.t("chart.scale").arg(root.ctx.money(root.peak, "", "round"))
      color: root.ctx.dim
      font.family: root.ctx.fontFamily
      font.pixelSize: Style.font.caption
    }

    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(12)

      Repeater {
        model: [
          { color: root.paidColor, label: root.ctx.strings.t("chart.paid"), line: false },
          { color: root.unpaidColor, label: root.ctx.strings.t("chart.unpaid"), line: false },
          { color: root.expenseColor, label: root.ctx.strings.t("chart.expenses"), line: true }
        ]

        Row {
          required property var modelData
          spacing: Style.space(4)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(9)
            height: modelData.line ? Math.max(2, Style.space(2)) : Style.space(9)
            radius: modelData.line ? height / 2 : Math.min(2, Style.cornerRadius)
            color: modelData.color
          }

          Text {
            textFormat: Text.PlainText
            text: modelData.label
            color: root.ctx.dim
            font.family: root.ctx.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  Item {
    id: plot
    anchors.top: header.bottom
    anchors.topMargin: Style.space(6)
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: labels.top
    anchors.bottomMargin: Style.space(4)

    // Grid: baseline, half, top
    Repeater {
      model: 3
      Rectangle {
        required property int index
        width: plot.width
        height: 1
        y: Math.round((plot.height - 1) * index / 2)
        color: root.gridColor
      }
    }

    Repeater {
      model: root.chart

      Item {
        id: column
        required property var modelData
        required property int index

        readonly property bool selected: root.isSelected(modelData)
        readonly property real paidHeight: root.barHeight(modelData.paid)
        readonly property real unpaidHeight: root.barHeight(modelData.unpaid)

        x: index * root.slot
        width: root.slot
        height: plot.height
        opacity: modelData.future ? 0.35 : 1.0

        Rectangle {
          anchors.fill: parent
          anchors.leftMargin: 1
          anchors.rightMargin: 1
          radius: Style.cornerRadius
          visible: column.selected || root.hoverIndex === column.index
          color: column.selected ? root.ctx.selectedFill : root.ctx.hoverFill
        }

        Rectangle {
          id: paidBar
          width: Math.max(3, Math.round(column.width * 0.52))
          x: Math.round((column.width - width) / 2)
          y: plot.height - height
          height: column.paidHeight
          radius: Math.min(Style.cornerRadius, 3)
          color: root.paidColor
          Behavior on height {
            NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic }
          }
        }

        Rectangle {
          width: paidBar.width
          x: paidBar.x
          y: plot.height - paidBar.height - height
          height: column.unpaidHeight
          radius: Math.min(Style.cornerRadius, 3)
          color: root.unpaidColor
          Behavior on height {
            NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic }
          }
        }
      }
    }

    // Expenses line
    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer
      visible: root.chart.length > 1

      ShapePath {
        strokeWidth: Math.max(1.5, Style.space(2))
        strokeColor: root.expenseColor
        fillColor: "transparent"
        joinStyle: ShapePath.RoundJoin
        capStyle: ShapePath.RoundCap

        PathPolyline {
          path: {
            var points = []
            for (var i = 0; i < root.chart.length; i++) {
              if (root.chart[i].future) break
              points.push(Qt.point((i + 0.5) * root.slot, plot.height - root.barHeight(root.chart[i].expenses)))
            }
            return points.length > 1 ? points : [Qt.point(0, plot.height), Qt.point(0, plot.height)]
          }
        }
      }
    }

    MouseArea {
      id: hoverArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (root.hoverIndex < 0) return
        var entry = root.chart[root.hoverIndex]
        if (entry && !entry.future) root.bucketClicked(entry)
      }
    }
  }

  Item {
    id: labels
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: caption.top
    anchors.bottomMargin: Style.space(4)
    height: Style.space(14)

    Repeater {
      model: root.chart

      Text {
        required property var modelData
        required property int index
        textFormat: Text.PlainText
        x: index * root.slot
        width: root.slot
        horizontalAlignment: Text.AlignHCenter
        text: root.ctx.bucketLabel(modelData)
        color: root.isSelected(modelData) ? root.ctx.foreground : root.ctx.dim
        font.family: root.ctx.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: root.isSelected(modelData)
        clip: true
      }
    }
  }

  Text {
    id: caption
    textFormat: Text.PlainText
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Style.space(16)
    verticalAlignment: Text.AlignVCenter
    text: root.hoverIndex >= 0 ? root.summary(root.chart[root.hoverIndex]) : root.ctx.strings.t("chart.hint")
    color: root.hoverIndex >= 0 ? root.ctx.foreground : root.ctx.dim
    font.family: root.ctx.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }
}
