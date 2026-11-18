// Pure helpers shared by the Worker and its tests. Everything here runs on
// standard Web APIs only, so `node --test` can exercise it without a runtime.

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

/** Extracts the token from an `Authorization: Bearer …` header. */
export function bearerToken(header: string | null): string | null {
  if (header === null) return null;
  const match = /^Bearer ([\x21-\x7e]{1,512})$/.exec(header.trim());
  return match?.[1] ?? null;
}
