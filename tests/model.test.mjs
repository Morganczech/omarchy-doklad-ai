import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { createRequire } from "node:module"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { tmpdir } from "node:os"
import { writeFileSync, mkdtempSync } from "node:fs"
import test from "node:test"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const source = readFileSync(join(root, "Model.js"), "utf8").replace(/^\.pragma library\s*/, "")
const dir = mkdtempSync(join(tmpdir(), "doklad-model-"))
const file = join(dir, "Model.cjs")
writeFileSync(file, source)
const Model = createRequire(import.meta.url)(file)

test("plainText strips control characters and truncates", () => {
  assert.equal(Model.plainText("a\u0000b  c", 10), "a b c")
  assert.equal(Model.plainText("abcdefghijk", 8).endsWith("…"), true)
})

test("formatMoney uses Czech grouping and currency", () => {
  assert.equal(Model.formatMoney(1234567.5, "CZK", "auto"), "1\u00a0234\u00a0567,50\u00a0Kč")
  assert.equal(Model.formatMoney(1200, "EUR", "auto"), "1\u00a0200\u00a0€")
  assert.equal(Model.formatMoney(-0.004, "CZK", "exact"), "0,00\u00a0Kč")
})

test("formatCompact uses tis./mil.", () => {
  assert.equal(Model.formatCompact(950), "950")
  assert.equal(Model.formatCompact(45230), "45,2\u00a0tis.")
  assert.equal(Model.formatCompact(1250000), "1,25\u00a0mil.")
})

test("filterInvoices ignores diacritics and sorts unpaid by urgency", () => {
  const invoices = [
    { id: 1, number: "1", customerName: "Škoda", variableSymbol: "", state: "pending", daysToDue: 5, issueDate: "2026-11-01", kind: "invoice", total: 1, open: 1, currency: "CZK", status: "sent", customerId: 1 },
    { id: 2, number: "2", customerName: "Acme", variableSymbol: "99", state: "overdue", daysToDue: -3, issueDate: "2026-10-01", kind: "invoice", total: 1, open: 1, currency: "CZK", status: "overdue", customerId: 2 },
    { id: 3, number: "3", customerName: "Beta", variableSymbol: "", state: "paid", daysToDue: null, issueDate: "2026-09-01", kind: "invoice", total: 1, open: 0, currency: "CZK", status: "paid", customerId: 3 },
  ]
  assert.equal(Model.filterInvoices(invoices, "all", "skoda")[0].id, 1)
  assert.deepEqual(Model.filterInvoices(invoices, "unpaid", "").map(i => i.id), [2, 1])
})

test("invoice form validates and builds a draft payload", () => {
  const form = {
    customerId: 7, customerName: "Acme", issueDate: "18.11.2026", dueDate: "2.12.2026", notes: "", final: false,
    items: [{ description: "Práce", quantity: "2", unit: "h", unitPrice: "1 000,50", vatRate: "21" }],
  }
  assert.equal(Model.invoiceFormProblem(form), "")
  const payload = Model.invoicePayload(form)
  assert.equal(payload.draft, true)
  assert.equal(payload.issueDate, "2026-11-18")
  assert.equal(payload.items[0].unitPrice, "1000.50")
})

test("estimateTotals matches line VAT rounding", () => {
  const totals = Model.estimateTotals([
    { description: "A", quantity: "1", unitPrice: "1000", vatRate: "21" },
    { description: "", quantity: "1", unitPrice: "", vatRate: "21" },
  ])
  assert.deepEqual(totals, { subtotal: 1000, vat: 210, total: 1210, filled: 1 })
})

test("parseSnapshot sanitizes untrusted fields", () => {
  const snap = Model.parseSnapshot(JSON.stringify({
    ok: true, status: "ready", hasData: true, fetchedAt: 1, today: "2026-11-18", baseCurrency: "CZK",
    bar: { unpaidTotal: 10, unpaidCount: 1, overdueTotal: 0, overdueCount: 0, draftCount: 0, monthInvoiced: 1, quarterInvoiced: 1, quarterIndex: 4 },
    period: { horizon: "month", offset: 0, kind: "month", year: 2026, index: 11, from: "2026-11-01", to: "2026-11-30",
      invoiced: { subtotal: 1, total: 1, count: 1 }, collected: { total: 0, count: 0 }, pending: { total: 1, count: 1 },
      overdue: { total: 0, count: 0 }, expenses: { subtotal: 0, total: 0, count: 0 }, net: 1,
      vat: { output: 0, input: 0, balance: 0 }, trend: { previous: null, yoy: null }, foreign: [] },
    chart: [], turnover: { year: 2026, yearToDate: 1, last12Months: 1, limit: 2000000 },
    invoices: [{ id: 1, number: "A<script>", customerName: "B", issueDate: "2026-11-01", dueDate: "2026-11-15",
      status: "sent", state: "pending", kind: "invoice", total: 10, open: 10, currency: "CZK", daysToDue: 0, variableSymbol: "1" }],
    invoiceCounts: { all: 1, unpaid: 1, overdue: 0, paid: 0, draft: 0 },
    customers: [], customerCount: 0, expensesAvailable: true, truncated: false, account: "",
    relay: { configured: false, ok: false, error: "", checkedAt: 0, lastEventAt: 0, webhookSecretStored: false },
  }))
  assert.equal(snap.invoices[0].number, "A<script>")
  assert.equal(Model.neutralizeMarkup(snap.invoices[0].number), "A‹script›")
  assert.equal(Model.errorKey("nope"), "error.generic")
})
