import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One invoice: figures, items, payments and everything that can be done with
// it. Each action that changes the invoice asks for confirmation first.
Column {
  id: root

  required property var ctx
  readonly property var strings: ctx.strings

  readonly property var row: Model.findById(ctx.snapshot.invoices, ctx.drawerId)
  readonly property var detail: ctx.detail !== null && ctx.detail.id === ctx.drawerId ? ctx.detail : null
  readonly property var info: detail !== null ? detail : row
  readonly property string invoiceState: row !== null ? row.state : (detail !== null ? detail.state : "pending")
  readonly property bool unpaid: invoiceState === "pending" || invoiceState === "overdue"
  readonly property string number: info !== null && info.number !== "" ? info.number : "#" + ctx.drawerId
  readonly property string currency: info !== null ? info.currency : ""
  readonly property real openAmount: detail !== null ? detail.open : (row !== null ? row.open : 0)

  // "" | "payment" | "email"
  property string mode: ""
  property string payMethod: "bank_transfer"

  readonly property var actions: {
    var list = []
    if (info === null) return list
    if (unpaid) {
      list.push({ id: "payment", icon: ctx.icons.cash, label: strings.t("drawer.recordPayment") })
      list.push({ id: "paid", icon: ctx.icons.check, label: strings.t("drawer.markPaid") })
    }
    if (invoiceState === "draft") list.push({ id: "issue", icon: ctx.icons.send, label: strings.t("drawer.issue") })
    if (unpaid || invoiceState === "paid") list.push({ id: "email", icon: ctx.icons.email, label: strings.t("drawer.email") })
    list.push({ id: "pdf", icon: ctx.icons.pdf, label: "PDF" })
    if (info.variableSymbol !== "") list.push({ id: "copy", icon: ctx.icons.copy, label: strings.t("drawer.copyVs") })
    if (unpaid) list.push({ id: "cancel", icon: ctx.icons.cancel, label: strings.t("drawer.cancelInvoice") })
    if (invoiceState === "draft") list.push({ id: "delete", icon: ctx.icons.trash, label: strings.t("drawer.deleteDraft") })
    return list
  }

  readonly property bool hasSearch: false
  readonly property var stops: {
    var list = [{ key: "back" }, { key: "actions", cols: actions.length }]
    if (mode === "payment") {
      list.push({ key: "payFields", cols: 2 }, { key: "payMethod", cols: 4 }, { key: "payNote" }, { key: "paySubmit", cols: 2 })
    } else if (mode === "email") {
      list.push({ key: "emailTo" }, { key: "emailMessage" }, { key: "emailSubmit", cols: 2 })
    }
    return list
  }

  readonly property var methods: ["bank_transfer", "cash", "card", "other"]

  function activate(key, row, col) {
    if (key === "back") ctx.closeDrawer()
    else if (key === "actions" && col < actions.length) runAction(actions[col].id)
    else if (key === "payFields") (col === 0 ? payAmount : payDate).edit()
    else if (key === "payMethod") payMethod = methods[col]
    else if (key === "payNote") payNote.edit()
    else if (key === "paySubmit") { if (col === 0) submitPayment(); else mode = "" }
    else if (key === "emailTo") emailTo.edit()
    else if (key === "emailMessage") emailMessage.edit()
    else if (key === "emailSubmit") { if (col === 0) submitEmail(); else mode = "" }
  }

  function cursorItem(key, row) {
    if (key === "back") return backButton
    if (key === "actions") return actionFlow
    if (key.indexOf("pay") === 0) return paymentForm
    return emailForm
  }

  function runAction(id) {
    var invoiceId = ctx.drawerId
    if (id === "payment") {
      mode = mode === "payment" ? "" : "payment"
      if (mode === "payment") {
        payAmount.text = openAmount > 0 ? String(Math.round(openAmount * 100) / 100).replace(".", ",") : ""
        payDate.text = ctx.dateText(ctx.snapshot.today)
        payNote.text = ""
        payMethod = "bank_transfer"
      }
    } else if (id === "email") {
      mode = mode === "email" ? "" : "email"
      if (mode === "email") {
        emailTo.text = detail !== null ? detail.customerEmail : ""
        emailMessage.text = ""
      }
    } else if (id === "pdf") {
      ctx.act("download-pdf", { id: invoiceId, number: number, open: true }, "download-pdf")
    } else if (id === "copy") {
      ctx.act("copy", { text: info.variableSymbol }, "copy")
    } else if (id === "paid") {
      ctx.ask(strings.t("confirm.markPaid").arg(number).arg(ctx.plainMoney(info.total, currency)),
        strings.t("confirm.markPaidButton"),
        function() { root.ctx.act("set-status", { id: invoiceId, status: "paid" }, "set-status") })
    } else if (id === "issue") {
      ctx.ask(strings.t("confirm.issue").arg(number).arg(info.customerName).arg(ctx.plainMoney(info.total, currency)),
        strings.t("confirm.issueButton"),
        function() { root.ctx.act("set-status", { id: invoiceId, status: "sent" }, "set-status") })
    } else if (id === "cancel") {
      ctx.ask(strings.t("confirm.cancelInvoice").arg(number).arg(info.customerName),
        strings.t("confirm.cancelInvoiceButton"),
        function() { root.ctx.act("set-status", { id: invoiceId, status: "cancelled" }, "set-status") })
    } else if (id === "delete") {
      ctx.ask(strings.t("confirm.deleteDraft").arg(number),
        strings.t("confirm.deleteButton"),
        function() { root.ctx.act("delete-draft", { id: invoiceId }, "delete-draft") })
    }
  }

  function submitPayment() {
    var amount = Model.normalizeDecimal(payAmount.text)
    var paidAt = Model.normalizeDate(payDate.text)
    if (amount === "" || Number(amount) <= 0) { ctx.notice(strings.t("form.badAmount"), "error"); return }
    if (paidAt === "") { ctx.notice(strings.t("form.badDate"), "error"); return }
    var payload = { id: ctx.drawerId, amount: amount, paidAt: paidAt, method: payMethod, note: Model.plainText(payNote.text, 200) }
    ctx.ask(strings.t("confirm.payment").arg(ctx.plainMoney(Number(amount), currency)).arg(number).arg(ctx.dateText(paidAt)),
      strings.t("confirm.paymentButton"),
      function() {
        if (root.ctx.act("record-payment", payload, "record-payment")) root.mode = ""
      })
  }

  function submitEmail() {
    var to = emailTo.text.trim()
    if (to !== "" && !Model.validEmail(to)) { ctx.notice(strings.t("form.badEmail"), "error"); return }
    var payload = { id: ctx.drawerId }
    if (to !== "") payload.to = to
    if (emailMessage.text.trim() !== "") payload.message = emailMessage.text.trim()
    ctx.ask(strings.t("confirm.email").arg(number).arg(to !== "" ? to : strings.t("confirm.emailDefault")),
      strings.t("confirm.emailButton"),
      function() {
        if (root.ctx.act("send-email", payload, "send-email")) root.mode = ""
      })
  }

  Connections {
    target: root.ctx
    function onDrawerIdChanged() { root.mode = "" }
  }

  spacing: Style.space(12)

  Item {
    width: parent.width
    implicitHeight: backButton.implicitHeight

    Btn {
      id: backButton
      ctx: root.ctx
      stop: "back"
      anchors.left: parent.left
      iconText: root.ctx.icons.back
      text: root.strings.t("drawer.back")
      onClicked: root.ctx.closeDrawer()
    }

    Rectangle {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: stateLabel.implicitWidth + Style.space(16)
      height: stateLabel.implicitHeight + Style.space(6)
      radius: height / 2
      readonly property color tint: root.ctx.stateColor(root.invoiceState)
      color: Qt.rgba(tint.r, tint.g, tint.b, 0.14)
      border.width: 1
      border.color: Qt.rgba(tint.r, tint.g, tint.b, 0.45)

      Txt {
        id: stateLabel
        ctx: root.ctx
        anchors.centerIn: parent
        text: root.row !== null ? root.ctx.dueText(root.row) : root.ctx.stateText(root.invoiceState)
        color: parent.tint
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }

  Column {
    width: parent.width
    spacing: Style.space(2)

    Txt {
      ctx: root.ctx
      width: parent.width
      text: root.number
      font.pixelSize: Style.font.heading
      font.bold: true
      elide: Text.ElideRight
    }

    Txt {
      ctx: root.ctx
      dim: true
      width: parent.width
      text: root.info !== null ? root.info.customerName : ""
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
  }

  Txt {
    ctx: root.ctx
    dim: true
    width: parent.width
    visible: root.info === null
    text: root.strings.t("drawer.missing")
    wrapMode: Text.WordWrap
  }

  Grid {
    id: facts
    visible: root.info !== null
    width: parent.width
    columns: 3
    columnSpacing: Style.space(8)
    rowSpacing: Style.space(8)
    readonly property real cellWidth: (width - 2 * columnSpacing) / 3

    Repeater {
      model: {
        var info = root.info
        if (info === null) return []
        var detail = root.detail
        var list = [
          { label: root.strings.t("drawer.total"), value: root.ctx.money(info.total, root.currency, "exact"), strong: true },
          { label: root.strings.t("drawer.open"), value: root.unpaid ? root.ctx.money(root.openAmount, root.currency, "exact") : "\u2014",
            strong: root.unpaid },
          { label: root.strings.t("drawer.variableSymbol"), value: info.variableSymbol !== "" ? info.variableSymbol : "\u2014" },
          { label: root.strings.t("drawer.issued"), value: root.ctx.dateText(info.issueDate) },
          { label: root.strings.t("drawer.due"), value: root.ctx.dateText(info.dueDate) },
          { label: root.strings.t("drawer.taxDate"), value: detail !== null ? root.ctx.dateText(detail.taxDate) : "\u2026" }
        ]
        if (detail !== null) {
          list.push({ label: root.strings.t("drawer.subtotal"), value: root.ctx.money(detail.subtotal, root.currency, "exact") })
          list.push({ label: root.strings.t("drawer.vat"), value: root.ctx.money(detail.vatAmount, root.currency, "exact") })
        }
        return list
      }

      Column {
        required property var modelData
        width: facts.cellWidth
        spacing: Style.space(1)

        Txt {
          ctx: root.ctx
          dim: true
          width: parent.width
          text: modelData.label
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Txt {
          ctx: root.ctx
          width: parent.width
          text: modelData.value
          font.bold: modelData.strong === true
          elide: Text.ElideRight
        }
      }
    }
  }

  Flow {
    id: actionFlow
    width: parent.width
    spacing: Style.space(6)

    Repeater {
      model: root.actions

      Btn {
        required property var modelData
        required property int index
        ctx: root.ctx
        stop: "actions"
        stopCol: index
        iconText: modelData.icon
        text: modelData.label
        selected: (modelData.id === "payment" && root.mode === "payment") || (modelData.id === "email" && root.mode === "email")
        enabled: !root.ctx.busy
        onClicked: root.runAction(modelData.id)
      }
    }
  }

  // ---- Record a payment ------------------------------------------------------
  Column {
    id: paymentForm
    visible: root.mode === "payment"
    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      text: root.strings.t("drawer.recordPayment")
      foreground: root.ctx.foreground
      fontFamily: root.ctx.fontFamily
    }

    Row {
      width: parent.width
      spacing: Style.space(8)

      Field {
        id: payAmount
        ctx: root.ctx
        width: (parent.width - parent.spacing) / 2
        label: root.strings.t("drawer.payAmount").arg(root.currency)
        maximumLength: 16
        hasCursor: root.ctx.cursorOn("payFields", 0, 0)
        onAccepted: root.submitPayment()
      }

      Field {
        id: payDate
        ctx: root.ctx
        width: (parent.width - parent.spacing) / 2
        label: root.strings.t("drawer.payDate")
        maximumLength: 14
        hasCursor: root.ctx.cursorOn("payFields", 0, 1)
        onAccepted: root.submitPayment()
      }
    }

    Seg {
      ctx: root.ctx
      width: parent.width
      stop: "payMethod"
      value: root.payMethod
      options: [
        { value: "bank_transfer", label: root.strings.t("method.bank_transfer") },
        { value: "cash", label: root.strings.t("method.cash") },
        { value: "card", label: root.strings.t("method.card") },
        { value: "other", label: root.strings.t("method.other") }
      ]
      onChanged: function(value) { root.payMethod = value }
    }

    Field {
      id: payNote
      ctx: root.ctx
      width: parent.width
      label: root.strings.t("drawer.payNote")
      maximumLength: 200
      hasCursor: root.ctx.cursorOn("payNote", 0, 0)
      onAccepted: root.submitPayment()
    }

    Row {
      spacing: Style.space(8)

      Btn {
        ctx: root.ctx
        stop: "paySubmit"
        stopCol: 0
        iconText: root.ctx.icons.check
        text: root.strings.t("drawer.paySubmit")
        enabled: !root.ctx.busy
        onClicked: root.submitPayment()
      }

      Btn {
        ctx: root.ctx
        stop: "paySubmit"
        stopCol: 1
        text: root.strings.t("confirm.cancel")
        onClicked: root.mode = ""
      }
    }
  }

  // ---- Send by e-mail --------------------------------------------------------
  Column {
    id: emailForm
    visible: root.mode === "email"
    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      text: root.strings.t("drawer.email")
      foreground: root.ctx.foreground
      fontFamily: root.ctx.fontFamily
    }

    Field {
      id: emailTo
      ctx: root.ctx
      width: parent.width
      label: root.strings.t("drawer.emailTo")
      placeholderText: root.strings.t("drawer.emailToHint")
      maximumLength: 200
      hasCursor: root.ctx.cursorOn("emailTo", 0, 0)
      onAccepted: root.submitEmail()
    }

    Field {
      id: emailMessage
      ctx: root.ctx
      width: parent.width
      label: root.strings.t("drawer.emailMessage")
      maximumLength: 1000
      hasCursor: root.ctx.cursorOn("emailMessage", 0, 0)
      onAccepted: root.submitEmail()
    }

    Row {
      spacing: Style.space(8)

      Btn {
        ctx: root.ctx
        stop: "emailSubmit"
        stopCol: 0
        iconText: root.ctx.icons.send
        text: root.strings.t("drawer.emailSubmit")
        enabled: !root.ctx.busy
        onClicked: root.submitEmail()
      }

      Btn {
        ctx: root.ctx
        stop: "emailSubmit"
        stopCol: 1
        text: root.strings.t("confirm.cancel")
        onClicked: root.mode = ""
      }
    }
  }

  Txt {
    ctx: root.ctx
    dim: true
    width: parent.width
    visible: root.info !== null && root.detail === null
    text: root.ctx.busy || root.ctx.detailPending ? root.strings.t("drawer.loading") : root.strings.t("drawer.noDetail")
    font.pixelSize: Style.font.caption
  }

  // ---- Items -----------------------------------------------------------------
  Column {
    visible: root.detail !== null && root.detail.items.length > 0
    width: parent.width
    spacing: Style.space(6)

    PanelSectionHeader {
      text: root.strings.t("drawer.items")
      foreground: root.ctx.foreground
      fontFamily: root.ctx.fontFamily
    }

    Repeater {
      model: root.detail !== null ? root.detail.items : []

      Item {
        required property var modelData
        width: parent.width
        implicitHeight: itemText.implicitHeight

        Column {
          id: itemText
          anchors.left: parent.left
          anchors.right: itemTotal.left
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(1)

          Txt {
            ctx: root.ctx
            width: parent.width
            text: modelData.description
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }

          Txt {
            ctx: root.ctx
            dim: true
            width: parent.width
            text: modelData.quantity + " " + modelData.unit + " \u00d7 "
              + root.ctx.money(modelData.unitPrice, root.currency, "auto")
              + (modelData.vatRate !== "" ? " \u00b7 " + root.strings.t("drawer.vatRate").arg(modelData.vatRate) : "")
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Txt {
          id: itemTotal
          ctx: root.ctx
          anchors.right: parent.right
          text: root.ctx.money(modelData.total, root.currency, "auto")
        }
      }
    }
  }

  // ---- Payments --------------------------------------------------------------
  Column {
    visible: root.detail !== null && root.detail.payments.length > 0
    width: parent.width
    spacing: Style.space(6)

    PanelSectionHeader {
      text: root.strings.t("drawer.payments")
      foreground: root.ctx.foreground
      fontFamily: root.ctx.fontFamily
    }

    Repeater {
      model: root.detail !== null ? root.detail.payments : []

      Item {
        required property var modelData
        width: parent.width
        implicitHeight: paymentText.implicitHeight

        Txt {
          id: paymentText
          ctx: root.ctx
          anchors.left: parent.left
          anchors.right: paymentAmount.left
          anchors.rightMargin: Style.space(10)
          text: {
            var parts = [root.ctx.dateText(modelData.paidAt)]
            if (root.methods.indexOf(modelData.method) !== -1) parts.push(root.strings.t("method." + modelData.method))
            if (modelData.note !== "") parts.push(modelData.note)
            return parts.join(" \u00b7 ")
          }
          elide: Text.ElideRight
        }

        Txt {
          id: paymentAmount
          ctx: root.ctx
          anchors.right: parent.right
          text: root.ctx.money(modelData.amount, root.currency, "auto")
          color: root.ctx.positive
        }
      }
    }
  }

  Txt {
    ctx: root.ctx
    dim: true
    width: parent.width
    visible: root.detail !== null && root.detail.notes !== ""
    text: root.detail !== null ? root.detail.notes : ""
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
