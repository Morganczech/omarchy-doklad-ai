#!/usr/bin/env python3
"""Hardened Doklad.ai client, analytics engine and action runner for Omarchy.

Runs as an isolated helper (`/usr/bin/python3 -I -B doklad.py ...`) so that API
credentials never enter the shell's QML state, process arguments or logs.

Commands:
  snapshot [--horizon H] [--offset N] [--max-age S] [--force] [--cached]
           [--notify] [--privacy] [--lang CODE] [--limit CZK]
  action <name>        (JSON payload on one stdin line)
  verify-auth
  set-secret <NAME>    (value on one stdin line; empty removes it)
"""

import argparse
import datetime as dt
import errno
import fcntl
import hashlib
import http.client
import json
import math
import os
import re
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import time
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from urllib.parse import quote, urlencode, urlsplit

API_HOST = "doklad.ai"
WEB_URL = "https://doklad.ai/"
USER_AGENT = "omarchy-doklad-ai/1.0"

MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_BINARY_BYTES = 96 * 1024 * 1024
MAX_ENV_BYTES = 16 * 1024
MAX_CACHE_BYTES = 48 * 1024 * 1024
MAX_STATE_BYTES = 4 * 1024 * 1024
MAX_STDIN_BYTES = 128 * 1024
MAX_CATALOG_BYTES = 256 * 1024

PAGE_LIMIT = 100
MAX_PAGES = 200
MAX_RECORDS = 20000
MAX_UI_INVOICES = 400
MAX_UI_CUSTOMERS = 300
MAX_ITEMS = 50
MAX_BULK_IDS = 200
MAX_EVENTS = 30
MAX_NOTIFICATIONS = 4

API_TIMEOUT = 20
RELAY_TIMEOUT = 8
SELF_TOUCH_TTL = 900
DUPLICATE_WINDOW = 120
CACHE_VERSION = 2
STATE_VERSION = 1

SECRET_KEYS = (
    "DOKLAD_API_KEY",
    "DOKLAD_RELAY_URL",
    "DOKLAD_RELAY_TOKEN",
    "DOKLAD_WEBHOOK_SECRET",
)

HORIZONS = ("month", "quarter", "year", "ltm")
EXCLUDED_INVOICE_STATUSES = {"draft", "cancelled", "canceled"}
EXCLUDED_EXPENSE_STATUSES = {"draft", "concept", "rejected", "cancelled", "canceled"}
SETTABLE_STATUSES = {"sent", "paid", "overdue", "cancelled"}
PAYMENT_METHODS = {"bank_transfer", "cash", "card", "other"}
EXPORT_FORMATS = {
    "csv": ("csv", "csv"),
    "isdoc": ("isdoc", "isdoc"),
    "pohoda": ("pohoda", "xml"),
    "money-s3": ("money-s3", "xml"),
}
# Events the public documentation confirms are actually delivered.
WEBHOOK_EVENTS = [
    "invoice.created",
    "invoice.paid",
    "invoice.overdue",
    "customer.created",
]

SECRET_VALUE_RE = re.compile(r"^[\x21-\x7e]{1,512}$")
ENV_LINE_RE = re.compile(r"^(?:export\s+)?([A-Z][A-Z0-9_]{0,63})=(.*)$")
DECIMAL_RE = re.compile(r"^-?\d{1,15}(?:\.\d{1,6})?$")
ICO_RE = re.compile(r"^\d{8}$")
EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+\-]{1,64}@[A-Za-z0-9.\-]{1,190}\.[A-Za-z]{2,24}$")
HOST_RE = re.compile(r"^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)+$")
RELAY_PREFIX_RE = re.compile(r"^(?:/[A-Za-z0-9._~\-]{1,64}){0,4}$")
EVENT_NAME_RE = re.compile(r"^[a-z_]{1,32}\.[a-z_]{1,32}$")
LABEL_RE = re.compile(r"^[A-Za-z0-9_\-]{1,40}$")
BIDI_RE = re.compile("[\u200e\u200f\u202a-\u202e\u2066-\u2069\ufeff]")

CENT = Decimal("0.01")
ZERO = Decimal(0)


class DokladError(Exception):
    """Controlled, UI-safe error. `code` is a stable identifier, `detail` is sanitized."""

    def __init__(self, code, detail="", status=0):
        super().__init__(code)
        self.code = code
        self.detail = clean_text(detail, 240)
        self.status = status


# --------------------------------------------------------------------------
# Sanitizing and parsing primitives
# --------------------------------------------------------------------------

def clean_text(value, max_len=120):
    """Collapse to a single plain-text line: no control or bidi characters."""
    if isinstance(value, bool) or value is None:
        return ""
    if isinstance(value, (int, float)):
        value = str(value)
    if not isinstance(value, str):
        return ""
    out = []
    for ch in value:
        code = ord(ch)
        out.append(" " if code < 0x20 or code == 0x7F or 0x80 <= code <= 0x9F else ch)
    cleaned = BIDI_RE.sub("", "".join(out))
    return " ".join(cleaned.split())[:max_len]


