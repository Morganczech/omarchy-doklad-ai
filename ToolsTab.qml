import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Accounting exports and PDF archives for the selected period, and the state
// of the optional webhook relay.
Column {
  id: root

  required property var ctx
  readonly property var strings: ctx.strings
  readonly property var period: ctx.snapshot.period
  readonly property var relay: ctx.snapshot.relay

  readonly property var formats: ["csv", "isdoc", "pohoda", "money-s3"]
  readonly property int bulkLimit: 200
  readonly property var periodInvoices: visible ? Model.invoicesInRange(ctx.snapshot.invoices, period.from, period.to) : []

  property var webhooks: []
  property bool webhooksLoaded: false

  readonly property bool hasSearch: false
  readonly property var stops: [
    { key: "period", cols: 2 },
    { key: "export", cols: formats.length },
    { key: "files", cols: 2 },
    { key: "hooks", cols: 2 }
  ]

  function activate(key, row, col) {
    if (key === "period") ctx.stepPeriod(col === 0 ? -1 : 1)
    else if (key === "export") exportPeriod(formats[col])
    else if (key === "files") { if (col === 0) bulkPdf(); else ctx.act("open", { target: "downloads" }, "open") }
    else if (key === "hooks") { if (col === 0) ctx.act("list-webhooks", {}, "list-webhooks"); else registerWebhook() }
  }

  function cursorItem(key, row) {
    if (key === "period") return periodRow
    if (key === "export") return exportGroup
    if (key === "files") return fileRow
    return hookRow
  }

  function periodLabel() {
    return period.from + "_" + period.to
  }

  function exportPeriod(format) {
    if (period.from === "" || period.to === "") return
    ctx.act("export", { format: format, from: period.from, to: period.to, label: periodLabel() }, "export")
  }

  function bulkPdf() {
    var ids = periodInvoices.slice(0, bulkLimit).map(function(invoice) { return invoice.id })
    if (ids.length === 0) { ctx.notice(strings.t("tools.noInvoices"), "info"); return }
    ctx.act("bulk-pdf", { ids: ids, label: periodLabel() }, "bulk-pdf")
  }

  function registerWebhook() {
    if (!relay.configured) { ctx.notice(strings.t("error.relay_not_configured"), "error"); return }
    ctx.ask(strings.t("confirm.registerWebhook"), strings.t("confirm.registerWebhookButton"),
      function() { root.ctx.act("register-webhook", {}, "register-webhook") })
  }

  Connections {
    target: root.ctx.service
    function onActionFinished(tag, result) {
      if ((tag !== "list-webhooks" && tag !== "register-webhook") || !result.ok) return
      root.webhooks = Model.parseWebhooks(result.webhooks)
      root.webhooksLoaded = true
      if (tag === "register-webhook") {
        root.ctx.notice(result.secretStored === true
          ? root.strings.t("done.webhookSecret").arg(root.ctx.relayCommand + " secret")
          : root.strings.t("done.webhookNoSecret"), result.secretStored === true ? "ok" : "info")
      }
    }
  }

  spacing: Style.space(10)

  PanelSectionHeader {
    text: root.strings.t("tools.exportTitle")
    foreground: root.ctx.foreground
    fontFamily: root.ctx.fontFamily
  }

  Item {
    id: periodRow
    width: parent.width
    implicitHeight: Math.max(previous.implicitHeight, periodText.implicitHeight)

    Btn {
      id: previous
      ctx: root.ctx
      stop: "period"
      stopCol: 0
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      iconText: root.ctx.icons.left
      tooltipText: root.strings.t("period.previous")
      onClicked: root.ctx.stepPeriod(-1)
    }

    Column {
      id: periodText
      anchors.left: previous.right
      anchors.right: next.left
      anchors.margins: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Txt {
        ctx: root.ctx
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: root.ctx.periodTitle(root.period)
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Txt {
        ctx: root.ctx
        dim: true
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: root.ctx.dateText(root.period.from) + " \u2013 " + root.ctx.dateText(root.period.to)
          + " \u00b7 " + root.strings.tn("invoices.count", root.periodInvoices.length).arg(root.periodInvoices.length)
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Btn {
      id: next
      ctx: root.ctx
      stop: "period"
      stopCol: 1
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      iconText: root.ctx.icons.right
      tooltipText: root.strings.t("period.next")
      enabled: root.ctx.service.offset < 0
      onClicked: root.ctx.stepPeriod(1)
    }
  }

  Seg {
    id: exportGroup
    ctx: root.ctx
    width: parent.width
    stop: "export"
    enabled: !root.ctx.busy
    fontSize: Style.font.bodySmall
    options: [
      { value: "csv", icon: root.ctx.icons.exportFile, label: "CSV" },
      { value: "isdoc", icon: root.ctx.icons.exportFile, label: "ISDOC" },
      { value: "pohoda", icon: root.ctx.icons.exportFile, label: "Pohoda XML" },
      { value: "money-s3", icon: root.ctx.icons.exportFile, label: "Money S3" }
    ]
    onChanged: function(value) { root.exportPeriod(value) }
  }

  Row {
    id: fileRow
    spacing: Style.space(8)

    Btn {
      ctx: root.ctx
      stop: "files"
      stopCol: 0
      iconText: root.ctx.icons.pdf
      text: root.strings.t("tools.bulkPdf").arg(Math.min(root.periodInvoices.length, root.bulkLimit))
      enabled: !root.ctx.busy && root.periodInvoices.length > 0
      onClicked: root.bulkPdf()
    }

    Btn {
      ctx: root.ctx
      stop: "files"
      stopCol: 1
      iconText: root.ctx.icons.folder
      text: root.strings.t("tools.openFolder")
      onClicked: root.ctx.act("open", { target: "downloads" }, "open")
    }
  }

  Txt {
    ctx: root.ctx
    dim: true
    width: parent.width
    text: root.periodInvoices.length > root.bulkLimit
      ? root.strings.t("tools.bulkLimit").arg(root.bulkLimit)
      : root.strings.t("tools.filesHint")
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  PanelSeparator { foreground: root.ctx.foreground }

  PanelSectionHeader {
    text: root.strings.t("tools.webhookTitle")
    foreground: root.ctx.foreground
    fontFamily: root.ctx.fontFamily
  }

  Txt {
    ctx: root.ctx
    width: parent.width
    color: !root.relay.configured ? root.ctx.dim : (root.relay.ok ? root.ctx.positive : root.ctx.urgent)
    text: {
      if (!root.relay.configured) return root.strings.t("tools.relayOff").arg(root.ctx.relayCommand + " deploy")
      if (!root.relay.ok) {
        return root.strings.t("tools.relayError").arg(root.strings.t(Model.errorKey(root.relay.error !== "" ? root.relay.error : "relay_error")))
      }
      return root.relay.lastEventAt > 0
        ? root.strings.t("tools.relayOkEvent").arg(root.ctx.ago(root.relay.lastEventAt))
        : root.strings.t("tools.relayOk")
    }
    wrapMode: Text.WordWrap
  }

  Txt {
    ctx: root.ctx
    dim: true
    width: parent.width
    visible: root.relay.configured
    text: root.relay.webhookSecretStored ? root.strings.t("tools.secretStored") : root.strings.t("tools.secretMissing")
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Row {
    id: hookRow
    spacing: Style.space(8)

    Btn {
      ctx: root.ctx
      stop: "hooks"
      stopCol: 0
      iconText: root.ctx.icons.webhook
      text: root.strings.t("tools.listWebhooks")
      enabled: !root.ctx.busy
      onClicked: root.ctx.act("list-webhooks", {}, "list-webhooks")
    }

    Btn {
      ctx: root.ctx
      stop: "hooks"
      stopCol: 1
      iconText: root.ctx.icons.plus
      text: root.strings.t("tools.registerWebhook")
      enabled: !root.ctx.busy && root.relay.configured
      onClicked: root.registerWebhook()
    }
  }

  Txt {
    ctx: root.ctx
    dim: true
    width: parent.width
    visible: root.webhooksLoaded && root.webhooks.length === 0
    text: root.strings.t("tools.noWebhooks")
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: root.webhooks

    Column {
      required property var modelData
      width: parent.width
      spacing: Style.space(1)

      Txt {
        ctx: root.ctx
        width: parent.width
        text: modelData.url
        color: modelData.active ? root.ctx.foreground : root.ctx.dim
        elide: Text.ElideMiddle
      }

      Txt {
        ctx: root.ctx
        dim: true
        width: parent.width
        text: (modelData.active ? root.strings.t("tools.hookActive") : root.strings.t("tools.hookInactive"))
          + (modelData.events.length > 0 ? " \u00b7 " + modelData.events.join(", ") : "")
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  Txt {
    ctx: root.ctx
    dim: true
    width: parent.width
    text: root.strings.t("tools.webhookHint")
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
