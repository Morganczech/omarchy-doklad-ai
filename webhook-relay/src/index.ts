// Authenticate incoming webhooks and expose only a change counter.

import { DurableObject } from "cloudflare:workers";
import { bearerToken, verifySignature } from "./signal.ts";

const MAX_BODY_BYTES = 256 * 1024;
const MIN_WEBHOOK_SECRET_LENGTH = 16;
const MIN_RELAY_TOKEN_LENGTH = 32;

export class SignalStore extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      const sql = ctx.storage.sql;
      sql.exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL)");
      // Existing deployments keep their counter while discarding the old queue.
      sql.exec("DROP TABLE IF EXISTS signals");
      await ctx.storage.deleteAlarm();
    });
  }

  async record(): Promise<void> {
    this.ctx.storage.sql.exec(
      "INSERT INTO meta (key, value) VALUES ('head', 1) ON CONFLICT (key) DO UPDATE SET value = value + 1",
    );
  }

  async head(): Promise<number> {
    return this.ctx.storage.sql
      .exec<{ value: number }>("SELECT value FROM meta WHERE key = 'head'")
      .toArray()[0]?.value ?? 0;
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

  await env.SIGNALS.getByName("default").record();
  return json(200, { ok: true });
}

async function handleEvents(request: Request, env: Env): Promise<Response> {
  if (!configured(env.RELAY_TOKEN, MIN_RELAY_TOKEN_LENGTH)) {
    log("events rejected", { reason: "token_not_configured" });
    return refuse(503);
  }
  const token = bearerToken(request.headers.get("authorization"));
  if (token === null || !(await secretsMatch(token, env.RELAY_TOKEN))) {
    log("events rejected", { reason: "unauthorized" });
    return refuse(401, { "WWW-Authenticate": "Bearer" });
  }
  return json(200, { head: await env.SIGNALS.getByName("default").head() });
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
        return request.method === "GET" ? await handleEvents(request, env) : refuse(405, { Allow: "GET" });
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
