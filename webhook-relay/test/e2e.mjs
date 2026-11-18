// End-to-end check against a running relay (local `wrangler dev` by default).
//
//   printf 'WEBHOOK_SECRET=whsec_localtest_0123456789abcdef\nRELAY_TOKEN=localtesttoken_0123456789abcdef0123456789abcdef\n' > .dev.vars
//   npx wrangler dev --port 8799      (in another terminal)
//   npm run test:e2e
//
// RELAY_E2E_URL, WEBHOOK_SECRET and RELAY_TOKEN override the defaults. Do not
// point this at a production relay: test webhooks change its counter.

import assert from "node:assert/strict";
import { createHmac } from "node:crypto";

const base = (process.env.RELAY_E2E_URL ?? "http://127.0.0.1:8799").replace(/\/+$/, "");
const secret = process.env.WEBHOOK_SECRET ?? "whsec_localtest_0123456789abcdef";
const token = process.env.RELAY_TOKEN ?? "localtesttoken_0123456789abcdef0123456789abcdef";

const sign = (body, key = secret) => createHmac("sha256", key).update(body).digest("hex");

async function deliver(body, { signature = sign(body), method = "POST" } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (signature !== null) headers["X-Webhook-Signature"] = signature;
  return fetch(`${base}/webhook`, { method, headers, body: method === "POST" ? body : undefined });
}

async function events(after, auth = `Bearer ${token}`) {
  const headers = auth === null ? {} : { Authorization: auth };
  return fetch(`${base}/events?after=${after}`, { headers });
}

const steps = [];
const step = (name, run) => steps.push([name, run]);

let start = 0;

step("reading signals requires the bearer token", async () => {
  assert.equal((await events(0, null)).status, 401);
  assert.equal((await events(0, "Bearer wrong-token")).status, 401);
  assert.equal((await events(0, `Basic ${token}`)).status, 401);
  assert.equal((await events(0, `Bearer ${token}x`)).status, 401);
  const response = await events(0);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  const page = await response.json();
  assert.deepEqual(Object.keys(page), ["head"]);
  start = page.head;
});

step("unsigned and wrongly signed webhooks are refused and store nothing", async () => {
  const body = JSON.stringify({ event: "invoice.paid", data: { id: 1 } });
  assert.equal((await deliver(body, { signature: null })).status, 401);
  assert.equal((await deliver(body, { signature: sign(body, "whsec_someone_else") })).status, 401);
  assert.equal((await deliver(body, { signature: "not-hex" })).status, 401);
  assert.equal((await deliver(body + " ")).status === 200, true); // signed over the exact bytes sent
  assert.equal((await deliver(body + "  ", { signature: sign(body) })).status, 401);
  const page = await (await events(start)).json();
  assert.equal(page.head, start + 1);
  start = page.head;
});

step("a signed webhook becomes a signal without any accounting data", async () => {
  const body = JSON.stringify({
    event: "invoice.paid",
    timestamp: new Date().toISOString(),
    data: { id: 4821, invoiceNumber: "20260042", customerName: "Tajný Zákazník s.r.o.", total: "121000.00" },
  });
  const response = await deliver(body);
  assert.equal(response.status, 200);
  const raw = await (await events(start)).text();
  for (const leaked of ["Tajný", "20260042", "121000", "customerName", "invoiceNumber"]) {
    assert.equal(raw.includes(leaked), false, `relay leaked ${leaked}`);
  }
  const page = JSON.parse(raw);
  assert.deepEqual(page, { head: start + 1 });
  start = page.head;
});

step("multiple deliveries update the same counter", async () => {
  const body = JSON.stringify({ event: "invoice.created", data: { id: 77 } });
  for (let attempt = 0; attempt < 3; attempt += 1) {
    assert.equal((await deliver(body)).status, 200);
  }
  const page = await (await events(start)).json();
  assert.deepEqual(page, { head: start + 3 });
  start = page.head;
});

step("oversized bodies and other routes are refused", async () => {
  const big = JSON.stringify({ event: "invoice.paid", filler: "x".repeat(300 * 1024) });
  assert.equal((await deliver(big)).status, 413);
  assert.equal((await deliver("", { method: "GET" })).status, 405);
  assert.equal((await fetch(`${base}/events`, { method: "POST", headers: { Authorization: `Bearer ${token}` } })).status, 405);
  assert.equal((await fetch(`${base}/`)).status, 404);
  assert.equal((await fetch(`${base}/admin`)).status, 404);
  const page = await (await events(start)).json();
  assert.deepEqual(page, { head: start });
});

let failed = 0;
for (const [name, run] of steps) {
  try {
    await run();
    console.log(`ok    ${name}`);
  } catch (error) {
    failed += 1;
    console.log(`FAIL  ${name}\n      ${error instanceof Error ? error.message : error}`);
  }
}
console.log(failed === 0 ? `\nall ${steps.length} checks passed against ${base}` : `\n${failed} of ${steps.length} checks failed`);
process.exit(failed === 0 ? 0 : 1);
