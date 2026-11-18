.pragma library

// Pure helpers for the Doklad.ai panel: sanitizing what the backend returns,
// filtering lists and formatting numbers. No Qt APIs are used here, so the
// file is unit-tested with plain node (tests/model.test.mjs).

var HORIZONS = ["month", "quarter", "year", "ltm"]
var STATES = ["draft", "cancelled", "paid", "overdue", "pending"]
var KINDS = ["invoice", "proforma", "credit_note"]
var FILTERS = ["all", "unpaid", "overdue", "paid", "draft"]
var STATUSES = ["ready", "unconfigured", "misconfigured", "unauthorized", "offline", "error"]

var KNOWN_ERRORS = {
  unconfigured: 1, insecure_env: 1, invalid_env: 1, storage_unsafe: 1, storage_unavailable: 1,
  storage_too_large: 1, unauthorized: 1, forbidden: 1, not_found: 1, conflict: 1, validation: 1,
  rate_limited: 1, service_unavailable: 1, server_error: 1, offline: 1, timeout: 1, tls_error: 1,
  response_too_large: 1, bad_response: 1, invalid_input: 1, invalid_date: 1, invalid_amount: 1,
  invalid_email: 1, invalid_ico: 1, not_a_draft: 1, duplicate_recent: 1, create_uncertain: 1,
  create_not_found: 1, customer_exists: 1, export_empty: 1, relay_not_configured: 1,
  relay_invalid_url: 1, relay_unauthorized: 1, relay_error: 1, relay_not_ready: 1, relay_offline: 1,
  relay_timeout: 1, relay_tls_error: 1, webhook_exists: 1, open_failed: 1, copy_failed: 1,
  no_data: 1, busy: 1
}

var KNOWN_EVENTS = { "invoice.created": 1, "invoice.paid": 1, "invoice.overdue": 1, "customer.created": 1 }

// ---- Text safety ----------------------------------------------------------

