/**
 * Tagwerk wire protocol, schema 1.
 *
 * The iPhone app is the capture surface, the vault stays the system of record.
 * The app never ships whole files. It ships field-level events; the plugin
 * applies them to exactly the existing note formats and publishes a snapshot
 * of the vault state back. Both directions are AES-GCM encrypted (see crypto.ts).
 *
 * Keep this file in sync with Packages/TagwerkCore/Sources/TagwerkCore/Protocol.swift.
 */

export const SCHEMA = 1 as const;

export type RatingSource = "ai" | "manual";

interface EventBase {
  /** UUID, unique per event. Used for idempotent application. */
  id: string;
  /** ISO-8601 creation time on the device. Events are applied in ts order. */
  ts: string;
}

/** Field-level patch of one daily note. Only the fields present are touched. */
export interface DayPatchEvent extends EventBase {
  type: "day.patch";
  /** YYYY-MM-DD, also the file name of the daily note. */
  date: string;
  habits?: Record<string, boolean>;
  /** Effective rating "0.0".."10.0" (string, one decimal) or null to clear. */
  rating?: string | null;
  ratingAI?: string | null;
  ratingSource?: RatingSource | null;
  ratingReason?: string | null;
  /** Weight in kg as string, e.g. "77.2", or null to clear. */
  weight?: string | null;
}

/** Replaces the managed journal block in the body of a daily note. */
export interface DayJournalEvent extends EventBase {
  type: "day.journal";
  date: string;
  text: string;
  /** journalHash() of the block content the app last saw; null if it saw none. */
  baseHash: string | null;
}

export interface TaskCreateEvent extends EventBase {
  type: "task.create";
  taskId: string;
  title: string;
  /** YYYY-MM-DD */
  created: string;
  date?: string | null;
  wichtig: boolean;
  notes?: string | null;
}

/** Patch of an existing task. Addressed by taskId (app-created) or path (vault-created). */
export interface TaskPatchEvent extends EventBase {
  type: "task.patch";
  taskId?: string | null;
  path?: string | null;
  completed?: boolean;
  wichtig?: boolean;
  /** undefined = unchanged, null = remove the due date */
  date?: string | null;
  title?: string;
}

export interface AppointmentSource {
  mailbox?: string | null;
  from?: string | null;
  subject?: string | null;
  receivedAt?: string | null;
}

export interface AppointmentAddEvent extends EventBase {
  type: "appointment.add";
  apptId: string;
  title: string;
  date: string;
  startTime?: string | null;
  endTime?: string | null;
  allDay: boolean;
  location?: string | null;
  notes?: string | null;
  source?: AppointmentSource | null;
  /** "klausur", "uni", "schule" or "termin" (planner feature). */
  category?: AppointmentCategory | null;
  /** School subject, e.g. "Chemie" (exams). */
  subject?: string | null;
  /** Weekly repetition; date is the first occurrence. */
  recur?: Recurrence | null;
}

export type AppointmentCategory = "klausur" | "uni" | "schule" | "termin";
export const CATEGORIES: readonly AppointmentCategory[] = ["klausur", "uni", "schule", "termin"];

/** Weekly on the given ISO weekdays (1 = Monday ... 7 = Sunday) until the given day. */
export interface Recurrence {
  days: number[];
  until: string;
}

/** Changes or deletes an appointment note (found by tagwerk_id or path). */
export interface AppointmentPatchEvent extends EventBase {
  type: "appointment.patch";
  apptId?: string | null;
  path?: string | null;
  deleted?: boolean;
  title?: string;
  date?: string;
  startTime?: string | null;
  endTime?: string | null;
  allDay?: boolean;
  location?: string | null;
  category?: AppointmentCategory | null;
  subject?: string | null;
  recur?: Recurrence | null;
  notes?: string | null;
}

export type OverrideState = "entfall" | "abwesend" | "anwesend";

/** A lesson (or a planner entry) the user marks for one day; state "clear" removes the mark. */
export interface SchoolOverrideEvent extends EventBase {
  type: "school.override";
  key: string;
  date: string;
  start: string;
  end?: string | null;
  subject?: string | null;
  title?: string | null;
  state: OverrideState | "clear";
  reason?: string | null;
}

/** A new note in the runs folder, in the vault's format: distance "3.02", time 00:16:29. */
export interface RunAddEvent extends EventBase {
  type: "run.add";
  runId: string;
  date: string;
  /** Kilometres with two decimals, e.g. "5.02". */
  distance: string;
  /** HH:MM:SS */
  time: string;
  /** "gps" or "manuell" */
  source?: string | null;
  /** Recorded route as GPX 1.1, written next to the note in the routes folder. */
  gpx?: string | null;
}

