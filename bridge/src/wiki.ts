/**
 * Read-only copy of the wiki folder for the app.
 *
 * The notes are packed into 32 buckets by a hash of their path, so a changed note re-uploads one
 * bucket of about 100 KB instead of the whole wiki. Notes with Dataview queries go into four
 * buckets of their own: their content depends on other notes, so they are re-rendered whenever the
 * wiki changes, and uploaded only if the rendered result differs. Every file is deflated and
 * sealed like the snapshot (kind "wiki"); the index lists all files with their bucket and the hash
 * of every bucket, so the app downloads only buckets whose hash changed.
 */
import { fromB64, seal, sha256Hex, toB64, type SealOptions } from "./crypto";
import type { GitHubRepo } from "./github";
import type { VaultFileStat, VaultPort } from "./vault";

export const WIKI_DIR = "wiki";
export const WIKI_INDEX = `${WIKI_DIR}/index.tw`;
const BUCKETS = 32;
const DV_BUCKETS = 4;
const TEXT_EXT = new Set(["md", "svg", "html", "txt"]);
const BIN_EXT = new Set(["png", "jpg", "jpeg", "gif", "webp"]);
const MAX_TEXT = 2_000_000;
const MAX_BIN = 2_500_000;

export interface WikiBucketState {
  sig: string;
  hash: string;
  sha: string | null;
  n: number;
  bytes: number;
}

export interface WikiState {
  buckets: Record<string, WikiBucketState>;
  globalSig: string | null;
  manifestHash: string | null;
  manifestSha: string | null;
  lastRun: string | null;
  lastDataview: string | null;
  files: number;
}

export const emptyWikiState = (): WikiState => ({
  buckets: {},
  globalSig: null,
  manifestHash: null,
  manifestSha: null,
  lastRun: null,
  lastDataview: null,
  files: 0,
});

export interface WikiOptions {
  folder: string;
  passphrase: string;
  seal: SealOptions;
  now: Date;
  force: boolean;
  /** Minimum time between two exports unless forced. */
  minIntervalMs?: number;
}

export interface WikiResult {
  skipped: boolean;
  uploaded: number;
  deleted: number;
  files: number;
  message: string;
}

export interface WikiManifest {
  v: 1;
  generatedAt: string;
  root: string;
  buckets: { id: string; hash: string; n: number; bytes: number }[];
  files: { p: string; b: string; s: number; m: number }[];
}

export interface WikiBucketFile {
  p: string;
  m: number;
  t: "text" | "b64";
  d: string;
}

const extOf = (p: string) => p.slice(p.lastIndexOf(".") + 1).toLowerCase();

