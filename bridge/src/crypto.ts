/**
 * Envelope encryption shared with the iPhone app (CryptoKit + CommonCrypto).
 *
 *   key  = PBKDF2-HMAC-SHA256(NFC(passphrase), salt, iter, 32 bytes)
 *   ct   = AES-256-GCM(key, iv[12], plaintext, aad = "tagwerk:" + kind) -> ciphertext || tag[16]
 *
 * Envelope (UTF-8 JSON): {"tw":1,"k":kind,"kdf":"pbkdf2-sha256","iter":n,"salt":b64,"iv":b64,"ct":b64}
 * Base64 is standard alphabet with padding.
 */

export type EnvelopeKind = "inbox" | "snapshot" | "wiki";

export interface Envelope {
  tw: 1;
  k: EnvelopeKind;
  kdf: "pbkdf2-sha256";
  iter: number;
  salt: string;
  iv: string;
  ct: string;
}

export const DEFAULT_ITERATIONS = 600_000;

const subtle = (): SubtleCrypto => {
  const c = globalThis.crypto;
  if (!c?.subtle) throw new Error("WebCrypto ist nicht verfügbar.");
  return c.subtle;
};

const te = new TextEncoder();
const td = new TextDecoder("utf-8", { fatal: true });

export class DecryptionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DecryptionError";
  }
}

export function toB64(bytes: Uint8Array): string {
  let bin = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(bin);
}

export function fromB64(s: string): Uint8Array {
  const clean = s.replace(/[\r\n\s]/g, "");
  const bin = atob(clean);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function randomBytes(n: number): Uint8Array {
  const b = new Uint8Array(n);
  globalThis.crypto.getRandomValues(b);
  return b;
}

export async function sha256Hex(data: string | Uint8Array): Promise<string> {
  const bytes = typeof data === "string" ? te.encode(data) : data;
  const digest = new Uint8Array(await subtle().digest("SHA-256", bytes as BufferSource));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Normalised journal text; both sides hash exactly this. */
export function normalizeJournal(text: string | null | undefined): string {
  if (!text) return "";
  return text.normalize("NFC").replace(/\r\n?/g, "\n").trim();
}

/** "" for no/empty journal, else the first 16 hex chars of SHA-256(normalized). */
export async function journalHash(text: string | null | undefined): Promise<string> {
  const n = normalizeJournal(text);
  if (!n) return "";
  return (await sha256Hex(n)).slice(0, 16);
}

const keyCache = new Map<string, Promise<CryptoKey>>();

async function deriveKey(passphrase: string, salt: Uint8Array, iter: number): Promise<CryptoKey> {
  const pw = passphrase.normalize("NFC");
  const cacheKey = `${iter}|${toB64(salt)}|${await sha256Hex(pw)}`;
  let p = keyCache.get(cacheKey);
  if (!p) {
    p = (async () => {
      const base = await subtle().importKey("raw", te.encode(pw) as BufferSource, "PBKDF2", false, ["deriveKey"]);
      return subtle().deriveKey(
        { name: "PBKDF2", hash: "SHA-256", salt: salt as BufferSource, iterations: iter },
        base,
        { name: "AES-GCM", length: 256 },
        false,
        ["encrypt", "decrypt"],
      );
    })();
    keyCache.set(cacheKey, p);
    p.catch(() => keyCache.delete(cacheKey));
  }
  return p;
}

export interface SealOptions {
  salt: Uint8Array;
  iterations?: number;
  /** Only for test vectors. Never reuse an IV with the same key. */
  iv?: Uint8Array;
}

export async function seal(plaintext: string, passphrase: string, kind: EnvelopeKind, opts: SealOptions): Promise<string> {
  if (!passphrase) throw new Error("Keine Passphrase gesetzt.");
  const iter = opts.iterations ?? DEFAULT_ITERATIONS;
  const iv = opts.iv ?? randomBytes(12);
  const key = await deriveKey(passphrase, opts.salt, iter);
  const ct = new Uint8Array(
    await subtle().encrypt(
      { name: "AES-GCM", iv: iv as BufferSource, additionalData: te.encode(`tagwerk:${kind}`) as BufferSource, tagLength: 128 },
      key,
      te.encode(plaintext) as BufferSource,
    ),
  );
  const env: Envelope = { tw: 1, k: kind, kdf: "pbkdf2-sha256", iter, salt: toB64(opts.salt), iv: toB64(iv), ct: toB64(ct) };
  return JSON.stringify(env);
}

export async function open(envelopeText: string, passphrase: string, expectedKind: EnvelopeKind): Promise<string> {
  let env: Envelope;
  try {
    env = JSON.parse(envelopeText) as Envelope;
  } catch {
    throw new DecryptionError("Datei ist kein Tagwerk-Umschlag (kein JSON).");
  }
  if (env?.tw !== 1 || env.kdf !== "pbkdf2-sha256") throw new DecryptionError("Unbekanntes Umschlagformat.");
  if (env.k !== expectedKind) throw new DecryptionError(`Falscher Dateityp: erwartet ${expectedKind}, gefunden ${env.k}.`);
  if (!Number.isInteger(env.iter) || env.iter < 100_000 || env.iter > 5_000_000) throw new DecryptionError("Ungültige Iterationszahl.");
  const key = await deriveKey(passphrase, fromB64(env.salt), env.iter);
  let pt: ArrayBuffer;
  try {
    pt = await subtle().decrypt(
      { name: "AES-GCM", iv: fromB64(env.iv) as BufferSource, additionalData: te.encode(`tagwerk:${env.k}`) as BufferSource, tagLength: 128 },
      key,
      fromB64(env.ct) as BufferSource,
    );
  } catch {
    throw new DecryptionError("Entschlüsselung fehlgeschlagen. Stimmt die Passphrase in App und Plugin überein?");
  }
  return td.decode(pt);
}
