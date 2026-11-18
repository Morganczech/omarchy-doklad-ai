import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Filterable, searchable list of invoices. Opening a row shows the drawer.
Column {
  id: root

  required property var ctx
  readonly property var strings: ctx.strings
  readonly property var counts: ctx.snapshot.invoiceCounts

  // Rows are added in pages so a long history does not build hundreds of items at once.
  readonly property int pageSize: 30
  property int shown: pageSize
  readonly property var matches: visible ? Model.filterInvoices(ctx.snapshot.invoices, ctx.invoiceFilter, ctx.invoiceQuery) : []
  readonly property var rows: matches.slice(0, shown)
  readonly property bool hasMore: matches.length > shown
  readonly property real openTotal: {
    var sum = 0
    for (var i = 0; i < matches.length; i++) if (matches[i].currency === ctx.snapshot.baseCurrency) sum += matches[i].open
    return sum
  }

  readonly property bool hasSearch: true
  readonly property var stops: [
    { key: "filter", cols: Model.FILTERS.length },
    { key: "search", cols: 1 },
    { key: "list", rows: rows.length, cols: 1 },
    { key: "more", rows: hasMore ? 1 : 0 }
  ]

  function activate(key, row, col) {
    if (key === "filter") setFilter(Model.FILTERS[col])
    else if (key === "search") search.edit()
    else if (key === "list" && row < rows.length) ctx.openInvoice(rows[row].id)
    else if (key === "more") shown += pageSize
  }

  function cursorItem(key, row) {
    if (key === "filter") return filterGroup
    if (key === "search") return search
    if (key === "list") return list.itemAt(row)
    return moreButton
  }

  function focusSearch() {
    search.edit()
  }

  function setFilter(value) {
    ctx.invoiceFilter = value
    shown = pageSize
  }

  Connections {
    target: root.ctx
    function onInvoiceQueryChanged() {
      root.shown = root.pageSize
      if (search.text !== root.ctx.invoiceQuery) search.text = root.ctx.invoiceQuery
    }
    function onInvoiceFilterChanged() { root.shown = root.pageSize }
  }

  spacing: Style.space(10)

  Seg {
    id: filterGroup
    ctx: root.ctx
    width: parent.width
    stop: "filter"
    value: root.ctx.invoiceFilter
    options: [
      { value: "all", label: root.strings.t("filter.all") + " " + root.counts.all },
      { value: "unpaid", label: root.strings.t("filter.unpaid") + " " + root.counts.unpaid },
      { value: "overdue", label: root.strings.t("filter.overdue") + " " + root.counts.overdue },
      { value: "paid", label: root.strings.t("filter.paid") + " " + root.counts.paid },
      { value: "draft", label: root.strings.t("filter.draft") + " " + root.counts.draft }
    ]
    onChanged: function(value) { root.setFilter(value) }
  }

  Field {
    id: search
    ctx: root.ctx
    width: parent.width
    placeholderText: root.strings.t("invoices.search")
    maximumLength: 60
    hasCursor: root.ctx.cursorOn("search", 0, 0)
    onEdited: function(text) { root.ctx.invoiceQuery = text }
    onAccepted: root.ctx.leaveEditor()
  }

  Txt {
    ctx: root.ctx
    dim: true
    width: parent.width
    text: {
      var line = root.strings.tn("invoices.count", root.matches.length).arg(root.matches.length)
      if (root.openTotal > 0) line += " \u00b7 " + root.strings.t("invoices.openTotal").arg(root.ctx.money(root.openTotal, "", "round"))
      return line
    }
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }

  Column {
    width: parent.width
    spacing: Style.space(2)

    Repeater {
      id: list
      model: root.rows

      Rectangle {
        id: row
        required property var modelData
        required property int index
        readonly property bool hot: root.ctx.cursorOn("list", index, 0) || rowHover.hovered

        width: parent.width
        implicitHeight: rowText.implicitHeight + Style.space(14)
        radius: Style.cornerRadius
        color: hot ? root.ctx.hoverFill : "transparent"

        HoverHandler {
          id: rowHover
          cursorShape: Qt.PointingHandCursor
          onHoveredChanged: if (hovered) root.ctx.pointTo("list", row.index, 0)
        }
        TapHandler { onTapped: root.ctx.openInvoice(row.modelData.id) }

        // State at a glance: paid, waiting, overdue.
        Rectangle {
          id: marker
          anchors.left: parent.left
          anchors.leftMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(3)
          height: parent.height - Style.space(12)
          radius: width / 2
          color: root.ctx.stateColor(row.modelData.state)
        }

        Column {
          id: rowText
          anchors.left: marker.right
          anchors.leftMargin: Style.space(9)
          anchors.right: figures.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Txt {
            ctx: root.ctx
            width: parent.width
            text: row.modelData.customerName !== "" ? row.modelData.customerName : root.strings.t("invoices.noCustomer")
            font.bold: true
            elide: Text.ElideRight
          }

          Txt {
            ctx: root.ctx
            dim: true
            width: parent.width
            text: {
              var parts = [row.modelData.number !== "" ? row.modelData.number : "#" + row.modelData.id]
              if (row.modelData.kind !== "invoice") parts.push(root.strings.t("kind." + row.modelData.kind))
              parts.push(root.ctx.dateText(row.modelData.issueDate))
              return parts.join(" \u00b7 ")
            }
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Column {
          id: figures
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Txt {
            ctx: root.ctx
            anchors.right: parent.right
            text: root.ctx.money(row.modelData.total, row.modelData.currency, "auto")
            font.bold: true
          }

          Txt {
            ctx: root.ctx
            anchors.right: parent.right
            text: root.ctx.dueText(row.modelData)
            color: root.ctx.stateColor(row.modelData.state)
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  Txt {
    ctx: root.ctx
    dim: true
    width: parent.width
    visible: root.matches.length === 0
    horizontalAlignment: Text.AlignHCenter
    topPadding: Style.space(14)
    bottomPadding: Style.space(14)
    text: root.ctx.invoiceQuery !== "" ? root.strings.t("invoices.noMatch") : root.strings.t("invoices.empty")
    wrapMode: Text.WordWrap
  }

  Btn {
    id: moreButton
    ctx: root.ctx
    stop: "more"
    visible: root.hasMore
    anchors.horizontalCenter: parent.horizontalCenter
    text: root.strings.t("invoices.more").arg(root.matches.length - root.shown)
    onClicked: root.shown += root.pageSize
  }
}