/** FNV-1a, stable across runs and platforms. */
function fnv(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

export function bucketFor(rel: string, dataview: boolean): string {
  const h = fnv(rel);
  return dataview ? `d${h % DV_BUCKETS}` : `b${String(h % BUCKETS).padStart(2, "0")}`;
}

async function pipe(data: Uint8Array, stream: CompressionStream | DecompressionStream): Promise<Uint8Array> {
  const out = new Blob([data as BlobPart]).stream().pipeThrough(stream);
  return new Uint8Array(await new Response(out).arrayBuffer());
}
export const deflateRaw = (d: Uint8Array) => pipe(d, new CompressionStream("deflate-raw"));
export const inflateRaw = (d: Uint8Array) => pipe(d, new DecompressionStream("deflate-raw"));

export const hasDataview = (md: string) => /^```dataview[ \t]*\r?$/m.test(md);
const DV_BLOCK = /^```dataview[ \t]*\r?\n([\s\S]*?)\r?\n```[ \t]*$/gm;

/** Replaces every ```dataview block by its result as Markdown; blocks that fail stay as they are. */
export async function renderDataviewBlocks(md: string, path: string, render?: (q: string, p: string) => Promise<string | null>): Promise<string> {
  if (!render || !hasDataview(md)) return md;
  let out = "";
  let last = 0;
  for (const m of md.matchAll(DV_BLOCK)) {
    out += md.slice(last, m.index);
    let result: string | null = null;
    try {
      result = await render(m[1], path);
    } catch {
      result = null;
    }
    out += result != null && result.trim() ? `<!-- tagwerk:dataview -->\n${result.trim()}\n` : m[0];
    last = (m.index ?? 0) + m[0].length;
  }
  return out + md.slice(last);
}

const te = new TextEncoder();

/** JSON -> deflate -> base64 -> sealed envelope. The hash is over the JSON. */
export async function packWiki(obj: unknown, passphrase: string, opts: SealOptions): Promise<{ bytes: Uint8Array; hash: string }> {
  const json = JSON.stringify(obj);
  const hash = await sha256Hex(json);
  const packed = toB64(await deflateRaw(te.encode(json)));
  return { bytes: te.encode(await seal(packed, passphrase, "wiki", opts)), hash };
}

/** Inverse of packWiki after open(): base64 -> inflate -> JSON. */
export async function unpackWiki<T>(opened: string): Promise<T> {
  return JSON.parse(new TextDecoder().decode(await inflateRaw(fromB64(opened)))) as T;
}

function included(f: VaultFileStat, folder: string): boolean {
  const rel = f.path.slice(folder.length + 1);
  if (rel.split("/").some((seg) => seg.startsWith(".") || seg === "_to_delete")) return false;
  const e = extOf(f.path);
  return (TEXT_EXT.has(e) && f.size <= MAX_TEXT) || (BIN_EXT.has(e) && f.size <= MAX_BIN);
}

async function shaOf(gh: GitHubRepo, path: string): Promise<string | undefined> {
  return (await gh.list(WIKI_DIR)).find((e) => e.path === path)?.sha;
}

async function putFile(gh: GitHubRepo, path: string, bytes: Uint8Array, sha: string | null, message: string): Promise<string> {
  try {
    return await gh.put(path, bytes, message, sha ?? undefined);
  } catch {
    // Unknown or stale sha: look up the current one and try once more.
    return gh.put(path, bytes, message, await shaOf(gh, path));
  }
}

export async function exportWiki(
  vault: VaultPort,
  gh: GitHubRepo,
  state: WikiState,
  o: WikiOptions,
  render?: (q: string, p: string) => Promise<string | null>,
): Promise<WikiResult> {
  const folder = o.folder.replace(/\/+$/, "");
  const now = o.now.getTime();
  const all = (await vault.listFiles(folder)).filter((f) => included(f, folder)).sort((a, b) => a.path.localeCompare(b.path));
  const globalSig = await sha256Hex(all.map((f) => `${f.path}|${f.mtime}|${f.size}`).join("\n"));
  const dvDue = !state.lastDataview || now - Date.parse(state.lastDataview) > 24 * 3600_000;
  const unchanged = globalSig === state.globalSig;
  const skip = (message: string): WikiResult => ({ skipped: true, uploaded: 0, deleted: 0, files: all.length, message });
  if (!o.force && unchanged && !dvDue) return skip("Wiki unverändert.");
  if (!o.force && state.lastRun && o.minIntervalMs && now - Date.parse(state.lastRun) < o.minIntervalMs) return skip("Wiki: nächster Abgleich später.");

  const rel = (p: string) => p.slice(folder.length + 1);
  const members = new Map<string, VaultFileStat[]>();
  const bucketOf = new Map<string, string>();
  const texts = new Map<string, string>();
  for (const f of all) {
    let dv = false;
    if (extOf(f.path) === "md") {
      const t = await vault.read(f.path);
      texts.set(f.path, t);
      dv = hasDataview(t);
    }
    const id = bucketFor(rel(f.path), dv);
    bucketOf.set(f.path, id);
    if (!members.has(id)) members.set(id, []);
    members.get(id)!.push(f);
  }

  let uploaded = 0;
  let deleted = 0;
  for (const [id, list] of [...members.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
    const sig = await sha256Hex(list.map((f) => `${f.path}|${f.mtime}|${f.size}`).join("\n"));
    const prev = state.buckets[id];
    const isDv = id.startsWith("d");
    if (!o.force && prev && prev.sig === sig && (!isDv || (unchanged && !dvDue))) continue;
    const files: WikiBucketFile[] = [];
    let bytes = 0;
    for (const f of list) {
      const e = extOf(f.path);
      bytes += f.size;
      if (BIN_EXT.has(e)) files.push({ p: rel(f.path), m: f.mtime, t: "b64", d: toB64(await vault.readBinary(f.path)) });
      else {
        const text = texts.get(f.path) ?? (await vault.read(f.path));
        files.push({ p: rel(f.path), m: f.mtime, t: "text", d: isDv && e === "md" ? await renderDataviewBlocks(text, f.path, render) : text });
      }
    }
    const packed = await packWiki({ v: 1, files }, o.passphrase, o.seal);
    if (prev && prev.hash === packed.hash && prev.sha) {
      state.buckets[id] = { ...prev, sig, n: files.length, bytes };
      continue;
    }
    const sha = await putFile(gh, `${WIKI_DIR}/${id}.tw`, packed.bytes, prev?.sha ?? null, `tagwerk: Wiki ${id}`);
    state.buckets[id] = { sig, hash: packed.hash, sha, n: files.length, bytes };
    uploaded++;
  }

  for (const id of Object.keys(state.buckets)) {
    if (members.has(id)) continue;
    const path = `${WIKI_DIR}/${id}.tw`;
    const sha = state.buckets[id].sha ?? (await shaOf(gh, path));
    if (sha) await gh.delete(path, sha, `tagwerk: Wiki ${id} leer`);
    delete state.buckets[id];
    deleted++;
  }

  const manifest: WikiManifest = {
    v: 1,
    generatedAt: o.now.toISOString(),
    root: folder,
    buckets: Object.entries(state.buckets)
      .map(([id, b]) => ({ id, hash: b.hash, n: b.n, bytes: b.bytes }))
      .sort((a, b) => a.id.localeCompare(b.id)),
    files: all.map((f) => ({ p: rel(f.path), b: bucketOf.get(f.path)!, s: f.size, m: f.mtime })),
  };
  const { generatedAt: _g, ...stable } = manifest;
  const manifestHash = await sha256Hex(JSON.stringify(stable));
  if (o.force || manifestHash !== state.manifestHash || !state.manifestSha) {
    const packed = await packWiki(manifest, o.passphrase, o.seal);
    state.manifestSha = await putFile(gh, WIKI_INDEX, packed.bytes, state.manifestSha, "tagwerk: Wiki-Index");
    state.manifestHash = manifestHash;
    uploaded++;
  }

  state.globalSig = globalSig;
  state.lastRun = o.now.toISOString();
  if (dvDue || !unchanged) state.lastDataview = o.now.toISOString();
  state.files = all.length;
  const message = uploaded || deleted ? `Wiki: ${all.length} Dateien, ${uploaded} Teile übertragen.` : `Wiki: ${all.length} Dateien, aktuell.`;
  return { skipped: false, uploaded, deleted, files: all.length, message };
}
