"""Unit and security tests for the Doklad.ai backend.

Run with:  python3 -I -B -m unittest discover -s tests -v

No test talks to the network: the API is replaced by FakeTransport.
"""

import datetime as dt
import json
import os
import stat
import sys
import tempfile
import unittest
from decimal import Decimal
from urllib.parse import parse_qsl

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.dont_write_bytecode = True

import doklad  # noqa: E402

TODAY = dt.date(2026, 11, 18)
NOW = 1795000000


def reply(status, body=None, headers=None):
    data = b"" if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode("utf-8"))
    return status, headers or {}, data


class FakeTransport:
    def __init__(self):
        self.routes = {}
        self.calls = []

    def on(self, method, path, responder):
        self.routes[(method, path)] = responder

    def __call__(self, method, target, body, headers, max_bytes):
        path, _, query_string = target.partition("?")
        call = {
            "method": method, "path": path, "query": dict(parse_qsl(query_string)),
            "payload": json.loads(body.decode("utf-8")) if body else None, "headers": dict(headers),
        }
        self.calls.append(call)
        responder = self.routes.get((method, path))
        if responder is None:
            return reply(404, {"message": "not found"})
        result = responder(call) if callable(responder) else responder
        if isinstance(result, Exception):
            raise result
        return result

    def count(self, method, path):
        return sum(1 for call in self.calls if call["method"] == method and call["path"] == path)

    def last(self, method, path):
        for call in reversed(self.calls):
            if call["method"] == method and call["path"] == path:
                return call
        return None


def api_invoice(invoice_id, subtotal, status="sent", issue="2026-11-05", due="2026-12-05", **extra):
    subtotal = Decimal(subtotal)
    vat = (subtotal * Decimal("0.21")).quantize(Decimal("0.01"))
    row = {
        "id": invoice_id, "invoiceNumber": "2026%04d" % invoice_id, "customerId": 7, "customerName": "Acme s.r.o.",
        "issueDate": issue, "dueDate": due, "taxDate": issue, "status": status,
        "subtotal": str(subtotal), "vatAmount": str(vat), "total": str(subtotal + vat), "currency": "CZK",
    }
    row.update(extra)
    return row


def sample_invoices():
    return [
        api_invoice(1, "1000.00", issue="2026-11-03", due="2026-11-17"),                 # overdue by due date
        api_invoice(2, "2000.00", issue="2026-11-10", due="2026-11-24"),                 # pending
        api_invoice(3, "10000.00", status="paid", issue="2026-11-12"),                   # paid
        api_invoice(4, "825.62", status="draft", issue="2026-11-15"),                    # excluded
        api_invoice(5, "413.22", status="cancelled", issue="2026-11-16"),                # excluded
        api_invoice(6, "5000.00", status="paid", issue="2026-10-20"),                    # previous month
        api_invoice(7, "3000.00", status="paid", issue="2025-11-11"),                    # same month last year
        api_invoice(8, "1000.00", issue="2026-11-08", due="2026-12-08", paidAmount="500.00"),  # partially paid
        api_invoice(9, "4132.23", issue="2026-11-09", type="proforma"),                  # excluded proforma
        api_invoice(10, "82.64", issue="2026-11-02", currency="EUR"),                    # foreign, no rate
        api_invoice(11, "100.00", status="paid", issue="2026-11-04", currency="EUR", exchangeRate="25"),
    ]


def sample_expenses():
    return [
        {"id": 1, "amount": "1000.00", "vatAmount": "210.00", "total": "1210.00", "status": "approved",
         "expenseDate": "2026-11-06"},
        {"id": 2, "amount": "500.00", "vatAmount": "105.00", "total": "605.00", "status": "rejected",
         "expenseDate": "2026-11-07"},
        {"id": 3, "amount": "200.00", "vatAmount": "42.00", "total": "242.00", "status": "paid",
         "expenseDate": "2026-10-01"},
    ]


def sample_customers():
    return [
        {"id": 7, "name": "Acme s.r.o.", "ico": "12345678", "email": "fakturace@acme.cz", "zip": "11000"},
        {"id": 8, "name": "Beta a.s.", "ico": "87654321", "postalCode": "60200", "isActive": True},
    ]


def cache_from(invoices, expenses=(), customers=(), overdue_ids=()):
    return {
        "version": doklad.CACHE_VERSION, "fetchedAt": NOW,
        "invoices": [doklad.normalize_invoice(row) for row in invoices],
        "overdueIds": list(overdue_ids),
        "expenses": [doklad.normalize_expense(row) for row in expenses],
        "expensesAvailable": True,
        "customers": [doklad.normalize_customer(row) for row in customers],
        "truncated": False,
    }


def options(**overrides):
    base = {"horizon": "month", "offset": 0, "max_age": 300, "limit": 2000000, "lang": "cs",
            "force": False, "cached": False, "notify": True, "privacy": False}
    base.update(overrides)
    return base