def clean_multiline(value, max_len=5000):
    """Like clean_text but keeps line breaks (e-mail message bodies)."""
    if not isinstance(value, str):
        return ""
    lines = [clean_text(line, max_len) for line in value.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    return "\n".join(lines).strip()[:max_len]


def to_decimal(value, default=None):
    """Parse an API or user supplied amount. Accepts a decimal comma."""
    if isinstance(value, bool) or value is None:
        return default
    if isinstance(value, int):
        return Decimal(value) if abs(value) < 10 ** 15 else default
    if isinstance(value, float):
        if not math.isfinite(value) or abs(value) >= 10 ** 15:
            return default
        value = format(value, ".6f")
    if not isinstance(value, str):
        return default
    text = value.strip().replace(" ", "").replace("\u00a0", "").replace("\u202f", "")
    if "," in text and "." not in text:
        text = text.replace(",", ".")
    if not DECIMAL_RE.match(text):
        return default
    try:
        return Decimal(text)
    except InvalidOperation:
        return default


def money(value):
    return value.quantize(CENT, rounding=ROUND_HALF_UP)


def money_str(value):
    return format(money(value), "f")


def money_float(value):
    return float(money(value))


def plain_decimal(value):
    """Shortest exact decimal string ("2", "1.5") for quantities and rates."""
    text = format(value.normalize(), "f")
    return text if text not in ("-0", "") else "0"


def parse_date(value):
    """Return a date for 'YYYY-MM-DD' or an ISO timestamp (converted to local time)."""
    if not isinstance(value, str):
        return None
    text = value.strip()
    try:
        if len(text) == 10:
            return dt.date.fromisoformat(text)
        if 10 < len(text) <= 40:
            stamp = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
            if stamp.tzinfo is not None:
                stamp = stamp.astimezone()
            return stamp.date()
    except ValueError:
        return None
    return None


def iso(date_value):
    return date_value.isoformat() if date_value else ""


def to_int_id(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if 0 < value < 2 ** 53 else None
    if isinstance(value, str) and value.isdigit() and len(value) <= 16:
        number = int(value)
        return number if number > 0 else None
    return None


def first_of(raw, *keys):
    for key in keys:
        if key in raw and raw[key] is not None:
            return raw[key]
    return None


# --------------------------------------------------------------------------
# Private filesystem access
# --------------------------------------------------------------------------

class Paths:
    def __init__(self, config_dir, state_dir, download_dir, plugin_dir):
        self.config_dir = config_dir
        self.state_dir = state_dir
        self.download_dir = download_dir
        self.plugin_dir = plugin_dir

    @property
    def env_file(self):
        return os.path.join(self.config_dir, "env")

    @property
    def cache_file(self):
        return os.path.join(self.state_dir, "cache.json")

    @property
    def state_file(self):
        return os.path.join(self.state_dir, "state.json")

    @property
    def lock_file(self):
        return os.path.join(self.state_dir, "lock")

    @classmethod
    def from_environ(cls, environ):
        home = environ.get("HOME") or os.path.expanduser("~")

        def base(var, fallback):
            value = environ.get(var, "")
            return value if value.startswith("/") else os.path.join(home, fallback)

        downloads = environ.get("XDG_DOWNLOAD_DIR", "")
        if not downloads.startswith("/"):
            downloads = os.path.join(home, "Downloads")
        return cls(
            config_dir=os.path.join(base("XDG_CONFIG_HOME", ".config"), "omarchy-doklad-ai"),
            state_dir=os.path.join(base("XDG_STATE_HOME", ".local/state"), "omarchy-doklad-ai"),
            download_dir=os.path.join(downloads, "Doklad.ai"),
            plugin_dir=os.path.dirname(os.path.abspath(__file__)),
        )


def ensure_private_dir(path):
    """Create `path` as a 0700 directory owned by us; refuse symlinks."""
    try:
        os.makedirs(path, mode=0o700, exist_ok=True)
        info = os.lstat(path)
    except OSError:
        raise DokladError("storage_unavailable")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise DokladError("storage_unsafe")
    if stat.S_IMODE(info.st_mode) != 0o700:
        try:
            os.chmod(path, 0o700)
        except OSError:
            raise DokladError("storage_unsafe")


def read_private_file(path, max_bytes, require_private_mode=False):
    """Read a regular file we own without following symlinks. None when absent."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as exc:
        if exc.errno == errno.ENOENT:
            return None
        if exc.errno in (errno.ELOOP, errno.EMLINK):
            raise DokladError("storage_unsafe")
        raise DokladError("storage_unavailable")
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise DokladError("storage_unsafe")
        if require_private_mode and stat.S_IMODE(info.st_mode) & 0o077:
            raise DokladError("insecure_env")
        if info.st_size > max_bytes:
            raise DokladError("storage_too_large")
        chunks = []
        remaining = max_bytes + 1
        while remaining > 0:
            chunk = os.read(fd, min(remaining, 1 << 20))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > max_bytes:
            raise DokladError("storage_too_large")
        return data
    finally:
        os.close(fd)


def write_private_file(path, data):
    """Atomically write a 0600 file next to its final location."""
    directory = os.path.dirname(path)
    fd, tmp_path = tempfile.mkstemp(prefix=".tmp-", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            view = view[written:]
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(tmp_path, path)
    except OSError:
        raise DokladError("storage_unavailable")
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def read_json_file(path, max_bytes):
    raw = read_private_file(path, max_bytes)
    if raw is None:
        return None
    try:
        return json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None


def write_json_file(path, value):
    write_private_file(path, json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


# --------------------------------------------------------------------------
# Credentials
# --------------------------------------------------------------------------

def parse_env_text(text):
    values = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = ENV_LINE_RE.match(line)
        if not match:
            continue
        key, value = match.group(1), match.group(2).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    return values


def load_secrets(paths, environ):
    """Process environment first, then the private 0600 env file."""
    secrets = {}
    file_values = {}
    raw = read_private_file(paths.env_file, MAX_ENV_BYTES, require_private_mode=True)
    if raw is not None:
        try:
            file_values = parse_env_text(raw.decode("utf-8"))
        except UnicodeDecodeError:
            raise DokladError("invalid_env")
    for key in SECRET_KEYS:
        value = environ.get(key) or file_values.get(key) or ""
        value = value.strip()
        if value and not SECRET_VALUE_RE.fullmatch(value):
            raise DokladError("invalid_env", key)
        secrets[key] = value
    return secrets


def update_env_file(paths, updates):
    """Merge keys into the private env file, keeping unrelated lines. An empty value removes the key."""
    ensure_private_dir(paths.config_dir)
    raw = read_private_file(paths.env_file, MAX_ENV_BYTES, require_private_mode=True)
    try:
        lines = raw.decode("utf-8").splitlines() if raw else []
    except UnicodeDecodeError:
        raise DokladError("invalid_env")
    if not lines:
        lines = ["# Private credentials for gruut.doklad-ai (mode 0600)"]
    pending = dict(updates)
    out = []
    for line in lines:
        match = ENV_LINE_RE.match(line.strip())
        if match and match.group(1) in pending:
            value = pending.pop(match.group(1))
            if value:
                out.append("%s=%s" % (match.group(1), value))
        else:
            out.append(line)
    for key, value in pending.items():
        if value:
            out.append("%s=%s" % (key, value))
    write_private_file(paths.env_file, ("\n".join(out) + "\n").encode("utf-8"))


def store_secret(paths, name, value):
    """Validate and persist one credential. Used by the setup scripts so they never write files themselves."""
    if name not in SECRET_KEYS:
        raise DokladError("invalid_input", "name")
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1].strip()
    if value and not SECRET_VALUE_RE.fullmatch(value):
        raise DokladError("invalid_env", name)
    if value and name == "DOKLAD_RELAY_URL":
        parse_relay_url(value)
        value = value.rstrip("/")
    update_env_file(paths, {name: value})
    return bool(value)


def parse_relay_url(value):
    """Validate an https relay base URL. Returns (host, port, path_prefix)."""
    try:
        parts = urlsplit(value)
        port = parts.port or 443
    except ValueError:
        raise DokladError("relay_invalid_url")
    host = parts.hostname or ""
    if parts.scheme != "https" or parts.username or parts.password or parts.query or parts.fragment:
        raise DokladError("relay_invalid_url")
    if not HOST_RE.fullmatch(host) or not 0 < port < 65536:
        raise DokladError("relay_invalid_url")
    prefix = parts.path.rstrip("/")
    if not RELAY_PREFIX_RE.fullmatch(prefix) or any(part in (".", "..") for part in prefix.split("/")):
        raise DokladError("relay_invalid_url")
    return host, port, prefix


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

class HttpsTransport:
    """Single-host HTTPS transport. Never follows redirects."""

    def __init__(self, host, port=443, timeout=API_TIMEOUT):
        self.host = host
        self.port = port
        self.timeout = timeout
        self._conn = None

    def close(self):
        if self._conn is not None:
            try:
                self._conn.close()
            except OSError:
                pass
            self._conn = None

    def __call__(self, method, target, body, headers, max_bytes):
        reused = self._conn is not None
        try:
            return self._send(method, target, body, headers, max_bytes)
        except DokladError as exc:
            self.close()
            # A stale keep-alive socket is safe to retry for reads only.
            if reused and method == "GET" and exc.code == "offline":
                return self._send(method, target, body, headers, max_bytes)
            raise

    def _send(self, method, target, body, headers, max_bytes):
        try:
            if self._conn is None:
                self._conn = http.client.HTTPSConnection(
                    self.host, self.port, timeout=self.timeout, context=ssl.create_default_context()
                )
            self._conn.request(method, target, body=body, headers=headers)
            response = self._conn.getresponse()
            data = response.read(max_bytes + 1)
            if len(data) > max_bytes:
                self.close()
                raise DokladError("response_too_large")
            response_headers = {name.lower(): value for name, value in response.getheaders()}
            return response.status, response_headers, data
        except DokladError:
            raise
        except (socket.timeout, TimeoutError):
            self.close()
            raise DokladError("timeout")
        except ssl.SSLError:
            self.close()
            raise DokladError("tls_error")
        except (OSError, http.client.HTTPException):
            self.close()
            raise DokladError("offline")


def error_detail(data):
    try:
        body = json.loads(data.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return ""
    if not isinstance(body, dict):
        return ""
    parts = []
    message = body.get("message") or body.get("error")
    if isinstance(message, str):
        parts.append(clean_text(message, 160))
    errors = body.get("errors")
    if isinstance(errors, list):
        for item in errors[:3]:
            if isinstance(item, dict):
                path = item.get("path")
                if isinstance(path, list):
                    path = ".".join(str(part) for part in path[:4])
                parts.append("%s: %s" % (clean_text(path, 40), clean_text(item.get("message"), 80)))
    return clean_text(" | ".join(part for part in parts if part), 240)


STATUS_CODES = {400: "validation", 401: "unauthorized", 403: "forbidden", 404: "not_found",
                409: "conflict", 422: "validation", 429: "rate_limited", 503: "service_unavailable"}


def raise_for_status(status, data):
    if 200 <= status < 300:
        return
    code = STATUS_CODES.get(status)
    if code is None:
        code = "server_error" if status >= 500 else "unexpected_status"
    raise DokladError(code, error_detail(data), status)


class ApiClient:
    """Doklad.ai REST client over an injectable transport."""

    def __init__(self, transport, api_key=""):
        self.transport = transport
        self.api_key = api_key

    def _headers(self, auth, accept, has_body):
        headers = {"Accept": accept, "User-Agent": USER_AGENT}
        if auth:
            if not self.api_key:
                raise DokladError("unconfigured")
            headers["Authorization"] = "Bearer " + self.api_key
        if has_body:
            headers["Content-Type"] = "application/json"
        return headers

    @staticmethod
    def _target(path, query):
        if not path.startswith("/api/"):
            raise DokladError("internal")
        if not query:
            return path
        pairs = [(key, str(value)) for key, value in query.items() if value is not None and value != ""]
        return path + ("?" + urlencode(pairs) if pairs else "")

    def request(self, method, path, query=None, payload=None, auth=True,
                accept="application/json", max_bytes=MAX_JSON_BYTES):
        body = None
        if payload is not None:
            body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        status, headers, data = self.transport(
            method, self._target(path, query), body, self._headers(auth, accept, body is not None), max_bytes
        )
        raise_for_status(status, data)
        return status, headers, data

    def json(self, method, path, query=None, payload=None, auth=True):
        status, headers, data = self.request(method, path, query, payload, auth)
        if not data.strip():
            return status, headers, None
        try:
            return status, headers, json.loads(data.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise DokladError("bad_response")

    def get(self, path, query=None, auth=True):
        return self.json("GET", path, query, None, auth)[2]

    def paginate(self, path, query=None):
        """Collect every page. Handles the `{data,totalPages}` envelope and bare arrays."""
        items, seen, truncated = [], set(), False
        page, limit = 1, PAGE_LIMIT
        while True:
            params = dict(query or {})
            params["page"] = page
            if limit:
                params["limit"] = limit
            try:
                payload = self.get(path, params)
            except DokladError as exc:
                if exc.code == "validation" and page == 1 and limit:
                    limit = None  # server rejected our page size; use its default
                    continue
                raise
            total_pages = None
            if isinstance(payload, dict):
                rows = payload.get("data")
                pages = payload.get("totalPages")
                if isinstance(pages, int) and not isinstance(pages, bool):
                    total_pages = pages
            else:
                rows = payload
            if not isinstance(rows, list):
                raise DokladError("bad_response")
            added = 0
            for row in rows:
                if not isinstance(row, dict):
                    continue
                key = row.get("id")
                key = key if isinstance(key, (int, str)) and not isinstance(key, bool) else None
                if key is not None:
                    if key in seen:
                        continue
                    seen.add(key)
                items.append(row)
                added += 1
            if len(items) >= MAX_RECORDS:
                truncated = True
                break
            # No new rows means the last page, or a server that ignores `page`.
            if added == 0:
                break
            if total_pages is not None:
                if page >= total_pages:
                    break
            elif len(rows) < (limit or 50):
                break
            page += 1
            if page > MAX_PAGES:
                truncated = True
                break
        return items[:MAX_RECORDS], truncated


# --------------------------------------------------------------------------
# Normalization (tolerant of the documented Swagger/real API differences)
# --------------------------------------------------------------------------

def invoice_kind(raw):
    label = clean_text(first_of(raw, "type", "invoiceType", "documentType"), 40).lower()
    if "proforma" in label or "advance" in label or "zaloh" in label or "záloh" in label:
        return "proforma"
    if "credit" in label or "dobropis" in label:
        return "credit_note"
    return "invoice"


def normalize_invoice(raw):
    """JSON-safe invoice record, or None when it has no usable id."""
    if not isinstance(raw, dict):
        return None
    invoice_id = to_int_id(raw.get("id"))
    if invoice_id is None:
        return None
    customer = raw.get("customer") if isinstance(raw.get("customer"), dict) else {}
    total = to_decimal(raw.get("total"), ZERO)
    subtotal = to_decimal(raw.get("subtotal"), None)
    vat = to_decimal(raw.get("vatAmount"), None)
    if subtotal is None:
        subtotal = total - (vat or ZERO)
    if vat is None:
        vat = total - subtotal
    paid = to_decimal(first_of(raw, "paidAmount", "amountPaid", "paidTotal"), None)
    remaining = to_decimal(first_of(raw, "remainingAmount", "amountDue", "balance"), None)
    rate = to_decimal(first_of(raw, "exchangeRate", "currencyRate"), None)
    currency = clean_text(raw.get("currency"), 3).upper()
    return {
        "id": invoice_id,
        "number": clean_text(first_of(raw, "invoiceNumber", "number"), 40),
        "customerId": to_int_id(first_of(raw, "customerId") or customer.get("id")),
        "customerName": clean_text(first_of(raw, "customerName") or customer.get("name"), 120),
        "issueDate": iso(parse_date(raw.get("issueDate"))),
        "dueDate": iso(parse_date(raw.get("dueDate"))),
        "taxDate": iso(parse_date(first_of(raw, "taxDate", "taxableDate"))),
        "paidDate": iso(parse_date(first_of(raw, "paidDate", "paidAt"))),
        "status": clean_text(raw.get("status"), 24).lower() or "sent",
        "subtotal": money_str(subtotal),
        "vatAmount": money_str(vat),
        "total": money_str(total),
        "paid": money_str(paid) if paid is not None else None,
        "remaining": money_str(remaining) if remaining is not None else None,
        "currency": currency if re.fullmatch(r"[A-Z]{3}", currency) else "CZK",
        "rate": plain_decimal(rate) if rate is not None and rate > 0 else None,
        "kind": invoice_kind(raw),
        "variableSymbol": clean_text(raw.get("variableSymbol"), 20),
        "createdAt": clean_text(raw.get("createdAt"), 40),
    }


def normalize_expense(raw):
    if not isinstance(raw, dict):
        return None
    expense_id = to_int_id(raw.get("id"))
    if expense_id is None:
        return None
    total = to_decimal(raw.get("total"), ZERO)
    amount = to_decimal(raw.get("amount"), None)
    vat = to_decimal(raw.get("vatAmount"), None)
    if amount is None:
        amount = total - (vat or ZERO)
    if vat is None:
        vat = total - amount
    return {
        "id": expense_id,
        "number": clean_text(first_of(raw, "expenseNumber", "number"), 40),
        "supplierId": to_int_id(raw.get("supplierId")),
        "category": clean_text(raw.get("category"), 60),
        "description": clean_text(raw.get("description"), 160),
        "amount": money_str(amount),
        "vatAmount": money_str(vat),
        "total": money_str(total),
        "status": clean_text(raw.get("status"), 24).lower() or "submitted",
        "date": iso(parse_date(first_of(raw, "expenseDate", "date", "issueDate"))),
    }


def normalize_customer(raw):
    if not isinstance(raw, dict):
        return None
    customer_id = to_int_id(raw.get("id"))
    if customer_id is None:
        return None
    return {
        "id": customer_id,
        "name": clean_text(raw.get("name"), 120),
        "ico": clean_text(raw.get("ico"), 12),
        "dic": clean_text(raw.get("dic"), 16),
        "email": clean_text(raw.get("email"), 160),
        "phone": clean_text(raw.get("phone"), 32),
        "address": clean_text(raw.get("address"), 160),
        "city": clean_text(raw.get("city"), 80),
        "postalCode": clean_text(first_of(raw, "postalCode", "zip"), 12),
        "country": clean_text(raw.get("country"), 2).upper() or "CZ",
        "active": raw.get("isActive") is not False,
    }


def hydrate_invoice(record):
    """Runtime invoice with Decimal amounts and date objects (tolerates a damaged cache)."""
    if not isinstance(record, dict):
        return None
    invoice_id = to_int_id(record.get("id"))
    if invoice_id is None:
        return None
    total = to_decimal(record.get("total"), ZERO)
    status = clean_text(record.get("status"), 24).lower() or "sent"
    paid = to_decimal(record.get("paid"), None)
    remaining = to_decimal(record.get("remaining"), None)
    if status == "paid":
        open_amount = ZERO
    elif remaining is not None:
        open_amount = max(ZERO, remaining)
    elif paid is not None:
        open_amount = max(ZERO, total - paid)
    else:
        open_amount = max(ZERO, total)
    kind = record.get("kind") if record.get("kind") in ("invoice", "proforma", "credit_note") else "invoice"
    rate = to_decimal(record.get("rate"), None)
    currency = clean_text(record.get("currency"), 3).upper()
    return {
        "id": invoice_id,
        "number": clean_text(record.get("number"), 40),
        "customerId": to_int_id(record.get("customerId")),
        "customerName": clean_text(record.get("customerName"), 120),
        "issue": parse_date(record.get("issueDate")),
        "due": parse_date(record.get("dueDate")),
        "tax": parse_date(record.get("taxDate")),
        "status": status,
        "subtotal": to_decimal(record.get("subtotal"), ZERO),
        "vat": to_decimal(record.get("vatAmount"), ZERO),
        "total": total,
        "open": open_amount,
        "currency": currency if re.fullmatch(r"[A-Z]{3}", currency) else "CZK",
        "rate": rate if rate is not None and rate > 0 else None,
        "kind": kind,
        "variableSymbol": clean_text(record.get("variableSymbol"), 20),
        "createdAt": clean_text(record.get("createdAt"), 40),
    }


def hydrate_expense(record):
    if not isinstance(record, dict) or to_int_id(record.get("id")) is None:
        return None
    return {
        "id": to_int_id(record.get("id")),
        "amount": to_decimal(record.get("amount"), ZERO),
        "vat": to_decimal(record.get("vatAmount"), ZERO),
        "total": to_decimal(record.get("total"), ZERO),
        "status": clean_text(record.get("status"), 24).lower(),
        "date": parse_date(record.get("date")),
    }


def invoice_counted(invoice):
    """Counts toward revenue and VAT: issued, not cancelled, not a proforma."""
    return invoice["status"] not in EXCLUDED_INVOICE_STATUSES and invoice["kind"] != "proforma"


def invoice_state(invoice, today, overdue_ids=frozenset()):
    status = invoice["status"]
    if status == "draft":
        return "draft"
    if status in ("cancelled", "canceled"):
        return "cancelled"
    if status == "paid" or (invoice["total"] > 0 and invoice["open"] <= 0):
        return "paid"
    if invoice["total"] <= 0:
        return "pending"
    if status == "overdue" or invoice["id"] in overdue_ids or (invoice["due"] is not None and invoice["due"] < today):
        return "overdue"
    return "pending"


# --------------------------------------------------------------------------
# Synchronization
# --------------------------------------------------------------------------

def fetch_dataset(client, now):
    """Fetch invoices, expenses and customers. Raises DokladError on failure."""
    raw_invoices, truncated = client.paginate("/api/invoices")
    invoices = [item for item in (normalize_invoice(row) for row in raw_invoices) if item]

    overdue_ids = []
    try:
        payload = client.get("/api/invoices/overdue")
        rows = payload.get("data") if isinstance(payload, dict) else payload
        if isinstance(rows, list):
            for row in rows[:MAX_RECORDS]:
                invoice_id = to_int_id(row.get("id")) if isinstance(row, dict) else None
                if invoice_id is not None:
                    overdue_ids.append(invoice_id)
    except DokladError as exc:
        # Overdue is also derived locally from due dates; only auth problems are fatal.
        if exc.code == "unauthorized":
            raise

    expenses_available = True
    expenses = []
    try:
        raw_expenses, expenses_truncated = client.paginate("/api/expenses")
        truncated = truncated or expenses_truncated
        expenses = [item for item in (normalize_expense(row) for row in raw_expenses) if item]
    except DokladError as exc:
        if exc.code != "forbidden":
            raise
        expenses_available = False  # plan without the expenses module

    customers = []
    try:
        raw_customers, customers_truncated = client.paginate("/api/customers")
        truncated = truncated or customers_truncated
        customers = [item for item in (normalize_customer(row) for row in raw_customers) if item]
    except DokladError as exc:
        if exc.code != "forbidden":
            raise

    return {
        "version": CACHE_VERSION,
        "fetchedAt": int(now),
        "invoices": invoices,
        "overdueIds": overdue_ids,
        "expenses": expenses,
        "expensesAvailable": expenses_available,
        "customers": customers,
        "truncated": truncated,
    }


def load_cache(paths):
    cache = read_json_file(paths.cache_file, MAX_CACHE_BYTES)
    if not isinstance(cache, dict) or cache.get("version") != CACHE_VERSION:
        return None
    for key in ("invoices", "expenses", "customers", "overdueIds"):
        if not isinstance(cache.get(key), list):
            return None
    if not isinstance(cache.get("fetchedAt"), int):
        return None
    return cache


def default_state():
    return {
        "version": STATE_VERSION,
        "baseline": False,
        "known": {},
        "selfTouched": {},
        "recentCreates": [],
        "relayCursor": 0,
        "relayError": "",
        "relayCheckedAt": 0,
        "events": [],
    }


def load_state(paths):
    state = default_state()
    raw = read_json_file(paths.state_file, MAX_STATE_BYTES)
    if not isinstance(raw, dict) or raw.get("version") != STATE_VERSION:
        return state
    state["baseline"] = raw.get("baseline") is True
    if isinstance(raw.get("known"), dict):
        for key, value in list(raw["known"].items())[:MAX_RECORDS]:
            if to_int_id(key) and isinstance(value, list) and len(value) == 2 and isinstance(value[0], str):
                state["known"][str(to_int_id(key))] = [clean_text(value[0], 24), value[1] is True]
    if isinstance(raw.get("selfTouched"), dict):
        for key, value in list(raw["selfTouched"].items())[:500]:
            if to_int_id(key) and isinstance(value, (int, float)) and not isinstance(value, bool):
                state["selfTouched"][str(to_int_id(key))] = int(value)
    if isinstance(raw.get("recentCreates"), list):
        for item in raw["recentCreates"][-20:]:
            if isinstance(item, dict) and isinstance(item.get("fp"), str) and isinstance(item.get("at"), int):
                state["recentCreates"].append({"fp": item["fp"][:64], "at": item["at"]})
    if isinstance(raw.get("relayCursor"), int) and not isinstance(raw.get("relayCursor"), bool):
        state["relayCursor"] = max(0, raw["relayCursor"])
    state["relayError"] = clean_text(raw.get("relayError"), 40)
    if isinstance(raw.get("relayCheckedAt"), int):
        state["relayCheckedAt"] = raw["relayCheckedAt"]
    if isinstance(raw.get("events"), list):
        for item in raw["events"][-MAX_EVENTS:]:
            event = normalize_relay_event(item)
            if event:
                state["events"].append(event)
    return state


def mark_self_touched(state, invoice_id, now):
    state["selfTouched"][str(invoice_id)] = int(now)


class StateLock:
    """Advisory lock so several bar instances never sync or notify twice."""

    def __init__(self, paths, wait_seconds=25):
        self.path = paths.lock_file
        self.wait_seconds = wait_seconds
        self.fd = -1
        self.acquired = False

    def __enter__(self):
        try:
            self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        except OSError:
            return self
        deadline = time.monotonic() + self.wait_seconds
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.acquired = True
                break
            except OSError:
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.2)
        return self

    def __exit__(self, *_):
        if self.fd >= 0:
            try:
                if self.acquired:
                    fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
        return False


# --------------------------------------------------------------------------
# Change detection (works with or without the webhook relay)
# --------------------------------------------------------------------------

def diff_invoices(known, baseline, invoices, today, self_touched, now, overdue_ids=frozenset()):
    """Compare fresh invoices with the last seen state.

    Returns (new_known, changes) where changes is a list of (kind, invoice) with
    kind in {"created", "paid", "overdue"}. Nothing is reported on the first run.
    """
    new_known, changes = {}, []
    for invoice in invoices:
        key = str(invoice["id"])
        state = invoice_state(invoice, today, overdue_ids)
        is_overdue = state == "overdue"
        new_known[key] = [state, is_overdue]
        if not baseline:
            continue
        touched = self_touched.get(key)
        if touched is not None and now - touched < SELF_TOUCH_TTL:
            continue  # the user just did this from the panel
        if invoice["kind"] == "proforma":
            continue
        previous = known.get(key)
        if previous is None:
            if state in ("pending", "overdue", "paid"):
                issue = invoice["issue"]
                if issue is None or (today - issue).days <= 14:
                    changes.append(("created", invoice))
            continue
        if state == "paid" and previous[0] != "paid":
            changes.append(("paid", invoice))
        elif is_overdue and not previous[1]:
            changes.append(("overdue", invoice))
    return new_known, changes


def format_money_text(amount, currency, lang):
    value = money(amount)
    sign = "-" if value < 0 else ""
    whole, _, fraction = format(abs(value), "f").partition(".")
    groups = []
    while len(whole) > 3:
        groups.insert(0, whole[-3:])
        whole = whole[:-3]
    groups.insert(0, whole)
    unit = "Kč" if currency == "CZK" else currency
    return "%s%s,%s %s" % (sign, "\u00a0".join(groups), fraction, unit)


# The plugin speaks Czech and Slovak only; Czech is the fallback.
NOTIFY_FALLBACK = {
    "notify.paid": "Faktura zaplacena",
    "notify.overdue": "Faktura po splatnosti",
    "notify.created": "Nová faktura",
    "notify.more": "Další změny u faktur: %1",
}


def ui_language(lang):
    return "sk" if str(lang).split("-")[0] == "sk" else "cs"


def load_notify_strings(paths, lang):
    strings = dict(NOTIFY_FALLBACK)
    for code in ("cs", "sk") if ui_language(lang) == "sk" else ("cs",):
        catalog = read_json_file(os.path.join(paths.plugin_dir, "i18n", code + ".json"), MAX_CATALOG_BYTES)
        if isinstance(catalog, dict):
            for key in NOTIFY_FALLBACK:
                if isinstance(catalog.get(key), str) and catalog[key]:
                    strings[key] = clean_text(catalog[key], 80)
    return strings


def notify_markup_safe(text):
    """Notification bodies may be parsed as markup; make angle brackets inert."""
    return text.replace("&", "\uff06").replace("<", "\u2039").replace(">", "\u203a")


def build_notifications(changes, strings, privacy, lang):
    messages = []
    for kind, invoice in changes[:MAX_NOTIFICATIONS]:
        parts = [invoice["number"] or "#%d" % invoice["id"]]
        if invoice["customerName"]:
            parts.append(invoice["customerName"])
        if not privacy:
            parts.append(format_money_text(invoice["total"], invoice["currency"], lang))
        messages.append((kind, strings["notify." + kind], notify_markup_safe(" \u00b7 ".join(parts))))
    extra = len(changes) - MAX_NOTIFICATIONS
    if extra > 0:
        messages.append(("more", "Doklad.ai", strings["notify.more"].replace("%1", str(extra))))
    return messages


def child_environ():
    return {key: value for key, value in os.environ.items() if not key.startswith("DOKLAD_")}


def send_notifications(messages):
    for _kind, title, body in messages:
        try:
            subprocess.run(
                ["/usr/bin/notify-send", "-a", "Doklad.ai", "--", title, body],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=5, check=False, env=child_environ(),
            )
        except (OSError, subprocess.SubprocessError):
            return


# --------------------------------------------------------------------------
# Webhook relay client (signals only: event name + resource id)
# --------------------------------------------------------------------------

def normalize_relay_event(item):
    if not isinstance(item, dict):
        return None
    name = item.get("event")
    seq = item.get("seq")
    at = first_of(item, "at", "receivedAt")
    if not isinstance(name, str) or not EVENT_NAME_RE.fullmatch(name):
        return None
    if isinstance(seq, bool) or not isinstance(seq, int) or seq < 0:
        return None
    if isinstance(at, bool) or not isinstance(at, (int, float)) or at < 0:
        return None
    if at > 10 ** 11:  # milliseconds
        at = at / 1000
    return {"seq": seq, "event": name, "resourceId": to_int_id(item.get("resourceId")), "at": int(at)}


def relay_request(transport, prefix, token, cursor):
    target = "%s/events?%s" % (prefix, urlencode({"after": cursor}))
    headers = {"Accept": "application/json", "User-Agent": USER_AGENT, "Authorization": "Bearer " + token}
    status, _, data = transport("GET", target, None, headers, 256 * 1024)
    if status in (401, 403):
        raise DokladError("relay_unauthorized")
    if status == 503:
        raise DokladError("relay_not_ready")  # Worker deployed without its secrets
    if status != 200:
        raise DokladError("relay_error")
    try:
        payload = json.loads(data.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise DokladError("relay_error")
    rows = payload.get("events") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        raise DokladError("relay_error")
    head = payload.get("head")
    if isinstance(head, bool) or not isinstance(head, int) or head < 0:
        head = None
    return rows, head


def relay_fetch(transport, prefix, token, cursor):
    """Returns (new events, next cursor). Sequence numbers only ever grow on one relay."""
    rows, head = relay_request(transport, prefix, token, cursor)
    if head is not None and head < cursor:
        # The relay was redeployed from scratch and counts from 1 again; start over once.
        cursor = 0
        rows, head = relay_request(transport, prefix, token, cursor)
    events = [event for event in (normalize_relay_event(row) for row in rows[:200]) if event and event["seq"] > cursor]
    events.sort(key=lambda event: event["seq"])
    next_cursor = max([cursor] + [event["seq"] for event in events])
    return events, next_cursor


def poll_relay(secrets, state, now, transport_factory):
    """Pull pending signals. Returns the number of new events; failures are recorded, never fatal."""
    url, token = secrets.get("DOKLAD_RELAY_URL", ""), secrets.get("DOKLAD_RELAY_TOKEN", "")
    if not url or not token:
        return 0
    state["relayCheckedAt"] = int(now)
    try:
        host, port, prefix = parse_relay_url(url)
        transport = transport_factory(host, port)
        try:
            events, cursor = relay_fetch(transport, prefix, token, state["relayCursor"])
        finally:
            close = getattr(transport, "close", None)
            if close:
                close()
    except DokladError as exc:
        state["relayError"] = exc.code if exc.code.startswith("relay_") else "relay_" + exc.code
        return 0
    state["relayError"] = ""
    state["relayCursor"] = cursor
    if events:
        state["events"] = (state["events"] + events)[-MAX_EVENTS:]
    return len(events)


# --------------------------------------------------------------------------
# Analytics
# --------------------------------------------------------------------------

def month_shift(year, month, delta):
    index = year * 12 + (month - 1) + delta
    return index // 12, index % 12 + 1


def month_end(year, month):
    next_year, next_month = month_shift(year, month, 1)
    return dt.date(next_year, next_month, 1) - dt.timedelta(days=1)


def period_bounds(horizon, offset, today):
    """Describe a reporting period. `offset` is 0 for the current one, negative for history."""
    if horizon == "quarter":
        index = today.year * 4 + (today.month - 1) // 3 + offset
        year, quarter = index // 4, index % 4 + 1
        start = dt.date(year, 3 * (quarter - 1) + 1, 1)
        return {"kind": "quarter", "year": year, "index": quarter, "start": start, "end": month_end(year, 3 * quarter)}
    if horizon == "year":
        year = today.year + offset
        return {"kind": "year", "year": year, "index": 0, "start": dt.date(year, 1, 1), "end": dt.date(year, 12, 31)}
    year, month = month_shift(today.year, today.month, offset)
    if horizon == "ltm":
        start_year, start_month = month_shift(year, month, -11)
        return {"kind": "ltm", "year": year, "index": month,
                "start": dt.date(start_year, start_month, 1), "end": month_end(year, month)}
    return {"kind": "month", "year": year, "index": month, "start": dt.date(year, month, 1), "end": month_end(year, month)}


def conversion_factor(invoice, base):
    if invoice["currency"] == base:
        return Decimal(1)
    return invoice["rate"]


def aggregate(invoices, expenses, start, end, base, today, overdue_ids=frozenset()):
    """Totals for invoices issued (revenue, receivables) and taxed (VAT) within [start, end]."""
    out = {
        "subtotal": ZERO, "total": ZERO, "count": 0,
        "collected": ZERO, "paidCount": 0,
        "pending": ZERO, "pendingCount": 0,
        "overdue": ZERO, "overdueCount": 0,
        "vatOut": ZERO, "turnover": ZERO,
        "expSubtotal": ZERO, "expTotal": ZERO, "expCount": 0, "vatIn": ZERO,
        "foreign": {},
    }
    for invoice in invoices:
        if not invoice_counted(invoice):
            continue
        issue = invoice["issue"]
        tax = invoice["tax"] or issue
        in_issue = issue is not None and start <= issue <= end
        in_tax = tax is not None and start <= tax <= end
        if not in_issue and not in_tax:
            continue
        factor = conversion_factor(invoice, base)
        if factor is None:
            if in_issue:
                bucket = out["foreign"].setdefault(invoice["currency"], [ZERO, 0])
                bucket[0] += invoice["total"]
                bucket[1] += 1
            continue
        if in_tax:
            out["vatOut"] += invoice["vat"] * factor
            out["turnover"] += invoice["subtotal"] * factor
        if not in_issue:
            continue
        total = invoice["total"] * factor
        open_amount = min(invoice["open"], max(ZERO, invoice["total"])) * factor
        out["subtotal"] += invoice["subtotal"] * factor
        out["total"] += total
        out["count"] += 1
        state = invoice_state(invoice, today, overdue_ids)
        if state == "paid":
            out["paidCount"] += 1
            out["collected"] += total
        else:
            out["collected"] += total - open_amount
            if state == "overdue":
                out["overdue"] += open_amount
                out["overdueCount"] += 1
            else:
                out["pending"] += open_amount
                out["pendingCount"] += 1
    for expense in expenses:
        if expense["status"] in EXCLUDED_EXPENSE_STATUSES:
            continue
        date_value = expense["date"]
        if date_value is None or not start <= date_value <= end:
            continue
        out["expSubtotal"] += expense["amount"]
        out["expTotal"] += expense["total"]
        out["vatIn"] += expense["vat"]
        out["expCount"] += 1
    return out


def percent_change(current, previous):
    if previous == 0:
        return None
    change = (current - previous) / abs(previous) * 100
    return float(change.quantize(Decimal("0.1"), rounding=ROUND_HALF_UP))


def pick_base_currency(invoices):
    counts = {}
    for invoice in invoices:
        counts[invoice["currency"]] = counts.get(invoice["currency"], 0) + 1
    if not counts or "CZK" in counts:
        return "CZK"
    return max(sorted(counts), key=lambda code: counts[code])


def chart_series(horizon, period, invoices, expenses, base, today, overdue_ids):
    points = []
    if horizon == "quarter":
        last = period["year"] * 4 + period["index"] - 1
        for index in range(last - 7, last + 1):
            year, quarter = index // 4, index % 4 + 1
            points.append(("quarter", year, quarter, dt.date(year, 3 * (quarter - 1) + 1, 1), month_end(year, 3 * quarter)))
    else:
        if horizon == "year":
            first_year, first_month = period["year"], 1
        else:
            first_year, first_month = month_shift(period["year"], period["index"], -11)
        for step in range(12):
            year, month = month_shift(first_year, first_month, step)
            points.append(("month", year, month, dt.date(year, month, 1), month_end(year, month)))
    series = []
    for kind, year, index, start, end in points:
        totals = aggregate(invoices, expenses, start, end, base, today, overdue_ids)
        series.append({
            "kind": kind, "year": year, "index": index,
            "paid": money_float(totals["collected"]),
            "unpaid": money_float(totals["pending"] + totals["overdue"]),
            "expenses": money_float(totals["expTotal"]),
            "future": start > today,
        })
    return series


def period_summary(horizon, offset, invoices, expenses, base, today, overdue_ids):
    period = period_bounds(horizon, offset, today)
    totals = aggregate(invoices, expenses, period["start"], period["end"], base, today, overdue_ids)

    def subtotal_for(other_offset):
        bounds = period_bounds(horizon, other_offset, today)
        return aggregate(invoices, expenses, bounds["start"], bounds["end"], base, today, overdue_ids)["subtotal"]

    previous_offset = offset - (12 if horizon == "ltm" else 1)
    yoy_offset = {"month": offset - 12, "quarter": offset - 4, "year": None, "ltm": None}[horizon]
    return {
        "horizon": horizon,
        "offset": offset,
        "kind": period["kind"],
        "year": period["year"],
        "index": period["index"],
        "from": iso(period["start"]),
        "to": iso(period["end"]),
        "invoiced": {"subtotal": money_float(totals["subtotal"]), "total": money_float(totals["total"]),
                     "count": totals["count"]},
        "collected": {"total": money_float(totals["collected"]), "count": totals["paidCount"]},
        "pending": {"total": money_float(totals["pending"]), "count": totals["pendingCount"]},
        "overdue": {"total": money_float(totals["overdue"]), "count": totals["overdueCount"]},
        "expenses": {"subtotal": money_float(totals["expSubtotal"]), "total": money_float(totals["expTotal"]),
                     "count": totals["expCount"]},
        "net": money_float(totals["subtotal"] - totals["expSubtotal"]),
        "vat": {"output": money_float(totals["vatOut"]), "input": money_float(totals["vatIn"]),
                "balance": money_float(totals["vatOut"] - totals["vatIn"])},
        "trend": {
            "previous": percent_change(totals["subtotal"], subtotal_for(previous_offset)),
            "yoy": percent_change(totals["subtotal"], subtotal_for(yoy_offset)) if yoy_offset is not None else None,
        },
        "foreign": [{"currency": code, "total": money_float(bucket[0]), "count": bucket[1]}
                    for code, bucket in sorted(totals["foreign"].items())],
    }, period, totals


def build_snapshot(cache, state, options, today):
    """Pure projection of cached data into everything the panel renders."""
    overdue_ids = frozenset(item for item in cache["overdueIds"] if isinstance(item, int))
    invoices = [item for item in (hydrate_invoice(row) for row in cache["invoices"]) if item]
    expenses = [item for item in (hydrate_expense(row) for row in cache["expenses"]) if item]
    base = pick_base_currency(invoices)
    horizon, offset = options["horizon"], options["offset"]
    summary, period, _ = period_summary(horizon, offset, invoices, expenses, base, today, overdue_ids)

    bar = {"unpaidTotal": ZERO, "unpaidCount": 0, "overdueTotal": ZERO, "overdueCount": 0, "draftCount": 0}
    counts = {"all": 0, "unpaid": 0, "overdue": 0, "paid": 0, "draft": 0}
    open_by_customer = {}
    rows = []
    for invoice in invoices:
        state_name = invoice_state(invoice, today, overdue_ids)
        counts["all"] += 1
        if state_name == "draft":
            counts["draft"] += 1
            bar["draftCount"] += 1
        elif state_name == "paid":
            counts["paid"] += 1
        elif state_name in ("pending", "overdue"):
            counts["unpaid"] += 1
            if state_name == "overdue":
                counts["overdue"] += 1
            factor = conversion_factor(invoice, base)
            if invoice["kind"] != "proforma" and factor is not None:
                amount = invoice["open"] * factor
                bar["unpaidTotal"] += amount
                bar["unpaidCount"] += 1
                if state_name == "overdue":
                    bar["overdueTotal"] += amount
                    bar["overdueCount"] += 1
                if invoice["customerId"] is not None:
                    open_by_customer[invoice["customerId"]] = open_by_customer.get(invoice["customerId"], ZERO) + amount
        rows.append((state_name, invoice))

    # Open invoices and drafts are always listed; the rest fills up to the cap, newest first.
    def sort_key(entry):
        return (entry[1]["issue"] or dt.date.min, entry[1]["id"])

    rows.sort(key=sort_key, reverse=True)
    priority = [entry for entry in rows if entry[0] in ("pending", "overdue", "draft")]
    others = [entry for entry in rows if entry[0] not in ("pending", "overdue", "draft")]
    listed = (priority + others[:max(0, MAX_UI_INVOICES - len(priority))])[:MAX_UI_INVOICES * 2]
    listed.sort(key=sort_key, reverse=True)
    invoice_rows = []
    for state_name, invoice in listed:
        invoice_rows.append({
            "id": invoice["id"],
            "number": invoice["number"],
            "customerId": invoice["customerId"],
            "customerName": invoice["customerName"],
            "issueDate": iso(invoice["issue"]),
            "dueDate": iso(invoice["due"]),
            "status": invoice["status"],
            "state": state_name,
            "kind": invoice["kind"],
            "total": money_float(invoice["total"]),
            "open": money_float(invoice["open"]) if state_name in ("pending", "overdue") else 0.0,
            "currency": invoice["currency"],
            "daysToDue": (invoice["due"] - today).days if invoice["due"] is not None else None,
            "variableSymbol": invoice["variableSymbol"],
        })

    revenue_by_customer, count_by_customer = {}, {}
    for invoice in invoices:
        if not invoice_counted(invoice) or invoice["customerId"] is None or invoice["issue"] is None:
            continue
        if not period["start"] <= invoice["issue"] <= period["end"]:
            continue
        factor = conversion_factor(invoice, base)
        if factor is None:
            continue
        customer_id = invoice["customerId"]
        revenue_by_customer[customer_id] = revenue_by_customer.get(customer_id, ZERO) + invoice["subtotal"] * factor
        count_by_customer[customer_id] = count_by_customer.get(customer_id, 0) + 1
    customers = []
    for record in cache["customers"]:
        customer = normalize_customer(record)
        if customer is None or not customer["active"]:
            continue
        customer_id = customer["id"]
        customers.append({
            "id": customer_id, "name": customer["name"], "ico": customer["ico"], "dic": customer["dic"],
            "email": customer["email"], "phone": customer["phone"], "city": customer["city"],
            "revenue": money_float(revenue_by_customer.get(customer_id, ZERO)),
            "invoiceCount": count_by_customer.get(customer_id, 0),
            "open": money_float(open_by_customer.get(customer_id, ZERO)),
        })
    customers.sort(key=lambda item: (-item["revenue"], -item["open"], item["name"].lower()))

    current_month = period_bounds("month", 0, today)
    current_quarter = period_bounds("quarter", 0, today)
    year_bounds = period_bounds("year", 0, today)
    ltm_bounds = period_bounds("ltm", 0, today)

    def totals_for(bounds):
        return aggregate(invoices, expenses, bounds["start"], bounds["end"], base, today, overdue_ids)

    numbers = {invoice["id"]: invoice["number"] for invoice in invoices}
    events = [{"event": event["event"], "resourceId": event["resourceId"], "at": event["at"],
               "number": numbers.get(event["resourceId"], "") if event["event"].startswith("invoice.") else ""}
              for event in reversed(state["events"][-20:])]

    return {
        "baseCurrency": base,
        "bar": {
            "unpaidTotal": money_float(bar["unpaidTotal"]), "unpaidCount": bar["unpaidCount"],
            "overdueTotal": money_float(bar["overdueTotal"]), "overdueCount": bar["overdueCount"],
            "draftCount": bar["draftCount"],
            "monthInvoiced": money_float(totals_for(current_month)["subtotal"]),
            "quarterInvoiced": money_float(totals_for(current_quarter)["subtotal"]),
            "quarterIndex": current_quarter["index"],
        },
        "period": summary,
        "chart": chart_series(horizon, period, invoices, expenses, base, today, overdue_ids),
        "turnover": {
            "year": today.year,
            "yearToDate": money_float(totals_for(year_bounds)["turnover"]),
            "last12Months": money_float(totals_for(ltm_bounds)["turnover"]),
            "limit": options["limit"],
        },
        "invoices": invoice_rows,
        "invoiceCounts": counts,
        "customers": customers[:MAX_UI_CUSTOMERS],
        "customerCount": len(customers),
        "expensesAvailable": cache.get("expensesAvailable") is not False,
        "truncated": cache.get("truncated") is True,
        "events": events,
    }


# --------------------------------------------------------------------------
# Runtime context
# --------------------------------------------------------------------------

class Context:
    def __init__(self, paths=None, environ=None, transport=None, relay_transport_factory=None,
                 today=None, now=None, notifier=None, spawner=None):
        self.environ = os.environ if environ is None else environ
        self.paths = paths or Paths.from_environ(self.environ)
        self._transport = transport
        self.relay_transport_factory = relay_transport_factory or (
            lambda host, port: HttpsTransport(host, port, RELAY_TIMEOUT))
        self.today = today or dt.date.today()
        self.now = time.time() if now is None else now
        self.notifier = notifier or send_notifications
        self.spawner = spawner or spawn_detached
        self._secrets = None

    @property
    def secrets(self):
        if self._secrets is None:
            self._secrets = load_secrets(self.paths, self.environ)
        return self._secrets

    def client(self, require_key=True):
        key = self.secrets["DOKLAD_API_KEY"]
        if require_key and not key:
            raise DokladError("unconfigured")
        if self._transport is None:
            self._transport = HttpsTransport(API_HOST)
        return ApiClient(self._transport, key)


def spawn_detached(argv):
    try:
        subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, close_fds=True, env=child_environ())
        return True
    except OSError:
        return False


# --------------------------------------------------------------------------
# snapshot command
# --------------------------------------------------------------------------

def empty_snapshot(status, error="", detail=""):
    return {"ok": False, "status": status, "error": error, "errorDetail": detail, "hasData": False}


def run_snapshot(ctx, options):
    try:
        secrets = ctx.secrets
    except DokladError as exc:
        return empty_snapshot("misconfigured", exc.code, exc.detail)
    try:
        ensure_private_dir(ctx.paths.state_dir)
    except DokladError as exc:
        return empty_snapshot("error", exc.code)

    relay_configured = bool(secrets["DOKLAD_RELAY_URL"] and secrets["DOKLAD_RELAY_TOKEN"])
    error, detail, messages = "", "", []
    with StateLock(ctx.paths) as lock:
        state = load_state(ctx.paths)
        cache = load_cache(ctx.paths)
        # --cached re-projects stored data (period switches) without touching the network.
        if lock.acquired and not (options["cached"] and cache is not None):
            new_events = poll_relay(secrets, state, ctx.now, ctx.relay_transport_factory)
            age = ctx.now - cache["fetchedAt"] if cache else None
            stale = cache is None or age is None or age < 0 or age > options["max_age"]
            if secrets["DOKLAD_API_KEY"] and (options["force"] or stale or new_events):
                try:
                    cache = fetch_dataset(ctx.client(), ctx.now)
                    write_json_file(ctx.paths.cache_file, cache)
                    hydrated = [item for item in (hydrate_invoice(row) for row in cache["invoices"]) if item]
                    known, changes = diff_invoices(
                        state["known"], state["baseline"], hydrated, ctx.today, state["selfTouched"],
                        ctx.now, frozenset(cache["overdueIds"]))
                    state["known"], state["baseline"] = known, True
                    state["selfTouched"] = {key: value for key, value in state["selfTouched"].items()
                                            if ctx.now - value < SELF_TOUCH_TTL}
                    if options["notify"] and changes:
                        strings = load_notify_strings(ctx.paths, options["lang"])
                        messages = build_notifications(changes, strings, options["privacy"], options["lang"])
                except DokladError as exc:
                    error, detail = exc.code, exc.detail
            try:
                write_json_file(ctx.paths.state_file, state)
            except DokladError:
                pass
    if messages:
        ctx.notifier(messages)

    relay = {
        "configured": relay_configured,
        "ok": relay_configured and not state["relayError"],
        "error": state["relayError"] if relay_configured else "",
        "checkedAt": state["relayCheckedAt"],
        "lastEventAt": state["events"][-1]["at"] if state["events"] else 0,
        "webhookSecretStored": bool(secrets["DOKLAD_WEBHOOK_SECRET"]),
    }
    if not secrets["DOKLAD_API_KEY"]:
        result = empty_snapshot("unconfigured")
        result["relay"] = relay
        return result
    if cache is None:
        status = "unauthorized" if error == "unauthorized" else ("offline" if error in ("offline", "timeout") else "error")
        result = empty_snapshot(status, error or "no_data", detail)
        result["relay"] = relay
        return result

    snapshot = build_snapshot(cache, state, options, ctx.today)
    if error == "unauthorized":
        status = "unauthorized"
    elif error in ("offline", "timeout"):
        status = "offline"
    elif error:
        status = "error"
    else:
        status = "ready"
    snapshot.update({
        "ok": not error,
        "status": status,
        "error": error,
        "errorDetail": detail,
        "hasData": True,
        "stale": bool(error),
        "fetchedAt": cache["fetchedAt"],
        "today": iso(ctx.today),
        "relay": relay,
    })
    return snapshot


# --------------------------------------------------------------------------
# Action payload builders (pure, unit tested)
# --------------------------------------------------------------------------

def require_id(payload, key="id"):
    value = to_int_id(payload.get(key))
    if value is None:
        raise DokladError("invalid_input", key)
    return value


def require_date(payload, key, required=True):
    value = payload.get(key)
    if value in (None, "") and not required:
        return None
    parsed = parse_date(value) if isinstance(value, str) and len(value.strip()) == 10 else None
    if parsed is None or not 2000 <= parsed.year <= 2100:
        raise DokladError("invalid_date", key)
    return parsed


def build_invoice_payload(payload, draft):
    """Validate the quick-invoice form and compute totals with exact decimals.

    VAT is computed per rate on the summed base, each rounded half-up to cents.
    """
    customer_id = require_id(payload, "customerId")
    customer_name = clean_text(payload.get("customerName"), 200)
    if not customer_name:
        raise DokladError("invalid_input", "customerName")
    issue = require_date(payload, "issueDate")
    due = require_date(payload, "dueDate")
    tax = require_date(payload, "taxDate", required=False) or issue
    if due < issue:
        raise DokladError("invalid_date", "dueDate")
    raw_items = payload.get("items")
    if not isinstance(raw_items, list) or not 1 <= len(raw_items) <= MAX_ITEMS:
        raise DokladError("invalid_input", "items")
    items, bases = [], {}
    for raw in raw_items:
        if not isinstance(raw, dict):
            raise DokladError("invalid_input", "items")
        description = clean_text(raw.get("description"), 500)
        quantity = to_decimal(raw.get("quantity"))
        unit_price = to_decimal(raw.get("unitPrice"))
        vat_rate = to_decimal(raw.get("vatRate"))
        if not description:
            raise DokladError("invalid_input", "description")
        if quantity is None or quantity <= 0 or quantity > 10 ** 7:
            raise DokladError("invalid_amount", "quantity")
        if unit_price is None or abs(unit_price) > 10 ** 9:
            raise DokladError("invalid_amount", "unitPrice")
        if vat_rate is None or not 0 <= vat_rate <= 100:
            raise DokladError("invalid_amount", "vatRate")
        bases[vat_rate] = bases.get(vat_rate, ZERO) + money(quantity * unit_price)
        items.append({
            "description": description,
            "quantity": plain_decimal(quantity),
            "unit": clean_text(raw.get("unit"), 20) or "ks",
            "unitPrice": money_str(unit_price) if unit_price == money(unit_price) else plain_decimal(unit_price),
            "vatRate": plain_decimal(vat_rate),
        })
    subtotal = sum(bases.values(), ZERO)
    vat_amount = sum((money(base * rate / 100) for rate, base in bases.items()), ZERO)
    if subtotal <= 0:
        raise DokladError("invalid_amount", "total")
    body = {
        "customerId": customer_id,
        "customerName": customer_name,
        "issueDate": iso(issue),
        "taxDate": iso(tax),
        "dueDate": iso(due),
        "subtotal": money_str(subtotal),
        "vatAmount": money_str(vat_amount),
        "total": money_str(subtotal + vat_amount),
        "items": items,
    }
    notes = clean_multiline(payload.get("notes"), 1000)
    if notes:
        body["notes"] = notes
    if draft:
        body["status"] = "draft"
    return body


def invoice_fingerprint(body):
    relevant = {key: body[key] for key in ("customerId", "issueDate", "dueDate", "total", "items")}
    return hashlib.sha256(json.dumps(relevant, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()


def build_expense_payload(payload):
    description = clean_text(payload.get("description"), 300)
    if not description:
        raise DokladError("invalid_input", "description")
    amount = to_decimal(payload.get("amount"))
    vat_rate = to_decimal(payload.get("vatRate"), ZERO)
    if amount is None or amount <= 0 or amount > 10 ** 9:
        raise DokladError("invalid_amount", "amount")
    if not 0 <= vat_rate <= 100:
        raise DokladError("invalid_amount", "vatRate")
    amount = money(amount)
    vat_amount = money(amount * vat_rate / 100)
    body = {
        "description": description,
        "amount": money_str(amount),
        "vatAmount": money_str(vat_amount),
        "total": money_str(amount + vat_amount),
        "expenseDate": iso(require_date(payload, "expenseDate")),
    }
    category = clean_text(payload.get("category"), 60)
    if category:
        body["category"] = category
    receipt = clean_text(payload.get("receiptNumber"), 40)
    if receipt:
        body["receiptNumber"] = receipt
    supplier = to_int_id(payload.get("supplierId"))
    if supplier is not None:
        body["supplierId"] = supplier
    return body


def build_customer_payload(payload):
    name = clean_text(payload.get("name"), 200)
    if not name:
        raise DokladError("invalid_input", "name")
    body = {"name": name}
    ico = clean_text(payload.get("ico"), 12)
    if ico:
        if not ICO_RE.fullmatch(ico):
            raise DokladError("invalid_ico")
        body["ico"] = ico
    email = clean_text(payload.get("email"), 200)
    if email:
        if not EMAIL_RE.fullmatch(email):
            raise DokladError("invalid_email")
        body["email"] = email
    for key, limit in (("dic", 16), ("phone", 32), ("address", 200), ("city", 80), ("postalCode", 12)):
        value = clean_text(payload.get(key), limit)
        if value:
            body[key] = value
    country = clean_text(payload.get("country"), 2).upper()
    body["country"] = country if country in ("CZ", "SK") else "CZ"
    return body


def find_secret(payload):
    """Locate a webhook signing secret in a registration response."""
    if not isinstance(payload, dict):
        return ""
    for container in (payload, payload.get("data"), payload.get("webhook")):
        if isinstance(container, dict):
            value = container.get("secret")
            if isinstance(value, str) and value.startswith("whsec_") and SECRET_VALUE_RE.fullmatch(value):
                return value
    return ""


def safe_file_label(value, fallback):
    label = re.sub(r"[^A-Za-z0-9_\-]+", "-", clean_text(value, 60)).strip("-")
    return label[:40] or fallback


def save_download(ctx, filename, data):
    ensure_private_dir(ctx.paths.download_dir)
    path = os.path.join(ctx.paths.download_dir, filename)
    write_private_file(path, data)
    return path


# --------------------------------------------------------------------------
# Actions
# --------------------------------------------------------------------------

def with_state(ctx, mutate):
    try:
        ensure_private_dir(ctx.paths.state_dir)
        with StateLock(ctx.paths, wait_seconds=5):
            state = load_state(ctx.paths)
            mutate(state)
            write_json_file(ctx.paths.state_file, state)
    except DokladError:
        pass  # bookkeeping must never fail a completed API write


def cached_customers(ctx):
    cache = load_cache(ctx.paths)
    return [item for item in (normalize_customer(row) for row in (cache or {}).get("customers", [])) if item]


def rows_of(payload):
    rows = payload.get("data") if isinstance(payload, dict) else payload
    return [row for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []


def unwrap(payload):
    if isinstance(payload, dict) and isinstance(payload.get("data"), dict) and "id" not in payload:
        return payload["data"]
    return payload if isinstance(payload, dict) else {}


def action_invoice_detail(ctx, payload):
    invoice_id = require_id(payload)
    client = ctx.client()
    raw = unwrap(client.get("/api/invoices/%d" % invoice_id))
    invoice = normalize_invoice(raw)
    if invoice is None:
        raise DokladError("bad_response")
    items = []
    for item in (raw.get("items") if isinstance(raw.get("items"), list) else [])[:MAX_ITEMS]:
        if isinstance(item, dict):
            items.append({
                "description": clean_text(item.get("description"), 200),
                "quantity": plain_decimal(to_decimal(item.get("quantity"), ZERO)),
                "unit": clean_text(item.get("unit"), 20),
                "unitPrice": money_float(to_decimal(item.get("unitPrice"), ZERO)),
                "vatRate": plain_decimal(to_decimal(item.get("vatRate"), ZERO)),
                "total": money_float(to_decimal(item.get("total"), ZERO)),
            })
    payments = []
    try:
        for row in rows_of(client.get("/api/invoices/%d/payments" % invoice_id))[:50]:
            payments.append({
                "amount": money_float(to_decimal(row.get("amount"), ZERO)),
                "paidAt": iso(parse_date(first_of(row, "paidAt", "paidDate", "date"))),
                "method": clean_text(first_of(row, "paymentMethod", "method"), 24),
                "note": clean_text(row.get("note"), 120),
            })
    except DokladError as exc:
        if exc.code in ("unauthorized", "offline", "timeout"):
            raise
    email = ""
    for customer in cached_customers(ctx):
        if customer["id"] == invoice["customerId"]:
            email = customer["email"]
            break
    hydrated = hydrate_invoice(invoice)
    return {"detail": {
        "id": invoice_id, "number": invoice["number"], "status": invoice["status"],
        "state": invoice_state(hydrated, ctx.today),
        "customerName": invoice["customerName"], "customerEmail": email,
        "issueDate": invoice["issueDate"], "dueDate": invoice["dueDate"], "taxDate": invoice["taxDate"],
        "subtotal": money_float(hydrated["subtotal"]), "vatAmount": money_float(hydrated["vat"]),
        "total": money_float(hydrated["total"]), "open": money_float(hydrated["open"]),
        "currency": invoice["currency"], "variableSymbol": invoice["variableSymbol"],
        "notes": clean_text(raw.get("notes"), 300), "items": items, "payments": payments,
    }}


def action_record_payment(ctx, payload):
    invoice_id = require_id(payload)
    amount = to_decimal(payload.get("amount"))
    if amount is None or amount <= 0 or amount > 10 ** 12:
        raise DokladError("invalid_amount", "amount")
    paid_at = require_date(payload, "paidAt")
    if paid_at > ctx.today:
        raise DokladError("invalid_date", "paidAt")
    method = payload.get("method") if payload.get("method") in PAYMENT_METHODS else "bank_transfer"
    body = {"amount": money_str(amount), "paidAt": iso(paid_at), "paymentMethod": method}
    note = clean_text(payload.get("note"), 200)
    if note:
        body["note"] = note
    ctx.client().json("POST", "/api/invoices/%d/payments" % invoice_id, payload=body)
    with_state(ctx, lambda state: mark_self_touched(state, invoice_id, ctx.now))
    return {"refresh": True, "amount": money_float(amount)}


def action_send_email(ctx, payload):
    invoice_id = require_id(payload)
    body = {}
    recipient = clean_text(payload.get("to"), 200)
    if recipient:
        if not EMAIL_RE.fullmatch(recipient):
            raise DokladError("invalid_email")
        body["to"] = recipient
    subject = clean_text(payload.get("subject"), 200)
    if subject:
        body["subject"] = subject
    message = clean_multiline(payload.get("message"), 5000)
    if message:
        body["customMessage"] = message
    ctx.client().json("POST", "/api/invoices/%d/email" % invoice_id, payload=body)
    return {"refresh": False}


def action_set_status(ctx, payload):
    invoice_id = require_id(payload)
    status = payload.get("status")
    if status not in SETTABLE_STATUSES:
        raise DokladError("invalid_input", "status")
    ctx.client().json("PATCH", "/api/invoices/%d" % invoice_id, payload={"status": status})
    with_state(ctx, lambda state: mark_self_touched(state, invoice_id, ctx.now))
    return {"refresh": True, "status": status}


def action_delete_draft(ctx, payload):
    invoice_id = require_id(payload)
    client = ctx.client()
    current = normalize_invoice(unwrap(client.get("/api/invoices/%d" % invoice_id)))
    if current is None or current["status"] != "draft":
        raise DokladError("not_a_draft")  # numbered documents are never deleted from the bar
    client.json("DELETE", "/api/invoices/%d" % invoice_id)
    return {"refresh": True}


def created_recently(invoice, now, window=900):
    """False only when the record carries a timestamp that is clearly older than this attempt."""
    try:
        stamp = dt.datetime.fromisoformat(invoice["createdAt"].replace("Z", "+00:00"))
    except ValueError:
        return True
    if stamp.tzinfo is None:
        return True
    return abs(now - stamp.timestamp()) <= window


def find_created_invoice(client, body, now):
    """After an ambiguous create, look for the invoice instead of blindly retrying."""
    query = {"customerId": body["customerId"], "dateFrom": body["issueDate"], "dateTo": body["issueDate"]}
    rows, _ = client.paginate("/api/invoices", query)
    total = to_decimal(body["total"], ZERO)
    for row in rows:
        invoice = normalize_invoice(row)
        if not invoice or invoice["customerId"] != body["customerId"]:
            continue
        if to_decimal(invoice["total"], ZERO) == total and created_recently(invoice, now):
            return invoice
    return None


def action_create_invoice(ctx, payload):
    draft = payload.get("draft") is not False
    body = build_invoice_payload(payload, draft)
    fingerprint = invoice_fingerprint(body)
    if payload.get("force") is not True:
        state = load_state(ctx.paths)
        for entry in state["recentCreates"]:
            if entry["fp"] == fingerprint and ctx.now - entry["at"] < DUPLICATE_WINDOW:
                raise DokladError("duplicate_recent")
    client = ctx.client()
    try:
        _, headers, response = client.json("POST", "/api/invoices", payload=body)
    except DokladError as exc:
        if exc.code not in ("timeout", "offline", "server_error", "bad_response"):
            raise
        # The API has no idempotency key: verify before anyone retries.
        try:
            found = find_created_invoice(client, body, ctx.now)
        except DokladError:
            raise DokladError("create_uncertain")
        if found is None:
            raise DokladError("create_not_found" if exc.code in ("timeout", "offline") else exc.code, exc.detail)
        headers, response = {}, {"id": found["id"], "invoiceNumber": found["number"]}
    created = unwrap(response)
    invoice_id = to_int_id(created.get("id"))

    def remember(state):
        state["recentCreates"] = (state["recentCreates"] + [{"fp": fingerprint, "at": int(ctx.now)}])[-20:]
        if invoice_id is not None:
            mark_self_touched(state, invoice_id, ctx.now)

    with_state(ctx, remember)
    warning = bool(headers.get("x-duplicate-warning")) or bool(created.get("duplicateWarning")) \
        or bool(isinstance(response, dict) and response.get("duplicateWarning"))
    return {
        "refresh": True, "id": invoice_id, "draft": draft,
        "number": clean_text(first_of(created, "invoiceNumber", "number"), 40),
        "total": money_float(to_decimal(body["total"], ZERO)),
        "duplicateWarning": warning,
    }


def action_preview_invoice(ctx, payload):
    """Offline: validates the form and returns the exact totals shown in the confirmation."""
    draft = payload.get("draft") is not False
    body = build_invoice_payload(payload, draft)
    return {
        "draft": draft, "customerName": body["customerName"], "itemCount": len(body["items"]),
        "subtotal": money_float(to_decimal(body["subtotal"], ZERO)),
        "vatAmount": money_float(to_decimal(body["vatAmount"], ZERO)),
        "total": money_float(to_decimal(body["total"], ZERO)),
    }


def action_preview_expense(ctx, payload):
    body = build_expense_payload(payload)
    return {
        "description": body["description"],
        "amount": money_float(to_decimal(body["amount"], ZERO)),
        "vatAmount": money_float(to_decimal(body["vatAmount"], ZERO)),
        "total": money_float(to_decimal(body["total"], ZERO)),
    }


def action_create_expense(ctx, payload):
    body = build_expense_payload(payload)
    ctx.client().json("POST", "/api/expenses", payload=body)
    return {"refresh": True, "total": money_float(to_decimal(body["total"], ZERO))}


def action_ares_lookup(ctx, payload):
    ico = clean_text(payload.get("ico"), 12)
    if not ICO_RE.fullmatch(ico):
        raise DokladError("invalid_ico")
    country = payload.get("country") if payload.get("country") in ("CZ", "SK") else "CZ"
    # Public route: no Authorization header is sent.
    raw = ctx.client(require_key=False).get("/api/test/ares/lookup/" + quote(ico, safe=""), {"country": country}, auth=False)
    if not isinstance(raw, dict) or not clean_text(raw.get("name"), 200):
        raise DokladError("not_found")
    legal_form = raw.get("legalForm") if isinstance(raw.get("legalForm"), dict) else {}
    existing = None
    for customer in cached_customers(ctx):
        if customer["ico"] == ico:
            existing = customer["id"]
            break
    return {"company": {
        "ico": ico, "country": country,
        "name": clean_text(raw.get("name"), 200), "dic": clean_text(raw.get("dic"), 16),
        "isVatPayer": raw.get("isVatPayer") is True,
        "address": clean_text(raw.get("address"), 200), "city": clean_text(raw.get("city"), 80),
        "postalCode": clean_text(first_of(raw, "postalCode", "zip"), 12),
        "legalForm": clean_text(legal_form.get("name"), 80),
        "existingCustomerId": existing,
    }}


def action_create_customer(ctx, payload):
    body = build_customer_payload(payload)
    if body.get("ico"):
        for customer in cached_customers(ctx):
            if customer["ico"] == body["ico"]:
                raise DokladError("customer_exists")
    _, _, response = ctx.client().json("POST", "/api/customers", payload=body)
    created = unwrap(response)
    return {"refresh": True, "id": to_int_id(created.get("id")), "name": body["name"]}


def action_update_customer(ctx, payload):
    customer_id = require_id(payload)
    body = {}
    if "email" in payload:
        email = clean_text(payload.get("email"), 200)
        if email and not EMAIL_RE.fullmatch(email):
            raise DokladError("invalid_email")
        body["email"] = email
    if "phone" in payload:
        body["phone"] = clean_text(payload.get("phone"), 32)
    if not body:
        raise DokladError("invalid_input")
    ctx.client().json("PATCH", "/api/customers/%d" % customer_id, payload=body)
    return {"refresh": True}


def action_download_pdf(ctx, payload):
    invoice_id = require_id(payload)
    _, _, data = ctx.client().request("GET", "/api/invoices/%d/pdf" % invoice_id,
                                      accept="application/pdf", max_bytes=MAX_BINARY_BYTES)
    if not data.startswith(b"%PDF"):
        raise DokladError("bad_response")
    label = safe_file_label(payload.get("number"), str(invoice_id))
    path = save_download(ctx, "faktura-%s.pdf" % label, data)
    opened = payload.get("open") is not False and ctx.spawner(["/usr/bin/xdg-open", path])
    return {"file": os.path.basename(path), "opened": bool(opened)}


def action_bulk_pdf(ctx, payload):
    raw_ids = payload.get("ids")
    if not isinstance(raw_ids, list):
        raise DokladError("invalid_input", "ids")
    ids = []
    for value in raw_ids[:MAX_BULK_IDS]:
        invoice_id = to_int_id(value)
        if invoice_id is not None and invoice_id not in ids:
            ids.append(invoice_id)
    if not ids:
        raise DokladError("invalid_input", "ids")
    client = ctx.client()
    data, last_error = None, None
    # The request body is not part of the published OpenAPI document; both common shapes are tried.
    for body in ({"invoiceIds": ids}, {"ids": ids}):
        try:
            _, _, data = client.request("POST", "/api/invoices/bulk-pdf", payload=body,
                                        accept="application/zip", max_bytes=MAX_BINARY_BYTES)
            break
        except DokladError as exc:
            last_error = exc
            if exc.code != "validation":
                raise
    if data is None:
        raise last_error
    if not data.startswith(b"PK"):
        raise DokladError("bad_response")
    label = safe_file_label(payload.get("label"), "vyber")
    path = save_download(ctx, "faktury-%s.zip" % label, data)
    return {"file": os.path.basename(path), "count": len(ids)}


def action_export(ctx, payload):
    spec = EXPORT_FORMATS.get(payload.get("format"))
    if spec is None:
        raise DokladError("invalid_input", "format")
    start, end = require_date(payload, "from"), require_date(payload, "to")
    if end < start:
        raise DokladError("invalid_date", "to")
    _, _, data = ctx.client().request(
        "GET", "/api/export/invoices/" + spec[0], {"dateFrom": iso(start), "dateTo": iso(end)},
        accept="*/*", max_bytes=MAX_BINARY_BYTES)
    if not data:
        raise DokladError("export_empty")
    extension = "zip" if data.startswith(b"PK") else spec[1]
    label = safe_file_label(payload.get("label"), "%s_%s" % (iso(start), iso(end)))
    path = save_download(ctx, "doklad-%s-%s.%s" % (label, spec[0], extension), data)
    return {"file": os.path.basename(path), "bytes": len(data)}


def list_webhooks(client):
    hooks = []
    for row in rows_of(client.get("/api/settings/webhooks"))[:50]:
        events = row.get("events") if isinstance(row.get("events"), list) else []
        hooks.append({
            "id": to_int_id(row.get("id")),
            "url": clean_text(row.get("url"), 200),
            "events": [clean_text(event, 40) for event in events[:20] if isinstance(event, str)],
            "active": first_of(row, "isActive", "active") is not False,
        })
    return hooks


def action_list_webhooks(ctx, payload):
    return {"webhooks": list_webhooks(ctx.client())}


def action_register_webhook(ctx, payload):
    relay_url = ctx.secrets["DOKLAD_RELAY_URL"]
    if not relay_url:
        raise DokladError("relay_not_configured")
    host, port, prefix = parse_relay_url(relay_url)
    if port != 443:
        raise DokladError("relay_invalid_url")  # Doklad.ai only delivers to port 443
    url = "https://%s%s/webhook" % (host, prefix)
    client = ctx.client()
    for hook in list_webhooks(client):
        if hook["url"].rstrip("/") == url:
            raise DokladError("webhook_exists")
    _, _, response = client.json("POST", "/api/settings/webhooks", payload={"url": url, "events": WEBHOOK_EVENTS})
    secret = find_secret(response)
    stored = False
    if secret:
        update_env_file(ctx.paths, {"DOKLAD_WEBHOOK_SECRET": secret})
        stored = True
    return {"registered": True, "secretStored": stored, "url": url, "webhooks": list_webhooks(client)}


def action_open(ctx, payload):
    target = payload.get("target")
    if target == "web":
        argv = ["/usr/bin/xdg-open", WEB_URL]
    elif target == "downloads":
        ensure_private_dir(ctx.paths.download_dir)
        argv = ["/usr/bin/xdg-open", ctx.paths.download_dir]
    else:
        raise DokladError("invalid_input", "target")
    if not ctx.spawner(argv):
        raise DokladError("open_failed")
    return {}


def action_copy(ctx, payload):
    text = clean_text(payload.get("text"), 200)
    if not text:
        raise DokladError("invalid_input", "text")
    try:
        subprocess.run(["/usr/bin/wl-copy"], input=text.encode("utf-8"), stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=5, check=True, env=child_environ())
    except (OSError, subprocess.SubprocessError):
        raise DokladError("copy_failed")
    return {}


ACTIONS = {
    "invoice-detail": action_invoice_detail,
    "record-payment": action_record_payment,
    "send-email": action_send_email,
    "set-status": action_set_status,
    "delete-draft": action_delete_draft,
    "preview-invoice": action_preview_invoice,
    "create-invoice": action_create_invoice,
    "preview-expense": action_preview_expense,
    "create-expense": action_create_expense,
    "ares-lookup": action_ares_lookup,
    "create-customer": action_create_customer,
    "update-customer": action_update_customer,
    "download-pdf": action_download_pdf,
    "bulk-pdf": action_bulk_pdf,
    "export": action_export,
    "list-webhooks": action_list_webhooks,
    "register-webhook": action_register_webhook,
    "open": action_open,
    "copy": action_copy,
}


def run_action(ctx, name, payload):
    handler = ACTIONS.get(name)
    if handler is None:
        return {"ok": False, "action": clean_text(name, 40), "error": "unknown_action", "detail": ""}
    if not isinstance(payload, dict):
        return {"ok": False, "action": name, "error": "invalid_input", "detail": ""}
    try:
        result = handler(ctx, payload) or {}
    except DokladError as exc:
        return {"ok": False, "action": name, "error": exc.code, "detail": exc.detail}
    result.update({"ok": True, "action": name})
    return result


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def emit(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def read_stdin_payload():
    line = sys.stdin.buffer.readline(MAX_STDIN_BYTES + 1)
    if len(line) > MAX_STDIN_BYTES:
        raise DokladError("invalid_input", "payload")
    try:
        return json.loads(line.decode("utf-8")) if line.strip() else {}
    except (ValueError, UnicodeDecodeError):
        raise DokladError("invalid_input", "payload")


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="doklad.py", add_help=True)
    commands = parser.add_subparsers(dest="command", required=True)
    snapshot = commands.add_parser("snapshot")
    snapshot.add_argument("--horizon", choices=HORIZONS, default="month")
    snapshot.add_argument("--offset", type=int, default=0)
    snapshot.add_argument("--max-age", type=int, default=300)
    snapshot.add_argument("--limit", type=int, default=2000000)
    snapshot.add_argument("--lang", default="cs")
    snapshot.add_argument("--force", action="store_true")
    snapshot.add_argument("--cached", action="store_true")
    snapshot.add_argument("--notify", action="store_true")
    snapshot.add_argument("--privacy", action="store_true")
    action = commands.add_parser("action")
    action.add_argument("name")
    commands.add_parser("verify-auth")
    secret = commands.add_parser("set-secret")
    secret.add_argument("name", choices=SECRET_KEYS)
    return parser.parse_args(argv)


def snapshot_options(args):
    return {
        "horizon": args.horizon,
        "offset": max(-600, min(0, args.offset)),
        "max_age": max(0, min(86400, args.max_age)),
        "limit": max(0, min(10 ** 9, args.limit)),
        "lang": ui_language(args.lang),
        "force": args.force,
        "cached": args.cached,
        "notify": args.notify,
        "privacy": args.privacy,
    }


def verify_auth(ctx):
    try:
        ctx.client().get("/api/invoices", {"limit": 1})
    except DokladError as exc:
        sys.stderr.write("Doklad.ai: %s%s\n" % (exc.code, (" (" + exc.detail + ")") if exc.detail else ""))
        return 1
    sys.stdout.write("Doklad.ai: OK\n")
    return 0


def set_secret(ctx, name):
    """Reads the value from stdin (never argv) and stores it in the private env file."""
    try:
        line = sys.stdin.buffer.readline(MAX_ENV_BYTES + 1)
        if len(line) > MAX_ENV_BYTES:
            raise DokladError("invalid_env", name)
        try:
            stored = store_secret(ctx.paths, name, line.decode("utf-8"))
        except UnicodeDecodeError:
            raise DokladError("invalid_env", name)
    except DokladError as exc:
        sys.stderr.write("Doklad.ai: %s%s\n" % (exc.code, (" (" + exc.detail + ")") if exc.detail else ""))
        return 1
    sys.stdout.write("Doklad.ai: %s %s\n" % (name, "uloženo" if stored else "odstraněno"))
    return 0


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    ctx = Context()
    try:
        if args.command == "verify-auth":
            return verify_auth(ctx)
        if args.command == "set-secret":
            return set_secret(ctx, args.name)
        if args.command == "snapshot":
            emit(run_snapshot(ctx, snapshot_options(args)))
            return 0
        try:
            payload = read_stdin_payload()
        except DokladError as exc:
            emit({"ok": False, "action": clean_text(args.name, 40), "error": exc.code, "detail": exc.detail})
            return 0
        emit(run_action(ctx, args.name, payload))
        return 0
    except Exception as exc:  # last line of defence: never leak a traceback into the shell log
        emit({"ok": False, "status": "error", "error": "internal", "errorDetail": type(exc).__name__,
              "detail": type(exc).__name__, "hasData": False})
        return 0


if __name__ == "__main__":
    sys.exit(main())
