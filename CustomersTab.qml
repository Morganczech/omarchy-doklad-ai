import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Company lookup in the public registers (ARES for CZ, RPO for SK) with
// one-step customer creation, and the address book ranked by revenue in the
// selected period.
Column {
  id: root

  required property var ctx
  readonly property var strings: ctx.strings

  property var company: null
  property string country: "CZ"

  readonly property int pageSize: 25
  property int shown: pageSize
  readonly property var matches: visible ? Model.filterCustomers(ctx.snapshot.customers, search.text) : []
  readonly property var rows: matches.slice(0, shown)
  readonly property bool hasMore: matches.length > shown
  readonly property bool companyIsNew: company !== null && company.existingCustomerId === 0

  readonly property bool hasSearch: true
  readonly property var stops: [
    { key: "ares", cols: 4 },
    { key: "companyEmail", rows: companyIsNew ? 1 : 0 },
    { key: "companyActions", rows: company !== null ? 1 : 0, cols: 2 },
    { key: "search" },
    { key: "list", rows: rows.length, cols: 3 },
    { key: "more", rows: hasMore ? 1 : 0 }
  ]

  function activate(key, row, col) {
    if (key === "ares") {
      if (col === 0) ico.edit()
      else if (col === 1) country = "CZ"
      else if (col === 2) country = "SK"
      else lookup()
    } else if (key === "companyEmail") companyEmail.edit()
    else if (key === "companyActions") { if (col === 0) companyPrimary(); else company = null }
    else if (key === "search") search.edit()
    else if (key === "list" && row < rows.length) {
      if (col === 0) ctx.showInvoices("all", rows[row].name)
      else if (col === 1) ctx.newInvoiceFor(rows[row])
      else copyEmail(rows[row])
    } else if (key === "more") shown += pageSize
  }

  function cursorItem(key, row) {
    if (key === "ares") return aresRow
    if (key === "companyEmail" || key === "companyActions") return companyCard
    if (key === "search") return search
    if (key === "list") return list.itemAt(row)
    return moreButton
  }

  function resetView() {
    company = null
    search.text = ""
    ico.text = ""
  }

  function focusSearch() {
    search.edit()
  }

  function lookup() {
    var value = ico.text.trim()
    if (!Model.validIco(value)) { ctx.notice(strings.t("error.invalid_ico"), "error"); return }
    ctx.leaveEditor()
    ctx.act("ares-lookup", { ico: value, country: country }, "ares-lookup")
  }

  function companyPrimary() {
    var found = company
    if (found === null) return
    if (found.existingCustomerId !== 0) {
      ctx.newInvoiceFor({ id: found.existingCustomerId, name: found.name })
      return
    }
    var email = companyEmail.text.trim()
    if (email !== "" && !Model.validEmail(email)) { ctx.notice(strings.t("form.badEmail"), "error"); return }
    var payload = {
      name: found.name, ico: found.ico, dic: found.dic, address: found.address,
      city: found.city, postalCode: found.postalCode, country: found.country
    }
    if (email !== "") payload.email = email
    ctx.ask(strings.t("confirm.createCustomer").arg(found.name).arg(found.ico), strings.t("confirm.createCustomerButton"),
      function() { root.ctx.act("create-customer", payload, "create-customer") })
  }

  function copyEmail(customer) {
    if (customer.email === "") { ctx.notice(strings.t("customers.noEmail"), "info"); return }
    ctx.act("copy", { text: customer.email }, "copy")
  }

  Connections {
    target: root.ctx.service
    function onActionFinished(tag, result) {
      if (tag === "ares-lookup") {
        root.company = result.ok ? Model.parseCompany(result.company) : null
        companyEmail.text = ""
      } else if (tag === "create-customer" && result.ok) {
        root.company = null
        ico.text = ""
      }
    }
  }

  spacing: Style.space(10)

  PanelSectionHeader {
    text: root.strings.t("customers.lookupTitle")
    foreground: root.ctx.foreground
    fontFamily: root.ctx.fontFamily
  }

  Item {
    id: aresRow
    width: parent.width
    implicitHeight: ico.implicitHeight

    Field {
      id: ico
      ctx: root.ctx
      anchors.left: parent.left
      width: Style.space(150)
      label: root.strings.t("customers.ico")
      placeholderText: "12345678"
      maximumLength: 8
      invalid: text !== "" && !/^\d{0,8}$/.test(text)
      hasCursor: root.ctx.cursorOn("ares", 0, 0)
      onAccepted: root.lookup()
    }

    Seg {
      id: countryGroup
      ctx: root.ctx
      anchors.left: ico.right
      anchors.leftMargin: Style.space(8)
      anchors.bottom: parent.bottom
      stop: "ares"
      stopColOffset: 1
      value: root.country
      options: [
        { value: "CZ", label: "CZ", tooltip: "ARES" },
        { value: "SK", label: "SK", tooltip: "RPO" }
      ]
      onChanged: function(value) { root.country = value }
    }

    Btn {
      ctx: root.ctx
      stop: "ares"
      stopCol: 3
      anchors.left: countryGroup.right
      anchors.leftMargin: Style.space(8)
      anchors.bottom: parent.bottom
      iconText: root.ctx.icons.search
      text: root.strings.t("customers.lookup")
      enabled: !root.ctx.busy
      onClicked: root.lookup()
    }
  }

  BorderSurface {
    id: companyCard
    visible: root.company !== null
    width: parent.width
    implicitHeight: companyColumn.implicitHeight + Style.space(22)
    radius: Style.cornerRadius
    color: Qt.rgba(root.ctx.accent.r, root.ctx.accent.g, root.ctx.accent.b, 0.06)
    borderSpec: Border.flat(Qt.rgba(root.ctx.accent.r, root.ctx.accent.g, root.ctx.accent.b, 0.30), 1)

    Column {
      id: companyColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(12)
      spacing: Style.space(6)

      Txt {
        ctx: root.ctx
        width: parent.width
        text: root.company !== null ? root.company.name : ""
        font.pixelSize: Style.font.body
        font.bold: true
        wrapMode: Text.WordWrap
      }

      Txt {
        ctx: root.ctx
        dim: true
        width: parent.width
        text: {
          var found = root.company
          if (found === null) return ""
          var parts = [root.strings.t("customers.ico") + " " + found.ico]
          if (found.dic !== "") parts.push(root.strings.t("customers.dic") + " " + found.dic)
          parts.push(found.isVatPayer ? root.strings.t("customers.vatPayer") : root.strings.t("customers.notVatPayer"))
          if (found.legalForm !== "") parts.push(found.legalForm)
          return parts.join(" \u00b7 ")
        }
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Txt {
        ctx: root.ctx
        dim: true
        width: parent.width
        text: {
          var found = root.company
          if (found === null) return ""
          var parts = []
          if (found.address !== "") parts.push(found.address)
          var town = (found.postalCode + " " + found.city).trim()
          if (town !== "" && found.address.indexOf(found.city) === -1) parts.push(town)
          return parts.join(", ")
        }
        visible: text !== ""
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Txt {
        ctx: root.ctx
        width: parent.width
        visible: root.company !== null && !root.companyIsNew
        text: root.strings.t("customers.alreadyThere")
        color: root.ctx.positive
        font.pixelSize: Style.font.caption
      }

      Field {
        id: companyEmail
        ctx: root.ctx
        visible: root.companyIsNew
        width: parent.width
        label: root.strings.t("customers.emailOptional")
        maximumLength: 200
        hasCursor: root.ctx.cursorOn("companyEmail", 0, 0)
        onAccepted: root.companyPrimary()
      }

      Row {
        spacing: Style.space(8)

        Btn {
          ctx: root.ctx
          stop: "companyActions"
          stopCol: 0
          iconText: root.companyIsNew ? root.ctx.icons.plus : root.ctx.icons.newInvoice
          text: root.companyIsNew ? root.strings.t("customers.create") : root.strings.t("customers.newInvoice")
          enabled: !root.ctx.busy
          onClicked: root.companyPrimary()
        }

        Btn {
          ctx: root.ctx
          stop: "companyActions"
          stopCol: 1
          text: root.strings.t("customers.dismiss")
          onClicked: root.company = null
        }
      }
    }
  }

  PanelSectionHeader {
    text: root.strings.t("customers.listTitle").arg(root.ctx.snapshot.customerCount)
    foreground: root.ctx.foreground
    fontFamily: root.ctx.fontFamily
  }

  Field {
    id: search
    ctx: root.ctx
    width: parent.width
    placeholderText: root.strings.t("customers.search")
    maximumLength: 60
    hasCursor: root.ctx.cursorOn("search", 0, 0)
    onEdited: root.shown = root.pageSize
    onAccepted: root.ctx.leaveEditor()
  }

  Txt {
    ctx: root.ctx
    dim: true
    width: parent.width
    text: root.strings.t("customers.rankHint").arg(root.ctx.periodTitle(root.ctx.snapshot.period))
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
        implicitHeight: Math.max(rowText.implicitHeight, rowButtons.implicitHeight) + Style.space(12)
        radius: Style.cornerRadius
        color: hot ? root.ctx.hoverFill : "transparent"

        HoverHandler {
          id: rowHover
          cursorShape: Qt.PointingHandCursor
          onHoveredChanged: if (hovered) root.ctx.pointTo("list", row.index, 0)
        }
        TapHandler { onTapped: root.ctx.showInvoices("all", row.modelData.name) }

        Column {
          id: rowText
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          anchors.right: figures.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Txt {
            ctx: root.ctx
            width: parent.width
            text: row.modelData.name
            font.bold: true
            elide: Text.ElideRight
          }

          Txt {
            ctx: root.ctx
            dim: true
            width: parent.width
            text: {
              var parts = []
              if (row.modelData.ico !== "") parts.push(row.modelData.ico)
              if (row.modelData.city !== "") parts.push(row.modelData.city)
              if (row.modelData.email !== "") parts.push(row.modelData.email)
              return parts.join(" \u00b7 ")
            }
            visible: text !== ""
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Column {
          id: figures
          anchors.right: rowButtons.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Txt {
            ctx: root.ctx
            anchors.right: parent.right
            text: row.modelData.invoiceCount > 0 ? root.ctx.money(row.modelData.revenue, "", "round") : "\u2014"
            font.bold: row.modelData.invoiceCount > 0
          }

          Txt {
            ctx: root.ctx
            anchors.right: parent.right
            visible: row.modelData.open > 0
            text: root.strings.t("customers.open").arg(root.ctx.money(row.modelData.open, "", "round"))
            color: root.ctx.warning
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          id: rowButtons
          anchors.right: parent.right
          anchors.rightMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          PanelActionButton {
            iconText: root.ctx.icons.newInvoice
            tooltipText: root.strings.t("customers.newInvoice")
            foreground: root.ctx.foreground
            fontFamily: root.ctx.fontFamily
            size: Style.space(26)
            hasCursor: root.ctx.cursorOn("list", row.index, 1)
            onHovered: function(on) { if (on) root.ctx.pointTo("list", row.index, 1) }
            onClicked: root.ctx.newInvoiceFor(row.modelData)
          }

          PanelActionButton {
            iconText: root.ctx.icons.email
            tooltipText: root.strings.t("customers.copyEmail")
            foreground: root.ctx.foreground
            fontFamily: root.ctx.fontFamily
            size: Style.space(26)
            enabled: row.modelData.email !== ""
            opacity: enabled ? 1.0 : 0.35
            hasCursor: root.ctx.cursorOn("list", row.index, 2)
            onHovered: function(on) { if (on) root.ctx.pointTo("list", row.index, 2) }
            onClicked: root.copyEmail(row.modelData)
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
    topPadding: Style.space(12)
    bottomPadding: Style.space(12)
    text: search.text.trim() !== "" ? root.strings.t("customers.noMatch") : root.strings.t("customers.empty")
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