function plainText(value, maxLen) {
  var limit = (typeof maxLen === "number" && maxLen > 0) ? maxLen : 120
  if (typeof value !== "string" && typeof value !== "number") return ""
  var cleaned = String(value)
    .replace(/[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
  if (cleaned.length > limit) return cleaned.substring(0, limit - 1) + "\u2026"
  return cleaned
}

// Shared shell components (hero, tooltips, confirm dialog) own their Text
// items, so text passed to them gets its markup characters replaced as well.
function neutralizeMarkup(value, maxLen) {
  return plainText(value, maxLen).replace(/</g, "\u2039").replace(/>/g, "\u203a").replace(/&/g, "\uff06")
}

function num(value, fallback) {
  return (typeof value === "number" && isFinite(value)) ? value : (fallback === undefined ? 0 : fallback)
}

function count(value) {
  var n = num(value, 0)
  return n > 0 ? Math.floor(n) : 0
}

function idOf(value) {
  return (typeof value === "number" && isFinite(value) && value > 0 && Math.floor(value) === value) ? value : 0
}

function oneOf(value, allowed, fallback) {
  return allowed.indexOf(value) !== -1 ? value : fallback
}

function isoDate(value) {
  return (typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value)) ? value : ""
}

function rows(value, limit) {
  return Array.isArray(value) ? value.slice(0, limit) : []
}

function obj(value) {
  return (value && typeof value === "object" && !Array.isArray(value)) ? value : {}
}

// ---- Snapshot parsing -----------------------------------------------------

function emptySnapshot(status) {
  return {
    ok: false, status: status || "error", error: "", errorDetail: "", hasData: false, stale: false,
    fetchedAt: 0, today: "", baseCurrency: "CZK",
    bar: { unpaidTotal: 0, unpaidCount: 0, overdueTotal: 0, overdueCount: 0, draftCount: 0,
           monthInvoiced: 0, quarterInvoiced: 0, quarterIndex: 1 },
    period: emptyPeriod(),
    chart: [],
    turnover: { year: 0, yearToDate: 0, last12Months: 0, limit: 0 },
    invoices: [], invoiceCounts: { all: 0, unpaid: 0, overdue: 0, paid: 0, draft: 0 },
    customers: [], customerCount: 0, expensesAvailable: true, truncated: false, events: [],
    relay: { configured: false, ok: false, error: "", checkedAt: 0, lastEventAt: 0, webhookSecretStored: false }
  }
}

function emptyPeriod() {
  return {
    horizon: "month", offset: 0, kind: "month", year: 0, index: 0, from: "", to: "",
    invoiced: { subtotal: 0, total: 0, count: 0 }, collected: { total: 0, count: 0 },
    pending: { total: 0, count: 0 }, overdue: { total: 0, count: 0 },
    expenses: { subtotal: 0, total: 0, count: 0 }, net: 0,
    vat: { output: 0, input: 0, balance: 0 }, trend: { previous: null, yoy: null }, foreign: []
  }
}

function amountCount(value) {
  var raw = obj(value)
  return { total: num(raw.total), count: count(raw.count) }
}

function trendValue(value) {
  return (typeof value === "number" && isFinite(value)) ? value : null
}

function parsePeriod(value) {
  var raw = obj(value)
  var invoiced = obj(raw.invoiced), expenses = obj(raw.expenses), vat = obj(raw.vat), trend = obj(raw.trend)
  return {
    horizon: oneOf(raw.horizon, HORIZONS, "month"),
    offset: Math.min(0, Math.round(num(raw.offset))),
    kind: oneOf(raw.kind, HORIZONS, "month"),
    year: count(raw.year), index: count(raw.index),
    from: isoDate(raw.from), to: isoDate(raw.to),
    invoiced: { subtotal: num(invoiced.subtotal), total: num(invoiced.total), count: count(invoiced.count) },
    collected: amountCount(raw.collected),
    pending: amountCount(raw.pending),
    overdue: amountCount(raw.overdue),
    expenses: { subtotal: num(expenses.subtotal), total: num(expenses.total), count: count(expenses.count) },
    net: num(raw.net),
    vat: { output: num(vat.output), input: num(vat.input), balance: num(vat.balance) },
    trend: { previous: trendValue(trend.previous), yoy: trendValue(trend.yoy) },
    foreign: rows(raw.foreign, 8).map(function(item) {
      var entry = obj(item)
      return { currency: plainText(entry.currency, 3), total: num(entry.total), count: count(entry.count) }
    }).filter(function(item) { return item.currency !== "" })
  }
}

function parseInvoice(value) {
  var raw = obj(value)
  var id = idOf(raw.id)
  if (!id) return null
  return {
    id: id,
    number: plainText(raw.number, 40),
    customerId: idOf(raw.customerId),
    customerName: plainText(raw.customerName, 80),
    issueDate: isoDate(raw.issueDate), dueDate: isoDate(raw.dueDate),
    status: plainText(raw.status, 20),
    state: oneOf(raw.state, STATES, "pending"),
    kind: oneOf(raw.kind, KINDS, "invoice"),
    total: num(raw.total), open: num(raw.open),
    currency: plainText(raw.currency, 3) || "CZK",
    daysToDue: (typeof raw.daysToDue === "number" && isFinite(raw.daysToDue)) ? Math.round(raw.daysToDue) : null,
    variableSymbol: plainText(raw.variableSymbol, 20)
  }
}

function parseCustomer(value) {
  var raw = obj(value)
  var id = idOf(raw.id)
  if (!id) return null
  return {
    id: id, name: plainText(raw.name, 80), ico: plainText(raw.ico, 12), dic: plainText(raw.dic, 16),
    email: plainText(raw.email, 120), phone: plainText(raw.phone, 32), city: plainText(raw.city, 60),
    revenue: num(raw.revenue), invoiceCount: count(raw.invoiceCount), open: num(raw.open)
  }
}

function parseSnapshot(text) {
  var raw
  try {
    raw = JSON.parse(String(text || ""))
  } catch (e) {
    return emptySnapshot("error")
  }
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return emptySnapshot("error")

  var result = emptySnapshot(oneOf(raw.status, STATUSES, "error"))
  result.ok = raw.ok === true
  result.error = plainText(raw.error, 40)
  result.errorDetail = plainText(raw.errorDetail, 160)
  var relay = obj(raw.relay)
  result.relay = {
    configured: relay.configured === true, ok: relay.ok === true, error: plainText(relay.error, 40),
    checkedAt: count(relay.checkedAt), lastEventAt: count(relay.lastEventAt),
    webhookSecretStored: relay.webhookSecretStored === true
  }
  if (raw.hasData !== true) return result

  result.hasData = true
  result.stale = raw.stale === true
  result.fetchedAt = count(raw.fetchedAt)
  result.today = isoDate(raw.today)
  result.baseCurrency = plainText(raw.baseCurrency, 3) || "CZK"
  var bar = obj(raw.bar)
  result.bar = {
    unpaidTotal: num(bar.unpaidTotal), unpaidCount: count(bar.unpaidCount),
    overdueTotal: num(bar.overdueTotal), overdueCount: count(bar.overdueCount),
    draftCount: count(bar.draftCount), monthInvoiced: num(bar.monthInvoiced),
    quarterInvoiced: num(bar.quarterInvoiced), quarterIndex: Math.max(1, Math.min(4, count(bar.quarterIndex) || 1))
  }
  result.period = parsePeriod(raw.period)
  result.chart = rows(raw.chart, 24).map(function(item) {
    var entry = obj(item)
    return {
      kind: oneOf(entry.kind, HORIZONS, "month"), year: count(entry.year), index: count(entry.index),
      paid: Math.max(0, num(entry.paid)), unpaid: Math.max(0, num(entry.unpaid)),
      expenses: Math.max(0, num(entry.expenses)), future: entry.future === true
    }
  })
  var turnover = obj(raw.turnover)
  result.turnover = {
    year: count(turnover.year), yearToDate: num(turnover.yearToDate),
    last12Months: num(turnover.last12Months), limit: Math.max(0, num(turnover.limit))
  }
  result.invoices = rows(raw.invoices, 1000).map(parseInvoice).filter(function(item) { return item !== null })
  var counts = obj(raw.invoiceCounts)
  result.invoiceCounts = {
    all: count(counts.all), unpaid: count(counts.unpaid), overdue: count(counts.overdue),
    paid: count(counts.paid), draft: count(counts.draft)
  }
  result.customers = rows(raw.customers, 400).map(parseCustomer).filter(function(item) { return item !== null })
  result.customerCount = count(raw.customerCount)
  result.expensesAvailable = raw.expensesAvailable !== false
  result.truncated = raw.truncated === true
  result.events = rows(raw.events, 20).map(function(item) {
    var entry = obj(item)
    var name = plainText(entry.event, 40)
    return {
      event: KNOWN_EVENTS[name] ? name : "other", resourceId: idOf(entry.resourceId),
      at: count(entry.at), number: plainText(entry.number, 40)
    }
  })
  return result
}

function parseActionResult(text) {
  var raw
  try {
    raw = JSON.parse(String(text || ""))
  } catch (e) {
    return { ok: false, action: "", error: "internal", detail: "" }
  }
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { ok: false, action: "", error: "internal", detail: "" }
  raw.ok = raw.ok === true
  raw.action = plainText(raw.action, 40)
  raw.error = raw.ok ? "" : (plainText(raw.error, 40) || "internal")
  raw.detail = plainText(raw.detail, 200)
  return raw
}

function parseDetail(value) {
  var raw = obj(value)
  var id = idOf(raw.id)
  if (!id) return null
  return {
    id: id, number: plainText(raw.number, 40), status: plainText(raw.status, 20),
    state: oneOf(raw.state, STATES, "pending"),
    customerName: plainText(raw.customerName, 100), customerEmail: plainText(raw.customerEmail, 120),
    issueDate: isoDate(raw.issueDate), dueDate: isoDate(raw.dueDate), taxDate: isoDate(raw.taxDate),
    subtotal: num(raw.subtotal), vatAmount: num(raw.vatAmount), total: num(raw.total), open: num(raw.open),
    currency: plainText(raw.currency, 3) || "CZK", variableSymbol: plainText(raw.variableSymbol, 20),
    notes: plainText(raw.notes, 300),
    items: rows(raw.items, 50).map(function(item) {
      var entry = obj(item)
      return {
        description: plainText(entry.description, 160), quantity: plainText(entry.quantity, 16),
        unit: plainText(entry.unit, 12), unitPrice: num(entry.unitPrice),
        vatRate: plainText(entry.vatRate, 6), total: num(entry.total)
      }
    }),
    payments: rows(raw.payments, 50).map(function(item) {
      var entry = obj(item)
      return {
        amount: num(entry.amount), paidAt: isoDate(entry.paidAt),
        method: plainText(entry.method, 24), note: plainText(entry.note, 120)
      }
    })
  }
}

function parseCompany(value) {
  var raw = obj(value)
  var name = plainText(raw.name, 160)
  if (name === "") return null
  return {
    ico: plainText(raw.ico, 12), country: raw.country === "SK" ? "SK" : "CZ", name: name,
    dic: plainText(raw.dic, 16), isVatPayer: raw.isVatPayer === true,
    address: plainText(raw.address, 160), city: plainText(raw.city, 80),
    postalCode: plainText(raw.postalCode, 12), legalForm: plainText(raw.legalForm, 80),
    existingCustomerId: idOf(raw.existingCustomerId)
  }
}

function parseWebhooks(value) {
  return rows(value, 20).map(function(item) {
    var entry = obj(item)
    return {
      id: idOf(entry.id), url: plainText(entry.url, 120), active: entry.active !== false,
      events: rows(entry.events, 10).map(function(name) { return plainText(name, 40) })
    }
  })
}

function errorKey(code) {
  return "error." + (KNOWN_ERRORS[code] ? code : "generic")
}

// ---- Lists ----------------------------------------------------------------

function fold(value) {
  var text = String(value || "").toLowerCase()
  return typeof text.normalize === "function" ? text.normalize("NFD").replace(/[\u0300-\u036f]/g, "") : text
}

function matchesFilter(invoice, filter) {
  if (filter === "unpaid") return invoice.state === "pending" || invoice.state === "overdue"
  if (filter === "overdue") return invoice.state === "overdue"
  if (filter === "paid") return invoice.state === "paid"
  if (filter === "draft") return invoice.state === "draft"
  return true
}

function filterInvoices(invoices, filter, query) {
  var needle = fold(plainText(query, 60))
  var result = []
  for (var i = 0; i < invoices.length; i++) {
    var invoice = invoices[i]
    if (!matchesFilter(invoice, filter)) continue
    if (needle !== "" && fold(invoice.number + " " + invoice.customerName + " " + invoice.variableSymbol).indexOf(needle) === -1) continue
    result.push(invoice)
  }
  if (filter === "unpaid" || filter === "overdue") {
    // Most urgent first: the longest overdue on top.
    result.sort(function(a, b) {
      var da = a.daysToDue === null ? 99999 : a.daysToDue
      var db = b.daysToDue === null ? 99999 : b.daysToDue
      return da - db
    })
  }
  return result
}

function invoicesInRange(invoices, from, to) {
  if (from === "" || to === "") return []
  return invoices.filter(function(invoice) {
    return invoice.issueDate !== "" && invoice.issueDate >= from && invoice.issueDate <= to
      && invoice.state !== "draft" && invoice.state !== "cancelled"
  })
}

function filterCustomers(customers, query) {
  var needle = fold(plainText(query, 60))
  if (needle === "") return customers
  return customers.filter(function(customer) {
    return fold(customer.name + " " + customer.ico + " " + customer.email + " " + customer.city).indexOf(needle) !== -1
  })
}

function findById(list, id) {
  for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
  return null
}

// ---- Numbers --------------------------------------------------------------

// Czech and Slovak share the convention: decimal comma, groups of three
// separated by a non-breaking space.
function formatDecimal(value, decimals) {
  return num(value).toFixed(decimals).replace(".", ",")
}

function formatAmount(value, decimals) {
  var n = num(value)
  var text = formatDecimal(Math.abs(n), decimals)
  var match = /^(\d+)(\D\d+)?$/.exec(text)
  if (match) text = match[1].replace(/\B(?=(\d{3})+(?!\d))/g, "\u00a0") + (match[2] || "")
  var rounded = Math.abs(n) >= 0.5 * Math.pow(10, -decimals)
  return (n < 0 && rounded ? "\u2212" : "") + text
}

function currencyUnit(currency) {
  if (currency === "CZK") return "K\u010d"
  if (currency === "EUR") return "\u20ac"
  return plainText(currency, 3)
}

// mode: "round" (no decimals), "exact" (two), "auto" (two only when there are hellers)
function formatMoney(value, currency, mode) {
  var n = num(value)
  var decimals = 2
  if (mode === "round") decimals = 0
  else if (mode === "auto") decimals = Math.abs(n - Math.round(n)) < 0.005 ? 0 : 2
  return formatAmount(n, decimals) + "\u00a0" + currencyUnit(currency)
}

// Short form for the bar: 950, 45,2 tis., 1,25 mil.
function formatCompact(value) {
  var n = Math.abs(num(value))
  if (n < 1000) return formatDecimal(n, 0)
  if (n < 999950) return formatDecimal(n / 1000, n < 99950 ? 1 : 0) + "\u00a0tis."
  return formatDecimal(n / 1000000, n < 99995000 ? 2 : 1) + "\u00a0mil."
}

function maskedMoney() {
  return "\u2022\u2022\u2022\u2022"
}

function percentOf(part, whole) {
  var total = num(whole)
  if (total <= 0) return 0
  return Math.max(0, Math.min(1, num(part) / total))
}

function formatTrend(value) {
  if (value === null || value === undefined) return ""
  var n = num(value)
  var magnitude = Math.abs(n)
  var text = magnitude >= 1000 ? ">999" : formatDecimal(magnitude, magnitude < 10 ? 1 : 0)
  return (n > 0.05 ? "\u25b2\u00a0" : (n < -0.05 ? "\u25bc\u00a0" : "")) + text + "\u00a0%"
}

// Upper bound of the chart axis: the next 1 / 2 / 2.5 / 5 x 10^n above the data.
function niceCeil(value) {
  var n = num(value)
  if (n <= 0) return 1
  var magnitude = Math.pow(10, Math.floor(Math.log(n) / Math.LN10))
  var steps = [1, 2, 2.5, 5, 10]
  for (var i = 0; i < steps.length; i++) if (n <= steps[i] * magnitude * 1.0000001) return steps[i] * magnitude
  return 10 * magnitude
}

function chartMax(chart) {
  var top = 0
  for (var i = 0; i < chart.length; i++) top = Math.max(top, chart[i].paid + chart[i].unpaid, chart[i].expenses)
  return niceCeil(top)
}

// ---- Dates ----------------------------------------------------------------

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

function toIso(date) {
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1) + "-" + pad2(date.getDate())
}

