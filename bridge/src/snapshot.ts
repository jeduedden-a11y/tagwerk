import { journalHash, normalizeJournal } from "./crypto";
import { findFoodBlock, profileFromFrontmatter, runDateFromStem, runDistance, runOrdinal, runSeconds } from "./fitness";
import { bodyOutsideJournal, findJournalBlock, splitFrontmatter, taskNotes } from "./markdown";
import { parseSchoolNote, recurrenceOf } from "./planner";
import type { BodyProfile, SchoolOverride, Snapshot, SnapshotAppointment, SnapshotDay, SnapshotFoodDay, SnapshotRun, SnapshotTask, BridgeError, RatingSource } from "./protocol";
import { FEATURES, isDate, isTime, SCHEMA } from "./protocol";
import type { ApplyContext } from "./apply";
import { localDate } from "./apply";
import type { Frontmatter } from "./vault";

export interface SnapshotOptions {
  snapshotDays: number;
  textDays: number;
  pluginVersion: string;
  applied: string[];
  errors: BridgeError[];
  lastIngestAt: string | null;
}

const basename = (p: string) => p.slice(p.lastIndexOf("/") + 1).replace(/\.md$/i, "");

function str(v: unknown): string | null {
  if (v === null || v === undefined) return null;
  if (typeof v === "string") return v.trim() || null;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  if (v instanceof Date && !isNaN(v.getTime())) return v.toISOString().slice(0, 10);
  return null;
}

/** "77.2" for 77.2, "77.2", " 77,20 "; null for empty or out-of-range values. */
function decimal(v: unknown, digits: number, min: number, max: number): string | null {
  const s = str(v);
  if (s === null) return null;
  const n = Number(s.replace(",", "."));
  if (!Number.isFinite(n) || n < min || n > max) return null;
  return n.toFixed(digits);
}

const ratingStr = (v: unknown) => {
  const s = str(v);
  if (s === null) return null;
  const n = Number(s.replace(",", "."));
  if (!Number.isFinite(n) || n < 0 || n > 10) return null;
  return n.toFixed(1);
};

const dateStr = (v: unknown) => {
  const s = str(v);
  return s && isDate(s.slice(0, 10)) ? s.slice(0, 10) : null;
};

const bool = (v: unknown) => v === true || v === "true";

async function parse(ctx: ApplyContext, path: string): Promise<{ fm: Frontmatter; body: string }> {
  const s = splitFrontmatter(await ctx.vault.read(path));
  let fm: Frontmatter = {};
  if (s.yaml) {
    try {
      const p = ctx.vault.parseYaml(s.yaml);
      if (p && typeof p === "object") fm = p as Frontmatter;
    } catch {
      /* ignore broken YAML */
    }
  }
  return { fm, body: s.body };
}

