/**
 * Notes from the learning app Lernwerk (learn.note, plugin 1.3, feature "lernen").
 *
 * Every note written in the app owns one managed block in a wiki note, collected under a heading:
 *
 *   ## Eigene Notizen
 *
 *   %% lernwerk:5f0c… 3f2a9c0d1e4b5a6c %%
 *   Text from the app
 *
 *   *Lernwerk, Lektion »Supremum und Infimum«, Stand 08.11.2026*
 *   %% /lernwerk:5f0c… %%
 *
 * The hash in the start marker belongs to the block content as the plugin wrote it. If the block was edited
 * in Obsidian since, the edited version stays visible as a quote below the new block: a duplicate is visible,
 * a silent overwrite is not. Everything outside the block belongs to the vault and is left as it is.
 * Pure text helpers, no Obsidian imports.
 */
import { sha256Hex } from "./crypto";

export interface LearnBlock {
  /** Block content between the markers, without the surrounding line breaks. */
  inner: string;
  /** Hash from the start marker, null for blocks without one. */
  hash: string | null;
  start: number;
  end: number;
}

/** "lernwerk-<id>" -> "<id>" */
export const learnKey = (block: string) => block.replace(/^lernwerk-/, "");

export const learnStart = (key: string, hash: string) => `%% lernwerk:${key} ${hash} %%`;
export const learnEnd = (key: string) => `%% /lernwerk:${key} %%`;

const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** Line endings and surrounding whitespace do not count as a change. */
export const normalizeLearn = (s: string) => s.replace(/\r\n?/g, "\n").trim();
const normalize = normalizeLearn;

/** Hash of block content, insensitive to line endings and surrounding whitespace. */
export async function learnHash(inner: string): Promise<string> {
  return (await sha256Hex(normalize(inner))).slice(0, 16);
}

export function findLearnBlock(body: string, key: string): LearnBlock | null {
  const m = new RegExp(`%% lernwerk:${escapeRe(key)}(?: ([0-9a-f]{16}))? %%`).exec(body);
  if (!m) return null;
  const endMarker = learnEnd(key);
  const e = body.indexOf(endMarker, m.index + m[0].length);
  if (e < 0) return null;
  const inner = body.slice(m.index + m[0].length, e).replace(/^\r?\n/, "").replace(/\r?\n$/, "");
  return { inner, hash: m[1] ?? null, start: m.index, end: e + endMarker.length };
}

/** Block content: the text from the app and a line saying where it comes from. */
export function renderLearnInner(text: string, source: string | null, stand: string): string {
  const origin = source?.trim() ? `${source.trim()}, Stand ${stand}` : `Lernwerk, Stand ${stand}`;
  return `${normalize(text)}\n\n*${origin}*`;
}

export function renderLearnBlock(key: string, hash: string, inner: string): string {
  return `${learnStart(key, hash)}\n${normalize(inner)}\n${learnEnd(key)}`;
}

interface HeadingHit {
  /** Index of the first character after the heading line (and its line break). */
  after: number;
  /** Start of the line that ends the section: next heading of the same or a higher level, or the end. */
  sectionEnd: number;
  lineStart: number;
}

function findHeading(body: string, heading: string): HeadingHit | null {
  const m = new RegExp(`^(#{1,6})[ \\t]+${escapeRe(heading)}[ \\t]*#*[ \\t]*\\r?$`, "m").exec(body);
  if (!m) return null;
  let after = m.index + m[0].length;
  if (body[after] === "\n") after++;
  // The section ends at the next heading of the same or a higher level; headings in code blocks do not count.
  const ends = new RegExp(`^#{1,${m[1].length}}[ \\t]`);
  let sectionEnd = body.length;
  let fence = false;
  for (const line of body.slice(after).matchAll(/^.*$/gm)) {
    if (/^\s*(```|~~~)/.test(line[0])) fence = !fence;
    else if (!fence && ends.test(line[0])) {
      sectionEnd = after + (line.index ?? 0);
      break;
    }
  }
  return { after, sectionEnd, lineStart: m.index };
}

export interface LearnUpsert {
  key: string;
  heading: string;
  /** New block content; null removes the block. */
  inner: string | null;
  hash: string;
  /** Edited-in-Obsidian version to keep visible below the block. */
  conflict: { label: string; text: string } | null;
}

const quote = (label: string, text: string) => `> [!quote] ${label}\n${normalize(text).split("\n").map((l) => (l ? `> ${l}` : ">")).join("\n")}`;

/** Removes the heading if nothing but whitespace is left in its section. */
function dropEmptyHeading(body: string, heading: string): string {
  const h = findHeading(body, heading);
  if (!h || body.slice(h.after, h.sectionEnd).trim()) return body;
  const head = body.slice(0, h.lineStart).replace(/\s+$/, "");
  const tail = body.slice(h.sectionEnd).replace(/^\s+/, "");
  return joinParts([head, tail]);
}

/** Parts separated by one blank line, the note ending with exactly one line break. */
function joinParts(parts: (string | null)[]): string {
  const joined = parts.filter(Boolean).join("\n\n").replace(/\s+$/, "");
  return joined ? `${joined}\n` : "";
}

/** Body of a note with the block for `key` written, replaced or removed. */
export function upsertLearnBlock(body: string, u: LearnUpsert): string {
  const existing = findLearnBlock(body, u.key);
  const kept = u.conflict ? quote(u.conflict.label, u.conflict.text) : null;

  if (existing) {
    if (u.inner === null) {
      const head = body.slice(0, existing.start).replace(/\s+$/, "");
      const tail = body.slice(existing.end).replace(/^\s+/, "");
      const out = joinParts([head, kept, tail]);
      return kept ? out : dropEmptyHeading(out, u.heading);
    }
    const block = renderLearnBlock(u.key, u.hash, u.inner) + (kept ? `\n\n${kept}` : "");
    return body.slice(0, existing.start) + block + body.slice(existing.end);
  }

  if (u.inner === null) return body;
  const block = renderLearnBlock(u.key, u.hash, u.inner);
  const h = findHeading(body, u.heading);
  if (!h) {
    const trimmed = body.replace(/\s+$/, "");
    return `${trimmed ? `${trimmed}\n\n` : ""}## ${u.heading}\n\n${block}\n`;
  }
  // Append at the end of the section, after whatever is already there.
  const before = body.slice(0, h.after).replace(/\n?$/, "\n");
  const section = body.slice(h.after, h.sectionEnd).replace(/\s+$/, "");
  const rest = body.slice(h.sectionEnd);
  const middle = section ? `${section.replace(/^\n+/, "\n")}\n\n` : "\n";
  return `${before}${middle}${block}\n${rest ? `\n${rest}` : ""}`;
}
