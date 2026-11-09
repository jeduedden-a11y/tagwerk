import { journalHash, normalizeJournal, sha256Hex } from "./crypto";
import {
  findFoodBlock,
  foodFrontmatter,
  newFoodNote,
  newProfileNote,
  newRunNote,
  normalizeVisible,
  profileToFrontmatter,
  renderFoodBlock,
  renderFoodVisible,
  upsertSummary,
} from "./fitness";
import {
  bodyOutsideJournal,
  findJournalBlock,
  retitleHeading,
  sanitizeFileName,
  splitFrontmatter,
  upsertJournal,
  JOURNAL_END,
  JOURNAL_START,
} from "./markdown";
import { findLearnBlock, learnHash, learnKey, normalizeLearn, renderLearnBlock, renderLearnInner, upsertLearnBlock } from "./learn";
import { fcDays, parseSchoolNote, recurrenceOf, renderSchoolNote, upsertOverride } from "./planner";
import type {
  AppointmentAddEvent,
  AppointmentPatchEvent,
  BridgeEvent,
  DayJournalEvent,
  DayPatchEvent,
  FoodDayEvent,
  HabitConfig,
  LearnNoteEvent,
  ProfileSetEvent,
  SchoolOverrideEvent,
  RunAddEvent,
  RunPatchEvent,
  TaskCreateEvent,
  TaskPatchEvent,
} from "./protocol";
import { validateEvent } from "./protocol";
import type { Frontmatter, VaultPort } from "./vault";

export interface FolderSettings {
  dailyFolder: string;
  tasksFolder: string;
  appointmentsFolder: string;
  /** One note per run: YYYY-MM-DD.md with distance and time ("Lauf Chart.canvas" reads them). */
  runsFolder: string;
  /** GPX files of runs recorded with the app. */
  routesFolder: string;
  /** One note per day with the food log. */
  foodFolder: string;
  /** Note with the body data. */
  profilePath: string;
  /** Note with the lessons the user marked himself (cancelled, absent). */
  schoolNotePath: string;
  habits: HabitConfig[];
}


export const DEFAULT_FITNESS_FOLDERS = {
  runsFolder: "01 Leben/Fittness/Laufen/Laufzeiten",
  routesFolder: "01 Leben/Fittness/Laufen/Routen",
  foodFolder: "01 Leben/Fittness/Ernährung",
  profilePath: "01 Leben/Fittness/Körperprofil.md",
  // Planner (plugin 1.2): the lessons the user marked himself
  schoolNotePath: "01 Leben/Schule/Stundenplan-Änderungen.md",
};

export interface ApplyContext {
  vault: VaultPort;
  folders: FolderSettings;
  now: () => Date;
}

const pad = (n: number) => String(n).padStart(2, "0");
export const localDate = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const deDate = (d: Date) => `${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${d.getFullYear()}`;
const deDateTime = (d: Date) => `${deDate(d)} ${pad(d.getHours())}:${pad(d.getMinutes())}`;

const join = (folder: string, name: string) => (folder ? `${folder.replace(/\/+$/, "")}/${name}` : name);

