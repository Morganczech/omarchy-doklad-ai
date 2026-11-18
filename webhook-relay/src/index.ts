// Zero-Data webhook relay for the Omarchy Doklad.ai bar plugin.
//
//   POST …/webhook   Doklad.ai delivers here. The HMAC signature is verified,
//                    the body is reduced to {event, resourceId} and dropped.
//   GET  …/events    The desktop plugin reads signals newer than ?after=<seq>
//                    with `Authorization: Bearer <RELAY_TOKEN>` and then asks
//                    Doklad.ai directly for the details.
//
// Signals expire after 24 hours. Request bodies are never stored or logged.

import { DurableObject } from "cloudflare:workers";
import { bearerToken, deliveryKey, extractSignal, parseCursor, verifySignature } from "./signal.ts";

const MAX_BODY_BYTES = 256 * 1024;
const RETENTION_MS = 24 * 60 * 60 * 1000;
const MAX_STORED = 500;
const PAGE_SIZE = 200;
const MIN_WEBHOOK_SECRET_LENGTH = 16;
const MIN_RELAY_TOKEN_LENGTH = 32;

type SignalRow = {
  seq: number;
  event: string;
  resource_id: number | null;
  received_at: number;
};

export type StoredSignal = {
  seq: number;
  event: string;
  resourceId: number | null;
  receivedAt: number;
};

export type SignalPage = {
  events: StoredSignal[];
  /** Sequence number to pass as `after` next time. */
  cursor: number;
  /** Highest sequence number ever assigned; lets a client notice a reset relay. */
  head: number;
};

export type RecordResult = {
  seq: number;
  duplicate: boolean;
};