class TempHome(unittest.TestCase):
    """Gives every test an isolated HOME with private config/state directories."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self.addCleanup(self._tmp.cleanup)
        self.environ = {"HOME": self.home}
        self.paths = doklad.Paths.from_environ(self.environ)
        self.transport = FakeTransport()
        self.notifications = []
        self.spawned = []

    def write_env(self, text, mode=0o600):
        os.makedirs(self.paths.config_dir, mode=0o700, exist_ok=True)
        with open(self.paths.env_file, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(self.paths.env_file, mode)

    def context(self, **kwargs):
        def spawner(argv):
            self.spawned.append(argv)
            return True

        return doklad.Context(
            paths=self.paths, environ=self.environ, transport=self.transport,
            relay_transport_factory=kwargs.pop("relay_factory", lambda host, port: self.transport),
            today=TODAY, now=kwargs.pop("now", NOW), notifier=self.notifications.extend, spawner=spawner)

    def serve_dataset(self, invoices=None, expenses=None, customers=None):
        invoices = sample_invoices() if invoices is None else invoices
        self.transport.on("GET", "/api/invoices", lambda call: reply(
            200, {"data": invoices, "total": len(invoices), "page": 1, "totalPages": 1}))
        self.transport.on("GET", "/api/invoices/overdue", reply(200, {"data": []}))
        self.transport.on("GET", "/api/expenses", reply(200, sample_expenses() if expenses is None else expenses))
        self.transport.on("GET", "/api/customers", reply(
            200, {"data": sample_customers() if customers is None else customers, "totalPages": 1}))


# --------------------------------------------------------------------------

class SanitizingTests(unittest.TestCase):
    def test_clean_text_strips_control_and_bidi_characters(self):
        self.assertEqual(doklad.clean_text("A\x00B\nC\x7f\u202eD\u2066E"), "A B C DE")

    def test_clean_text_bounds_length_and_rejects_non_strings(self):
        self.assertEqual(len(doklad.clean_text("x" * 500, 40)), 40)
        self.assertEqual(doklad.clean_text({"a": 1}), "")
        self.assertEqual(doklad.clean_text(True), "")

    def test_notification_body_neutralizes_markup(self):
        invoice = doklad.hydrate_invoice(doklad.normalize_invoice(
            api_invoice(1, "100.00", customerName='<img src="https://evil.invalid/x">&amp;')))
        messages = doklad.build_notifications([("paid", invoice)], doklad.NOTIFY_FALLBACK, False, "cs")
        body = messages[0][2]
        self.assertNotIn("<", body)
        self.assertNotIn(">", body)
        self.assertNotIn("&", body)

    def test_markup_shaped_names_stay_single_line_plain_text(self):
        record = doklad.normalize_customer({"id": 1, "name": "<b>Zl\u00fd</b>\r\n<script>"})
        self.assertEqual(record["name"], "<b>Zl\u00fd</b> <script>")

    def test_multiline_message_keeps_newlines_but_not_controls(self):
        self.assertEqual(doklad.clean_multiline("Dobr\u00fd den,\r\n\x07d\u011bkujeme."), "Dobr\u00fd den,\nd\u011bkujeme.")


class DecimalTests(unittest.TestCase):
    def test_to_decimal_accepts_api_and_user_formats(self):
        self.assertEqual(doklad.to_decimal("1210.00"), Decimal("1210.00"))
        self.assertEqual(doklad.to_decimal("1 000,50"), Decimal("1000.50"))
        self.assertEqual(doklad.to_decimal(12), Decimal(12))
        self.assertEqual(doklad.to_decimal(0.1), Decimal("0.100000"))

    def test_to_decimal_rejects_garbage(self):
        for value in ("", "abc", "1e9", "1.2.3", "--1", None, True, float("nan"), [1], "9" * 20):
            self.assertIsNone(doklad.to_decimal(value), value)

    def test_money_rounds_half_up(self):
        self.assertEqual(doklad.money_str(Decimal("0.125")), "0.13")
        self.assertEqual(doklad.money_str(Decimal("2.675")), "2.68")
        self.assertEqual(doklad.money_str(Decimal("-0.125")), "-0.13")

    def test_format_money_text_localizes(self):
        self.assertEqual(doklad.format_money_text(Decimal("1234567.5"), "CZK", "cs"), "1\u00a0234\u00a0567,50 K\u010d")
        self.assertEqual(doklad.format_money_text(Decimal("1234.5"), "EUR", "sk"), "1\u00a0234,50 EUR")
        self.assertEqual(doklad.format_money_text(Decimal("1234.5"), "EUR", "en"), "1\u00a0234,50 EUR")


class InvoicePayloadTests(unittest.TestCase):
    def form(self, **overrides):
        form = {
            "customerId": 7, "customerName": "Acme s.r.o.", "issueDate": "2026-11-18", "dueDate": "2026-12-02",
            "items": [{"description": "Konzultace", "quantity": "1", "unitPrice": "1000", "vatRate": "21"}],
        }
        form.update(overrides)
        return form

    def test_matches_documented_example(self):
        body = doklad.build_invoice_payload(self.form(), draft=False)
        self.assertEqual(body["subtotal"], "1000.00")
        self.assertEqual(body["vatAmount"], "210.00")
        self.assertEqual(body["total"], "1210.00")
        self.assertEqual(body["taxDate"], "2026-11-18")
        self.assertEqual(body["customerName"], "Acme s.r.o.")
        self.assertNotIn("status", body)
        self.assertNotIn("invoiceNumber", body)
        item = body["items"][0]
        self.assertEqual(item, {"description": "Konzultace", "quantity": "1", "unit": "ks",
                                "unitPrice": "1000.00", "vatRate": "21"})

    def test_all_amounts_are_strings_with_decimal_point(self):
        body = doklad.build_invoice_payload(self.form(items=[
            {"description": "Pr\u00e1ce", "quantity": "2,5", "unit": "hod", "unitPrice": "1 333,33", "vatRate": "21"}]), True)
        for key in ("subtotal", "vatAmount", "total"):
            self.assertIsInstance(body[key], str)
            self.assertRegex(body[key], r"^\d+\.\d{2}$")
        self.assertEqual(body["items"][0]["quantity"], "2.5")
        self.assertEqual(body["subtotal"], "3333.33")     # 2.5 * 1333.33 = 3333.325 -> half up
        self.assertEqual(body["vatAmount"], "700.00")     # 3333.33 * 0.21 = 699.9993
        self.assertEqual(body["status"], "draft")

    def test_vat_is_computed_per_rate(self):
        body = doklad.build_invoice_payload(self.form(items=[
            {"description": "A", "quantity": "3", "unitPrice": "33.35", "vatRate": "21"},
            {"description": "B", "quantity": "1", "unitPrice": "200", "vatRate": "12"},
            {"description": "C", "quantity": "1", "unitPrice": "50", "vatRate": "0"},
        ]), False)
        self.assertEqual(body["subtotal"], "350.05")
        self.assertEqual(body["vatAmount"], "45.01")      # 100.05*0.21=21.0105 -> 21.01, 200*0.12=24.00
        self.assertEqual(body["total"], "395.06")

    def test_rejects_invalid_forms(self):
        cases = [
            ({"customerId": 0}, "invalid_input"),
            ({"customerName": "  "}, "invalid_input"),
            ({"issueDate": "18.11.2026"}, "invalid_date"),
            ({"dueDate": "2026-11-01"}, "invalid_date"),
            ({"items": []}, "invalid_input"),
            ({"items": [{"description": "", "quantity": "1", "unitPrice": "1", "vatRate": "21"}]}, "invalid_input"),
            ({"items": [{"description": "x", "quantity": "0", "unitPrice": "1", "vatRate": "21"}]}, "invalid_amount"),
            ({"items": [{"description": "x", "quantity": "1", "unitPrice": "abc", "vatRate": "21"}]}, "invalid_amount"),
            ({"items": [{"description": "x", "quantity": "1", "unitPrice": "1", "vatRate": "121"}]}, "invalid_amount"),
            ({"items": [{"description": "x", "quantity": "1", "unitPrice": "-5", "vatRate": "21"}]}, "invalid_amount"),
        ]
        for overrides, code in cases:
            with self.assertRaises(doklad.DokladError) as caught:
                doklad.build_invoice_payload(self.form(**overrides), True)
            self.assertEqual(caught.exception.code, code, overrides)

    def test_expense_payload(self):
        body = doklad.build_expense_payload({"description": "Hosting", "amount": "999,99", "vatRate": "21",
                                             "expenseDate": "2026-11-18", "category": "IT"})
        self.assertEqual(body["amount"], "999.99")
        self.assertEqual(body["vatAmount"], "210.00")
        self.assertEqual(body["total"], "1209.99")
        self.assertEqual(body["category"], "IT")

    def test_customer_payload_uses_real_postal_code_field(self):
        body = doklad.build_customer_payload({"name": "Beta", "ico": "87654321", "postalCode": "60200",
                                              "email": "a@b.cz", "country": "sk"})
        self.assertEqual(body["postalCode"], "60200")
        self.assertNotIn("zip", body)
        self.assertEqual(body["country"], "SK")
        with self.assertRaises(doklad.DokladError):
            doklad.build_customer_payload({"name": "Beta", "ico": "123"})
        with self.assertRaises(doklad.DokladError):
            doklad.build_customer_payload({"name": "Beta", "email": "not-an-email"})


class NormalizationTests(unittest.TestCase):
    def test_tax_date_accepts_both_field_names(self):
        self.assertEqual(doklad.normalize_invoice({"id": 1, "taxDate": "2026-10-06"})["taxDate"], "2026-10-06")
        self.assertEqual(doklad.normalize_invoice({"id": 1, "taxableDate": "2026-10-07"})["taxDate"], "2026-10-07")

    def test_iso_timestamps_become_dates(self):
        self.assertEqual(doklad.normalize_invoice({"id": 1, "issueDate": "2026-10-06T12:00:00.000Z"})["issueDate"],
                         "2026-10-06")
        self.assertEqual(doklad.normalize_invoice({"id": 1, "issueDate": "06.10.2026"})["issueDate"], "")

    def test_postal_code_accepts_both_field_names(self):
        self.assertEqual(doklad.normalize_customer({"id": 1, "name": "A", "zip": "11000"})["postalCode"], "11000")
        self.assertEqual(doklad.normalize_customer({"id": 1, "name": "A", "postalCode": "60200"})["postalCode"], "60200")

    def test_records_without_usable_id_are_dropped(self):
        for raw in ({}, {"id": "abc"}, {"id": -1}, {"id": True}, {"id": 1.5}, None, "x"):
            self.assertIsNone(doklad.normalize_invoice(raw))

    def test_numeric_amounts_from_swagger_shape_are_accepted(self):
        record = doklad.normalize_invoice({"id": 1, "subtotal": 1000, "vatAmount": 210, "total": 1210})
        self.assertEqual((record["subtotal"], record["vatAmount"], record["total"]), ("1000.00", "210.00", "1210.00"))

    def test_open_amount_from_partial_payment_fields(self):
        base = api_invoice(1, "1000.00")
        self.assertEqual(doklad.hydrate_invoice(doklad.normalize_invoice(base))["open"], Decimal("1210.00"))
        self.assertEqual(doklad.hydrate_invoice(doklad.normalize_invoice(dict(base, paidAmount="500")))["open"],
                         Decimal("710.00"))
        self.assertEqual(doklad.hydrate_invoice(doklad.normalize_invoice(dict(base, remainingAmount="10")))["open"],
                         Decimal("10.00"))
        self.assertEqual(doklad.hydrate_invoice(doklad.normalize_invoice(dict(base, status="paid")))["open"], 0)

    def test_hydrate_tolerates_a_damaged_cache(self):
        self.assertIsNone(doklad.hydrate_invoice("garbage"))
        record = doklad.hydrate_invoice({"id": 5, "total": "nonsense", "issueDate": 12, "kind": "weird"})
        self.assertEqual(record["total"], 0)
        self.assertIsNone(record["issue"])
        self.assertEqual(record["kind"], "invoice")


class PaginationTests(unittest.TestCase):
    def client(self, transport):
        return doklad.ApiClient(transport, "dk_test")

    def test_follows_documented_envelope(self):
        transport = FakeTransport()
        pages = {"1": [{"id": 1}, {"id": 2}], "2": [{"id": 3}]}
        transport.on("GET", "/api/invoices", lambda call: reply(
            200, {"data": pages[call["query"]["page"]], "total": 3, "page": int(call["query"]["page"]), "totalPages": 2}))
        rows, truncated = self.client(transport).paginate("/api/invoices")
        self.assertEqual([row["id"] for row in rows], [1, 2, 3])
        self.assertFalse(truncated)
        self.assertEqual(transport.count("GET", "/api/invoices"), 2)
        self.assertEqual(transport.calls[0]["query"]["limit"], str(doklad.PAGE_LIMIT))

    def test_accepts_bare_array_from_swagger_shape(self):
        transport = FakeTransport()
        transport.on("GET", "/api/expenses", reply(200, [{"id": 1}, {"id": 2}]))
        rows, _ = self.client(transport).paginate("/api/expenses")
        self.assertEqual(len(rows), 2)
        self.assertEqual(transport.count("GET", "/api/expenses"), 1)

    def test_stops_when_server_ignores_page_parameter(self):
        transport = FakeTransport()
        full_page = [{"id": index} for index in range(1, doklad.PAGE_LIMIT + 1)]
        transport.on("GET", "/api/expenses", reply(200, full_page))
        rows, _ = self.client(transport).paginate("/api/expenses")
        self.assertEqual(len(rows), doklad.PAGE_LIMIT)
        self.assertEqual(transport.count("GET", "/api/expenses"), 2)

    def test_falls_back_when_page_size_is_rejected(self):
        transport = FakeTransport()
        transport.on("GET", "/api/invoices", lambda call: reply(400, {"code": "VALIDATION_ERROR"})
                     if "limit" in call["query"] else reply(200, {"data": [{"id": 1}], "totalPages": 1}))
        rows, _ = self.client(transport).paginate("/api/invoices")
        self.assertEqual(len(rows), 1)

    def test_status_codes_map_to_stable_error_codes(self):
        expected = {401: "unauthorized", 403: "forbidden", 404: "not_found", 429: "rate_limited",
                    503: "service_unavailable", 500: "server_error", 400: "validation"}
        for status, code in expected.items():
            transport = FakeTransport()
            transport.on("GET", "/api/invoices", reply(status, {
                "message": "Chyba", "errors": [{"path": "items.0.unitPrice", "message": "Required"}]}))
            with self.assertRaises(doklad.DokladError) as caught:
                self.client(transport).get("/api/invoices")
            self.assertEqual(caught.exception.code, code)
        self.assertIn("items.0.unitPrice", caught.exception.detail)

    def test_only_api_paths_are_requested(self):
        with self.assertRaises(doklad.DokladError):
            self.client(FakeTransport()).get("/etc/passwd")


class PeriodTests(unittest.TestCase):
    def bounds(self, horizon, offset, today=TODAY):
        period = doklad.period_bounds(horizon, offset, today)
        return period["start"].isoformat(), period["end"].isoformat()

    def test_month(self):
        self.assertEqual(self.bounds("month", 0), ("2026-11-01", "2026-11-30"))
        self.assertEqual(self.bounds("month", -11), ("2025-12-01", "2025-12-31"))
        self.assertEqual(self.bounds("month", -9, dt.date(2024, 11, 5)), ("2024-02-01", "2024-02-29"))

    def test_quarter(self):
        self.assertEqual(self.bounds("quarter", 0), ("2026-10-01", "2026-12-31"))
        self.assertEqual(self.bounds("quarter", -1), ("2026-07-01", "2026-09-30"))
        self.assertEqual(self.bounds("quarter", -4), ("2025-10-01", "2025-12-31"))
        self.assertEqual(doklad.period_bounds("quarter", 0, dt.date(2026, 1, 1))["index"], 1)

    def test_year_and_trailing_twelve_months(self):
        self.assertEqual(self.bounds("year", -1), ("2025-01-01", "2025-12-31"))
        self.assertEqual(self.bounds("ltm", 0), ("2025-12-01", "2026-11-30"))
        self.assertEqual(self.bounds("ltm", -12), ("2024-12-01", "2025-11-30"))


class AnalyticsTests(unittest.TestCase):
    def snapshot(self, **overrides):
        cache = cache_from(sample_invoices(), sample_expenses(), sample_customers())
        return doklad.build_snapshot(cache, doklad.default_state(), options(**overrides), TODAY)

    def test_monthly_totals(self):
        period = self.snapshot()["period"]
        self.assertEqual(period["invoiced"], {"subtotal": 16500.0, "total": 19965.0, "count": 5})
        self.assertEqual(period["collected"], {"total": 15625.0, "count": 2})
        self.assertEqual(period["pending"], {"total": 3130.0, "count": 2})
        self.assertEqual(period["overdue"], {"total": 1210.0, "count": 1})
        invoiced = period["collected"]["total"] + period["pending"]["total"] + period["overdue"]["total"]
        self.assertEqual(invoiced, period["invoiced"]["total"])

    def test_expenses_vat_and_net(self):
        period = self.snapshot()["period"]
        self.assertEqual(period["expenses"], {"subtotal": 1000.0, "total": 1210.0, "count": 1})
        self.assertEqual(period["vat"], {"output": 3465.0, "input": 210.0, "balance": 3255.0})
        self.assertEqual(period["net"], 15500.0)

    def test_trends_compare_previous_period_and_last_year(self):
        trend = self.snapshot()["period"]["trend"]
        self.assertEqual(trend["previous"], 230.0)   # 5 000 -> 16 500
        self.assertEqual(trend["yoy"], 450.0)        # 3 000 -> 16 500

    def test_trend_is_none_without_a_baseline(self):
        self.assertIsNone(doklad.percent_change(Decimal(5), Decimal(0)))
        self.assertEqual(doklad.percent_change(Decimal(50), Decimal(100)), -50.0)

    def test_foreign_currency_without_rate_is_reported_separately(self):
        period = self.snapshot()["period"]
        self.assertEqual(period["foreign"], [{"currency": "EUR", "total": 99.99, "count": 1}])   # 82.64 + 21 %

    def test_quarter_and_year_horizons(self):
        quarter = self.snapshot(horizon="quarter")["period"]
        self.assertEqual((quarter["kind"], quarter["year"], quarter["index"]), ("quarter", 2026, 4))
        self.assertEqual(quarter["invoiced"]["subtotal"], 21500.0)
        year = self.snapshot(horizon="year", offset=-1)["period"]
        self.assertEqual(year["invoiced"]["subtotal"], 3000.0)
        self.assertIsNone(year["trend"]["yoy"])

    def test_bar_summary_counts_all_open_receivables(self):
        snapshot = self.snapshot()
        self.assertEqual(snapshot["bar"]["unpaidTotal"], 4340.0)
        self.assertEqual(snapshot["bar"]["unpaidCount"], 3)
        self.assertEqual(snapshot["bar"]["overdueTotal"], 1210.0)
        self.assertEqual(snapshot["bar"]["overdueCount"], 1)
        self.assertEqual(snapshot["bar"]["draftCount"], 1)
        self.assertEqual(snapshot["bar"]["monthInvoiced"], 16500.0)
        self.assertEqual(snapshot["invoiceCounts"], {"all": 11, "unpaid": 5, "overdue": 1, "paid": 4, "draft": 1})

    def test_turnover_tracks_calendar_year(self):
        turnover = self.snapshot()["turnover"]
        self.assertEqual(turnover["year"], 2026)
        self.assertEqual(turnover["yearToDate"], 21500.0)
        self.assertEqual(turnover["last12Months"], 21500.0)
        self.assertEqual(turnover["limit"], 2000000)

    def test_vat_follows_tax_date_not_issue_date(self):
        invoices = [api_invoice(1, "1000.00", status="paid", issue="2026-10-31", taxDate="2026-11-01")]
        hydrated = [doklad.hydrate_invoice(doklad.normalize_invoice(row)) for row in invoices]
        november = doklad.aggregate(hydrated, [], dt.date(2026, 11, 1), dt.date(2026, 11, 30), "CZK", TODAY)
        october = doklad.aggregate(hydrated, [], dt.date(2026, 10, 1), dt.date(2026, 10, 31), "CZK", TODAY)
        self.assertEqual((november["vatOut"], november["subtotal"]), (Decimal("210.00"), 0))
        self.assertEqual((october["vatOut"], october["subtotal"]), (0, Decimal("1000.00")))

    def test_overdue_endpoint_ids_are_honoured(self):
        invoices = [doklad.hydrate_invoice(doklad.normalize_invoice(api_invoice(2, "2000.00", due="2026-12-24")))]
        self.assertEqual(doklad.invoice_state(invoices[0], TODAY), "pending")
        self.assertEqual(doklad.invoice_state(invoices[0], TODAY, frozenset([2])), "overdue")

    def test_chart_series_shape(self):
        monthly = self.snapshot()["chart"]
        self.assertEqual(len(monthly), 12)
        self.assertEqual((monthly[-1]["year"], monthly[-1]["index"]), (2026, 11))
        self.assertEqual(monthly[-1]["paid"], 15625.0)
        self.assertEqual(monthly[-1]["unpaid"], 4340.0)
        self.assertEqual(monthly[-1]["expenses"], 1210.0)
        self.assertEqual(len(self.snapshot(horizon="quarter")["chart"]), 8)
        yearly = self.snapshot(horizon="year")["chart"]
        self.assertEqual((yearly[0]["index"], yearly[-1]["index"]), (1, 12))
        self.assertTrue(yearly[-1]["future"])

    def test_customers_rank_by_period_revenue(self):
        customers = self.snapshot()["customers"]
        self.assertEqual(customers[0]["id"], 7)
        self.assertEqual(customers[0]["revenue"], 16500.0)
        self.assertEqual(customers[0]["open"], 4340.0)
        self.assertEqual(customers[1]["revenue"], 0.0)

    def test_open_invoices_survive_the_list_cap(self):
        invoices = [api_invoice(index, "100.00", status="paid", issue="2026-06-01") for index in range(1, 700)]
        invoices.append(api_invoice(9000, "100.00", issue="2019-01-01", due="2019-02-01"))
        cache = cache_from(invoices)
        rows = doklad.build_snapshot(cache, doklad.default_state(), options(), TODAY)["invoices"]
        self.assertEqual(len(rows), doklad.MAX_UI_INVOICES)
        self.assertIn(9000, [row["id"] for row in rows])


class DiffTests(unittest.TestCase):
    def hydrate(self, rows):
        return [doklad.hydrate_invoice(doklad.normalize_invoice(row)) for row in rows]

    def run_diff(self, before, after, touched=None):
        known, _ = doklad.diff_invoices({}, False, self.hydrate(before), TODAY, {}, NOW)
        return doklad.diff_invoices(known, True, self.hydrate(after), TODAY, touched or {}, NOW)[1]

    def test_first_run_is_silent(self):
        _, changes = doklad.diff_invoices({}, False, self.hydrate(sample_invoices()), TODAY, {}, NOW)
        self.assertEqual(changes, [])

    def test_detects_payment(self):
        changes = self.run_diff([api_invoice(2, "2000.00")], [api_invoice(2, "2000.00", status="paid")])
        self.assertEqual([(kind, invoice["id"]) for kind, invoice in changes], [("paid", 2)])

    def test_detects_invoice_becoming_overdue_once(self):
        before = [api_invoice(2, "2000.00", due="2026-11-24")]
        after = [api_invoice(2, "2000.00", due="2026-11-17")]
        self.assertEqual([kind for kind, _ in self.run_diff(before, after)], ["overdue"])
        self.assertEqual(self.run_diff(after, after), [])

    def test_detects_new_invoice_but_not_drafts_or_old_imports(self):
        before = [api_invoice(1, "100.00")]
        after = before + [api_invoice(2, "100.00", issue="2026-11-17"),
                          api_invoice(3, "100.00", status="draft", issue="2026-11-17"),
                          api_invoice(4, "100.00", status="paid", issue="2024-01-01")]
        self.assertEqual([(kind, invoice["id"]) for kind, invoice in self.run_diff(before, after)], [("created", 2)])

    def test_own_actions_are_not_announced(self):
        before, after = [api_invoice(2, "2000.00")], [api_invoice(2, "2000.00", status="paid")]
        self.assertEqual(self.run_diff(before, after, {"2": NOW - 30}), [])
        self.assertEqual(len(self.run_diff(before, after, {"2": NOW - doklad.SELF_TOUCH_TTL - 1})), 1)

    def test_privacy_mode_hides_amounts(self):
        invoice = self.hydrate([api_invoice(2, "2000.00")])[0]
        visible = doklad.build_notifications([("paid", invoice)], doklad.NOTIFY_FALLBACK, False, "cs")[0][2]
        hidden = doklad.build_notifications([("paid", invoice)], doklad.NOTIFY_FALLBACK, True, "cs")[0][2]
        self.assertIn("2\u00a0420,00", visible)
        self.assertNotIn("420", hidden)

    def test_notification_burst_is_capped(self):
        invoices = self.hydrate([api_invoice(index, "10.00") for index in range(1, 11)])
        messages = doklad.build_notifications([("paid", invoice) for invoice in invoices],
                                              doklad.NOTIFY_FALLBACK, False, "en")
        self.assertEqual(len(messages), doklad.MAX_NOTIFICATIONS + 1)
        self.assertIn("6", messages[-1][2])


class SecretStorageTests(TempHome):
    def test_env_file_with_private_mode_is_loaded(self):
        self.write_env("# comment\nDOKLAD_API_KEY=dk_file\nexport DOKLAD_RELAY_TOKEN='tok'\nUNRELATED=1\n")
        secrets = doklad.load_secrets(self.paths, self.environ)
        self.assertEqual(secrets["DOKLAD_API_KEY"], "dk_file")
        self.assertEqual(secrets["DOKLAD_RELAY_TOKEN"], "tok")
        self.assertNotIn("UNRELATED", secrets)

    def test_process_environment_takes_priority(self):
        self.write_env("DOKLAD_API_KEY=dk_file\n")
        secrets = doklad.load_secrets(self.paths, dict(self.environ, DOKLAD_API_KEY="dk_env"))
        self.assertEqual(secrets["DOKLAD_API_KEY"], "dk_env")

    def test_group_or_world_readable_env_file_is_refused(self):
        for mode in (0o640, 0o644, 0o604):
            self.write_env("DOKLAD_API_KEY=dk_file\n", mode)
            with self.assertRaises(doklad.DokladError) as caught:
                doklad.load_secrets(self.paths, self.environ)
            self.assertEqual(caught.exception.code, "insecure_env")

    def test_symlinked_env_file_is_refused(self):
        os.makedirs(self.paths.config_dir, mode=0o700)
        target = os.path.join(self.home, "elsewhere")
        with open(target, "w", encoding="utf-8") as handle:
            handle.write("DOKLAD_API_KEY=dk_link\n")
        os.chmod(target, 0o600)
        os.symlink(target, self.paths.env_file)
        with self.assertRaises(doklad.DokladError) as caught:
            doklad.load_secrets(self.paths, self.environ)
        self.assertEqual(caught.exception.code, "storage_unsafe")

    def test_header_injection_in_key_is_rejected(self):
        with self.assertRaises(doklad.DokladError) as caught:
            doklad.load_secrets(self.paths, dict(self.environ, DOKLAD_API_KEY="dk_x\r\nX-Evil: 1"))
        self.assertEqual(caught.exception.code, "invalid_env")

    def test_update_env_file_keeps_other_keys_and_private_mode(self):
        self.write_env("DOKLAD_API_KEY=dk_file\nDOKLAD_WEBHOOK_SECRET=whsec_old\n")
        doklad.update_env_file(self.paths, {"DOKLAD_WEBHOOK_SECRET": "whsec_new"})
        secrets = doklad.load_secrets(self.paths, self.environ)
        self.assertEqual(secrets["DOKLAD_API_KEY"], "dk_file")
        self.assertEqual(secrets["DOKLAD_WEBHOOK_SECRET"], "whsec_new")
        self.assertEqual(stat.S_IMODE(os.stat(self.paths.env_file).st_mode), 0o600)

    def test_store_secret_validates_and_removes(self):
        self.assertTrue(doklad.store_secret(self.paths, "DOKLAD_API_KEY", "  'dk_quoted'\n"))
        self.assertTrue(doklad.store_secret(self.paths, "DOKLAD_RELAY_URL", "https://hook.example.cz/\n"))
        secrets = doklad.load_secrets(self.paths, self.environ)
        self.assertEqual(secrets["DOKLAD_API_KEY"], "dk_quoted")
        self.assertEqual(secrets["DOKLAD_RELAY_URL"], "https://hook.example.cz")
        self.assertEqual(stat.S_IMODE(os.stat(self.paths.env_file).st_mode), 0o600)
        self.assertFalse(doklad.store_secret(self.paths, "DOKLAD_RELAY_URL", "\n"))
        self.assertEqual(doklad.load_secrets(self.paths, self.environ)["DOKLAD_RELAY_URL"], "")
        for name, value in (("DOKLAD_API_KEY", "dk with space"), ("DOKLAD_API_KEY", "dk_x\nX: 1"),
                            ("DOKLAD_RELAY_URL", "http://hook.example.cz"), ("PATH", "/tmp")):
            with self.assertRaises(doklad.DokladError, msg=name):
                doklad.store_secret(self.paths, name, value)
        self.assertEqual(doklad.load_secrets(self.paths, self.environ)["DOKLAD_API_KEY"], "dk_quoted")

    def test_private_files_and_directories_have_tight_modes(self):
        doklad.ensure_private_dir(self.paths.state_dir)
        doklad.write_json_file(self.paths.state_file, {"a": 1})
        self.assertEqual(stat.S_IMODE(os.stat(self.paths.state_dir).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(self.paths.state_file).st_mode), 0o600)
        os.chmod(self.paths.state_dir, 0o755)
        doklad.ensure_private_dir(self.paths.state_dir)
        self.assertEqual(stat.S_IMODE(os.stat(self.paths.state_dir).st_mode), 0o700)

    def test_symlinked_state_directory_is_refused(self):
        real = os.path.join(self.home, "real")
        os.makedirs(real)
        os.makedirs(os.path.dirname(self.paths.state_dir))
        os.symlink(real, self.paths.state_dir)
        with self.assertRaises(doklad.DokladError):
            doklad.ensure_private_dir(self.paths.state_dir)

    def test_oversized_file_is_refused(self):
        self.write_env("DOKLAD_API_KEY=" + "x" * (doklad.MAX_ENV_BYTES + 10) + "\n")
        with self.assertRaises(doklad.DokladError) as caught:
            doklad.load_secrets(self.paths, self.environ)
        self.assertEqual(caught.exception.code, "storage_too_large")


class SnapshotTests(TempHome):
    def test_unconfigured_without_key(self):
        result = doklad.run_snapshot(self.context(), options())
        self.assertEqual(result["status"], "unconfigured")
        self.assertEqual(self.transport.calls, [])

    def test_full_refresh_writes_private_cache_and_never_leaks_the_key(self):
        self.write_env("DOKLAD_API_KEY=dk_supersecret_value\n")
        self.serve_dataset()
        result = doklad.run_snapshot(self.context(), options())
        self.assertEqual(result["status"], "ready")
        self.assertTrue(result["hasData"])
        self.assertEqual(result["period"]["invoiced"]["subtotal"], 16500.0)
        self.assertNotIn("dk_supersecret_value", json.dumps(result))
        self.assertEqual(stat.S_IMODE(os.stat(self.paths.cache_file).st_mode), 0o600)
        with open(self.paths.cache_file, encoding="utf-8") as handle:
            self.assertNotIn("dk_supersecret_value", handle.read())
        for call in self.transport.calls:
            self.assertEqual(call["headers"]["Authorization"], "Bearer dk_supersecret_value")
            self.assertNotIn("dk_supersecret_value", json.dumps(call["query"]))

    def test_fresh_cache_is_reused_and_cached_mode_skips_network(self):
        self.write_env("DOKLAD_API_KEY=dk_test\n")
        self.serve_dataset()
        doklad.run_snapshot(self.context(), options())
        calls = len(self.transport.calls)
        result = doklad.run_snapshot(self.context(now=NOW + 60), options(horizon="quarter"))
        self.assertEqual(len(self.transport.calls), calls)
        self.assertEqual(result["period"]["kind"], "quarter")
        doklad.run_snapshot(self.context(now=NOW + 99999), options(cached=True))
        self.assertEqual(len(self.transport.calls), calls)
        doklad.run_snapshot(self.context(now=NOW + 400), options())
        self.assertGreater(len(self.transport.calls), calls)

    def test_network_failure_serves_stale_cache(self):
        self.write_env("DOKLAD_API_KEY=dk_test\n")
        self.serve_dataset()
        doklad.run_snapshot(self.context(), options())
        self.transport.on("GET", "/api/invoices", doklad.DokladError("offline"))
        result = doklad.run_snapshot(self.context(now=NOW + 1000), options())
        self.assertEqual(result["status"], "offline")
        self.assertTrue(result["stale"])
        self.assertTrue(result["hasData"])
        self.assertEqual(result["period"]["invoiced"]["count"], 5)

    def test_invalid_key_without_cache(self):
        self.write_env("DOKLAD_API_KEY=dk_test\n")
        self.transport.on("GET", "/api/invoices", reply(401, {"message": "Unauthorized"}))
        result = doklad.run_snapshot(self.context(), options())
        self.assertEqual((result["status"], result["hasData"]), ("unauthorized", False))

    def test_plan_without_expenses_still_works(self):
        self.write_env("DOKLAD_API_KEY=dk_test\n")
        self.serve_dataset()
        self.transport.on("GET", "/api/expenses", reply(403, {"message": "Not in plan"}))
        result = doklad.run_snapshot(self.context(), options())
        self.assertEqual(result["status"], "ready")
        self.assertFalse(result["expensesAvailable"])
        self.assertEqual(result["period"]["expenses"]["count"], 0)

    def test_change_notifications_fire_once(self):
        self.write_env("DOKLAD_API_KEY=dk_test\n")
        self.serve_dataset(invoices=[api_invoice(2, "2000.00")])
        doklad.run_snapshot(self.context(), options())
        self.assertEqual(self.notifications, [])
        self.serve_dataset(invoices=[api_invoice(2, "2000.00", status="paid")])
        doklad.run_snapshot(self.context(now=NOW + 400), options())
        self.assertEqual(len(self.notifications), 1)
        self.assertEqual(self.notifications[0][0], "paid")
        doklad.run_snapshot(self.context(now=NOW + 800), options())
        self.assertEqual(len(self.notifications), 1)

    def test_notifications_can_be_disabled(self):
        self.write_env("DOKLAD_API_KEY=dk_test\n")
        self.serve_dataset(invoices=[api_invoice(2, "2000.00")])
        doklad.run_snapshot(self.context(), options(notify=False))
        self.serve_dataset(invoices=[api_invoice(2, "2000.00", status="paid")])
        doklad.run_snapshot(self.context(now=NOW + 400), options(notify=False))
        self.assertEqual(self.notifications, [])


class RelayTests(TempHome):
    def test_relay_url_validation(self):
        self.assertEqual(doklad.parse_relay_url("https://hook.example.cz"), ("hook.example.cz", 443, ""))
        self.assertEqual(doklad.parse_relay_url("https://example.cz/doklad/"), ("example.cz", 443, "/doklad"))
        for bad in ("http://hook.example.cz", "https://user:pw@hook.example.cz", "https://hook.example.cz/?a=1",
                    "https://localhost", "https://exa mple.cz", "ftp://x.cz", "https://hook.example.cz/../x",
                    "https://hook.example.cz:99999", ""):
            with self.assertRaises(doklad.DokladError, msg=bad):
                doklad.parse_relay_url(bad)

    def relay_env(self):
        self.write_env("DOKLAD_API_KEY=dk_test\nDOKLAD_RELAY_URL=https://hook.example.cz\n"
                       "DOKLAD_RELAY_TOKEN=relaytoken\n")

    def test_signal_forces_refresh_and_is_listed(self):
        self.relay_env()
        self.serve_dataset(invoices=[api_invoice(2, "2000.00")])
        self.transport.on("GET", "/events", reply(200, {"events": [], "cursor": 0}))
        doklad.run_snapshot(self.context(), options())
        fetches = self.transport.count("GET", "/api/invoices")
        self.serve_dataset(invoices=[api_invoice(2, "2000.00", status="paid")])
        self.transport.on("GET", "/events", reply(200, {"events": [
            {"seq": 4, "event": "invoice.paid", "resourceId": 2, "receivedAt": NOW + 5}], "cursor": 4}))
        result = doklad.run_snapshot(self.context(now=NOW + 10), options())
        self.assertEqual(self.transport.count("GET", "/api/invoices"), fetches + 1)   # cache was still fresh
        self.assertEqual(len(self.notifications), 1)
        self.assertEqual(result["events"][0]["event"], "invoice.paid")
        self.assertEqual(result["events"][0]["number"], "20260002")
        self.assertTrue(result["relay"]["ok"])
        call = self.transport.last("GET", "/events")
        self.assertEqual(call["headers"]["Authorization"], "Bearer relaytoken")
        self.assertEqual(self.transport.calls[-1]["headers"]["Authorization"], "Bearer dk_test")
        doklad.run_snapshot(self.context(now=NOW + 20), options())
        self.assertEqual(self.transport.last("GET", "/events")["query"]["after"], "4")

    def test_api_key_is_never_sent_to_the_relay(self):
        self.relay_env()
        self.serve_dataset()
        self.transport.on("GET", "/events", reply(200, {"events": [], "cursor": 0}))
        doklad.run_snapshot(self.context(), options())
        for call in self.transport.calls:
            if call["path"] == "/events":
                self.assertNotIn("dk_test", json.dumps(call))

    def test_relay_failure_is_reported_but_not_fatal(self):
        self.relay_env()
        self.serve_dataset()
        self.transport.on("GET", "/events", reply(401, {}))
        result = doklad.run_snapshot(self.context(), options())
        self.assertEqual(result["status"], "ready")
        self.assertEqual(result["relay"]["error"], "relay_unauthorized")
        self.assertFalse(result["relay"]["ok"])

    def test_reset_relay_restarts_the_cursor(self):
        seen = []

        def transport(method, target, body, headers, max_bytes):
            seen.append(target)
            if target.endswith("after=40"):
                return reply(200, {"events": [], "cursor": 2, "head": 2})
            return reply(200, {"events": [{"seq": 1, "event": "invoice.paid", "receivedAt": NOW},
                                          {"seq": 2, "event": "invoice.created", "receivedAt": NOW}],
                               "cursor": 2, "head": 2})

        events, cursor = doklad.relay_fetch(transport, "", "tok", 40)
        self.assertEqual(seen, ["/events?after=40", "/events?after=0"])
        self.assertEqual(([event["seq"] for event in events], cursor), ([1, 2], 2))
        events, cursor = doklad.relay_fetch(
            lambda *args: reply(200, {"events": [], "cursor": 40, "head": 40}), "", "tok", 40)
        self.assertEqual((events, cursor), ([], 40))

    def test_relay_without_secrets_is_reported(self):
        with self.assertRaises(doklad.DokladError) as caught:
            doklad.relay_fetch(lambda *args: reply(503), "", "tok", 0)
        self.assertEqual(caught.exception.code, "relay_not_ready")

    def test_malformed_signals_are_dropped(self):
        events, cursor = doklad.relay_fetch(
            lambda *args: reply(200, {"events": [
                {"seq": 2, "event": "invoice.paid", "resourceId": 9, "receivedAt": NOW},
                {"seq": 3, "event": "<script>", "receivedAt": NOW},
                {"seq": "4", "event": "invoice.paid", "receivedAt": NOW},
                {"seq": 1, "event": "invoice.paid", "receivedAt": NOW},
                "junk"]}), "", "tok", 1)
        self.assertEqual([event["seq"] for event in events], [2])
        self.assertEqual(cursor, 2)


class ActionTests(TempHome):
    def setUp(self):
        super().setUp()
        self.write_env("DOKLAD_API_KEY=dk_test\n")

    def run_action(self, name, payload, **kwargs):
        return doklad.run_action(self.context(**kwargs), name, payload)

    def test_unknown_action_and_bad_payload(self):
        self.assertEqual(self.run_action("rm-rf", {})["error"], "unknown_action")
        self.assertEqual(self.run_action("copy", ["x"])["error"], "invalid_input")

    def test_record_payment(self):
        self.transport.on("POST", "/api/invoices/12/payments", reply(201, {"id": 1}))
        result = self.run_action("record-payment", {"id": 12, "amount": "1 210,00", "paidAt": "2026-11-18"})
        self.assertTrue(result["ok"])
        self.assertEqual(self.transport.last("POST", "/api/invoices/12/payments")["payload"],
                         {"amount": "1210.00", "paidAt": "2026-11-18", "paymentMethod": "bank_transfer"})
        self.assertEqual(doklad.load_state(self.paths)["selfTouched"], {"12": NOW})

    def test_record_payment_validation(self):
        for payload in ({"id": 12, "amount": "0", "paidAt": "2026-11-18"},
                        {"id": 12, "amount": "-5", "paidAt": "2026-11-18"},
                        {"id": 12, "amount": "10", "paidAt": "2026-11-19"},
                        {"id": "x", "amount": "10", "paidAt": "2026-11-18"}):
            self.assertFalse(self.run_action("record-payment", payload)["ok"])
        self.assertEqual(self.transport.calls, [])

    def test_send_email(self):
        self.transport.on("POST", "/api/invoices/12/email", reply(200, {}))
        result = self.run_action("send-email", {"id": 12, "to": "jana@example.cz", "message": "D\u011bkujeme\nza platbu"})
        self.assertTrue(result["ok"])
        self.assertEqual(self.transport.last("POST", "/api/invoices/12/email")["payload"],
                         {"to": "jana@example.cz", "customMessage": "D\u011bkujeme\nza platbu"})
        self.assertEqual(self.run_action("send-email", {"id": 12, "to": "x@y"})["error"], "invalid_email")
        self.transport.on("POST", "/api/invoices/12/email", reply(429, {"message": "limit"}))
        self.assertEqual(self.run_action("send-email", {"id": 12})["error"], "rate_limited")

    def test_set_status_only_allows_known_values(self):
        self.transport.on("PATCH", "/api/invoices/12", reply(200, {}))
        self.assertTrue(self.run_action("set-status", {"id": 12, "status": "cancelled"})["ok"])
        self.assertEqual(self.run_action("set-status", {"id": 12, "status": "draft"})["error"], "invalid_input")
        self.assertEqual(self.transport.count("PATCH", "/api/invoices/12"), 1)

    def test_only_drafts_can_be_deleted(self):
        self.transport.on("GET", "/api/invoices/12", reply(200, api_invoice(12, "100.00", status="sent")))
        self.transport.on("DELETE", "/api/invoices/12", reply(200, {}))
        self.assertEqual(self.run_action("delete-draft", {"id": 12})["error"], "not_a_draft")
        self.assertEqual(self.transport.count("DELETE", "/api/invoices/12"), 0)
        self.transport.on("GET", "/api/invoices/12", reply(200, api_invoice(12, "100.00", status="draft")))
        self.assertTrue(self.run_action("delete-draft", {"id": 12})["ok"])
        self.assertEqual(self.transport.count("DELETE", "/api/invoices/12"), 1)

    def invoice_form(self, **overrides):
        form = {"customerId": 7, "customerName": "Acme s.r.o.", "issueDate": "2026-11-18", "dueDate": "2026-12-02",
                "items": [{"description": "Konzultace", "quantity": "1", "unitPrice": "1000", "vatRate": "21"}]}
        form.update(overrides)
        return form

    def test_create_invoice_defaults_to_draft(self):
        self.transport.on("POST", "/api/invoices", reply(201, {"id": 55, "invoiceNumber": None}))
        result = self.run_action("create-invoice", self.invoice_form())
        self.assertTrue(result["ok"])
        self.assertTrue(result["draft"])
        self.assertEqual(self.transport.last("POST", "/api/invoices")["payload"]["status"], "draft")
        self.assertEqual(result["total"], 1210.0)

    def test_create_final_invoice_reports_duplicate_warning(self):
        self.transport.on("POST", "/api/invoices", reply(
            201, {"id": 56, "invoiceNumber": "20260056", "duplicateWarning": True}, {"x-duplicate-warning": "1"}))
        result = self.run_action("create-invoice", self.invoice_form(draft=False))
        self.assertEqual((result["number"], result["draft"], result["duplicateWarning"]), ("20260056", False, True))
        self.assertNotIn("status", self.transport.last("POST", "/api/invoices")["payload"])

    def test_double_submit_is_blocked_locally(self):
        self.transport.on("POST", "/api/invoices", reply(201, {"id": 55}))
        self.assertTrue(self.run_action("create-invoice", self.invoice_form())["ok"])
        self.assertEqual(self.run_action("create-invoice", self.invoice_form())["error"], "duplicate_recent")
        self.assertEqual(self.transport.count("POST", "/api/invoices"), 1)
        self.assertTrue(self.run_action("create-invoice", self.invoice_form(force=True))["ok"])
        self.assertTrue(self.run_action("create-invoice", self.invoice_form(), now=NOW + 500)["ok"])

    def test_timeout_is_verified_instead_of_retried(self):
        self.transport.on("POST", "/api/invoices", doklad.DokladError("timeout"))
        self.transport.on("GET", "/api/invoices", reply(200, {"data": [
            api_invoice(77, "1000.00", issue="2026-11-18", status="draft")], "totalPages": 1}))
        result = self.run_action("create-invoice", self.invoice_form())
        self.assertTrue(result["ok"])
        self.assertEqual(result["id"], 77)
        self.assertEqual(self.transport.count("POST", "/api/invoices"), 1)
        query = self.transport.last("GET", "/api/invoices")["query"]
        self.assertEqual((query["customerId"], query["dateFrom"], query["dateTo"]), ("7", "2026-11-18", "2026-11-18"))

    def test_timeout_without_a_created_invoice(self):
        self.transport.on("POST", "/api/invoices", doklad.DokladError("timeout"))
        self.transport.on("GET", "/api/invoices", reply(200, {"data": [], "totalPages": 1}))
        self.assertEqual(self.run_action("create-invoice", self.invoice_form())["error"], "create_not_found")
        self.transport.on("GET", "/api/invoices", doklad.DokladError("offline"))
        self.assertEqual(self.run_action("create-invoice", self.invoice_form(force=True))["error"], "create_uncertain")
        self.assertEqual(self.transport.count("POST", "/api/invoices"), 2)

    def test_old_lookalike_invoice_is_not_mistaken_for_the_new_one(self):
        self.transport.on("POST", "/api/invoices", doklad.DokladError("timeout"))
        self.transport.on("GET", "/api/invoices", reply(200, {"data": [
            api_invoice(70, "1000.00", issue="2026-11-18", createdAt="2026-11-18T06:00:00Z")], "totalPages": 1}))
        result = self.run_action("create-invoice", self.invoice_form(), now=dt.datetime(
            2026, 11, 18, 20, 0, tzinfo=dt.timezone.utc).timestamp())
        self.assertEqual(result["error"], "create_not_found")

    def test_validation_error_is_not_followed_by_a_lookup(self):
        self.transport.on("POST", "/api/invoices", reply(400, {"code": "VALIDATION_ERROR", "message": "Chyba"}))
        self.assertEqual(self.run_action("create-invoice", self.invoice_form())["error"], "validation")
        self.assertEqual(self.transport.count("GET", "/api/invoices"), 0)

    def test_ares_lookup_is_unauthenticated(self):
        self.transport.on("GET", "/api/test/ares/lookup/27074358", reply(200, {
            "ico": "27074358", "name": "Asseco Central Europe, a.s.", "dic": "CZ27074358", "isVatPayer": True,
            "legalForm": {"code": "121", "name": "Akciov\u00e1 spole\u010dnost"},
            "address": "Bud\u011bjovick\u00e1 778/3a", "city": "Praha", "postalCode": "14000"}))
        result = self.run_action("ares-lookup", {"ico": "27074358", "country": "CZ"})
        self.assertEqual(result["company"]["name"], "Asseco Central Europe, a.s.")
        self.assertEqual(result["company"]["postalCode"], "14000")
        self.assertTrue(result["company"]["isVatPayer"])
        call = self.transport.last("GET", "/api/test/ares/lookup/27074358")
        self.assertNotIn("Authorization", call["headers"])
        self.assertEqual(call["query"]["country"], "CZ")
        self.assertEqual(self.run_action("ares-lookup", {"ico": "../../x"})["error"], "invalid_ico")

    def test_create_customer_refuses_known_ico(self):
        doklad.ensure_private_dir(self.paths.state_dir)
        doklad.write_json_file(self.paths.cache_file, cache_from([], [], sample_customers()))
        self.assertEqual(self.run_action("create-customer", {"name": "Acme", "ico": "12345678"})["error"],
                         "customer_exists")
        self.transport.on("POST", "/api/customers", reply(201, {"id": 9}))
        self.assertEqual(self.run_action("create-customer", {"name": "Nov\u00fd", "ico": "11112222"})["id"], 9)

    def test_download_pdf_checks_content_and_stores_privately(self):
        self.transport.on("GET", "/api/invoices/12/pdf", reply(200, b"%PDF-1.7 fake"))
        result = self.run_action("download-pdf", {"id": 12, "number": "2026/0012 ../x"})
        self.assertEqual(result["file"], "faktura-2026-0012-x.pdf")
        path = os.path.join(self.paths.download_dir, result["file"])
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(self.spawned, [["/usr/bin/xdg-open", path]])
        self.transport.on("GET", "/api/invoices/12/pdf", reply(200, b"<html>login</html>"))
        self.assertEqual(self.run_action("download-pdf", {"id": 12})["error"], "bad_response")

    def test_bulk_pdf_tries_alternative_body_shape(self):
        self.transport.on("POST", "/api/invoices/bulk-pdf", lambda call: reply(200, b"PK\x03\x04zip")
                          if "ids" in call["payload"] else reply(400, {"code": "VALIDATION_ERROR"}))
        result = self.run_action("bulk-pdf", {"ids": [1, 2, 2, "3", "x"], "label": "2026-Q4"})
        self.assertEqual((result["file"], result["count"]), ("faktury-2026-Q4.zip", 3))
        self.assertEqual(self.transport.last("POST", "/api/invoices/bulk-pdf")["payload"], {"ids": [1, 2, 3]})

    def test_export_names_file_by_period_and_format(self):
        self.transport.on("GET", "/api/export/invoices/pohoda", reply(200, b"<?xml version='1.0'?><dat/>"))
        result = self.run_action("export", {"format": "pohoda", "from": "2026-10-01", "to": "2026-12-31",
                                            "label": "2026-Q4"})
        self.assertEqual(result["file"], "doklad-2026-Q4-pohoda.xml")
        self.assertEqual(self.transport.last("GET", "/api/export/invoices/pohoda")["query"],
                         {"dateFrom": "2026-10-01", "dateTo": "2026-12-31"})
        self.assertEqual(self.run_action("export", {"format": "../x", "from": "2026-10-01", "to": "2026-12-31"})["error"],
                         "invalid_input")

    def test_preview_invoice_is_offline(self):
        result = self.run_action("preview-invoice", self.invoice_form())
        self.assertTrue(result["ok"])
        self.assertEqual((result["draft"], result["itemCount"], result["subtotal"], result["vatAmount"], result["total"]),
                         (True, 1, 1000.0, 210.0, 1210.0))
        self.assertEqual(self.transport.calls, [])

    def test_preview_expense_is_offline(self):
        result = self.run_action("preview-expense", {
            "description": "Hosting", "amount": "1 000", "vatRate": "21", "expenseDate": "2026-11-01"})
        self.assertTrue(result["ok"])
        self.assertEqual((result["amount"], result["vatAmount"], result["total"]), (1000.0, 210.0, 1210.0))
        self.assertEqual(self.transport.calls, [])
        self.assertEqual(self.run_action("preview-expense", {"description": "x", "amount": "0", "expenseDate": "2026-11-01"})["error"],
                         "invalid_amount")

    def test_load_notify_strings_uses_czech_and_slovak(self):
        strings = doklad.load_notify_strings(self.paths, "en")
        self.assertEqual(strings["notify.paid"], "Faktura zaplacena")
        strings = doklad.load_notify_strings(self.paths, "sk")
        self.assertEqual(strings["notify.paid"], "Faktúra zaplatená")

    def test_register_webhook_stores_secret_privately_and_never_returns_it(self):
        self.write_env("DOKLAD_API_KEY=dk_test\nDOKLAD_RELAY_URL=https://hook.example.cz\nDOKLAD_RELAY_TOKEN=tok\n")
        self.transport.on("GET", "/api/settings/webhooks", reply(200, []))
        self.transport.on("POST", "/api/settings/webhooks", reply(201, {"id": 3, "secret": "whsec_abc123"}))
        result = self.run_action("register-webhook", {})
        self.assertTrue(result["ok"])
        self.assertTrue(result["secretStored"])
        self.assertNotIn("whsec_abc123", json.dumps(result))
        payload = self.transport.last("POST", "/api/settings/webhooks")["payload"]
        self.assertEqual(payload["url"], "https://hook.example.cz/webhook")
        self.assertEqual(payload["events"], doklad.WEBHOOK_EVENTS)
        self.assertEqual(doklad.load_secrets(self.paths, self.environ)["DOKLAD_WEBHOOK_SECRET"], "whsec_abc123")
        self.assertEqual(stat.S_IMODE(os.stat(self.paths.env_file).st_mode), 0o600)

    def test_register_webhook_refuses_duplicates(self):
        self.write_env("DOKLAD_API_KEY=dk_test\nDOKLAD_RELAY_URL=https://hook.example.cz\nDOKLAD_RELAY_TOKEN=tok\n")
        self.transport.on("GET", "/api/settings/webhooks", reply(200, [
            {"id": 3, "url": "https://hook.example.cz/webhook", "events": ["invoice.paid"], "secret": "whsec_zzz"}]))
        result = self.run_action("register-webhook", {})
        self.assertEqual(result["error"], "webhook_exists")
        self.assertEqual(self.transport.count("POST", "/api/settings/webhooks"), 0)
        listed = self.run_action("list-webhooks", {})
        self.assertNotIn("whsec_zzz", json.dumps(listed))

    def test_register_webhook_needs_relay(self):
        self.assertEqual(self.run_action("register-webhook", {})["error"], "relay_not_configured")

    def test_open_accepts_only_known_targets(self):
        self.assertTrue(self.run_action("open", {"target": "web"})["ok"])
        self.assertEqual(self.spawned[-1], ["/usr/bin/xdg-open", "https://doklad.ai/"])
        self.assertEqual(self.run_action("open", {"target": "https://evil.invalid"})["error"], "invalid_input")
        self.assertEqual(len(self.spawned), 1)


if __name__ == "__main__":
    unittest.main()
