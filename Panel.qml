import QtQuick
import QtCore
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Doklad.ai in the bar: an icon with the amount still waiting for payment, and
// a panel with overviews, invoices, quick invoicing, customers and exports.
//
// This item is also the `ctx` every component of the plugin receives: colors,
// formatting, the keyboard cursor, navigation and the confirmation dialog all
// live here so the tabs stay small.
Panel {
  id: root
  moduleName: "gruut.doklad-ai"
  ipcTarget: "gruut.doklad-ai"
  manageIpc: false

  readonly property string pluginVersion: {
    try {
      var manifest = JSON.parse(manifestFile.text())
      return typeof manifest.version === "string" ? manifest.version : ""
    } catch (e) {
      return ""
    }
  }

  FileView {
    id: manifestFile
    path: Qt.resolvedUrl("manifest.json")
    blockLoading: true
    printErrors: false
  }

  // Czech or Slovak, see Strings.qml.
  Strings {
    id: catalog
  }

  Settings {
    id: preferences
    category: "gruut.doklad-ai"
    property bool privacy: false
  }

  Service {
    id: backend
    settings: root.settings
    panelOpen: root.opened
    privacy: root.privacy
    language: catalog.language
  }

  Component.onCompleted: backend.setPeriod(String(setting("defaultHorizon", "month")), 0)

  // ---- Shared context -------------------------------------------------------

  readonly property var strings: catalog
  readonly property var service: backend
  readonly property var snapshot: backend.snapshot
  readonly property bool privacy: preferences.privacy
  readonly property bool busy: backend.busy
  readonly property string language: catalog.language
  readonly property string defaultVatRate: String(setting("defaultVatRate", "21"))

  readonly property color foreground: Commons.Color.popups.text
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.65)
  readonly property bool darkPanel: 0.2126 * foreground.r + 0.7152 * foreground.g + 0.0722 * foreground.b > 0.55
  readonly property color positive: darkPanel ? "#86efac" : "#166534"
  readonly property color warning: darkPanel ? "#fcd34d" : "#92400e"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool verticalBar: bar ? bar.vertical : false
  readonly property color hoverFill: Style.hoverFillFor(foreground, accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, accent)

  readonly property var icons: ({
    refresh: "\udb81\udc50", eye: "\udb80\ude08", eyeOff: "\udb80\ude09", web: "\udb81\udd9f",
    left: "\udb80\udd41", right: "\udb80\udd42", back: "\udb80\udc4d", search: "\udb80\udf49",
    plus: "\udb81\udc15", check: "\udb80\udd2c", close: "\udb80\udd56", download: "\udb80\uddda",
    email: "\udb80\uddee", pdf: "\udb80\ude26", copy: "\udb80\udd8f", trash: "\udb80\uddb4",
    cash: "\udb80\udd14", folder: "\udb81\udf70", webhook: "\udb81\ude2f", send: "\udb81\udc8a",
    cancel: "\udb81\udf3a", invoice: "\udb80\ude19", newInvoice: "\udb81\udf52", people: "\udb80\udc0e",
    chart: "\udb80\udd28", tools: "\udb84\udc64", exportFile: "\udb80\ude07", receipt: "\udb81\udc49"
  })

  // An empty currency means the account's base currency. Privacy mode hides every amount.
  function money(value, currency, mode) {
    if (privacy) return Model.maskedMoney()
    return Model.formatMoney(value, currency || snapshot.baseCurrency, mode || "auto")
  }

  // Confirmation dialogs always show the real amount, also in privacy mode:
  // nobody should approve a payment they cannot read.
  function plainMoney(value, currency) {
    return Model.formatMoney(value, currency || snapshot.baseCurrency, "exact")
  }

  function dateText(iso) {
    var date = Model.parseIso(iso)
    if (date === null) return "\u2014"
    return date.getDate() + ". " + (date.getMonth() + 1) + ". " + date.getFullYear()
  }

  function monthName(index, standalone, shortForm) {
    var locale = Qt.locale(language === "sk" ? "sk_SK" : "cs_CZ")
    var format = shortForm ? Locale.ShortFormat : Locale.LongFormat
    var month = Math.max(0, Math.min(11, index - 1))
    return standalone ? locale.standaloneMonthName(month, format) : locale.monthName(month, format)
  }

  function capitalize(text) {
    return text.length > 0 ? text.charAt(0).toUpperCase() + text.substring(1) : text
  }

  function periodTitle(period) {
    if (!period || period.year === 0) return ""
    if (period.kind === "quarter") return strings.t("period.quarterTitle").arg(period.index).arg(period.year)
    if (period.kind === "year") return strings.t("period.yearTitle").arg(period.year)
    if (period.kind === "ltm") return strings.t("period.ltmTitle").arg(monthName(period.index, false, false)).arg(period.year)
    return capitalize(monthName(period.index, true, false)) + " " + period.year
  }

  function bucketTitle(entry) {
    if (entry.kind === "quarter") return strings.t("period.quarterTitle").arg(entry.index).arg(entry.year)
    return capitalize(monthName(entry.index, true, false)) + " " + entry.year
  }

  function bucketLabel(entry) {
    if (entry.kind === "quarter") return "Q" + entry.index
    return monthName(entry.index, true, true).replace(".", "")
  }

  function ago(seconds) {
    if (!seconds) return ""
    var elapsed = Math.max(0, Math.floor(Date.now() / 1000) - seconds)
    if (elapsed < 90) return strings.t("ago.now")
    if (elapsed < 3600) return strings.t("ago.minutes").arg(Math.round(elapsed / 60))
    if (elapsed < 172800) return strings.t("ago.hours").arg(Math.round(elapsed / 3600))
    return strings.t("ago.days").arg(Math.round(elapsed / 86400))
  }

  function stateText(state) {
    return strings.t("state." + state)
  }

  function stateColor(state) {
    if (state === "paid") return positive
    if (state === "overdue") return urgent
    if (state === "pending") return warning
    return dim
  }

  function dueText(invoice) {
    if (!invoice) return ""
    if (invoice.state !== "pending" && invoice.state !== "overdue") return stateText(invoice.state)
    if (invoice.daysToDue === null) return stateText(invoice.state)
    var days = Math.abs(invoice.daysToDue)
    if (invoice.daysToDue < 0) return strings.tn("due.overdueDays", days).arg(days)
    if (invoice.daysToDue === 0) return strings.t("due.today")
    return strings.tn("due.inDays", days).arg(days)
  }

  function errorText(result) {
    var text = strings.t(Model.errorKey(result.error))
    return result.detail ? text + " (" + result.detail + ")" : text
  }

  // ---- Notices --------------------------------------------------------------

  property string noticeText: ""
  property string noticeKind: "info"

  function notice(text, kind) {
    noticeText = String(text || "")
    noticeKind = kind || "info"
    noticeTimer.interval = noticeKind === "error" ? 12000 : 6000
    if (noticeText !== "") noticeTimer.restart()
    if (panelFlick) panelFlick.contentY = 0
  }

  Timer {
    id: noticeTimer
    onTriggered: root.noticeText = ""
  }

  // ---- Confirmation ---------------------------------------------------------

  property bool confirmOpen: false
  property string confirmMessage: ""
  property string confirmLabel: ""
  property var confirmAction: null

  // Every action that writes to the accounting system goes through here. The
  // dialog opens with "Cancel" selected, so a stray Enter never confirms.
  function ask(message, label, action) {
    confirmMessage = String(message || "").substring(0, 700)
    confirmLabel = label || strings.t("confirm.proceed")
    confirmAction = action
    leaveEditor()
    confirmOpen = true
  }

  function resolveConfirm(accepted) {
    var action = confirmAction
    confirmOpen = false
    confirmAction = null
    if (accepted && typeof action === "function") action()
  }

  // ---- Actions --------------------------------------------------------------

  function act(name, payload, tag) {
    if (backend.run(name, payload, tag)) return true
    notice(strings.t("error.busy"), "info")
    return false
  }

  property int drawerId: 0
  property var detail: null
  property bool detailPending: false
  readonly property bool drawerOpen: drawerId > 0

  function openInvoice(id) {
    if (!id) return
    drawerId = id
    detail = null
    stopKey = "back"
    stopRow = 0
    stopCol = 0
    if (panelFlick) panelFlick.contentY = 0
    reloadDetail()
  }

  function reloadDetail() {
    if (drawerId <= 0) return
    detailPending = !backend.run("invoice-detail", { id: drawerId }, "invoice-detail")
  }

  function closeDrawer() {
    drawerId = 0
    detail = null
    detailPending = false
    stopKey = "tabs"
    stopCol = tabNames.indexOf(tab)
  }

  Connections {
    target: backend
    function onActionFinished(tag, result) { root.handleResult(tag, result) }
    function onAccountViewReset() {
      root.resolveConfirm(false)
      root.closeDrawer()
      root.prefillCustomer = null
      root.invoiceQuery = ""
      createTab.resetInvoice()
      createTab.resetExpense()
      customersTab.resetView()
      toolsTab.webhooks = []
      toolsTab.webhooksLoaded = false
    }
  }

  function handleResult(tag, result) {
    if (!result.ok) {
      // The form asks whether to create the duplicate; everything else is reported here.
      if (!(tag === "create-invoice" && result.error === "duplicate_recent")) notice(errorText(result), "error")
    } else if (tag === "invoice-detail") {
      var parsed = Model.parseDetail(result.detail)
      if (parsed !== null && parsed.id === drawerId) detail = parsed
    } else if (tag === "record-payment") {
      notice(strings.t("done.payment"), "ok")
      reloadDetail()
    } else if (tag === "set-status") {
      notice(strings.t("done.status"), "ok")
      reloadDetail()
    } else if (tag === "send-email") {
      notice(strings.t("done.email"), "ok")
    } else if (tag === "delete-draft") {
      notice(strings.t("done.deleted"), "ok")
      closeDrawer()
    } else if (tag === "download-pdf") {
      notice(strings.t("done.file").arg(Model.plainText(result.file, 80)), "ok")
    } else if (tag === "bulk-pdf") {
      notice(strings.t("done.zip").arg(Number(result.count) || 0).arg(Model.plainText(result.file, 80)), "ok")
    } else if (tag === "export") {
      notice(strings.t("done.file").arg(Model.plainText(result.file, 80)), "ok")
    } else if (tag === "create-expense") {
      notice(strings.t("done.expense"), "ok")
    } else if (tag === "create-customer") {
      notice(strings.t("done.customer").arg(Model.plainText(result.name, 80)), "ok")
    } else if (tag === "clear-local-data") {
      notice(strings.t("done.localDataCleared"), "ok")
    } else if (tag === "copy") {
      notice(strings.t("done.copied"), "ok")
    }
    if (detailPending && tag !== "invoice-detail") reloadDetail()
  }

  // ---- Navigation -----------------------------------------------------------

  readonly property var tabNames: ["overview", "invoices", "create", "customers", "tools"]
  property string tab: "overview"
  property string invoiceFilter: "all"
  property string invoiceQuery: ""
  property var prefillCustomer: null

  function setTab(name) {
    if (tabNames.indexOf(name) === -1) return
    if (drawerOpen) closeDrawer()
    tab = name
    stopKey = "tabs"
    stopRow = 0
    stopCol = tabNames.indexOf(name)
    if (panelFlick) panelFlick.contentY = 0
  }

  function showInvoices(filter, query) {
    invoiceFilter = Model.FILTERS.indexOf(filter) !== -1 ? filter : "all"
    invoiceQuery = Model.plainText(query, 60)
    setTab("invoices")
  }

  function newInvoiceFor(customer) {
    if (!customer || !customer.id) return
    prefillCustomer = { id: customer.id, name: customer.name }
    setTab("create")
  }

  function stepPeriod(direction) {
    backend.setPeriod(backend.horizon, backend.offset + direction)
  }

  function selectBucket(entry) {
    var today = Model.parseIso(snapshot.today)
    if (today === null || !entry || entry.future) return
    var quarter = entry.kind === "quarter"
    var offset = quarter
      ? (entry.year * 4 + entry.index - 1) - (today.getFullYear() * 4 + Math.floor(today.getMonth() / 3))
      : (entry.year * 12 + entry.index - 1) - (today.getFullYear() * 12 + today.getMonth())
    if (offset <= 0) backend.setPeriod(quarter ? "quarter" : "month", offset)
  }

  function togglePrivacy() {
    preferences.privacy = !preferences.privacy
  }

  function openWeb() {
    act("open", { target: "web" }, "open")
  }

  // Path of a script shipped with the plugin, shortened to ~ for display and copying.
  function scriptPath(relative) {
    var path = decodeURIComponent(String(Qt.resolvedUrl(relative)).replace(/^file:\/\//, ""))
    var home = String(Quickshell.env("HOME") || "")
    return home !== "" && path.indexOf(home + "/") === 0 ? "~" + path.substring(home.length) : path
  }

  readonly property string setupCommand: scriptPath("setup-env.sh")
  readonly property string relayCommand: scriptPath("webhook-relay/relay-setup.sh")

  // ---- Keyboard and pointer cursor ------------------------------------------
  //
  // The panel is a vertical list of "stops" (header, tabs, then whatever the
  // visible tab declares). j/k walk the stops and the rows inside one, h/l walk
  // the columns of a stop, Enter activates.

  property bool cursorActive: false
  property bool pointerUnlocked: false
  property string stopKey: "tabs"
  property int stopRow: 0
  property int stopCol: 0

  property Item activeEditor: null
  readonly property bool editing: activeEditor !== null

  readonly property Item content: panel.loadedContent
  readonly property Item panelFlick: content ? content.panelFlick : null
  readonly property Item activeView: content ? content.activeView : null
  readonly property bool tabsVisible: snapshot.hasData
  readonly property bool bannerAction: !snapshot.hasData && (snapshot.status === "unconfigured" || snapshot.status === "misconfigured")

  readonly property var allStops: {
    var list = [{ key: "header", rows: 1, cols: 3 }]
    if (bannerAction) list.push({ key: "banner", rows: 1, cols: 1 })
    if (!snapshot.hasData && snapshot.status !== "loading") list.push({ key: "clear-cache", rows: 1, cols: 1 })
    if (!tabsVisible) return list
    list.push({ key: "tabs", rows: 1, cols: tabNames.length })
    var extra = activeView ? activeView.stops : []
    for (var i = 0; i < extra.length; i++) {
      var rows = extra[i].rows === undefined ? 1 : extra[i].rows
      var cols = extra[i].cols === undefined ? 1 : extra[i].cols
      if (rows > 0 && cols > 0) list.push({ key: extra[i].key, rows: rows, cols: cols })
    }
    return list
  }

  onAllStopsChanged: clampCursor()

  function stopIndex() {
    for (var i = 0; i < allStops.length; i++) if (allStops[i].key === stopKey) return i
    return -1
  }

  function clampCursor() {
    var index = stopIndex()
    if (index < 0) {
      index = Math.min(allStops.length - 1, tabsVisible ? (bannerAction ? 2 : 1) : 0)
      stopKey = allStops[index].key
      stopRow = 0
      stopCol = stopKey === "tabs" ? tabNames.indexOf(tab) : 0
    }
    stopRow = Math.max(0, Math.min(allStops[index].rows - 1, stopRow))
    stopCol = Math.max(0, Math.min(allStops[index].cols - 1, stopCol))
  }

  function cursorOn(key, row, col) {
    return cursorActive && stopKey === key && stopRow === row && stopCol === col
  }

  function cursorCol(key) {
    return cursorActive && stopKey === key ? stopCol : -1
  }

  function cursorRow(key) {
    return cursorActive && stopKey === key ? stopRow : -1
  }

  function pointTo(key, row, col) {
    if (!pointerUnlocked || editing || confirmOpen) return
    cursorActive = true
    stopKey = key
    stopRow = row
    stopCol = col
  }

  function moveCursor(dx, dy) {
    clampCursor()
    var index = stopIndex()
    var stop = allStops[index]
    if (dx !== 0) stopCol = Math.max(0, Math.min(stop.cols - 1, stopCol + dx))
    if (dy !== 0) {
      var row = stopRow + dy
      if (row >= 0 && row < stop.rows) {
        stopRow = row
      } else {
        var next = index + dy
        if (next < 0 || next >= allStops.length) return
        var target = allStops[next]
        stopKey = target.key
        stopRow = dy < 0 ? target.rows - 1 : 0
        stopCol = target.key === "tabs" ? tabNames.indexOf(tab) : Math.min(stopCol, target.cols - 1)
      }
    }
    scrollCursorIntoView()
  }

  function activateCursor() {
    clampCursor()
    if (stopKey === "header") {
      if (stopCol === 0) backend.forceRefresh()
      else if (stopCol === 1) togglePrivacy()
      else openWeb()
    } else if (stopKey === "banner") {
      act("copy", { text: setupCommand }, "copy")
    } else if (stopKey === "clear-cache") {
      toolsTab.clearLocalData()
    } else if (stopKey === "tabs") {
      setTab(tabNames[stopCol])
    } else if (activeView) {
      activeView.activate(stopKey, stopRow, stopCol)
    }
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var margin = Style.space(8)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin) {
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
      }
    })
  }

  function scrollCursorIntoView() {
    if (!content) return
    if (stopKey === "header" || stopKey === "banner") panelFlick.contentY = 0
    else if (stopKey === "clear-cache") scrollItemIntoView(clearCacheButton)
    else if (stopKey === "tabs") scrollItemIntoView(content.tabsItem)
    else if (activeView) scrollItemIntoView(activeView.cursorItem(stopKey, stopRow))
  }

  function editorFocus(item, focused) {
    if (focused) {
      activeEditor = item
      scrollItemIntoView(item)
    } else if (activeEditor === item) {
      activeEditor = null
    }
  }

  // Hands the keyboard back from a text field to the panel shortcuts.
  function leaveEditor() {
    if (content) content.forceActiveFocus()
    activeEditor = null
  }

  function handleTextKey(text, modifiers) {
    if (modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
    var index = "12345".indexOf(text)
    if (text.length === 1 && index !== -1) {
      if (tabsVisible) setTab(tabNames[index])
    } else if (text === "r" || text === "R") {
      backend.forceRefresh()
    } else if (text === "p" || text === "P") {
      togglePrivacy()
    } else if (text === "o" || text === "O") {
      openWeb()
    } else if (text === "n" || text === "N") {
      if (tabsVisible) setTab("create")
    } else if (text === "/") {
      if (!tabsVisible) return
      if (drawerOpen) closeDrawer()
      if (!activeView || !activeView.hasSearch) setTab("invoices")
      // Deferred, so the "/" that got us here is not typed into the field.
      Qt.callLater(function() { if (root.activeView && root.activeView.hasSearch) root.activeView.focusSearch() })
    }
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: root.panelFlick
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      pointerUnlocked = false
      pointerGate.reset()
      backend.refresh()
      Qt.callLater(function() {
        if (root.panelFlick) root.panelFlick.contentY = 0
        if (root.content) root.content.forceActiveFocus()
      })
    } else if (confirmOpen) {
      resolveConfirm(false)
    }
  }

  // ---- Bar ------------------------------------------------------------------

  readonly property string statusLabel: strings.t("status." + (backend.loading && !snapshot.hasData ? "loading" : snapshot.status))

  readonly property string barLabel: {
    if (verticalBar || !snapshot.hasData) return ""
    var mode = String(setting("barLabelMode", "unpaid"))
    var figures = snapshot.bar
    if (mode === "overdue_count") return figures.overdueCount > 0 ? String(figures.overdueCount) : ""
    var amount = mode === "unpaid" ? figures.unpaidTotal
      : (mode === "month" ? figures.monthInvoiced : (mode === "quarter" ? figures.quarterInvoiced : -1))
    if (amount < 0 || (mode === "unpaid" && amount === 0)) return ""
    return privacy ? Model.maskedMoney() : Model.formatCompact(amount)
  }

  readonly property string heroMeta: {
    if (!snapshot.hasData) return ""
    var figures = snapshot.bar
    if (figures.unpaidCount === 0) return strings.t("hero.allPaid")
    var text = strings.t("hero.unpaid").arg(money(figures.unpaidTotal, "", "round")).arg(figures.unpaidCount)
    if (figures.overdueCount > 0) text += " \u00b7 " + strings.tn("hero.overdue", figures.overdueCount).arg(figures.overdueCount)
    return text
  }

  readonly property string barTooltip: {
    var text = "Doklad.ai \u00b7 " + statusLabel
    if (heroMeta !== "") text += " \u00b7 " + heroMeta
    return Model.neutralizeMarkup(text, 160)
  }

  readonly property string bannerText: {
    var status = snapshot.status
    if (status === "loading") return snapshot.hasData ? "" : strings.t("banner.loading")
    if (status === "unconfigured") return strings.t("banner.unconfigured").arg(setupCommand)
    if (status === "misconfigured") return strings.t(Model.errorKey(snapshot.error)) + "\n" + strings.t("banner.rerunSetup").arg(setupCommand)
    if (status === "unauthorized") return strings.t("banner.unauthorized").arg(setupCommand)
    if (status === "offline") {
      return snapshot.hasData ? strings.t("banner.offlineStale").arg(ago(snapshot.fetchedAt)) : strings.t("banner.offline")
    }
    if (status === "error") {
      var text = strings.t(Model.errorKey(snapshot.error))
      return snapshot.errorDetail !== "" ? text + " (" + snapshot.errorDetail + ")" : text
    }
    if (snapshot.stale) return strings.t("banner.stale").arg(ago(snapshot.fetchedAt))
    if (snapshot.truncated) return strings.t("banner.truncated")
    return ""
  }
  readonly property bool bannerSerious: ["unconfigured", "misconfigured", "unauthorized", "error"].indexOf(snapshot.status) !== -1

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { backend.forceRefresh(); return "ok" }
    function togglePrivacy(): string { root.togglePrivacy(); return root.privacy ? "on" : "off" }
    function status(): string { return root.snapshot.status }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelText: root.barLabel
    slotSize: root.barLabel !== ""
      ? (Style.bar.iconCanvas + barLabelMetrics.advanceWidth(root.barLabel) + Style.space(22))
      : Style.bar.iconSlot
    tooltipText: root.barTooltip

    iconComponent: Component {
      Item {
        DokladIcon {
          x: (parent.width - width) / 2
          y: (parent.height - height) / 2
          iconSize: button.iconSize
          color: root.bannerSerious ? root.urgent : root.barForeground
          badge: root.snapshot.hasData && root.snapshot.bar.unpaidCount > 0
          badgeColor: root.snapshot.bar.overdueCount > 0 ? root.urgent : root.accent
          dimmed: !root.snapshot.hasData
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.togglePrivacy()
      else if (buttonCode === Qt.MiddleButton) backend.forceRefresh()
      else root.toggle()
    }
  }

  FontMetrics {
    id: barLabelMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.bar.iconFont
  }

  // ---- Panel ----------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(500))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(800))

    content: PanelKeyCatcher {
      id: keyCatcher

      property alias panelFlick: panelFlick
      property alias tabsItem: tabBar
      readonly property Item activeView: !root.tabsVisible ? null
        : (root.drawerOpen ? drawer
        : (root.tab === "invoices" ? invoicesTab
        : (root.tab === "create" ? createTab
        : (root.tab === "customers" ? customersTab
        : (root.tab === "tools" ? toolsTab : overviewTab)))))

      // Room for the confirmation dialog even when the visible tab is short.
      implicitHeight: Math.max(mainColumn.implicitHeight, root.confirmOpen ? Style.space(300) : 0)
      anchors.fill: parent
      blocked: root.editing || root.confirmOpen

      Keys.onPressed: function(event) {
        if (!root.confirmOpen) return
        // Nothing reaches the panel behind an open dialog.
        confirmDialog.handleKey(event)
        event.accepted = true
      }

      HoverHandler {
        onPointChanged: {
          if (!root.pointerUnlocked && pointerGate.moved(keyCatcher, point.position)) root.pointerUnlocked = true
        }
      }

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) {
          root.cursorActive = true
          root.clampCursor()
          root.scrollCursorIntoView()
          return
        }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: {
        if (root.drawerOpen) root.closeDrawer()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text, modifiers) { root.handleTextKey(text, modifiers) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: mainColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height && !root.confirmOpen
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: mainColumn
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Doklad.ai"
            detail: Model.neutralizeMarkup(root.statusLabel, 32)
            meta: Model.neutralizeMarkup(root.heroMeta, 96)
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.snapshot.hasData ? 1.0 : 0.55

            iconComponent: Component {
              DokladIcon {
                iconSize: Style.font.display
                color: root.bannerSerious ? root.urgent : root.accent
                badge: root.snapshot.hasData && root.snapshot.bar.unpaidCount > 0
                badgeColor: root.snapshot.bar.overdueCount > 0 ? root.urgent : root.accent
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.space(8)

                PanelActionButton {
                  iconText: root.icons.refresh
                  tooltipText: root.strings.t("action.refresh")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  size: Style.space(26)
                  enabled: !backend.loading
                  opacity: enabled ? 1.0 : 0.45
                  hasCursor: root.cursorOn("header", 0, 0)
                  onHovered: function(on) { if (on) root.pointTo("header", 0, 0) }
                  onClicked: backend.forceRefresh()
                }

                PanelActionButton {
                  iconText: root.privacy ? root.icons.eyeOff : root.icons.eye
                  tooltipText: root.privacy ? root.strings.t("action.showAmounts") : root.strings.t("action.hideAmounts")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  size: Style.space(26)
                  hasCursor: root.cursorOn("header", 0, 1)
                  onHovered: function(on) { if (on) root.pointTo("header", 0, 1) }
                  onClicked: root.togglePrivacy()
                }

                PanelActionButton {
                  iconText: root.icons.web
                  tooltipText: root.strings.t("action.openWeb")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  size: Style.space(26)
                  hasCursor: root.cursorOn("header", 0, 2)
                  onHovered: function(on) { if (on) root.pointTo("header", 0, 2) }
                  onClicked: root.openWeb()
                }
              }
            }
          }

          // Result of the last action. Click to dismiss.
          BorderSurface {
            id: noticeBox
            visible: root.noticeText !== ""
            width: parent.width
            implicitHeight: noticeLabel.implicitHeight + Style.space(18)
            radius: Style.cornerRadius
            readonly property color tint: root.noticeKind === "error" ? root.urgent
              : (root.noticeKind === "ok" ? root.positive : root.foreground)
            color: Qt.rgba(tint.r, tint.g, tint.b, 0.10)
            borderSpec: Border.flat(Qt.rgba(tint.r, tint.g, tint.b, 0.38), 1)

            Txt {
              id: noticeLabel
              ctx: root
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              text: root.noticeText
              color: root.noticeKind === "info" ? root.foreground : noticeBox.tint
              wrapMode: Text.WordWrap
            }

            TapHandler { onTapped: root.noticeText = "" }
          }

          // Connection and configuration state.
          BorderSurface {
            visible: root.bannerText !== ""
            width: parent.width
            implicitHeight: bannerColumn.implicitHeight + Style.space(20)
            radius: Style.cornerRadius
            readonly property color tint: root.bannerSerious ? root.urgent : root.foreground
            color: Qt.rgba(tint.r, tint.g, tint.b, root.bannerSerious ? 0.10 : 0.04)
            borderSpec: Border.flat(Qt.rgba(tint.r, tint.g, tint.b, root.bannerSerious ? 0.35 : 0.12), 1)

            Column {
              id: bannerColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              Txt {
                ctx: root
                width: parent.width
                text: root.bannerText
                color: root.bannerSerious ? root.urgent : root.dim
                wrapMode: Text.WordWrap
              }

              Btn {
                ctx: root
                stop: "banner"
                visible: root.bannerAction
                iconText: root.icons.copy
                text: root.strings.t("action.copyCommand")
                onClicked: root.act("copy", { text: root.setupCommand }, "copy")
              }

              Btn {
                id: clearCacheButton
                ctx: root
                stop: "clear-cache"
                visible: !root.snapshot.hasData && root.snapshot.status !== "loading"
                enabled: !root.busy
                text: root.strings.t("tools.clearLocalData")
                onClicked: toolsTab.clearLocalData()
              }
            }
          }

          Seg {
            id: tabBar
            ctx: root
            visible: root.tabsVisible
            width: parent.width
            stop: "tabs"
            fontSize: Style.font.bodySmall
            value: root.drawerOpen ? "invoices" : root.tab
            options: [
              { value: "overview", icon: root.icons.chart, label: root.strings.t("tab.overview") },
              { value: "invoices", icon: root.icons.invoice, label: root.strings.t("tab.invoices") },
              { value: "create", icon: root.icons.newInvoice, label: root.strings.t("tab.create") },
              { value: "customers", icon: root.icons.people, label: root.strings.t("tab.customers") },
              { value: "tools", icon: root.icons.tools, label: root.strings.t("tab.tools") }
            ]
            onChanged: function(value) { root.setTab(value) }
          }

          Item {
            visible: root.tabsVisible
            width: parent.width
            implicitHeight: keyCatcher.activeView ? keyCatcher.activeView.implicitHeight : 0

            OverviewTab {
              id: overviewTab
              ctx: root
              width: parent.width
              visible: keyCatcher.activeView === overviewTab
            }

            InvoicesTab {
              id: invoicesTab
              ctx: root
              width: parent.width
              visible: keyCatcher.activeView === invoicesTab
            }

            InvoiceDrawer {
              id: drawer
              ctx: root
              width: parent.width
              visible: keyCatcher.activeView === drawer
            }

            CreateTab {
              id: createTab
              ctx: root
              width: parent.width
              visible: keyCatcher.activeView === createTab
            }

            CustomersTab {
              id: customersTab
              ctx: root
              width: parent.width
              visible: keyCatcher.activeView === customersTab
            }

            ToolsTab {
              id: toolsTab
              ctx: root
              width: parent.width
              visible: keyCatcher.activeView === toolsTab
            }
          }

          Txt {
            ctx: root
            dim: true
            width: parent.width
            visible: root.snapshot.hasData || root.pluginVersion !== ""
            text: {
              var parts = []
              if (root.pluginVersion !== "") parts.push("v" + root.pluginVersion)
              if (root.snapshot.hasData) {
                if (root.busy) parts.push(root.strings.t("footer.working"))
                else if (root.snapshot.fetchedAt > 0) parts.push(root.strings.t("footer.updated").arg(root.ago(root.snapshot.fetchedAt)))
                parts.push(root.strings.t("footer.keys"))
              }
              return parts.join("  \u00b7  ")
            }
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 10
        opened: root.confirmOpen
        message: root.confirmMessage
        cancelText: root.strings.t("confirm.cancel")
        confirmText: root.confirmLabel
        background: Commons.Color.popups.background
        foreground: root.foreground
        selectedText: root.accent
        fontFamily: root.fontFamily
        // Open on "Cancel": confirming always takes a deliberate second key.
        onOpenedChanged: if (opened) selectedIndex = 0
        onCanceled: root.resolveConfirm(false)
        onConfirmed: root.resolveConfirm(true)
      }
    }
  }
}