export interface RunPatchEvent extends EventBase {
  type: "run.patch";
  runId?: string | null;
  path?: string | null;
  distance?: string;
  time?: string;
  /** Moves the note to the trash. */
  deleted?: boolean;
}

export interface Nutrients {
  kcal: number;
  protein: number;
  fat: number;
  carbs: number;
  fiber?: number | null;
  sugar?: number | null;
  satFat?: number | null;
  salt?: number | null;
}

export type Meal = "fruehstueck" | "mittag" | "abend" | "snack";
export const MEALS: Meal[] = ["fruehstueck", "mittag", "abend", "snack"];
export const MEAL_LABEL: Record<Meal, string> = { fruehstueck: "Frühstück", mittag: "Mittagessen", abend: "Abendessen", snack: "Snacks" };

export interface FoodEntry {
  id: string;
  /** HH:MM */
  time: string;
  meal: Meal;
  name: string;
  brand?: string | null;
  barcode?: string | null;
  itemId?: string | null;
  source: string;
  /** Amount in grams (or millilitres when unit is "ml"). */
  grams: number;
  unit: "g" | "ml";
  /** Values per 100 g / 100 ml. */
  per100: Nutrients;
  note?: string | null;
}

export interface DayTargets {
  kcal: number;
  protein: number;
  fat: number;
  carbs: number;
  fiber?: number | null;
  /** Percent */
  tolerance?: number | null;
}

/** Replaces the food log of one day. Entries are only edited in the app. */
export interface FoodDayEvent extends EventBase {
  type: "food.day";
  date: string;
  entries: FoodEntry[];
  targets?: DayTargets | null;
  met?: boolean | null;
}

export type Sex = "m" | "w";
export type Activity = "sitzend" | "leicht" | "maessig" | "hoch" | "sehr_hoch";
export const ACTIVITIES: Activity[] = ["sitzend", "leicht", "maessig", "hoch", "sehr_hoch"];

export interface BodyProfile {
  heightCm: number;
  birthYear: number;
  sex: Sex;
  bodyFat?: number | null;
  targetWeight?: number | null;
  activity: Activity;
  /** kg per week, the direction comes from the target weight */
  weeklyRate: number;
  proteinPerKg: number;
  /** percent of energy */
  fatPercent: number;
  /** percent */
  tolerance: number;
  checkProtein: boolean;
  checkFat: boolean;
  checkCarbs: boolean;
  checkFiber: boolean;
  addRuns: boolean;
  updated?: string | null;
}

export interface ProfileSetEvent extends EventBase {
  type: "profile.set";
  profile: BodyProfile;
  /** One line with the computed targets, written into the note body. */
  summary?: string | null;
}

export type BridgeEvent =
  | DayPatchEvent
  | DayJournalEvent
  | TaskCreateEvent
  | TaskPatchEvent
  | AppointmentAddEvent
  | AppointmentPatchEvent
  | SchoolOverrideEvent
  | RunAddEvent
  | RunPatchEvent
  | FoodDayEvent
  | ProfileSetEvent;

/** Event families this plugin understands; the app holds back events of families not listed. */
export const FEATURES = ["runs", "food", "profile", "planner", "wiki"] as const;

/** Plaintext of one inbox file. */
export interface InboxBatch {
  schema: typeof SCHEMA;
  device: string;
  createdAt: string;
  events: BridgeEvent[];
}

export interface HabitConfig {
  key: string;
  label: string;
  color: string;
  perWeek: number;
  weight: number;
  /** Max gap in days between two completions that keeps a streak going. */
  toleranceDays: number;
  /** Max days since the last completion for the current streak to count as alive. */
  aliveDays: number;
  /** SF Symbol name used by the app. */
  symbol: string;
}

export interface SnapshotDay {
  date: string;
  habits: Record<string, boolean>;
  rating: string | null;
  ratingAI: string | null;
  ratingSource: RatingSource | null;
  ratingReason: string | null;
  weight: string | null;
  /** Content of the managed journal block, null if there is none (or the day is outside textDays). */
  journal: string | null;
  journalHash: string;
  /** Body text outside the managed block (written in Obsidian), trimmed. */
  note: string | null;
  /** False for days outside the textDays window: journal/note are omitted, not empty. */
  hasText: boolean;
}