function parseIso(value) {
  var match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value || ""))
  if (!match) return null
  var date = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]))
  if (date.getFullYear() !== Number(match[1]) || date.getMonth() !== Number(match[2]) - 1 || date.getDate() !== Number(match[3])) return null
  return date
}

function addDays(iso, days) {
  var date = parseIso(iso)
  if (date === null) return ""
  date.setDate(date.getDate() + Math.round(num(days)))
  return toIso(date)
}

// Accepts 2026-11-18, 18.11.2026, 18. 11. 2026 and 18/11/2026. Returns ISO or "".
function normalizeDate(text) {
  var raw = String(text || "").trim()
  var date = parseIso(raw)
  if (date !== null) return raw
  var match = /^(\d{1,2})\s*[.\/]\s*(\d{1,2})\s*[.\/]\s*(\d{4})$/.exec(raw)
  if (!match) return ""
  var iso = match[3] + "-" + pad2(Number(match[2])) + "-" + pad2(Number(match[1]))
  return parseIso(iso) !== null ? iso : ""
}

// ---- Forms ----------------------------------------------------------------

// "1 234,50" -> "1234.50"; "" when it is not a plain decimal number.
function normalizeDecimal(text) {
  var raw = String(text === undefined || text === null ? "" : text).replace(/[\s\u00a0]/g, "").replace(",", ".")
  return /^-?\d{1,12}(\.\d{1,6})?$/.test(raw) ? raw : ""
}

