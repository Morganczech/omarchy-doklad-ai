import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons

// A document with a folded corner. The badge in the lower right corner tells
// the state at a glance: urgent = something is overdue, accent = waiting for
// payment, none = all settled.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Commons.Color.foreground
  property color badgeColor: Commons.Color.urgent
  property bool badge: false
  property bool dimmed: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize
  opacity: dimmed ? 0.55 : 1.0

  readonly property real strokePx: Math.max(1.3, width * 0.085)
  readonly property real x0: width * 0.2
  readonly property real x1: width * 0.8
  readonly property real y0: height * 0.1
  readonly property real y1: height * 0.9
  readonly property real fold: width * 0.24
  readonly property real corner: width * 0.08
  readonly property real lineInset: width * 0.15

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer

    // Sheet outline
    ShapePath {
      strokeWidth: root.strokePx
      strokeColor: root.color
      fillColor: "transparent"
      joinStyle: ShapePath.RoundJoin
      capStyle: ShapePath.RoundCap

      startX: root.x0 + root.corner
      startY: root.y0
      PathLine { x: root.x1 - root.fold; y: root.y0 }
      PathLine { x: root.x1; y: root.y0 + root.fold }
      PathLine { x: root.x1; y: root.y1 - root.corner }
      PathQuad { x: root.x1 - root.corner; y: root.y1; controlX: root.x1; controlY: root.y1 }
      PathLine { x: root.x0 + root.corner; y: root.y1 }
      PathQuad { x: root.x0; y: root.y1 - root.corner; controlX: root.x0; controlY: root.y1 }
      PathLine { x: root.x0; y: root.y0 + root.corner }
      PathQuad { x: root.x0 + root.corner; y: root.y0; controlX: root.x0; controlY: root.y0 }
    }

    // Folded corner
    ShapePath {
      strokeWidth: root.strokePx * 0.85
      strokeColor: root.color
      fillColor: "transparent"
      joinStyle: ShapePath.RoundJoin
      capStyle: ShapePath.RoundCap

      startX: root.x1 - root.fold
      startY: root.y0
      PathLine { x: root.x1 - root.fold; y: root.y0 + root.fold }
      PathLine { x: root.x1; y: root.y0 + root.fold }
    }

    // Two text lines; the lower one is shorter to leave room for the badge.
    ShapePath {
      strokeWidth: root.strokePx * 0.85
      strokeColor: root.color
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap

      startX: root.x0 + root.lineInset
      startY: root.height * 0.53
      PathLine { x: root.x1 - root.lineInset; y: root.height * 0.53 }
      PathMove { x: root.x0 + root.lineInset; y: root.height * 0.71 }
      PathLine { x: root.width * (root.badge ? 0.47 : 0.56); y: root.height * 0.71 }
    }
  }

  Rectangle {
    visible: root.badge
    width: Math.max(5, Math.round(root.width * 0.34))
    height: width
    radius: width / 2
    color: root.badgeColor
    x: root.width - width * 0.92
    y: root.height - height * 0.92
  }
}