export interface SnapshotTask {
  path: string;
  taskId: string | null;
  title: string;
  created: string | null;
  date: string | null;
  completed: boolean;
  wichtig: boolean;
  notes: string | null;
}

export interface SnapshotAppointment {
  path: string;
  apptId: string | null;
  title: string;
  /** First occurrence for recurring notes. */
  date: string;
  startTime: string | null;
  endTime: string | null;
  allDay: boolean;
  location: string | null;
  category: string | null;
  subject: string | null;
  recur: Recurrence | null;
  /** Body text below the heading, shortened. */
  notes: string | null;
}

export interface SchoolOverride {
  key: string;
  date: string;
  start: string;
  end: string | null;
  subject: string | null;
  title: string | null;
  state: OverrideState;
  reason: string | null;
  updated: string;
}

export interface BridgeError {
  eventId: string;
  at: string;
  message: string;
}

export interface SnapshotRun {
  /** runId for app-created runs, "vault:<path>" otherwise */
  id: string;
  runId: string | null;
  path: string;
  date: string;
  distanceKm: number;
  seconds: number;
  source: string | null;
  hasRoute: boolean;
}

export interface SnapshotFoodDay {
  date: string;
  path: string;
  entries: FoodEntry[];
  targets: DayTargets | null;
  met: boolean | null;
}

export interface Snapshot {
  schema: typeof SCHEMA;
  generatedAt: string;
  pluginVersion: string;
  habits: HabitConfig[];
  days: SnapshotDay[];
  tasks: SnapshotTask[];
  appointments: SnapshotAppointment[];
  /** Most recent applied event ids (acknowledgement for the app). */
  applied: string[];
  errors: BridgeError[];
  lastIngestAt: string | null;
  features: string[];
  runs: SnapshotRun[];
  foodDays: SnapshotFoodDay[];
  profile: BodyProfile | null;
  schoolOverrides: SchoolOverride[];
}

export const DEFAULT_HABITS: HabitConfig[] = [
  { key: "reading", label: "Lesen", color: "#7F77DD", perWeek: 3, weight: 1.0, toleranceDays: 1, aliveDays: 1, symbol: "book.fill" },
  { key: "writing", label: "Schreiben", color: "#D85A30", perWeek: 2, weight: 1.0, toleranceDays: 7, aliveDays: 6, symbol: "pencil.line" },
  { key: "gym", label: "Gym", color: "#2CC742", perWeek: 3, weight: 1.5, toleranceDays: 3, aliveDays: 2, symbol: "dumbbell.fill" },
  { key: "food", label: "Ernährung", color: "#EF9F27", perWeek: 7, weight: 0.5, toleranceDays: 1, aliveDays: 1, symbol: "fork.knife" },
  { key: "laufen", label: "Laufen", color: "#378ADD", perWeek: 1, weight: 1.0, toleranceDays: 7, aliveDays: 6, symbol: "figure.run" },
];

const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const RATING_RE = /^(10(\.0)?|\d(\.\d)?)$/;
const WEIGHT_RE = /^\d{2,3}(\.\d{1,2})?$/;

export function isDate(s: unknown): s is string {
  if (typeof s !== "string") return false;
  const m = DATE_RE.exec(s);
  if (!m) return false;
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  return d.getUTCFullYear() === +m[1] && d.getUTCMonth() === +m[2] - 1 && d.getUTCDate() === +m[3];
}
export const isTime = (s: unknown): s is string => typeof s === "string" && TIME_RE.test(s);
export const isRunDistance = (s: unknown): s is string => typeof s === "string" && /^\d{1,3}\.\d{2}$/.test(s) && Number(s) > 0;
export const isRunTime = (s: unknown): s is string =>
  typeof s === "string" && /^\d{2,3}:[0-5]\d:[0-5]\d$/.test(s) && s.split(":").reduce((a, p) => a * 60 + Number(p), 0) > 0;
const finite = (v: unknown, min: number, max: number) => typeof v === "number" && Number.isFinite(v) && v >= min && v <= max;
const optFinite = (v: unknown, min: number, max: number) => v === undefined || v === null || finite(v, min, max);

function nutrientsProblem(n: unknown): string | null {
  if (!n || typeof n !== "object") return "per100 fehlt";
  const v = n as Record<string, unknown>;
  if (!finite(v.kcal, 0, 1000)) return "kcal";
  for (const k of ["protein", "fat", "carbs"]) if (!finite(v[k], 0, 105)) return k;
  for (const k of ["fiber", "sugar", "satFat"]) if (!optFinite(v[k], 0, 105)) return k;
  if (!optFinite(v.salt, 0, 100)) return "salt";
  return null;
}