function emptyItem(vatRate) {
  return { description: "", quantity: "1", unit: "ks", unitPrice: "", vatRate: String(vatRate || "21") }
}

// Live estimate while typing. The confirmation dialog shows the exact totals
// computed by the backend with decimal arithmetic.
function estimateTotals(items) {
  var bases = {}
  var filled = 0
  for (var i = 0; i < items.length; i++) {
    var quantity = normalizeDecimal(items[i].quantity)
    var price = normalizeDecimal(items[i].unitPrice)
    var rate = normalizeDecimal(items[i].vatRate)
    if (quantity === "" || price === "" || rate === "") continue
    filled += 1
    var line = Math.round(Number(quantity) * Number(price) * 100 + 1e-7) / 100
    bases[rate] = (bases[rate] || 0) + line
  }
  var subtotal = 0, vat = 0
  for (var key in bases) {
    subtotal += bases[key]
    vat += Math.round(bases[key] * Number(key) + 1e-7) / 100
  }
  subtotal = Math.round(subtotal * 100) / 100
  vat = Math.round(vat * 100) / 100
  return { subtotal: subtotal, vat: vat, total: Math.round((subtotal + vat) * 100) / 100, filled: filled }
}

// Returns the i18n key of the first problem, or "" when the form can be sent for review.
function invoiceFormProblem(form) {
  if (!idOf(form.customerId)) return "form.needCustomer"
  if (normalizeDate(form.issueDate) === "") return "form.badIssueDate"
  var due = normalizeDate(form.dueDate)
  if (due === "" || due < normalizeDate(form.issueDate)) return "form.badDueDate"
  var used = 0
  for (var i = 0; i < form.items.length; i++) {
    var item = form.items[i]
    var blank = plainText(item.description, 500) === "" && String(item.unitPrice || "").trim() === ""
    if (blank) continue
    used += 1
    if (plainText(item.description, 500) === "") return "form.needDescription"
    var quantity = normalizeDecimal(item.quantity)
    if (quantity === "" || Number(quantity) <= 0) return "form.badQuantity"
    if (normalizeDecimal(item.unitPrice) === "") return "form.badPrice"
  }
  if (used === 0) return "form.needItem"
  return ""
}

