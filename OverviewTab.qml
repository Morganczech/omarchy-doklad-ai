import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Period switcher, headline figures, the income/expense chart, VAT and the
// yearly turnover gauge.
Column {
  id: root

  required property var ctx
  readonly property var snap: ctx.snapshot
  readonly property var period: snap.period
  readonly property var strings: ctx.strings

  readonly property var stops: [
    { key: "horizon", cols: 4 },
    { key: "nav", cols: ctx.service.offset < 0 ? 3 : 1 },
    { key: "tiles", cols: 4 }
  ]

  function activate(key, row, col) {
    if (key === "horizon") ctx.service.setPeriod(Model.HORIZONS[col], 0)
    else if (key === "nav") {
      if (col === 0) ctx.stepPeriod(-1)
      else if (col === 1) ctx.stepPeriod(1)
      else ctx.service.setPeriod(ctx.service.horizon, 0)
    } else if (key === "tiles") {
      if (col === 2) ctx.showInvoices("unpaid", "")
      else if (col === 3) ctx.showInvoices("overdue", "")
    }
  }

  function cursorItem(key, row) {
    if (key === "horizon") return horizonGroup
    if (key === "nav") return navRow
    return tiles
  }

  readonly property bool hasSearch: false

  readonly property real turnoverShare: Model.percentOf(snap.turnover.yearToDate, snap.turnover.limit)
  readonly property bool showTurnover: snap.turnover.limit > 0 && snap.baseCurrency === "CZK"

  spacing: Style.space(12)

  Seg {
    id: horizonGroup
    ctx: root.ctx
    width: parent.width
    stop: "horizon"
    value: root.ctx.service.horizon
    options: [
      { value: "month", label: root.strings.t("period.month") },
      { value: "quarter", label: root.strings.t("period.quarter") },
      { value: "year", label: root.strings.t("period.year") },
      { value: "ltm", label: root.strings.t("period.ltm") }
    ]
    onChanged: function(value) { root.ctx.service.setPeriod(value, 0) }
  }

  Item {
    id: navRow
    width: parent.width
    implicitHeight: Math.max(previous.implicitHeight, title.implicitHeight)

    Btn {
      id: previous
      ctx: root.ctx
      stop: "nav"
      stopCol: 0
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      iconText: root.ctx.icons.left
      tooltipText: root.strings.t("period.previous")
      onClicked: root.ctx.stepPeriod(-1)
    }

    Txt {
      id: title
      ctx: root.ctx
      anchors.left: previous.right
      anchors.right: next.left
      anchors.margins: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignHCenter
      text: root.ctx.periodTitle(root.period)
      font.pixelSize: Style.font.title
      font.bold: true
      elide: Text.ElideRight
    }

    Btn {
      id: next
      ctx: root.ctx
      stop: "nav"
      stopCol: 1
      anchors.right: today.visible ? today.left : parent.right
      anchors.rightMargin: today.visible ? Style.space(6) : 0
      anchors.verticalCenter: parent.verticalCenter
      iconText: root.ctx.icons.right
      tooltipText: root.strings.t("period.next")
      enabled: root.ctx.service.offset < 0
      onClicked: root.ctx.stepPeriod(1)
    }

    Btn {
      id: today
      ctx: root.ctx
      stop: "nav"
      stopCol: 2
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: root.ctx.service.offset < 0
      text: root.strings.t("period.today")
      fontSize: Style.font.caption
      onClicked: root.ctx.service.setPeriod(root.ctx.service.horizon, 0)
    }
  }

  Grid {
    id: tiles
    width: parent.width
    columns: 2
    spacing: Style.space(8)
    readonly property real tileWidth: (width - spacing) / 2

    Tile {
      ctx: root.ctx
      width: tiles.tileWidth
      hasCursor: root.ctx.cursorOn("tiles", 0, 0)
      label: root.strings.t("overview.invoiced")
      value: root.ctx.money(root.period.invoiced.subtotal, "", "round")
      trend: root.ctx.privacy ? "" : Model.formatTrend(root.period.trend.previous)
      trendPositive: (root.period.trend.previous || 0) >= 0
      detail: {
        var parts = [root.strings.tn("overview.invoiceCount", root.period.invoiced.count).arg(root.period.invoiced.count)]
        if (root.period.trend.yoy !== null && !root.ctx.privacy) {
          parts.push(root.strings.t("overview.yoy").arg(Model.formatTrend(root.period.trend.yoy)))
        }
        return parts.join(" \u00b7 ")
      }
    }

    Tile {
      ctx: root.ctx
      width: tiles.tileWidth
      hasCursor: root.ctx.cursorOn("tiles", 0, 1)
      label: root.strings.t("overview.collected")
      value: root.ctx.money(root.period.collected.total, "", "round")
      tint: root.ctx.positive
      detail: root.strings.t("overview.collectedShare")
        .arg(Math.round(Model.percentOf(root.period.collected.total, root.period.invoiced.total) * 100))
    }

    Tile {
      ctx: root.ctx
      width: tiles.tileWidth
      hasCursor: root.ctx.cursorOn("tiles", 0, 2)
      clickable: true
      label: root.strings.t("overview.pending")
      value: root.ctx.money(root.period.pending.total, "", "round")
      detail: root.strings.tn("overview.invoiceCount", root.period.pending.count).arg(root.period.pending.count)
      onClicked: root.ctx.showInvoices("unpaid", "")
    }

    Tile {
      ctx: root.ctx
      width: tiles.tileWidth
      hasCursor: root.ctx.cursorOn("tiles", 0, 3)
      clickable: true
      label: root.strings.t("overview.overdue")
      value: root.ctx.money(root.period.overdue.total, "", "round")
      tint: root.period.overdue.count > 0 ? root.ctx.urgent : root.ctx.foreground
      emphasized: root.period.overdue.count > 0
      detail: root.period.overdue.count > 0
        ? root.strings.tn("overview.invoiceCount", root.period.overdue.count).arg(root.period.overdue.count)
        : root.strings.t("overview.noneOverdue")
      onClicked: root.ctx.showInvoices("overdue", "")
    }
  }

  AnalyticsChart {
    ctx: root.ctx
    width: parent.width
    chart: root.snap.chart
    selectedKind: root.period.kind
    selectedYear: root.period.year
    selectedIndex: root.period.index
    selectAll: root.period.horizon === "year" || root.period.horizon === "ltm"
    onBucketClicked: function(entry) { root.ctx.selectBucket(entry) }
  }

  PanelSeparator { foreground: root.ctx.foreground }

  Row {
    id: secondary
    width: parent.width
    spacing: Style.space(8)
    readonly property real tileWidth: (width - 2 * spacing) / 3

    Tile {
      ctx: root.ctx
      width: secondary.tileWidth
      label: root.strings.t("overview.expenses")
      value: root.snap.expensesAvailable ? root.ctx.money(root.period.expenses.subtotal, "", "round") : "\u2014"
      detail: root.snap.expensesAvailable
        ? root.strings.tn("overview.expenseCount", root.period.expenses.count).arg(root.period.expenses.count)
        : root.strings.t("overview.expensesUnavailable")
    }

    Tile {
      ctx: root.ctx
      width: secondary.tileWidth
      label: root.strings.t("overview.net")
      value: root.ctx.money(root.period.net, "", "round")
      tint: root.period.net < 0 ? root.ctx.urgent : root.ctx.positive
      detail: root.strings.t("overview.netDetail")
    }

    Tile {
      ctx: root.ctx
      width: secondary.tileWidth
      label: root.period.vat.balance >= 0 ? root.strings.t("overview.vatDue") : root.strings.t("overview.vatRefund")
      value: root.ctx.money(Math.abs(root.period.vat.balance), "", "round")
      detail: root.strings.t("overview.vatDetail")
    }
  }

  // Calendar-year turnover against the VAT registration limit.
  Column {
    visible: root.showTurnover
    width: parent.width
    spacing: Style.space(5)

    Item {
      width: parent.width
      implicitHeight: turnoverLabel.implicitHeight

      Txt {
        id: turnoverLabel
        ctx: root.ctx
        dim: true
        text: root.strings.t("overview.turnover").arg(root.snap.turnover.year)
        font.pixelSize: Style.font.caption
      }

      Txt {
        ctx: root.ctx
        anchors.right: parent.right
        text: root.ctx.privacy
          ? Model.maskedMoney()
          : root.strings.t("overview.turnoverValue")
              .arg(root.ctx.money(root.snap.turnover.yearToDate, "CZK", "round"))
              .arg(root.ctx.money(root.snap.turnover.limit, "CZK", "round"))
              .arg(Math.round(root.turnoverShare * 100))
        font.pixelSize: Style.font.caption
      }
    }

    Rectangle {
      width: parent.width
      height: Style.space(6)
      radius: height / 2
      color: Qt.rgba(root.ctx.foreground.r, root.ctx.foreground.g, root.ctx.foreground.b, 0.10)

      Rectangle {
        height: parent.height
        radius: parent.radius
        width: root.ctx.privacy ? 0 : Math.max(root.turnoverShare > 0 ? parent.height : 0, parent.width * root.turnoverShare)
        color: root.turnoverShare >= 1 ? root.ctx.urgent : (root.turnoverShare >= 0.8 ? root.ctx.warning : root.ctx.accent)
        Behavior on width {
          NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic }
        }
      }
    }

    Txt {
      ctx: root.ctx
      dim: true
      width: parent.width
      visible: root.turnoverShare >= 0.8 && !root.ctx.privacy
      text: root.turnoverShare >= 1 ? root.strings.t("overview.turnoverOver") : root.strings.t("overview.turnoverNear")
      color: root.turnoverShare >= 1 ? root.ctx.urgent : root.ctx.warning
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  // Documents in a foreign currency without an exchange rate are not mixed into the totals.
  Txt {
    ctx: root.ctx
    dim: true
    width: parent.width
    visible: root.period.foreign.length > 0
    text: {
      var parts = []
      for (var i = 0; i < root.period.foreign.length; i++) {
        var entry = root.period.foreign[i]
        parts.push(root.ctx.money(entry.total, entry.currency, "auto") + " (" + entry.count + ")")
      }
      return root.strings.t("overview.foreign").arg(parts.join(", "))
    }
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

}