/** One instance holds the short-lived signal queue of the single company this relay serves. */
export class SignalStore extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS signals (
          seq INTEGER PRIMARY KEY,
          delivery_id TEXT NOT NULL UNIQUE,
          event TEXT NOT NULL,
          resource_id INTEGER,
          received_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS signals_received_at ON signals (received_at);
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          value INTEGER NOT NULL
        );
      `);
    });
  }

  private head(): number {
    const rows = this.ctx.storage.sql
      .exec<{ value: number }>("SELECT value FROM meta WHERE key = 'head'")
      .toArray();
    return rows[0]?.value ?? 0;
  }

  private prune(now: number): void {
    const sql = this.ctx.storage.sql;
    sql.exec("DELETE FROM signals WHERE received_at < ?", now - RETENTION_MS);
    sql.exec("DELETE FROM signals WHERE seq <= ?", this.head() - MAX_STORED);
  }

  async record(deliveryId: string, event: string, resourceId: number | null): Promise<RecordResult> {
    const now = Date.now();
    const sql = this.ctx.storage.sql;

    // No await until the writes are done, so they commit together.
    const known = sql.exec<{ seq: number }>("SELECT seq FROM signals WHERE delivery_id = ?", deliveryId).toArray();
    const existing = known[0];
    if (existing !== undefined) {
      return { seq: existing.seq, duplicate: true };
    }
    const seq = this.head() + 1;
    sql.exec(
      "INSERT INTO signals (seq, delivery_id, event, resource_id, received_at) VALUES (?, ?, ?, ?, ?)",
      seq,
      deliveryId,
      event,
      resourceId,
      now,
    );
    sql.exec(
      "INSERT INTO meta (key, value) VALUES ('head', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
      seq,
    );
    this.prune(now);

    if ((await this.ctx.storage.getAlarm()) === null) {
      await this.ctx.storage.setAlarm(now + RETENTION_MS + 60_000);
    }
    return { seq, duplicate: false };
  }

  async list(after: number): Promise<SignalPage> {
    this.prune(Date.now());
    const rows = this.ctx.storage.sql
      .exec<SignalRow>(
        "SELECT seq, event, resource_id, received_at FROM signals WHERE seq > ? ORDER BY seq LIMIT ?",
        after,
        PAGE_SIZE,
      )
      .toArray();
    const events = rows.map((row) => ({
      seq: row.seq,
      event: row.event,
      resourceId: row.resource_id,
      receivedAt: row.received_at,
    }));
    const head = this.head();
    return { events, cursor: events.at(-1)?.seq ?? Math.min(after, head), head };
  }

  override async alarm(): Promise<void> {
    const now = Date.now();
    this.prune(now);
    const oldest = this.ctx.storage.sql
      .exec<{ received_at: number }>("SELECT received_at FROM signals ORDER BY received_at LIMIT 1")
      .toArray()[0];
    if (oldest !== undefined) {
      await this.ctx.storage.setAlarm(oldest.received_at + RETENTION_MS + 60_000);
    }
  }
}

const BASE_HEADERS = {
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
};

function json(status: number, body: unknown): Response {
  return Response.json(body, { status, headers: BASE_HEADERS });
}

function refuse(status: number, extra?: Record<string, string>): Response {
  return new Response(null, { status, headers: { ...BASE_HEADERS, ...extra } });
}

function log(message: string, fields: Record<string, string | number | boolean | null> = {}): void {
  console.log(JSON.stringify({ message, ...fields }));
}

/** Reads the request body, giving up as soon as it exceeds `limit` bytes. */
async function readLimited(request: Request, limit: number): Promise<Uint8Array<ArrayBuffer> | null> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > limit) return null;
  if (request.body === null) return new Uint8Array(0);

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

/** Compares two secrets without leaking their length or contents through timing. */
async function secretsMatch(provided: string, expected: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [providedHash, expectedHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(provided)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  return crypto.subtle.timingSafeEqual(providedHash, expectedHash);
}

function configured(value: unknown, minimumLength: number): value is string {
  return typeof value === "string" && value.length >= minimumLength;
}

async function handleWebhook(request: Request, env: Env): Promise<Response> {
  if (!configured(env.WEBHOOK_SECRET, MIN_WEBHOOK_SECRET_LENGTH)) {
    log("webhook rejected", { reason: "secret_not_configured" });
    return refuse(503);
  }
  const signature = request.headers.get("x-webhook-signature");
  if (signature === null) {
    log("webhook rejected", { reason: "signature_missing" });
    return refuse(401);
  }
  const body = await readLimited(request, MAX_BODY_BYTES);
  if (body === null) {
    log("webhook rejected", { reason: "body_too_large" });
    return refuse(413);
  }
  if (!(await verifySignature(env.WEBHOOK_SECRET, body, signature))) {
    log("webhook rejected", { reason: "signature_invalid" });
    return refuse(401);
  }

  const signal = extractSignal(new TextDecoder().decode(body), request.headers.get("x-webhook-event"));
  const delivery = await deliveryKey(request.headers.get("x-webhook-delivery"), body);
  const stored = await env.SIGNALS.getByName("default").record(delivery, signal.event, signal.resourceId);
  log("signal accepted", {
    event: signal.event,
    seq: stored.seq,
    duplicate: stored.duplicate,
    hasResourceId: signal.resourceId !== null,
  });
  return json(200, { ok: true });
}

async function handleEvents(request: Request, url: URL, env: Env): Promise<Response> {
  if (!configured(env.RELAY_TOKEN, MIN_RELAY_TOKEN_LENGTH)) {
    log("events rejected", { reason: "token_not_configured" });
    return refuse(503);
  }
  const token = bearerToken(request.headers.get("authorization"));
  if (token === null || !(await secretsMatch(token, env.RELAY_TOKEN))) {
    log("events rejected", { reason: "unauthorized" });
    return refuse(401, { "WWW-Authenticate": "Bearer" });
  }
  const after = parseCursor(url.searchParams.get("after"));
  if (after === null) return refuse(400);
  return json(200, await env.SIGNALS.getByName("default").list(after));
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    const route = url.pathname.replace(/\/+$/, "");
    try {
      if (route.endsWith("/webhook")) {
        return request.method === "POST" ? await handleWebhook(request, env) : refuse(405, { Allow: "POST" });
      }
      if (route.endsWith("/events")) {
        return request.method === "GET" ? await handleEvents(request, url, env) : refuse(405, { Allow: "GET" });
      }
      return refuse(404);
    } catch (error) {
      console.error(
        JSON.stringify({ message: "relay failure", error: error instanceof Error ? error.name : "unknown" }),
      );
      return refuse(500);
    }
  },
} satisfies ExportedHandler<Env>;