function invoicePayload(form) {
  var items = []
  for (var i = 0; i < form.items.length; i++) {
    var item = form.items[i]
    if (plainText(item.description, 500) === "" && String(item.unitPrice || "").trim() === "") continue
    items.push({
      description: plainText(item.description, 500),
      quantity: normalizeDecimal(item.quantity),
      unit: plainText(item.unit, 20) || "ks",
      unitPrice: normalizeDecimal(item.unitPrice),
      vatRate: normalizeDecimal(item.vatRate) || "0"
    })
  }
  return {
    customerId: idOf(form.customerId),
    customerName: plainText(form.customerName, 200),
    issueDate: normalizeDate(form.issueDate),
    dueDate: normalizeDate(form.dueDate),
    items: items,
    notes: String(form.notes || "").substring(0, 1000),
    draft: form.final !== true
  }
}

function expenseFormProblem(form) {
  if (plainText(form.description, 300) === "") return "form.needDescription"
  var amount = normalizeDecimal(form.amount)
  if (amount === "" || Number(amount) <= 0) return "form.badPrice"
  if (normalizeDate(form.date) === "") return "form.badIssueDate"
  return ""
}

function expensePayload(form) {
  return {
    description: plainText(form.description, 300),
    category: plainText(form.category, 60),
    amount: normalizeDecimal(form.amount),
    vatRate: normalizeDecimal(form.vatRate) || "0",
    expenseDate: normalizeDate(form.date),
    receiptNumber: plainText(form.receiptNumber, 40)
  }
}