function entryProblem(e: unknown): string | null {
  if (!e || typeof e !== "object") return "Eintrag ist kein Objekt";
  const v = e as Record<string, unknown>;
  if (typeof v.id !== "string" || !v.id) return "Eintrag ohne id";
  if (!isTime(v.time)) return "Uhrzeit";
  if (!MEALS.includes(v.meal as Meal)) return "Mahlzeit";
  if (typeof v.name !== "string" || !v.name.trim() || v.name.length > 200) return "Name";
  if (!finite(v.grams, 0.01, 10000)) return "Menge";
  if (v.unit !== "g" && v.unit !== "ml") return "Einheit";
  return nutrientsProblem(v.per100);
}

export function profileProblem(p: unknown): string | null {
  if (!p || typeof p !== "object") return "profile fehlt";
  const v = p as Record<string, unknown>;
  if (!finite(v.heightCm, 100, 250)) return "heightCm";
  if (!finite(v.birthYear, 1900, 2100)) return "birthYear";
  if (v.sex !== "m" && v.sex !== "w") return "sex";
  if (!optFinite(v.bodyFat, 2, 70)) return "bodyFat";
  if (!optFinite(v.targetWeight, 30, 300)) return "targetWeight";
  if (!ACTIVITIES.includes(v.activity as Activity)) return "activity";
  if (!finite(v.weeklyRate, 0, 1.5)) return "weeklyRate";
  if (!finite(v.proteinPerKg, 0.5, 4)) return "proteinPerKg";
  if (!finite(v.fatPercent, 10, 60)) return "fatPercent";
  if (!finite(v.tolerance, 1, 50)) return "tolerance";
  for (const k of ["checkProtein", "checkFat", "checkCarbs", "checkFiber", "addRuns"]) if (typeof v[k] !== "boolean") return k;
  return null;
}
export function recurProblem(r: unknown, start: string | null): string | null {
  if (!r || typeof r !== "object") return "kein Objekt";
  const v = r as Record<string, unknown>;
  if (!Array.isArray(v.days) || v.days.length === 0 || v.days.length > 7) return "days";
  if (!v.days.every((d) => Number.isInteger(d) && (d as number) >= 1 && (d as number) <= 7)) return "days";
  if (!isDate(v.until)) return "until";
  if (start && (v.until as string) < start) return "until vor dem Beginn";
  return null;
}

export const isRating = (s: unknown): s is string => typeof s === "string" && RATING_RE.test(s);
export const isWeight = (s: unknown): s is string => typeof s === "string" && WEIGHT_RE.test(s);

