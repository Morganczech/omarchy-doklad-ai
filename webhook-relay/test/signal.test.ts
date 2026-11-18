// Run with:  npm test   (Node >= 22.12 executes TypeScript directly)

import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { test } from "node:test";

import { bearerToken, decodeSignature, verifySignature } from "../src/signal.ts";

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

test("bearer parsing", () => {
  assert.equal(bearerToken("Bearer abc123"), "abc123");
  assert.equal(bearerToken("bearer abc123"), null);
  assert.equal(bearerToken("Basic abc123"), null);
  assert.equal(bearerToken("Bearer "), null);
  assert.equal(bearerToken("Bearer a b"), null);
  assert.equal(bearerToken(null), null);
});