function validIco(text) {
  return /^\d{8}$/.test(String(text || "").trim())
}

function validEmail(text) {
  return /^[A-Za-z0-9._%+\-]{1,64}@[A-Za-z0-9.\-]{1,190}\.[A-Za-z]{2,24}$/.test(String(text || "").trim())
}

if (typeof module !== "undefined") {
  module.exports = {
    HORIZONS: HORIZONS, STATES: STATES, KINDS: KINDS, FILTERS: FILTERS, STATUSES: STATUSES,
    KNOWN_ERRORS: KNOWN_ERRORS, KNOWN_EVENTS: KNOWN_EVENTS,
    plainText: plainText, neutralizeMarkup: neutralizeMarkup, parseSnapshot: parseSnapshot,
    emptySnapshot: emptySnapshot, parseActionResult: parseActionResult, parseDetail: parseDetail,
    parseCompany: parseCompany, parseWebhooks: parseWebhooks, errorKey: errorKey,
    filterInvoices: filterInvoices, invoicesInRange: invoicesInRange, filterCustomers: filterCustomers,
    findById: findById, formatAmount: formatAmount, formatMoney: formatMoney, formatCompact: formatCompact,
    maskedMoney: maskedMoney, percentOf: percentOf, formatTrend: formatTrend, niceCeil: niceCeil,
    chartMax: chartMax, toIso: toIso, parseIso: parseIso, addDays: addDays, normalizeDate: normalizeDate,
    normalizeDecimal: normalizeDecimal, emptyItem: emptyItem, estimateTotals: estimateTotals,
    invoiceFormProblem: invoiceFormProblem, invoicePayload: invoicePayload,
    expenseFormProblem: expenseFormProblem, expensePayload: expensePayload,
    validIco: validIco, validEmail: validEmail
  }
}
