import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Quick invoice and expense entry. Nothing is sent straight from the form:
// the backend first computes the exact totals offline, the dialog shows them,
// and only a confirmed dialog creates the document. An invoice is created as a
// draft unless "issue right away" is switched on.
Column {
  id: root

  required property var ctx
  readonly property var strings: ctx.strings

  property string kind: "invoice"
  property bool initialized: false

  property int customerId: 0
  property string customerName: ""
  property bool finalInvoice: false
  property string expenseVat: "21"
  // Bumped on every item edit so the estimate below the items recomputes.
  property int revision: 0
  property var pendingInvoice: null
  property var pendingExpense: null

  readonly property var vatRates: ["21", "12", "0"]
  readonly property var vatOptions: [
    { value: "21", label: "21 %" }, { value: "12", label: "12 %" }, { value: "0", label: "0 %" }
  ]
  readonly property var dueChoices: [7, 14, 30]

  readonly property var suggestions: customerId === 0 && customerSearch.text.trim() !== ""
    ? Model.filterCustomers(ctx.snapshot.customers, customerSearch.text).slice(0, 5)
    : []

  readonly property var estimate: {
    root.revision
    return Model.estimateTotals(root.collectItems())
  }

  readonly property bool hasSearch: false
  readonly property var stops: {
    var list = [{ key: "kind", cols: 2 }]
    if (kind === "invoice") {
      list.push({ key: "customer" })
      list.push({ key: "suggest", rows: suggestions.length })
      list.push({ key: "dates", cols: 2 })
      list.push({ key: "dueQuick", cols: dueChoices.length })
      list.push({ key: "item", rows: items.count, cols: 8 })
      list.push({ key: "addItem" })
      list.push({ key: "notes" })
      list.push({ key: "final" })
      list.push({ key: "submit", cols: 2 })
    } else {
      list.push({ key: "xDescription" })
      list.push({ key: "xMoney", cols: 2 })
      list.push({ key: "xVat", cols: vatRates.length })
      list.push({ key: "xMeta", cols: 2 })
      list.push({ key: "xSubmit", cols: 2 })
    }
    return list
  }

  function activate(key, row, col) {
    if (key === "kind") kind = col === 0 ? "invoice" : "expense"
    else if (key === "customer") { if (customerId !== 0) clearCustomer(); else customerSearch.edit() }
    else if (key === "suggest" && row < suggestions.length) pickCustomer(suggestions[row])
    else if (key === "dates") (col === 0 ? issueDate : dueDate).edit()
    else if (key === "dueQuick") setDueDays(dueChoices[col])
    else if (key === "item") { var line = itemList.itemAt(row); if (line) line.activate(col) }
    else if (key === "addItem") addItem()
    else if (key === "notes") notes.edit()
    else if (key === "final") finalInvoice = !finalInvoice
    else if (key === "submit") { if (col === 0) submitInvoice(); else askReset() }
    else if (key === "xDescription") expenseDescription.edit()
    else if (key === "xMoney") (col === 0 ? expenseAmount : expenseDate).edit()
    else if (key === "xVat") expenseVat = vatRates[col]
    else if (key === "xMeta") (col === 0 ? expenseCategory : expenseReceipt).edit()
    else if (key === "xSubmit") { if (col === 0) submitExpense(); else resetExpense() }
  }

  function cursorItem(key, row) {
    if (key === "kind") return kindGroup
    if (key === "customer") return customerBox
    if (key === "suggest") return suggestionList.itemAt(row)
    if (key === "dates") return dateRow
    if (key === "dueQuick") return dueRow
    if (key === "item") return itemList.itemAt(row)
    if (key === "addItem") return addButton
    if (key === "notes") return notes
    if (key === "final") return finalToggle
    if (key === "submit") return submitRow
    if (key === "xDescription") return expenseDescription
    if (key === "xMoney") return expenseMoneyRow
    if (key === "xVat") return expenseVatGroup
    if (key === "xMeta") return expenseMetaRow
    return expenseSubmitRow
  }

  function today() {
    return ctx.snapshot.today !== "" ? ctx.snapshot.today : Model.toIso(new Date())
  }

  function ensureInitialized() {
    if (initialized) return
    initialized = true
    resetInvoice()
    resetExpense()
  }

  function resetInvoice() {
    // Rows are rebuilt below; a field must not hold the keyboard while it is destroyed.
    ctx.leaveEditor()
    customerId = 0
    customerName = ""
    customerSearch.text = ""
    finalInvoice = false
    issueDate.text = ctx.dateText(today())
    setDueDays(14)
    notes.text = ""
    items.clear()
    addItem()
    pendingInvoice = null
  }

  function resetExpense() {
    ctx.leaveEditor()
    expenseDescription.text = ""
    expenseAmount.text = ""
    expenseCategory.text = ""
    expenseReceipt.text = ""
    expenseDate.text = ctx.dateText(today())
    expenseVat = vatRates.indexOf(ctx.defaultVatRate) !== -1 ? ctx.defaultVatRate : "21"
    pendingExpense = null
  }

  function askReset() {
    if (customerId === 0 && estimate.filled === 0) { resetInvoice(); return }
    ctx.ask(strings.t("confirm.resetForm"), strings.t("confirm.resetButton"), function() { root.resetInvoice() })
  }

  function setDueDays(days) {
    var issue = Model.normalizeDate(issueDate.text)
    dueDate.text = ctx.dateText(Model.addDays(issue !== "" ? issue : today(), days))
  }

  function pickCustomer(customer) {
    customerId = customer.id
    customerName = customer.name
    customerSearch.text = ""
    ctx.leaveEditor()
  }

  function clearCustomer() {
    customerId = 0
    customerName = ""
  }

  function addItem() {
    if (items.count >= 20) return
    items.append(Model.emptyItem(vatRates.indexOf(ctx.defaultVatRate) !== -1 ? ctx.defaultVatRate : "21"))
    revision += 1
  }

  function removeItem(index) {
    if (items.count <= 1 || index < 0 || index >= items.count) return
    ctx.leaveEditor()
    items.remove(index)
    revision += 1
  }

  function setItem(index, role, value) {
    if (index < 0 || index >= items.count) return
    items.setProperty(index, role, String(value))
    revision += 1
  }

  function collectItems() {
    var list = []
    for (var i = 0; i < items.count; i++) {
      var item = items.get(i)
      list.push({ description: item.description, quantity: item.quantity, unit: item.unit,
                  unitPrice: item.unitPrice, vatRate: item.vatRate })
    }
    return list
  }

  function submitInvoice() {
    var form = {
      customerId: customerId, customerName: customerName, issueDate: issueDate.text, dueDate: dueDate.text,
      items: collectItems(), notes: notes.text, final: finalInvoice
    }
    var problem = Model.invoiceFormProblem(form)
    if (problem !== "") { ctx.notice(strings.t(problem), "error"); return }
    pendingInvoice = Model.invoicePayload(form)
    ctx.act("preview-invoice", pendingInvoice, "preview-invoice")
  }

  function submitExpense() {
    var form = {
      description: expenseDescription.text, category: expenseCategory.text, amount: expenseAmount.text,
      vatRate: expenseVat, date: expenseDate.text, receiptNumber: expenseReceipt.text
    }
    var problem = Model.expenseFormProblem(form)
    if (problem !== "") { ctx.notice(strings.t(problem), "error"); return }
    pendingExpense = Model.expensePayload(form)
    ctx.act("preview-expense", pendingExpense, "preview-expense")
  }

  function confirmInvoice(result) {
    var payload = pendingInvoice
    if (payload === null) return
    var draft = payload.draft !== false
    var message = strings.t(draft ? "confirm.createDraft" : "confirm.createFinal")
        .arg(Model.plainText(result.customerName, 80)).arg(ctx.plainMoney(result.total, ""))
      + "\n\n" + strings.t("confirm.createBreakdown")
        .arg(ctx.plainMoney(result.subtotal, "")).arg(ctx.plainMoney(result.vatAmount, "")).arg(Number(result.itemCount) || 0)
      + "\n" + strings.t("confirm.createDates").arg(ctx.dateText(payload.issueDate)).arg(ctx.dateText(payload.dueDate))
    ctx.ask(message, strings.t(draft ? "confirm.createDraftButton" : "confirm.createFinalButton"),
      function() { root.ctx.act("create-invoice", payload, "create-invoice") })
  }

  function confirmExpense(result) {
    var payload = pendingExpense
    if (payload === null) return
    var message = strings.t("confirm.createExpense")
        .arg(Model.plainText(result.description, 80)).arg(ctx.plainMoney(result.total, ""))
      + "\n\n" + strings.t("confirm.expenseBreakdown")
        .arg(ctx.plainMoney(result.amount, "")).arg(ctx.plainMoney(result.vatAmount, "")).arg(ctx.dateText(payload.expenseDate))
    ctx.ask(message, strings.t("confirm.createExpenseButton"),
      function() { root.ctx.act("create-expense", payload, "create-expense") })
  }

  function invoiceCreated(result) {
    var draft = result.draft !== false
    var id = Number(result.id) || 0
    var label = Model.plainText(result.number, 40)
    if (label === "") label = id > 0 ? "#" + id : ""
    var text = strings.t(draft ? "done.invoiceDraft" : "done.invoiceFinal").arg(label)
    if (result.duplicateWarning === true) text += " " + strings.t("done.duplicateWarning")
    resetInvoice()
    if (id > 0) ctx.openInvoice(id)
    ctx.notice(text, result.duplicateWarning === true ? "info" : "ok")
  }

  Connections {
    target: root.ctx.service
    function onActionFinished(tag, result) {
      if (tag === "preview-invoice" && result.ok) root.confirmInvoice(result)
      else if (tag === "preview-expense" && result.ok) root.confirmExpense(result)
      else if (tag === "create-invoice" && result.ok) root.invoiceCreated(result)
      else if (tag === "create-expense" && result.ok) root.resetExpense()
      else if (tag === "create-invoice" && result.error === "duplicate_recent" && root.pendingInvoice !== null) {
        var payload = root.pendingInvoice
        root.ctx.ask(root.strings.t("confirm.duplicate"), root.strings.t("confirm.duplicateButton"), function() {
          payload.force = true
          root.ctx.act("create-invoice", payload, "create-invoice")
        })
      }
    }
  }

  Connections {
    target: root.ctx
    function onPrefillCustomerChanged() {
      var customer = root.ctx.prefillCustomer
      if (!customer) return
      root.ensureInitialized()
      root.kind = "invoice"
      root.customerId = customer.id
      root.customerName = customer.name
      root.ctx.prefillCustomer = null
    }
  }

  onVisibleChanged: if (visible) ensureInitialized()
  Component.onCompleted: if (visible) ensureInitialized()

  ListModel { id: items }

  spacing: Style.space(10)

  Seg {
    id: kindGroup
    ctx: root.ctx
    width: parent.width
    stop: "kind"
    value: root.kind
    options: [
      { value: "invoice", icon: root.ctx.icons.invoice, label: root.strings.t("create.invoice") },
      { value: "expense", icon: root.ctx.icons.receipt, label: root.strings.t("create.expense") }
    ]
    onChanged: function(value) { root.kind = value }
  }

  // ---- Invoice ---------------------------------------------------------------
  Column {
    visible: root.kind === "invoice"
    width: parent.width
    spacing: Style.space(10)

    Column {
      id: customerBox
      width: parent.width
      spacing: Style.space(4)

      Field {
        id: customerSearch
        ctx: root.ctx
        visible: root.customerId === 0
        width: parent.width
        label: root.strings.t("create.customer")
        placeholderText: root.strings.t("create.customerHint")
        maximumLength: 60
        hasCursor: root.ctx.cursorOn("customer", 0, 0)
        onAccepted: if (root.suggestions.length > 0) root.pickCustomer(root.suggestions[0])
      }

      Item {
        visible: root.customerId !== 0
        width: parent.width
        implicitHeight: Math.max(chosen.implicitHeight, changeButton.implicitHeight)

        Column {
          id: chosen
          anchors.left: parent.left
          anchors.right: changeButton.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Txt {
            ctx: root.ctx
            dim: true
            text: root.strings.t("create.customer")
            font.pixelSize: Style.font.caption
          }

          Txt {
            ctx: root.ctx
            width: parent.width
            text: root.customerName
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }
        }

        Btn {
          id: changeButton
          ctx: root.ctx
          stop: "customer"
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.strings.t("create.changeCustomer")
          fontSize: Style.font.caption
          onClicked: root.clearCustomer()
        }
      }

      Repeater {
        id: suggestionList
        model: root.suggestions

        Rectangle {
          id: suggestion
          required property var modelData
          required property int index
          width: parent.width
          implicitHeight: suggestionText.implicitHeight + Style.space(10)
          radius: Style.cornerRadius
          color: root.ctx.cursorOn("suggest", index, 0) || suggestionHover.hovered ? root.ctx.hoverFill : "transparent"

          HoverHandler {
            id: suggestionHover
            cursorShape: Qt.PointingHandCursor
            onHoveredChanged: if (hovered) root.ctx.pointTo("suggest", suggestion.index, 0)
          }
          TapHandler { onTapped: root.pickCustomer(suggestion.modelData) }

          Txt {
            id: suggestionText
            ctx: root.ctx
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: suggestion.modelData.name + (suggestion.modelData.ico !== "" ? " \u00b7 " + suggestion.modelData.ico : "")
            elide: Text.ElideRight
          }
        }
      }

      Txt {
        ctx: root.ctx
        dim: true
        width: parent.width
        visible: root.customerId === 0 && customerSearch.text.trim() !== "" && root.suggestions.length === 0
        text: root.strings.t("create.noCustomer")
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    Row {
      id: dateRow
      width: parent.width
      spacing: Style.space(8)

      Field {
        id: issueDate
        ctx: root.ctx
        width: (parent.width - parent.spacing) / 2
        label: root.strings.t("create.issueDate")
        maximumLength: 14
        invalid: text !== "" && Model.normalizeDate(text) === ""
        hasCursor: root.ctx.cursorOn("dates", 0, 0)
        onAccepted: root.ctx.leaveEditor()
      }

      Field {
        id: dueDate
        ctx: root.ctx
        width: (parent.width - parent.spacing) / 2
        label: root.strings.t("create.dueDate")
        maximumLength: 14
        invalid: text !== "" && Model.normalizeDate(text) === ""
        hasCursor: root.ctx.cursorOn("dates", 0, 1)
        onAccepted: root.ctx.leaveEditor()
      }
    }

    Row {
      id: dueRow
      spacing: Style.space(6)

      Txt {
        ctx: root.ctx
        dim: true
        anchors.verticalCenter: parent.verticalCenter
        text: root.strings.t("create.dueIn")
        font.pixelSize: Style.font.caption
      }

      Repeater {
        model: root.dueChoices

        Btn {
          required property int modelData
          required property int index
          ctx: root.ctx
          stop: "dueQuick"
          stopCol: index
          text: root.strings.t("create.days").arg(modelData)
          fontSize: Style.font.caption
          onClicked: root.setDueDays(modelData)
        }
      }
    }

    PanelSectionHeader {
      text: root.strings.t("create.items")
      foreground: root.ctx.foreground
      fontFamily: root.ctx.fontFamily
    }

    Repeater {
      id: itemList
      model: items

      Column {
        id: line
        required property int index
        required property string description
        required property string quantity
        required property string unit
        required property string unitPrice
        required property string vatRate

        function activate(col) {
          if (col === 0) descriptionField.edit()
          else if (col === 1) quantityField.edit()
          else if (col === 2) unitField.edit()
          else if (col === 3) priceField.edit()
          else if (col <= 6) root.setItem(index, "vatRate", root.vatRates[col - 4])
          else root.removeItem(index)
        }

        width: parent.width
        spacing: Style.space(6)

        Field {
          id: descriptionField
          ctx: root.ctx
          width: parent.width
          label: root.strings.t("create.itemDescription").arg(line.index + 1)
          maximumLength: 300
          hasCursor: root.ctx.cursorOn("item", line.index, 0)
          Component.onCompleted: text = line.description
          onEdited: function(text) { root.setItem(line.index, "description", text) }
          onAccepted: quantityField.edit()
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Field {
            id: quantityField
            ctx: root.ctx
            width: Style.space(84)
            label: root.strings.t("create.quantity")
            maximumLength: 12
            invalid: text !== "" && Model.normalizeDecimal(text) === ""
            hasCursor: root.ctx.cursorOn("item", line.index, 1)
            Component.onCompleted: text = line.quantity
            onEdited: function(text) { root.setItem(line.index, "quantity", text) }
            onAccepted: priceField.edit()
          }

          Field {
            id: unitField
            ctx: root.ctx
            width: Style.space(72)
            label: root.strings.t("create.unit")
            maximumLength: 12
            hasCursor: root.ctx.cursorOn("item", line.index, 2)
            Component.onCompleted: text = line.unit
            onEdited: function(text) { root.setItem(line.index, "unit", text) }
            onAccepted: priceField.edit()
          }

          Field {
            id: priceField
            ctx: root.ctx
            width: parent.width - quantityField.width - unitField.width - 2 * parent.spacing
            label: root.strings.t("create.unitPrice")
            maximumLength: 16
            invalid: text !== "" && Model.normalizeDecimal(text) === ""
            hasCursor: root.ctx.cursorOn("item", line.index, 3)
            Component.onCompleted: text = line.unitPrice
            onEdited: function(text) { root.setItem(line.index, "unitPrice", text) }
            onAccepted: root.ctx.leaveEditor()
          }
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(vatGroup.implicitHeight, removeButton.implicitHeight)

          Txt {
            id: vatLabel
            ctx: root.ctx
            dim: true
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.strings.t("create.vat")
            font.pixelSize: Style.font.caption
          }

          Seg {
            id: vatGroup
            ctx: root.ctx
            anchors.left: vatLabel.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            stop: "item"
            stopRow: line.index
            stopColOffset: 4
            value: line.vatRate
            options: root.vatOptions
            onChanged: function(value) { root.setItem(line.index, "vatRate", value) }
          }

          PanelActionButton {
            id: removeButton
            visible: items.count > 1
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.ctx.icons.trash
            tooltipText: root.strings.t("create.removeItem")
            foreground: root.ctx.foreground
            fontFamily: root.ctx.fontFamily
            size: Style.space(26)
            hasCursor: root.ctx.cursorOn("item", line.index, 7)
            onHovered: function(on) { if (on) root.ctx.pointTo("item", line.index, 7) }
            onClicked: root.removeItem(line.index)
          }
        }
      }
    }

    Btn {
      id: addButton
      ctx: root.ctx
      stop: "addItem"
      visible: items.count < 20
      iconText: root.ctx.icons.plus
      text: root.strings.t("create.addItem")
      fontSize: Style.font.caption
      onClicked: root.addItem()
    }

    Field {
      id: notes
      ctx: root.ctx
      width: parent.width
      label: root.strings.t("create.notes")
      maximumLength: 500
      hasCursor: root.ctx.cursorOn("notes", 0, 0)
      onAccepted: root.ctx.leaveEditor()
    }

    Toggle {
      id: finalToggle
      width: parent.width
      label: root.strings.t("create.final")
      description: root.finalInvoice ? root.strings.t("create.finalOn") : root.strings.t("create.finalOff")
      foreground: root.ctx.foreground
      accent: root.ctx.accent
      fontFamily: root.ctx.fontFamily
      titleSize: Style.font.body
      checked: root.finalInvoice
      hasCursor: root.ctx.cursorOn("final", 0, 0)
      onHovered: function(on) { if (on) root.ctx.pointTo("final", 0, 0) }
      onClicked: root.finalInvoice = !root.finalInvoice
    }

    Txt {
      ctx: root.ctx
      width: parent.width
      visible: root.estimate.filled > 0
      text: root.strings.t("create.estimate")
        .arg(root.ctx.money(root.estimate.subtotal, "", "exact"))
        .arg(root.ctx.money(root.estimate.vat, "", "exact"))
        .arg(root.ctx.money(root.estimate.total, "", "exact"))
      wrapMode: Text.WordWrap
    }

    Row {
      id: submitRow
      spacing: Style.space(8)

      Btn {
        ctx: root.ctx
        stop: "submit"
        stopCol: 0
        iconText: root.ctx.icons.check
        text: root.finalInvoice ? root.strings.t("create.reviewFinal") : root.strings.t("create.reviewDraft")
        enabled: !root.ctx.busy
        onClicked: root.submitInvoice()
      }

      Btn {
        ctx: root.ctx
        stop: "submit"
        stopCol: 1
        text: root.strings.t("create.reset")
        onClicked: root.askReset()
      }
    }
  }

  // ---- Expense ---------------------------------------------------------------
  Column {
    visible: root.kind === "expense"
    width: parent.width
    spacing: Style.space(10)

    Txt {
      ctx: root.ctx
      dim: true
      width: parent.width
      visible: !root.ctx.snapshot.expensesAvailable
      text: root.strings.t("create.expensesUnavailable")
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Field {
      id: expenseDescription
      ctx: root.ctx
      width: parent.width
      label: root.strings.t("create.expenseDescription")
      maximumLength: 300
      hasCursor: root.ctx.cursorOn("xDescription", 0, 0)
      onAccepted: expenseAmount.edit()
    }

    Row {
      id: expenseMoneyRow
      width: parent.width
      spacing: Style.space(8)

      Field {
        id: expenseAmount
        ctx: root.ctx
        width: (parent.width - parent.spacing) / 2
        label: root.strings.t("create.expenseAmount")
        maximumLength: 16
        invalid: text !== "" && Model.normalizeDecimal(text) === ""
        hasCursor: root.ctx.cursorOn("xMoney", 0, 0)
        onAccepted: root.ctx.leaveEditor()
      }

      Field {
        id: expenseDate
        ctx: root.ctx
        width: (parent.width - parent.spacing) / 2
        label: root.strings.t("create.expenseDate")
        maximumLength: 14
        invalid: text !== "" && Model.normalizeDate(text) === ""
        hasCursor: root.ctx.cursorOn("xMoney", 0, 1)
        onAccepted: root.ctx.leaveEditor()
      }
    }

    Item {
      width: parent.width
      implicitHeight: expenseVatGroup.implicitHeight

      Txt {
        id: expenseVatLabel
        ctx: root.ctx
        dim: true
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.strings.t("create.vat")
        font.pixelSize: Style.font.caption
      }

      Seg {
        id: expenseVatGroup
        ctx: root.ctx
        anchors.left: expenseVatLabel.right
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        stop: "xVat"
        value: root.expenseVat
        options: root.vatOptions
        onChanged: function(value) { root.expenseVat = value }
      }
    }

    Row {
      id: expenseMetaRow
      width: parent.width
      spacing: Style.space(8)

      Field {
        id: expenseCategory
        ctx: root.ctx
        width: (parent.width - parent.spacing) / 2
        label: root.strings.t("create.expenseCategory")
        maximumLength: 60
        hasCursor: root.ctx.cursorOn("xMeta", 0, 0)
        onAccepted: root.ctx.leaveEditor()
      }

      Field {
        id: expenseReceipt
        ctx: root.ctx
        width: (parent.width - parent.spacing) / 2
        label: root.strings.t("create.expenseReceipt")
        maximumLength: 40
        hasCursor: root.ctx.cursorOn("xMeta", 0, 1)
        onAccepted: root.ctx.leaveEditor()
      }
    }

    Row {
      id: expenseSubmitRow
      spacing: Style.space(8)

      Btn {
        ctx: root.ctx
        stop: "xSubmit"
        stopCol: 0
        iconText: root.ctx.icons.check
        text: root.strings.t("create.reviewExpense")
        enabled: !root.ctx.busy
        onClicked: root.submitExpense()
      }

      Btn {
        ctx: root.ctx
        stop: "xSubmit"
        stopCol: 1
        text: root.strings.t("create.reset")
        onClicked: root.resetExpense()
      }
    }
  }
}