/** Throws a German, user-facing message if the event is malformed. */
export function validateEvent(ev: BridgeEvent): void {
  const fail = (msg: string): never => {
    throw new Error(`Ungültiges Ereignis (${(ev as EventBase).id ?? "?"}): ${msg}`);
  };
  if (!ev || typeof ev !== "object") fail("kein Objekt");
  if (typeof ev.id !== "string" || ev.id.length < 8) fail("id fehlt");
  switch (ev.type) {
    case "day.patch":
      if (!isDate(ev.date)) fail("date");
      if (ev.habits) for (const [k, v] of Object.entries(ev.habits)) {
        if (!/^[A-Za-z0-9_-]{1,40}$/.test(k) || typeof v !== "boolean") fail(`habit ${k}`);
      }
      for (const k of ["rating", "ratingAI"] as const) {
        const v = ev[k];
        if (v !== undefined && v !== null && !isRating(v)) fail(k);
      }
      if (ev.ratingSource !== undefined && ev.ratingSource !== null && ev.ratingSource !== "ai" && ev.ratingSource !== "manual") fail("ratingSource");
      if (ev.weight !== undefined && ev.weight !== null && !isWeight(ev.weight)) fail("weight");
      if (ev.ratingReason !== undefined && ev.ratingReason !== null && typeof ev.ratingReason !== "string") fail("ratingReason");
      return;
    case "day.journal":
      if (!isDate(ev.date)) fail("date");
      if (typeof ev.text !== "string") fail("text");
      return;
    case "task.create":
      if (typeof ev.taskId !== "string" || !ev.taskId) fail("taskId");
      if (typeof ev.title !== "string" || !ev.title.trim()) fail("title");
      if (!isDate(ev.created)) fail("created");
      if (ev.date !== undefined && ev.date !== null && !isDate(ev.date)) fail("date");
      return;
    case "task.patch":
      if (!ev.taskId && !ev.path) fail("taskId oder path nötig");
      if (ev.date !== undefined && ev.date !== null && !isDate(ev.date)) fail("date");
      if (ev.title !== undefined && (typeof ev.title !== "string" || !ev.title.trim())) fail("title");
      return;
    case "appointment.add":
      if (typeof ev.apptId !== "string" || !ev.apptId) fail("apptId");
      if (typeof ev.title !== "string" || !ev.title.trim()) fail("title");
      if (!isDate(ev.date)) fail("date");
      if (ev.startTime != null && !isTime(ev.startTime)) fail("startTime");
      if (ev.endTime != null && !isTime(ev.endTime)) fail("endTime");
      if (ev.category != null && !CATEGORIES.includes(ev.category)) fail("category");
      if (ev.subject != null && (typeof ev.subject !== "string" || ev.subject.length > 60)) fail("subject");
      if (ev.recur != null && recurProblem(ev.recur, ev.date)) fail(`recur: ${recurProblem(ev.recur, ev.date)}`);
      return;
    case "appointment.patch":
      if (!ev.apptId && !ev.path) fail("apptId oder path nötig");
      if (ev.deleted !== undefined && typeof ev.deleted !== "boolean") fail("deleted");
      if (ev.title !== undefined && (typeof ev.title !== "string" || !ev.title.trim())) fail("title");
      if (ev.date !== undefined && !isDate(ev.date)) fail("date");
      if (ev.startTime != null && !isTime(ev.startTime)) fail("startTime");
      if (ev.endTime != null && !isTime(ev.endTime)) fail("endTime");
      if (ev.allDay !== undefined && typeof ev.allDay !== "boolean") fail("allDay");
      if (ev.category != null && !CATEGORIES.includes(ev.category)) fail("category");
      if (ev.recur != null && recurProblem(ev.recur, ev.date ?? null)) fail(`recur: ${recurProblem(ev.recur, ev.date ?? null)}`);
      return;
    case "school.override":
      if (typeof ev.key !== "string" || !ev.key || ev.key.length > 200) fail("key");
      if (!isDate(ev.date)) fail("date");
      if (!isTime(ev.start)) fail("start");
      if (ev.end != null && !isTime(ev.end)) fail("end");
      if (!["entfall", "abwesend", "anwesend", "clear"].includes(ev.state)) fail("state");
      for (const k of ["subject", "title", "reason"] as const) {
        const v = ev[k];
        if (v != null && (typeof v !== "string" || v.length > 200)) fail(k);
      }
      return;
    case "run.add":
      if (typeof ev.runId !== "string" || ev.runId.length < 8) fail("runId");
      if (!isDate(ev.date)) fail("date");
      if (!isRunDistance(ev.distance)) fail("distance");
      if (!isRunTime(ev.time)) fail("time");
      if (ev.source != null && (typeof ev.source !== "string" || ev.source.length > 20)) fail("source");
      if (ev.gpx != null && (typeof ev.gpx !== "string" || ev.gpx.length > 3_000_000 || !/^\s*<(\?xml|gpx)/.test(ev.gpx))) fail("gpx");
      return;
    case "run.patch":
      if (!ev.runId && !ev.path) fail("runId oder path nötig");
      if (ev.distance !== undefined && !isRunDistance(ev.distance)) fail("distance");
      if (ev.time !== undefined && !isRunTime(ev.time)) fail("time");
      if (ev.deleted !== undefined && typeof ev.deleted !== "boolean") fail("deleted");
      return;
    case "food.day": {
      if (!isDate(ev.date)) fail("date");
      if (!Array.isArray(ev.entries) || ev.entries.length > 400) fail("entries");
      for (const e of ev.entries) {
        const problem = entryProblem(e);
        if (problem) fail(`Eintrag: ${problem}`);
      }
      if (ev.targets != null) {
        const t = ev.targets as unknown as Record<string, unknown>;
        for (const k of ["kcal", "protein", "fat", "carbs"]) if (!finite(t[k], 0, 20000)) fail(`targets.${k}`);
      }
      if (ev.met != null && typeof ev.met !== "boolean") fail("met");
      return;
    }
    case "profile.set": {
      const problem = profileProblem(ev.profile);
      if (problem) fail(`profile.${problem}`);
      if (ev.summary != null && (typeof ev.summary !== "string" || ev.summary.length > 600)) fail("summary");
      return;
    }
    default:
      fail(`unbekannter Typ ${(ev as { type?: string }).type}`);
  }
}
