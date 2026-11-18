// Run with:  npm test   (Node >= 22.12 executes TypeScript directly)

import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { test } from "node:test";

import {
  UNKNOWN_EVENT,
  bearerToken,
  decodeSignature,
  deliveryKey,
  extractSignal,
  parseCursor,
  verifySignature,
} from "../src/signal.ts";

const SECRET = "whsec_test_0123456789abcdef";
const encode = (text: string) => new TextEncoder().encode(text);
const sign = (secret: string, body: string) => createHmac("sha256", secret).update(body).digest("hex");

test("accepts the signature Doklad.ai documents", async () => {
  const body = '{"event":"invoice.paid","data":{"id":42}}';
  assert.equal(await verifySignature(SECRET, encode(body), sign(SECRET, body)), true);
  assert.equal(await verifySignature(SECRET, encode(body), sign(SECRET, body).toUpperCase()), true);
  assert.equal(await verifySignature(SECRET, encode(body), `sha256=${sign(SECRET, body)}`), true);
});

test("signature covers the body byte for byte", async () => {
  const body = '{"event":"invoice.paid","data":{"id":42}}';
  const signature = sign(SECRET, body);
  assert.equal(await verifySignature(SECRET, encode(body + " "), signature), false);
  assert.equal(await verifySignature(SECRET, encode(body.replace("42", "43")), signature), false);
  const unicode = '{"customerName":"Žluťoučký kůň"}';
  assert.equal(await verifySignature(SECRET, encode(unicode), sign(SECRET, unicode)), true);
});

test("rejects wrong, missing and malformed signatures", async () => {
  const body = '{"event":"invoice.paid"}';
  assert.equal(await verifySignature(SECRET, encode(body), sign("whsec_other", body)), false);
  assert.equal(await verifySignature(SECRET, encode(body), sign("test_0123456789abcdef", body)), false);
  assert.equal(await verifySignature(SECRET, encode(body), null), false);
  assert.equal(await verifySignature(SECRET, encode(body), ""), false);
  assert.equal(await verifySignature(SECRET, encode(body), "zz".repeat(32)), false);
  assert.equal(await verifySignature(SECRET, encode(body), sign(SECRET, body).slice(0, 62)), false);
  assert.equal(await verifySignature("", encode(body), sign("", body)), false);
});

test("decodeSignature only accepts a full SHA-256 hex digest", () => {
  assert.equal(decodeSignature("ab".repeat(32))?.length, 32);
  assert.equal(decodeSignature(` ${"0f".repeat(32)} `)?.[0], 15);
  assert.equal(decodeSignature("ab".repeat(31)), null);
  assert.equal(decodeSignature("ab".repeat(33)), null);
  assert.equal(decodeSignature("sha1=" + "ab".repeat(32)), null);
});

test("keeps only the event name and the record id", () => {
  const body = JSON.stringify({
    event: "invoice.paid",
    timestamp: "2026-11-18T10:00:00Z",
    data: { id: 42, invoiceNumber: "20260042", customerName: "Acme s.r.o.", total: "1210.00" },
  });
  const signal = extractSignal(body, null);
  assert.deepEqual(signal, { event: "invoice.paid", resourceId: 42 });
  assert.deepEqual(Object.keys(signal).sort(), ["event", "resourceId"]);
});

test("finds the id in the common payload layouts", () => {
  const cases: [unknown, number | null][] = [
    [{ event: "invoice.paid", data: { invoice: { id: 7, customerId: 3 } } }, 7],
    [{ event: "invoice.paid", data: { invoiceId: "8", id: 99 } }, 8],
    [{ type: "invoice.overdue", payload: { id: 9 } }, 9],
    [{ event: "invoice.created", invoice: { id: 10 } }, 10],
    [{ event: "invoice.created", invoiceId: 11 }, 11],
    [{ event: "customer.created", data: { id: 12, name: "Beta a.s." } }, 12],
    [{ event: "customer.created", data: { customer: { id: 13 } } }, 13],
    [{ event: "invoice.paid", id: "evt_123" }, null],
    [{ event: "invoice.paid", data: { id: -5 } }, null],
    [{ event: "invoice.paid", data: { id: 1.5 } }, null],
    [{ event: "invoice.paid", data: { id: "12abc" } }, null],
    [{ event: "invoice.paid", data: { id: 2 ** 60 } }, null],
  ];
  for (const [payload, expected] of cases) {
    assert.equal(extractSignal(JSON.stringify(payload), null).resourceId, expected, JSON.stringify(payload));
  }
});

test("falls back to the header and then to a neutral event name", () => {
  assert.equal(extractSignal('{"data":{"id":1}}', "invoice.paid").event, "invoice.paid");
  assert.equal(extractSignal("not json", " invoice.created ").event, "invoice.created");
  assert.equal(extractSignal("not json", null).event, UNKNOWN_EVENT);
  assert.equal(extractSignal("[1,2,3]", null).event, UNKNOWN_EVENT);
  assert.equal(extractSignal('{"event":"<script>alert(1)</script>"}', null).event, UNKNOWN_EVENT);
  assert.equal(extractSignal('{"event":"Invoice.Paid"}', null).event, UNKNOWN_EVENT);
  assert.equal(extractSignal(`{"event":"${"a".repeat(40)}.paid"}`, null).event, UNKNOWN_EVENT);
});

test("delivery key prefers the header and hashes the body otherwise", async () => {
  const body = encode('{"event":"invoice.paid"}');
  assert.equal(await deliveryKey("d1f0c5e2-0001", body), "id:d1f0c5e2-0001");
  const hashed = await deliveryKey(null, body);
  assert.match(hashed, /^body:[0-9a-f]{64}$/);
  assert.equal(await deliveryKey("", body), hashed);
  assert.equal(await deliveryKey("bad id with spaces", body), hashed);
  assert.equal(await deliveryKey("x".repeat(200), body), hashed);
  assert.notEqual(await deliveryKey(null, encode('{"event":"invoice.created"}')), hashed);
});

test("cursor and bearer parsing", () => {
  assert.equal(parseCursor(null), 0);
  assert.equal(parseCursor(""), 0);
  assert.equal(parseCursor("17"), 17);
  assert.equal(parseCursor("-1"), null);
  assert.equal(parseCursor("1e3"), null);
  assert.equal(parseCursor("1 OR 1=1"), null);
  assert.equal(bearerToken("Bearer abc123"), "abc123");
  assert.equal(bearerToken("bearer abc123"), null);
  assert.equal(bearerToken("Basic abc123"), null);
  assert.equal(bearerToken("Bearer "), null);
  assert.equal(bearerToken("Bearer a b"), null);
  assert.equal(bearerToken(null), null);
});
