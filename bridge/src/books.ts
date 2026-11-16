/**
 * Book cards for the library of Lernwerk (book.add, plugin 1.4, feature "buecher").
 *
 * The card carries the properties the book-search plugin writes, so the books folder stays uniform and
 * Bibliothek.base shows a scanned book like any other. File names follow the same rules:
 *   Bücher/<Title> - <Author>.md   single hyphen, no dots in the title
 *   Cover/<Title> — <Author>.jpg   em dash, punctuation of the title kept
 * Pure text helpers, no Obsidian imports.
 */
import type { BookAddEvent } from "./protocol";

export const DEFAULT_BOOKS_FOLDER = "Bücher";
export const DEFAULT_COVERS_FOLDER = "Cover";

// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u001f]/g;
const FS_ILLEGAL = /[\\/:*?"<>|#^[\]]/g;

const tidy = (s: string) => s.normalize("NFC").replace(CONTROL, " ").replace(/\s+/g, " ").trim();

/** One word group of a file name: nothing Windows or Obsidian cannot store, no trailing dots. */
function fileWord(s: string, keepDots: boolean): string {
  let t = tidy(s).replace(FS_ILLEGAL, "");
  if (!keepDots) t = t.replace(/\./g, "");
  return t.replace(/\s+/g, " ").replace(/[. ]+$/, "").trim();
}

type Named = Pick<BookAddEvent, "title" | "author">;

/** "Bücher/<Title> - <Author>.md" */
export function bookNotePath(folder: string, ev: Named): string {
  const title = fileWord(ev.title, false) || "Buch";
  const author = fileWord(ev.author, false) || "Unbekannt";
  return `${folder.replace(/\/+$/, "")}/${`${title} - ${author}`.slice(0, 180).trim()}.md`;
}

/** "<Title> — <Author>.jpg" */
export function bookCoverName(ev: Named): string {
  const title = fileWord(ev.title, true) || "Buch";
  const author = fileWord(ev.author, true) || "Unbekannt";
  return `${`${title} — ${author}`.slice(0, 180).trim()}.jpg`;
}

const slug = (s: string) =>
  tidy(s)
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, "_")
    .replace(/^_+|_+$/g, "");

/** Plain YAML scalar when unambiguous, double-quoted otherwise (same rule as the other notes of the plugin). */
function scalar(s: string): string {
  const plainOk =
    /^[A-Za-zÄÖÜäöüß0-9(][^\n]*$/.test(s) &&
    !/[:#]\s|:$|\s#|[{}[\],&*!|>'"%@`]/.test(s) &&
    !/^(true|false|yes|no|on|off|null|~)$/i.test(s) &&
    !/^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$/.test(s) &&
    s.trim() === s;
  return plainOk ? s : quoted(s);
}

const quoted = (s: string) => `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\r?\n/g, "\\n")}"`;

/** The card of a book: properties only, like the cards of the book-search plugin. */
export function renderBookCard(ev: BookAddEvent, coverFile: string | null): string {
  const title = tidy(ev.title);
  const author = tidy(ev.author);
  const tags = [...new Set([slug(author), slug(title)].filter(Boolean))];
  const categories = (ev.categories ?? []).map(tidy).filter(Boolean).join(", ");
  const description = tidy(ev.description ?? "");
  return [
    "---",
    `Title: ${scalar(title)}`,
    `Original title: ${scalar(tidy(ev.originalTitle || ev.title))}`,
    `Author: ${scalar(author)}`,
    `Translator: ${ev.translator?.trim() ? scalar(tidy(ev.translator)) : '""'}`,
    'Prologue: ""',
    `Description: ${quoted(description)}`,
    `Total Pages: ${quoted(ev.pages ? String(ev.pages) : "")}`,
    `Publisher: ${ev.publisher?.trim() ? scalar(tidy(ev.publisher)) : '""'}`,
    `Categories: ${categories ? scalar(categories) : '""'}`,
    `isbn 10: ${quoted(ev.isbn10 ?? "")}`,
    `isbn 13: ${quoted(ev.isbn13)}`,
    `Asin: ${quoted(ev.isbn10 ?? "")}`,
    `Published: ${ev.published?.trim() ? scalar(tidy(ev.published)) : '""'}`,
    'Date read: ""',
    `Cover: ${coverFile ? quoted(`[[${coverFile}]]`) : '""'}`,
    `Link: ${ev.link?.trim() ? scalar(tidy(ev.link)) : '""'}`,
    "Tags:",
    ...tags.map((t) => `  - ${t}`),
    "Read: false",
    "---",
    "",
  ].join("\n");
}

/** Does this card (its first lines are enough) belong to the book with these ISBNs? */
export function cardHasIsbn(head: string, isbn13: string, isbn10: string | null): boolean {
  const v13 = /^isbn[ _-]?13:\s*["']?(\d{13})/im.exec(head)?.[1];
  if (v13 && v13 === isbn13) return true;
  const v10 = /^isbn[ _-]?10:\s*["']?(\d{9}[\dX])/im.exec(head)?.[1];
  return !!(isbn10 && v10 && v10 === isbn10);
}

export function base64Bytes(b64: string): Uint8Array {
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}