export async function buildSnapshot(ctx: ApplyContext, opts: SnapshotOptions): Promise<Snapshot> {
  const now = ctx.now();
  const today = localDate(now);
  const textCutoff = localDate(new Date(now.getFullYear(), now.getMonth(), now.getDate() - opts.textDays));

  // Daily notes, newest first
  const dailyPaths = (await ctx.vault.list(ctx.folders.dailyFolder))
    .filter((p) => isDate(basename(p)) && basename(p) <= today)
    .sort((a, b) => basename(b).localeCompare(basename(a)))
    .slice(0, opts.snapshotDays);

  const days: SnapshotDay[] = [];
  for (const path of dailyPaths) {
    const date = basename(path);
    const { fm, body } = await parse(ctx, path);
    const habits: Record<string, boolean> = {};
    for (const h of ctx.folders.habits) habits[h.key] = bool(fm[h.key]);
    const withText = date >= textCutoff;
    const block = withText ? findJournalBlock(body) : null;
    const journal = block ? normalizeJournal(block.text) || null : null;
    const src = str(fm.rating_source);
    days.push({
      date,
      habits,
      rating: ratingStr(fm.rating),
      ratingAI: ratingStr(fm.rating_ai),
      ratingSource: src === "ai" || src === "manual" ? (src as RatingSource) : null,
      ratingReason: str(fm.rating_reason),
      weight: decimal(fm.weight, 1, 20, 400),
      journal,
      journalHash: await journalHash(journal),
      note: withText ? bodyOutsideJournal(body) : null,
      hasText: withText,
    });
  }

  // Tasks (flat folder)
  const tasks: SnapshotTask[] = [];
  for (const path of await ctx.vault.list(ctx.folders.tasksFolder)) {
    const { fm, body } = await parse(ctx, path);
    const title = str(fm.title) ?? basename(path);
    const notes = taskNotes(body, title);
    tasks.push({
      path,
      taskId: str(fm.tagwerk_id),
      title,
      created: dateStr(fm.created),
      date: dateStr(fm.date),
      completed: bool(fm.completed),
      wichtig: bool(fm.wichtig),
      notes: notes ? notes.slice(0, 2000) : null,
    });
  }
  tasks.sort((a, b) => Number(a.completed) - Number(b.completed) || (a.date ?? "9999").localeCompare(b.date ?? "9999"));

  // Appointments from the last week on
  const apptCutoff = localDate(new Date(now.getFullYear(), now.getMonth(), now.getDate() - 7));
  const appointments: SnapshotAppointment[] = [];
  for (const path of await ctx.vault.list(ctx.folders.appointmentsFolder)) {
    const { fm, body } = await parse(ctx, path);
    const rec = recurrenceOf(fm);
    const date = rec?.start ?? dateStr(fm.date);
    if (!date) continue;
    if (rec ? rec.recur.until < apptCutoff : date < apptCutoff) continue;
    const st = str(fm.startTime);
    const et = str(fm.endTime);
    appointments.push({
      path,
      apptId: str(fm.tagwerk_id),
      title: str(fm.title) ?? basename(path),
      date,
      startTime: st && isTime(st) ? st : null,
      endTime: et && isTime(et) ? et : null,
      allDay: fm.allDay === undefined ? !st : bool(fm.allDay),
      location: str(fm.ort) ?? str(fm.location),
      category: str(fm.kategorie)?.toLowerCase() ?? null,
      subject: str(fm.fach),
      recur: rec?.recur ?? null,
      notes: appointmentNotes(body),
    });
  }
  appointments.sort((a, b) => (a.date + (a.startTime ?? "")).localeCompare(b.date + (b.startTime ?? "")));

  // Runs: every note in the runs folder, the same set "Lauf Chart.canvas" draws
  const runs: SnapshotRun[] = [];
  for (const path of await ctx.vault.list(ctx.folders.runsFolder)) {
    const date = runDateFromStem(basename(path));
    if (!date || !isDate(date)) continue;
    const { fm } = await parse(ctx, path);
    const distanceKm = runDistance(fm.distance);
    const seconds = runSeconds(fm.time);
    if (distanceKm === null || seconds === null) continue;
    const runId = str(fm.tagwerk_id);
    runs.push({ id: runId ?? `vault:${path}`, runId, path, date, distanceKm, seconds, source: runId ? "app" : null, hasRoute: str(fm.route) !== null });
  }
  runs.sort((a, b) => a.date.localeCompare(b.date) || runOrdinal(basename(a.path)) - runOrdinal(basename(b.path)) || a.path.localeCompare(b.path));

  // Food log of the last weeks (older days stay on the phone and in the vault)
  const foodCutoff = localDate(new Date(now.getFullYear(), now.getMonth(), now.getDate() - Math.min(opts.textDays, 35)));
  const foodDays: SnapshotFoodDay[] = [];
  for (const path of await ctx.vault.list(ctx.folders.foodFolder)) {
    const date = basename(path);
    if (!isDate(date) || date < foodCutoff) continue;
    const { body } = await parse(ctx, path);
    const block = findFoodBlock(body);
    if (!block?.data) continue;
    foodDays.push({ date, path, entries: block.data.entries, targets: block.data.targets ?? null, met: block.data.met ?? null });
  }
  foodDays.sort((a, b) => b.date.localeCompare(a.date));

  let profile: BodyProfile | null = null;
  if (ctx.folders.profilePath && (await ctx.vault.exists(ctx.folders.profilePath))) {
    profile = profileFromFrontmatter((await parse(ctx, ctx.folders.profilePath)).fm);
  }

  let schoolOverrides: SchoolOverride[] = [];
  const schoolPath = ctx.folders.schoolNotePath;
  if (schoolPath && (await ctx.vault.exists(schoolPath))) {
    const from = localDate(new Date(now.getFullYear(), now.getMonth(), now.getDate() - 28));
    schoolOverrides = parseSchoolNote(await ctx.vault.read(schoolPath)).filter((o) => o.date >= from);
  }

  return {
    schema: SCHEMA,
    generatedAt: now.toISOString(),
    pluginVersion: opts.pluginVersion,
    habits: ctx.folders.habits,
    days,
    tasks: tasks.slice(0, 400),
    appointments: appointments.slice(0, 300),
    applied: opts.applied.slice(-500),
    errors: opts.errors.slice(-30),
    lastIngestAt: opts.lastIngestAt,
    features: [...FEATURES],
    runs: runs.slice(-3000),
    foodDays,
    profile,
    schoolOverrides,
  };
}

/** The notes block the app writes, otherwise the text below the heading without callouts and comments; at most 600 characters. */
function appointmentNotes(body: string): string | null {
  const m = /%% tagwerk:notizen %%\n([\s\S]*?)\n%% \/tagwerk:notizen %%/.exec(body);
  const text = (m
    ? m[1]
    : body
        .replace(/%%[\s\S]*?%%/g, "")
        .split("\n")
        .filter((l) => !/^#\s/.test(l) && !/^>/.test(l))
        .join("\n")
  ).trim();
  if (!text) return null;
  return text.length > 600 ? `${text.slice(0, 599).trimEnd()}…` : text;
}
