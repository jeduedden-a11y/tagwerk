/** Pure text helpers. No Obsidian imports, so everything here is unit-testable. */

export const JOURNAL_START = "%% tagwerk:journal %%";
export const JOURNAL_END = "%% /tagwerk:journal %%";

export interface SplitNote {
  /** Raw YAML between the fences, without the fences; null if the note has no frontmatter. */
  yaml: string | null;
  body: string;
}

const FM_RE = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/;

export function splitFrontmatter(content: string): SplitNote {
  const m = FM_RE.exec(content);
  if (!m) {
    // Obsidian also accepts an empty frontmatter block "---\n---"
    const empty = /^---\r?\n---[ \t]*(?:\r?\n|$)/.exec(content);
    if (empty) return { yaml: "", body: content.slice(empty[0].length) };
    return { yaml: null, body: content };
  }
  return { yaml: m[1], body: content.slice(m[0].length) };
}

export function joinFrontmatter(yaml: string | null, body: string): string {
  if (yaml === null) return body;
  return `---\n${yaml.replace(/\s+$/, "")}\n---\n${body}`;
}

export interface JournalBlock {
  /** Block content (between markers), not normalised. */
  text: string;
  start: number;
  end: number;
}

export function findJournalBlock(body: string): JournalBlock | null {
  const s = body.indexOf(JOURNAL_START);
  if (s < 0) return null;
  const e = body.indexOf(JOURNAL_END, s + JOURNAL_START.length);
  if (e < 0) return null;
  const inner = body.slice(s + JOURNAL_START.length, e).replace(/^\r?\n/, "").replace(/\r?\n$/, "");
  return { text: inner, start: s, end: e + JOURNAL_END.length };
}

/** Body text outside the managed block, trimmed; null if empty. */
export function bodyOutsideJournal(body: string): string | null {
  const b = findJournalBlock(body);
  const rest = b ? body.slice(0, b.start) + body.slice(b.end) : body;
  const t = rest.replace(/\r\n?/g, "\n").trim();
  return t ? t : null;
}

function renderBlock(text: string): string {
  const t = text.replace(/\r\n?/g, "\n").trim();
  return `${JOURNAL_START}\n${t}\n${JOURNAL_END}`;
}

/**
 * Writes text into the managed block. If the block was edited elsewhere (conflict),
 * the previous content is kept visibly as a callout below the block: a duplicate is
 * visible, a silent overwrite is not.
 */
export function upsertJournal(body: string, text: string, conflictLabel: string | null): string {
  const block = findJournalBlock(body);
  const rendered = renderBlock(text);
  if (!block) {
    const trimmed = body.replace(/\s+$/, "");
    return (trimmed ? `${trimmed}\n\n` : "") + rendered + "\n";
  }
  let replacement = rendered;
  if (conflictLabel !== null && block.text.trim()) {
    const quoted = block.text.trim().split("\n").map((l) => `> ${l}`).join("\n");
    replacement += `\n\n> [!quote] ${conflictLabel}\n${quoted}`;
  }
  return body.slice(0, block.start) + replacement + body.slice(block.end);
}

/** Windows- and Obsidian-safe file name stem. */
export function sanitizeFileName(title: string, fallback = "Aufgabe"): string {
  let s = title
    .normalize("NFC")
    .replace(/[\\/:*?"<>|#^[\]]/g, " ")
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u001f]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^\.+/, "")
    .replace(/[. ]+$/, "");
  if (s.length > 100) s = s.slice(0, 100).trim();
  if (/^(con|prn|aux|nul|com\d|lpt\d)$/i.test(s)) s = `${s}_`;
  return s || fallback;
}

/** First "# heading" line equal to oldTitle gets replaced by newTitle. */
export function retitleHeading(body: string, oldTitle: string, newTitle: string): string {
  const lines = body.split("\n");
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim() === `# ${oldTitle}`) {
      lines[i] = `# ${newTitle}`;
      break;
    }
  }
  return lines.join("\n");
}

/** Body of a task note without its leading "# title" heading, trimmed. */
export function taskNotes(body: string, title: string): string | null {
  const lines = body.replace(/\r\n?/g, "\n").split("\n");
  let i = 0;
  while (i < lines.length && !lines[i].trim()) i++;
  if (i < lines.length && lines[i].trim() === `# ${title}`) i++;
  const t = lines.slice(i).join("\n").trim();
  return t ? t : null;
}

/** Escape a value for a double-quoted YAML scalar. */
export function yamlQuote(s: string): string {
  return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n")}"`;
}
