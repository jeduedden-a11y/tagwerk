/**
 * Planner data in the vault: weekly appointments in Full Calendar's "recurring" format and the
 * note with the lessons the user marked himself (cancelled, absent, present despite a lecture).
 */
import type { Frontmatter } from "./vault";
import type { OverrideState, Recurrence, SchoolOverride } from "./protocol";
import { isDate, isTime } from "./protocol";

/** Full Calendar's day letters, indexed by ISO weekday - 1. */
export const FC_DAYS = ["M", "T", "W", "R", "F", "S", "U"] as const;

export function fcDays(days: number[]): string {
  return `[${[...new Set(days)].sort((a, b) => a - b).map((d) => FC_DAYS[d - 1]).join(", ")}]`;
}

const LONG_DAYS: Record<string, number> = {
  monday: 1, tuesday: 2, wednesday: 3, thursday: 4, friday: 5, saturday: 6, sunday: 7,
  montag: 1, dienstag: 2, mittwoch: 3, donnerstag: 4, freitag: 5, samstag: 6, sonntag: 7,
};

/** Reads daysOfWeek as Full Calendar writes it (letters) or spelled out. */
export function parseDays(v: unknown): number[] {
  const items = Array.isArray(v) ? v : typeof v === "string" ? v.split(/[,\s]+/) : [];
  const out = new Set<number>();
  for (const raw of items) {
    const s = String(raw).trim();
    const i = (FC_DAYS as readonly string[]).indexOf(s.toUpperCase());
    if (s.length === 1 && i >= 0) out.add(i + 1);
    else if (LONG_DAYS[s.toLowerCase()]) out.add(LONG_DAYS[s.toLowerCase()]);
  }
  return [...out].sort((a, b) => a - b);
}

const day = (v: unknown): string | null => {
  if (v instanceof Date && !isNaN(v.getTime())) return v.toISOString().slice(0, 10);
  const s = typeof v === "string" ? v.trim().slice(0, 10) : null;
  return s && isDate(s) ? s : null;
};

/** Recurrence of a note in Full Calendar's format, null for single events. */
export function recurrenceOf(fm: Frontmatter): { start: string; recur: Recurrence } | null {
  if (String(fm.type ?? "") !== "recurring") return null;
  const days = parseDays(fm.daysOfWeek);
  const start = day(fm.startRecur) ?? day(fm.date);
  if (!days.length || !start) return null;
  const until = day(fm.endRecur) ?? addDays(start, 365);
  return { start, recur: { days, until } };
}

export function addDays(date: string, n: number): string {
  const d = new Date(`${date}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

// MARK: - Note with the user's own marks

export const SCHOOL_DATA_START = "%% tagwerk:schule-data";
const STATE_LABEL: Record<OverrideState, string> = { entfall: "Entfall", abwesend: "nicht da", anwesend: "da, trotz Termin" };
const WEEKDAY = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"];

export function parseSchoolNote(content: string): SchoolOverride[] {
  const i = content.indexOf(SCHOOL_DATA_START);
  if (i < 0) return [];
  const rest = content.slice(i + SCHOOL_DATA_START.length);
  const end = rest.indexOf("%%");
  if (end < 0) return [];
  try {
    const data = JSON.parse(rest.slice(0, end).trim()) as unknown;
    if (!Array.isArray(data)) return [];
    return data.filter(
      (e): e is SchoolOverride =>
        !!e && typeof e === "object" && typeof (e as SchoolOverride).key === "string" && isDate((e as SchoolOverride).date) &&
        isTime((e as SchoolOverride).start) && ["entfall", "abwesend", "anwesend"].includes((e as SchoolOverride).state),
    );
  } catch {
    return [];
  }
}

const cell = (s: string | null | undefined) => (s ?? "").replace(/\|/g, "/").replace(/\s+/g, " ").trim();

export function renderSchoolNote(entries: SchoolOverride[]): string {
  const sorted = [...entries].sort((a, b) => (a.date + a.start).localeCompare(b.date + b.start));
  const rows = sorted.map((e) => {
    const d = new Date(`${e.date}T12:00:00Z`);
    const label = `${WEEKDAY[d.getUTCDay()]} ${e.date.slice(8, 10)}.${e.date.slice(5, 7)}.${e.date.slice(0, 4)}`;
    const time = e.end ? `${e.start}–${e.end}` : e.start;
    return `| ${label} | ${time} | ${cell(e.subject ?? e.title)} | ${STATE_LABEL[e.state]} | ${cell(e.reason)} |`;
  });
  const table = rows.length
    ? ["| Datum | Zeit | Fach | Status | Grund |", "| --- | --- | --- | --- | --- |", ...rows].join("\n")
    : "_Noch nichts eingetragen._";
  return [
    "---",
    "tags:",
    "  - /schule",
    "---",
    "",
    "# Stundenplan-Änderungen",
    "",
    "> [!info] Von Tagwerk gepflegt",
    "> Stunden, die du in der App selbst als Entfall oder Fehlzeit markiert hast. Der Stundenplan selbst kommt aus WebUntis.",
    "> Änderungen an dieser Notiz überschreibt der nächste Abgleich; ändere die Markierungen in der App.",
    "",
    table,
    "",
    SCHOOL_DATA_START,
    JSON.stringify(sorted),
    "%%",
    "",
  ].join("\n");
}

/** Applies one mark; "clear" removes it. Entries older than a year are dropped. */
export function upsertOverride(entries: SchoolOverride[], next: Omit<SchoolOverride, "state"> & { state: OverrideState | "clear" }, today: string): SchoolOverride[] {
  const cutoff = addDays(today, -400);
  const rest = entries.filter((e) => e.key !== next.key && e.date >= cutoff);
  if (next.state === "clear") return rest;
  return [...rest, { ...next, state: next.state }];
}
