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
import type {
  AppointmentAddEvent,
  BridgeEvent,
  DayJournalEvent,
  DayPatchEvent,
  FoodDayEvent,
  HabitConfig,
  ProfileSetEvent,
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
  habits: HabitConfig[];
}

export const DEFAULT_FITNESS_FOLDERS = {
  runsFolder: "01 Leben/Fittness/Laufen/Laufzeiten",
  routesFolder: "01 Leben/Fittness/Laufen/Routen",
  foodFolder: "01 Leben/Fittness/Ernährung",
  profilePath: "01 Leben/Fittness/Körperprofil.md",
};

export interface ApplyContext {
  vault: VaultPort;
  folders: FolderSettings;
  now: () => Date;
}

const pad = (n: number) => String(n).padStart(2, "0");
export const localDate = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const deDateTime = (d: Date) => `${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`;

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

async function applyAppointment(ctx: ApplyContext, ev: AppointmentAddEvent): Promise<void> {
  if (await findById(ctx, ctx.folders.appointmentsFolder, ev.apptId)) return;
  const title = ev.title.replace(/\s+/g, " ").trim();
  const path = await freePath(ctx, ctx.folders.appointmentsFolder, sanitizeFileName(`${ev.date} ${title}`, ev.date));
  const allDay = ev.allDay || !ev.startTime;
  const src = ev.source ?? {};
  const fm = [
    `title: ${yamlScalar(title)}`,
    `date: ${ev.date}`,
    ...(!allDay && ev.startTime ? [`startTime: "${ev.startTime}"`] : []),
    ...(!allDay && ev.endTime ? [`endTime: "${ev.endTime}"`] : []),
    `allDay: ${allDay ? "true" : "false"}`,
    "type: single",
    ...(ev.location?.trim() ? [`ort: ${yamlScalar(ev.location.trim())}`] : []),
    "quelle: E-Mail",
    ...(src.mailbox ? [`postfach: ${yamlScalar(src.mailbox)}`] : []),
    ...(src.from ? [`von: ${yamlScalar(src.from)}`] : []),
    ...(src.subject ? [`betreff: ${yamlScalar(clip(src.subject, 200))}`] : []),
    `erfasst: ${localDate(ctx.now())}`,
    `tagwerk_id: ${ev.apptId}`,
    "tags:",
    "  - /termine",
  ];
  const info: string[] = [];
  if (src.from) info.push(`> **Von:** ${src.from}`);
  if (src.subject) info.push(`> **Betreff:** ${src.subject}`);
  if (src.receivedAt) {
    const d = new Date(src.receivedAt);
    if (!isNaN(d.getTime())) info.push(`> **Empfangen:** ${deDateTime(d)}`);
  }
  const callout = info.length ? `\n> [!info] Aus einer E-Mail übernommen\n${info.join("\n")}\n` : "";
  const notes = ev.notes?.replace(/\r\n?/g, "\n").trim();
  await ctx.vault.create(path, `---\n${fm.join("\n")}\n---\n\n# ${title}\n${callout}${notes ? `\n${notes}\n` : ""}`);
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
    case "run.add":
      return applyRunAdd(ctx, ev);
    case "run.patch":
      return applyRunPatch(ctx, ev);
    case "food.day":
      return applyFoodDay(ctx, ev);
    case "profile.set":
      return applyProfileSet(ctx, ev);
  }
}

export const __test = { fmString, readFm, findById, JOURNAL_START, JOURNAL_END, bodyOutsideJournal };
