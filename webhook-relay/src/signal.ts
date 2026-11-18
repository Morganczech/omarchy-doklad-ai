// Pure helpers shared by the Worker and its tests. Everything here runs on
// standard Web APIs only, so `node --test` can exercise it without a runtime.

export type Signal = {
  event: string;
  resourceId: number | null;
};

export const UNKNOWN_EVENT = "unknown.event";

const EVENT_NAME = /^[a-z_]{1,32}\.[a-z_]{1,32}$/;
const DELIVERY_ID = /^[A-Za-z0-9._:\-]{1,128}$/;
const HEX_DIGEST = /^[0-9a-f]{64}$/;

/** Decodes a hex HMAC-SHA256 digest. Accepts an optional `sha256=` prefix. */
export function decodeSignature(header: string | null): Uint8Array<ArrayBuffer> | null {
  if (header === null) return null;
  let value = header.trim().toLowerCase();
  if (value.startsWith("sha256=")) value = value.slice(7);
  if (!HEX_DIGEST.test(value)) return null;
  const bytes = new Uint8Array(32);
  for (let index = 0; index < 32; index += 1) {
    bytes[index] = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

/**
 * Checks `X-Webhook-Signature`: hex HMAC-SHA256 of the untouched request body,
 * keyed with the whole `whsec_…` secret. `crypto.subtle.verify` compares in
 * constant time.
 */
export async function verifySignature(
  secret: string,
  body: Uint8Array<ArrayBuffer>,
  header: string | null,
): Promise<boolean> {
  const signature = decodeSignature(header);
  if (signature === null || secret.length === 0) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  return crypto.subtle.verify("HMAC", key, signature, body);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function eventName(value: unknown): string | null {
  return typeof value === "string" && EVENT_NAME.test(value) ? value : null;
}

function positiveId(value: unknown): number | null {
  if (typeof value === "number") {
    return Number.isSafeInteger(value) && value > 0 ? value : null;
  }
  if (typeof value === "string" && /^[1-9][0-9]{0,15}$/.test(value)) {
    const parsed = Number(value);
    return Number.isSafeInteger(parsed) ? parsed : null;
  }
  return null;
}

/**
 * Reduces a webhook body to the event name and the id of the record it is
 * about. Nothing else from the payload leaves this function.
 *
 * Doklad.ai does not document the payload layout, so the id is searched in the
 * places webhook payloads commonly use. When it cannot be found the signal is
 * still delivered; the plugin then simply refreshes everything.
 */
export function extractSignal(bodyText: string, headerEvent: string | null): Signal {
  let payload: unknown = null;
  try {
    payload = JSON.parse(bodyText);
  } catch {
    payload = null;
  }
  const root = isRecord(payload) ? payload : {};
  const event =
    eventName(root["event"]) ?? eventName(root["type"]) ?? eventName(headerEvent?.trim()) ?? UNKNOWN_EVENT;

  const entity = event.split(".")[0] ?? "";
  const containers: Record<string, unknown>[] = [];
  for (const key of ["data", "payload", "object"]) {
    const nested = root[key];
    if (isRecord(nested)) containers.push(nested);
  }

  let resourceId: number | null = null;
  for (const container of [...containers, root]) {
    const nested = container[entity];
    resourceId = positiveId(container[`${entity}Id`]) ?? (isRecord(nested) ? positiveId(nested["id"]) : null);
    if (resourceId !== null) break;
  }
  if (resourceId === null) {
    for (const container of containers) {
      resourceId = positiveId(container["id"]);
      if (resourceId !== null) break;
    }
  }
  return { event, resourceId };
}

/**
 * Key used to recognise a repeated delivery: the `X-Webhook-Delivery` header,
 * or a SHA-256 of the body when the header is missing or malformed.
 */
export async function deliveryKey(header: string | null, body: Uint8Array<ArrayBuffer>): Promise<string> {
  const value = header?.trim() ?? "";
  if (DELIVERY_ID.test(value)) return `id:${value}`;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", body));
  let hex = "";
  for (const byte of digest) hex += byte.toString(16).padStart(2, "0");
  return `body:${hex}`;
}

/** Parses the `after` cursor of `GET /events`. Returns null when it is not a sequence number. */
export function parseCursor(value: string | null): number | null {
  if (value === null || value === "") return 0;
  if (!/^[0-9]{1,15}$/.test(value)) return null;
  return Number(value);
}

/** Extracts the token from an `Authorization: Bearer …` header. */
export function bearerToken(header: string | null): string | null {
  if (header === null) return null;
  const match = /^Bearer ([\x21-\x7e]{1,512})$/.exec(header.trim());
  return match?.[1] ?? null;
}