/** Plain YAML scalar when unambiguous, double-quoted otherwise. */
export function yamlScalar(s: string): string {
  const plainOk =
    /^[A-Za-zÄÖÜäöüß0-9(][^\n]*$/.test(s) &&
    !/[:#]\s|:$|\s#|[{}[\],&*!|>'"%@`]/.test(s) &&
    !/^(true|false|yes|no|on|off|null|~)$/i.test(s) &&
    !/^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$/.test(s) &&
    !/^\d{4}-\d{2}-\d{2}/.test(s) &&
    s.trim() === s;
  if (plainOk) return s;
  return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n")}"`;
}

function setOrClear(fm: Frontmatter, key: string, value: unknown): void {
  if (value === null) {
    if (key in fm) fm[key] = null;
    return;
  }
  fm[key] = value;
}

const clip = (s: string, n: number) => (s.length > n ? `${s.slice(0, n - 1).trimEnd()}…` : s);

export function dailyNotePath(folders: FolderSettings, date: string): string {
  return join(folders.dailyFolder, `${date}.md`);
}

/** Same key order as the existing notes: tags, habits, rating, weight. */
export function newDailyNote(habits: HabitConfig[]): string {
  return ["---", "tags:", "  - /dailynotes", ...habits.map((h) => `${h.key}: false`), "rating:", "weight:", "---", ""].join("\n");
}

async function ensureDailyNote(ctx: ApplyContext, date: string): Promise<string> {
  const path = dailyNotePath(ctx.folders, date);
  if (!(await ctx.vault.exists(path))) await ctx.vault.create(path, newDailyNote(ctx.folders.habits));
  return path;
}

async function applyDayPatch(ctx: ApplyContext, ev: DayPatchEvent): Promise<void> {
  const path = await ensureDailyNote(ctx, ev.date);
  await ctx.vault.processFrontMatter(path, (fm) => {
    if (ev.habits) for (const [k, v] of Object.entries(ev.habits)) fm[k] = v;
    if (ev.rating !== undefined) fm.rating = ev.rating;
    if (ev.ratingAI !== undefined) setOrClear(fm, "rating_ai", ev.ratingAI);
    if (ev.ratingSource !== undefined) setOrClear(fm, "rating_source", ev.ratingSource);
    if (ev.ratingReason !== undefined) setOrClear(fm, "rating_reason", ev.ratingReason ? clip(ev.ratingReason.replace(/\s+/g, " ").trim(), 300) : null);
    if (ev.weight !== undefined) fm.weight = ev.weight;
  });
}

async function applyJournal(ctx: ApplyContext, ev: DayJournalEvent): Promise<void> {
  const text = normalizeJournal(ev.text);
  const path = dailyNotePath(ctx.folders, ev.date);
  if (!text && !(await ctx.vault.exists(path))) return;
  await ensureDailyNote(ctx, ev.date);
  const before = splitFrontmatter(await ctx.vault.read(path));
  const block = findJournalBlock(before.body);
  const currentHash = await journalHash(block?.text ?? null);
  const conflict =
    block !== null && currentHash !== "" && ev.baseHash !== currentHash && normalizeJournal(block.text) !== text;
  const label = conflict ? `Frühere Fassung aus Obsidian, in der App ersetzt am ${deDateTime(ctx.now())}` : null;

  await ctx.vault.process(path, (content) => {
    const s = splitFrontmatter(content);
    const prefix = content.slice(0, content.length - s.body.length);
    let body: string;
    if (!text) {
      const b = findJournalBlock(s.body);
      if (!b) return content;
      const head = s.body.slice(0, b.start).replace(/\s+$/, "");
      const tail = s.body.slice(b.end).replace(/^\s+/, "");
      body = [head, tail].filter(Boolean).join("\n\n");
      if (body) body += "\n";
    } else {
      body = upsertJournal(s.body, text, label);
    }
    return prefix + body;
  });
}

function fmString(v: unknown): string | null {
  if (v === null || v === undefined) return null;
  if (typeof v === "string") return v.trim() || null;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  if (v instanceof Date && !isNaN(v.getTime())) return v.toISOString().slice(0, 10);
  return null;
}

async function readFm(ctx: ApplyContext, path: string): Promise<{ fm: Frontmatter; body: string }> {
  const s = splitFrontmatter(await ctx.vault.read(path));
  let fm: Frontmatter = {};
  if (s.yaml) {
    try {
      const parsed = ctx.vault.parseYaml(s.yaml);
      if (parsed && typeof parsed === "object") fm = parsed as Frontmatter;
    } catch {
      /* unreadable frontmatter: treat as empty */
    }
  }
  return { fm, body: s.body };
}

async function findById(ctx: ApplyContext, folder: string, id: string): Promise<string | null> {
  for (const p of await ctx.vault.list(folder)) {
    const { fm } = await readFm(ctx, p);
    if (fmString(fm.tagwerk_id) === id) return p;
  }
  return null;
}

async function freePath(ctx: ApplyContext, folder: string, stem: string): Promise<string> {
  let path = join(folder, `${stem}.md`);
  for (let n = 2; await ctx.vault.exists(path); n++) path = join(folder, `${stem} (${n}).md`);
  return path;
}

async function applyTaskCreate(ctx: ApplyContext, ev: TaskCreateEvent): Promise<void> {
  if (await findById(ctx, ctx.folders.tasksFolder, ev.taskId)) return;
  const title = ev.title.replace(/\s+/g, " ").trim();
  const path = await freePath(ctx, ctx.folders.tasksFolder, sanitizeFileName(title));
  const fm = [
    `title: ${yamlScalar(title)}`,
    `created: ${ev.created}`,
    ...(ev.date ? [`date: ${ev.date}`, "allDay: true"] : []),
    "completed: false",
    `wichtig: ${ev.wichtig ? "true" : "false"}`,
    `tagwerk_id: ${ev.taskId}`,
  ];
  const notes = ev.notes?.replace(/\r\n?/g, "\n").trim();
  await ctx.vault.create(path, `---\n${fm.join("\n")}\n---\n\n# ${title}\n${notes ? `\n${notes}\n` : ""}`);
}

async function applyTaskPatch(ctx: ApplyContext, ev: TaskPatchEvent): Promise<void> {
  let path: string | null = null;
  if (ev.taskId) path = await findById(ctx, ctx.folders.tasksFolder, ev.taskId);
  if (!path && ev.path && (await ctx.vault.exists(ev.path))) path = ev.path;
  if (!path) throw new Error(`Aufgabe nicht gefunden (${ev.taskId ?? ev.path}). Wurde sie in Obsidian gelöscht oder umbenannt?`);
  let oldTitle: string | null = null;
  const newTitle = ev.title?.replace(/\s+/g, " ").trim();
  await ctx.vault.processFrontMatter(path, (fm) => {
    oldTitle = fmString(fm.title);
    if (ev.completed !== undefined) fm.completed = ev.completed;
    if (ev.wichtig !== undefined) fm.wichtig = ev.wichtig;
    if (ev.date !== undefined) {
      if (ev.date === null) {
        delete fm.date;
        delete fm.allDay;
      } else {
        fm.date = ev.date;
        fm.allDay = true;
      }
    }
    if (newTitle) fm.title = newTitle;
  });
  if (newTitle && oldTitle && oldTitle !== newTitle) {
    const from = oldTitle;
    await ctx.vault.process(path, (content) => {
      const s = splitFrontmatter(content);
      const prefix = content.slice(0, content.length - s.body.length);
      return prefix + retitleHeading(s.body, from, newTitle);
    });
  }
}

const CATEGORY_LABEL: Record<string, string> = { klausur: "Klausur", uni: "Uni", schule: "Schule", termin: "Termin" };

async function applyAppointment(ctx: ApplyContext, ev: AppointmentAddEvent): Promise<void> {
  if (await findById(ctx, ctx.folders.appointmentsFolder, ev.apptId)) return;
  const title = ev.title.replace(/\s+/g, " ").trim();
  const path = await freePath(ctx, ctx.folders.appointmentsFolder, sanitizeFileName(`${ev.date} ${title}`, ev.date));
  const allDay = ev.allDay || !ev.startTime;
  const src = ev.source ?? {};
  const quelle = src.mailbox ? (src.mailbox === "WebUntis" ? "WebUntis" : "E-Mail") : "Tagwerk";
  const when = ev.recur
    ? ["type: recurring", `daysOfWeek: ${fcDays(ev.recur.days)}`, `startRecur: ${ev.date}`, `endRecur: ${ev.recur.until}`]
    : [`date: ${ev.date}`];
  const fm = [
    `title: ${yamlScalar(title)}`,
    ...when,
    ...(!allDay && ev.startTime ? [`startTime: "${ev.startTime}"`] : []),
    ...(!allDay && ev.endTime ? [`endTime: "${ev.endTime}"`] : []),
    `allDay: ${allDay ? "true" : "false"}`,
    ...(ev.recur ? [] : ["type: single"]),
    ...(ev.category ? [`kategorie: ${ev.category}`] : []),
    ...(ev.subject?.trim() ? [`fach: ${yamlScalar(ev.subject.trim())}`] : []),
    ...(ev.location?.trim() ? [`ort: ${yamlScalar(ev.location.trim())}`] : []),
    `quelle: ${quelle}`,
    ...(src.mailbox ? [`postfach: ${yamlScalar(src.mailbox)}`] : []),
    ...(src.from ? [`von: ${yamlScalar(src.from)}`] : []),
    ...(src.subject ? [`betreff: ${yamlScalar(clip(src.subject, 200))}`] : []),
    `erfasst: ${localDate(ctx.now())}`,
    `tagwerk_id: ${ev.apptId}`,
    "tags:",
    "  - /termine",
    ...(ev.category === "klausur" ? ["  - /klausur"] : []),
  ];
  const info: string[] = [];
  if (src.from) info.push(`> **Von:** ${src.from}`);
  if (src.subject) info.push(`> **Betreff:** ${src.subject}`);
  if (src.receivedAt) {
    const d = new Date(src.receivedAt);
    if (!isNaN(d.getTime())) info.push(`> **Empfangen:** ${deDateTime(d)}`);
  }
  const origin = quelle === "WebUntis" ? "Aus einer WebUntis-Mitteilung übernommen" : "Aus einer E-Mail übernommen";
  const callout = info.length ? `\n> [!info] ${origin}\n${info.join("\n")}\n` : "";
  const notes = ev.notes?.replace(/\r\n?/g, "\n").trim();
  const heading = ev.category === "klausur" && ev.subject?.trim() && !title.toLowerCase().includes(ev.subject.trim().toLowerCase())
    ? `${title} (${ev.subject.trim()})`
    : title;
  const block = notes ? `\n%% tagwerk:notizen %%\n${notes}\n%% /tagwerk:notizen %%\n` : "";
  await ctx.vault.create(path, `---\n${fm.join("\n")}\n---\n\n# ${heading}\n${callout}${block}`);
}

async function findAppointment(ctx: ApplyContext, apptId?: string | null, path?: string | null): Promise<string | null> {
  if (apptId) {
    const p = await findById(ctx, ctx.folders.appointmentsFolder, apptId);
    if (p) return p;
  }
  if (path && (await ctx.vault.exists(path))) return path;
  return null;
}

async function applyAppointmentPatch(ctx: ApplyContext, ev: AppointmentPatchEvent): Promise<void> {
  const path = await findAppointment(ctx, ev.apptId, ev.path);
  if (!path) {
    if (ev.deleted) return; // already gone
    throw new Error(`Termin nicht gefunden (${ev.apptId ?? ev.path}). Wurde er in Obsidian gelöscht oder umbenannt?`);
  }
  if (ev.deleted) {
    await ctx.vault.trash(path);
    return;
  }
  let oldTitle: string | null = null;
  const newTitle = ev.title?.replace(/\s+/g, " ").trim();
  await ctx.vault.processFrontMatter(path, (fm) => {
    oldTitle = fmString(fm.title);
    if (newTitle) fm.title = newTitle;
    const rec = recurrenceOf(fm);
    if (ev.recur) {
      const start = ev.date ?? rec?.start ?? fmString(fm.date) ?? localDate(ctx.now());
      fm.type = "recurring";
      fm.daysOfWeek = [...new Set(ev.recur.days)].sort((a, b) => a - b).map((d) => "MTWRFSU"[d - 1]);
      fm.startRecur = start;
      fm.endRecur = ev.recur.until;
      delete fm.date;
    } else if (ev.recur === null && rec) {
      fm.type = "single";
      fm.date = ev.date ?? rec.start;
      delete fm.daysOfWeek;
      delete fm.startRecur;
      delete fm.endRecur;
    } else if (ev.date) {
      if (rec) fm.startRecur = ev.date;
      else fm.date = ev.date;
    }
    if (ev.allDay !== undefined) fm.allDay = ev.allDay;
    if (ev.startTime !== undefined) setOrClear(fm, "startTime", ev.startTime);
    if (ev.endTime !== undefined) setOrClear(fm, "endTime", ev.endTime);
    if (ev.allDay === true) {
      delete fm.startTime;
      delete fm.endTime;
    }
    if (ev.location !== undefined) {
      delete fm.location;
      setOrClear(fm, "ort", ev.location?.trim() || null);
    }
    if (ev.category !== undefined) setOrClear(fm, "kategorie", ev.category);
    if (ev.subject !== undefined) setOrClear(fm, "fach", ev.subject?.trim() || null);
  });
  if (newTitle && oldTitle && oldTitle !== newTitle) {
    const from = oldTitle;
    await ctx.vault.process(path, (content) => {
      const s = splitFrontmatter(content);
      const prefix = content.slice(0, content.length - s.body.length);
      return prefix + retitleHeading(s.body, from, newTitle);
    });
  }
  if (ev.notes !== undefined) {
    const notes = ev.notes?.replace(/\r\n?/g, "\n").trim() ?? "";
    await ctx.vault.process(path, (content) => {
      const s = splitFrontmatter(content);
      const prefix = content.slice(0, content.length - s.body.length);
      const lines = s.body.replace(/^\n+/, "").split("\n");
      const head = lines[0]?.startsWith("# ") ? lines[0] : null;
      let rest = (head ? lines.slice(1) : lines).join("\n");
      const marker = "%% tagwerk:notizen %%";
      const endMarker = "%% /tagwerk:notizen %%";
      const block = notes ? `${marker}\n${notes}\n${endMarker}` : "";
      const a = rest.indexOf(marker);
      const b = rest.indexOf(endMarker);
      if (a >= 0 && b > a) rest = rest.slice(0, a) + block + rest.slice(b + endMarker.length);
      else if (block) rest = `${rest.trimEnd()}\n\n${block}\n`;
      return `${prefix}\n${head ? `${head}\n` : ""}${rest.startsWith("\n") ? rest : `\n${rest}`}`;
    });
  }
}

async function applySchoolOverride(ctx: ApplyContext, ev: SchoolOverrideEvent): Promise<void> {
  const path = ctx.folders.schoolNotePath;
  if (!path) throw new Error("Kein Pfad für die Notiz mit den Stundenplan-Änderungen eingestellt.");
  const exists = await ctx.vault.exists(path);
  const entries = exists ? parseSchoolNote(await ctx.vault.read(path)) : [];
  const next = upsertOverride(
    entries,
    {
      key: ev.key,
      date: ev.date,
      start: ev.start,
      end: ev.end ?? null,
      subject: ev.subject?.trim() || null,
      title: ev.title?.trim() || null,
      state: ev.state,
      reason: ev.reason?.trim() || null,
      updated: ctx.now().toISOString(),
    },
    localDate(ctx.now()),
  );
  const content = renderSchoolNote(next);
  if (exists) await ctx.vault.process(path, () => content);
  else await ctx.vault.create(path, content);
}

async function applyRunAdd(ctx: ApplyContext, ev: RunAddEvent): Promise<void> {
  const folder = ctx.folders.runsFolder;
  if (await findById(ctx, folder, ev.runId)) return;
  // The chart reads the date from the file name; a second run on the same day gets "-2".
  let stem = ev.date;
  for (let n = 2; await ctx.vault.exists(join(folder, `${stem}.md`)); n++) stem = `${ev.date}-${n}`;
  let route: string | null = null;
  if (ev.gpx) {
    let r = stem;
    for (let n = 2; await ctx.vault.exists(join(ctx.folders.routesFolder, `${r}.gpx`)); n++) r = `${stem}-${n}`;
    await ctx.vault.create(join(ctx.folders.routesFolder, `${r}.gpx`), ev.gpx);
    route = `${r}.gpx`;
  }
  await ctx.vault.create(join(folder, `${stem}.md`), newRunNote(ev.distance, ev.time, ev.runId, route));
}

async function applyRunPatch(ctx: ApplyContext, ev: RunPatchEvent): Promise<void> {
  let path: string | null = null;
  if (ev.runId) path = await findById(ctx, ctx.folders.runsFolder, ev.runId);
  if (!path && ev.path && (await ctx.vault.exists(ev.path))) path = ev.path;
  if (!path) {
    if (ev.deleted) return; // already gone
    throw new Error(`Lauf nicht gefunden (${ev.runId ?? ev.path}). Wurde die Notiz in Obsidian gelöscht oder umbenannt?`);
  }
  if (ev.deleted) {
    await ctx.vault.trash(path);
    return;
  }
  await ctx.vault.processFrontMatter(path, (fm) => {
    if (ev.distance !== undefined) fm.distance = ev.distance;
    if (ev.time !== undefined) fm.time = ev.time;
  });
}

const shortHash = async (s: string) => (await sha256Hex(s)).slice(0, 16);

async function applyFoodDay(ctx: ApplyContext, ev: FoodDayEvent): Promise<void> {
  const path = join(ctx.folders.foodFolder, `${ev.date}.md`);
  const entries = ev.entries ?? [];
  const targets = ev.targets ?? null;
  const met = ev.met ?? null;
  const visible = renderFoodVisible(ev.date, entries, targets, met);
  const hash = await shortHash(normalizeVisible(visible));
  if (!(await ctx.vault.exists(path))) {
    if (entries.length) await ctx.vault.create(path, newFoodNote(ev.date, entries, targets, met, hash));
    return;
  }
  // Edited in Obsidian since the app last wrote it? Then that version stays visible below the block.
  const before = findFoodBlock(splitFrontmatter(await ctx.vault.read(path)).body);
  let conflict: string | null = null;
  if (before) {
    const seen = normalizeVisible(before.visible);
    if (seen && before.data?.hash && (await shortHash(seen)) !== before.data.hash) conflict = seen;
  }
  const block = renderFoodBlock(visible, { v: 1, entries, targets, met, hash });
  const label = `Am PC geänderte Fassung, von der App ersetzt am ${deDateTime(ctx.now())}`;
  await ctx.vault.process(path, (content) => {
    const s = splitFrontmatter(content);
    const prefix = content.slice(0, content.length - s.body.length);
    const b = findFoodBlock(s.body);
    if (!b) {
      const trimmed = s.body.replace(/\s+$/, "");
      return `${prefix}${trimmed ? `${trimmed}\n\n` : ""}${block}\n`;
    }
    const quote = conflict ? `\n\n> [!quote] ${label}\n${conflict.split("\n").map((l) => `> ${l}`).join("\n")}` : "";
    return prefix + s.body.slice(0, b.start) + block + quote + s.body.slice(b.end);
  });
  await ctx.vault.processFrontMatter(path, (fm) => foodFrontmatter(fm, entries, targets, met));
}

async function applyProfileSet(ctx: ApplyContext, ev: ProfileSetEvent): Promise<void> {
  const path = ctx.folders.profilePath;
  const today = localDate(ctx.now());
  const summary = ev.summary?.replace(/\s+/g, " ").trim() || null;
  if (!(await ctx.vault.exists(path))) {
    await ctx.vault.create(path, newProfileNote(ev.profile, today, summary));
    return;
  }
  await ctx.vault.processFrontMatter(path, (fm) => profileToFrontmatter(fm, ev.profile, today));
  await ctx.vault.process(path, (content) => {
    const s = splitFrontmatter(content);
    const prefix = content.slice(0, content.length - s.body.length);
    return prefix + upsertSummary(s.body, summary, today);
  });
}

/** A wiki note in the vault's format: title, tags, type, created, updated, status; then the notes heading. */
export function newLearnNote(ev: LearnNoteEvent, today: string, heading: string, block: string): string {
  const fm = ev.frontmatter ?? {};
  const tags = (fm.tags ?? []).filter((t) => t.trim());
  return [
    "---",
    `title: ${yamlScalar(ev.title.replace(/\s+/g, " ").trim())}`,
    ...(tags.length ? ["tags:", ...tags.map((t) => `  - ${yamlScalar(t)}`)] : []),
    `type: ${fm.type || "note"}`,
    `created: ${ev.created ?? today}`,
    `updated: ${today}`,
    `status: ${fm.status || "growing"}`,
    "---",
    "",
    `## ${heading}`,
    "",
    block,
    "",
  ].join("\n");
}

async function applyLearnNote(ctx: ApplyContext, ev: LearnNoteEvent): Promise<void> {
  const path = ev.path.normalize("NFC");
  const key = learnKey(ev.block);
  const heading = ev.heading.replace(/\s+/g, " ").trim();
  const text = normalizeLearn(ev.text);
  const now = ctx.now();
  const exists = await ctx.vault.exists(path);
  if (!text && !exists) return; // nothing to remove
  const inner = text ? renderLearnInner(text, ev.source ?? null, deDate(now)) : null;
  const hash = inner ? await learnHash(inner) : "";
  if (!exists) {
    await ctx.vault.create(path, newLearnNote(ev, localDate(now), heading, renderLearnBlock(key, hash, inner as string)));
    return;
  }
  // Edited in Obsidian since the plugin wrote it? Then that version stays visible as a quote.
  const current = findLearnBlock(splitFrontmatter(await ctx.vault.read(path)).body, key);
  let conflict: { label: string; text: string } | null = null;
  if (
    current?.hash &&
    normalizeLearn(current.inner) &&
    (await learnHash(current.inner)) !== current.hash &&
    (inner === null || normalizeLearn(current.inner) !== normalizeLearn(inner))
  ) {
    const verb = inner === null ? "entfernt" : "ersetzt";
    conflict = { label: `In Obsidian geänderte Fassung, von Lernwerk ${verb} am ${deDateTime(now)}`, text: current.inner };
  }
  await ctx.vault.process(path, (content) => {
    const s = splitFrontmatter(content);
    const prefix = content.slice(0, content.length - s.body.length);
    return prefix + upsertLearnBlock(s.body, { key, heading, inner, hash, conflict });
  });
}

export async function applyEvent(ctx: ApplyContext, ev: BridgeEvent): Promise<void> {
  validateEvent(ev);
  switch (ev.type) {
    case "day.patch":
      return applyDayPatch(ctx, ev);
    case "day.journal":
      return applyJournal(ctx, ev);
    case "task.create":
      return applyTaskCreate(ctx, ev);
    case "task.patch":
      return applyTaskPatch(ctx, ev);
    case "appointment.add":
      return applyAppointment(ctx, ev);
    case "appointment.patch":
      return applyAppointmentPatch(ctx, ev);
    case "school.override":
      return applySchoolOverride(ctx, ev);
    case "run.add":
      return applyRunAdd(ctx, ev);
    case "run.patch":
      return applyRunPatch(ctx, ev);
    case "food.day":
      return applyFoodDay(ctx, ev);
    case "profile.set":
      return applyProfileSet(ctx, ev);
    case "learn.note":
      return applyLearnNote(ctx, ev);
  }
}

export const __test = { fmString, readFm, findById, JOURNAL_START, JOURNAL_END, bodyOutsideJournal };
