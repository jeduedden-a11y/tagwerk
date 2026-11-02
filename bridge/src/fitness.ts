/**
 * Text formats of the fitness notes. No Obsidian imports, everything here is unit-testable.
 *
 * Runs:      "<runs>/YYYY-MM-DD.md" with distance "3.02" and time 00:16:29, the format of the
 *            existing notes that "Lauf Chart.canvas" reads.
 * Food:      "<food>/YYYY-MM-DD.md" with day totals in the frontmatter (for Dataview) and a managed
 *            block with table, check and the app's data as a hidden comment.
 * Profile:   one note with the body data as properties, editable in Obsidian as well.
 */

import type { BodyProfile, DayTargets, FoodEntry, Meal } from "./protocol";
import { ACTIVITIES, MEAL_LABEL, MEALS } from "./protocol";
import type { Frontmatter } from "./vault";

export const FOOD_START = "%% tagwerk:food %%";
export const FOOD_END = "%% /tagwerk:food %%";
const DATA_OPEN = "%% tagwerk:food-data";

export interface FoodData {
  v: 1;
  entries: FoodEntry[];
  targets: DayTargets | null;
  met: boolean | null;
  /** Hash of the visible part as written, to notice edits made in Obsidian. */
  hash?: string;
}

export interface Totals {
  kcal: number;
  protein: number;
  fat: number;
  carbs: number;
  fiber: number | null;
}

export function totals(entries: FoodEntry[]): Totals {
  const t: Totals = { kcal: 0, protein: 0, fat: 0, carbs: 0, fiber: null };
  for (const e of entries) {
    const f = e.grams / 100;
    t.kcal += e.per100.kcal * f;
    t.protein += e.per100.protein * f;
    t.fat += e.per100.fat * f;
    t.carbs += e.per100.carbs * f;
    if (typeof e.per100.fiber === "number") t.fiber = (t.fiber ?? 0) + e.per100.fiber * f;
  }
  return t;
}

/** German number: 10.8 -> "10,8" */
export const de = (n: number, digits = 1): string => n.toFixed(digits).replace(".", ",");

const amount = (g: number) => (Math.abs(g - Math.round(g)) < 0.05 ? String(Math.round(g)) : g.toFixed(1).replace(".", ","));
const cell = (s: string) => s.replace(/\|/g, "/").replace(/\s+/g, " ").trim();

function germanDate(date: string): string {
  const [y, m, d] = date.split("-");
  return `${d}.${m}.${y}`;
}

export function sortEntries(entries: FoodEntry[]): FoodEntry[] {
  return [...entries].sort((a, b) => a.time.localeCompare(b.time) || MEALS.indexOf(a.meal) - MEALS.indexOf(b.meal) || a.id.localeCompare(b.id));
}

/** Visible part of the managed block: heading, table and the check against the targets. */
export function renderFoodVisible(date: string, entries: FoodEntry[], targets: DayTargets | null, met: boolean | null): string {
  const lines: string[] = [`# Ernährung ${germanDate(date)}`, ""];
  const sorted = sortEntries(entries);
  if (sorted.length === 0) {
    lines.push("Keine Einträge.");
  } else {
    lines.push("| Zeit | Mahlzeit | Lebensmittel | Menge | kcal | Protein | Fett | KH |", "| :--- | :--- | :--- | ---: | ---: | ---: | ---: | ---: |");
    for (const e of sorted) {
      const f = e.grams / 100;
      const name = e.brand ? `${e.name} (${e.brand})` : e.name;
      lines.push(
        `| ${e.time} | ${MEAL_LABEL[e.meal as Meal] ?? e.meal} | ${cell(name)} | ${amount(e.grams)} ${e.unit} | ${Math.round(e.per100.kcal * f)} | ${de(e.per100.protein * f)} | ${de(e.per100.fat * f)} | ${de(e.per100.carbs * f)} |`,
      );
    }
    const t = totals(sorted);
    lines.push(`| **Summe** | | | | **${Math.round(t.kcal)}** | **${de(t.protein)}** | **${de(t.fat)}** | **${de(t.carbs)}** |`);
  }
  if (targets) {
    const t = totals(sorted);
    const tol = targets.tolerance ?? 10;
    lines.push(
      "",
      met ? "> [!success] Ziel erreicht" : "> [!warning] Ziel nicht erreicht",
      `> ${Math.round(t.kcal)} von ${Math.round(targets.kcal)} kcal (±${de(tol, 0)} %) · Protein ${de(t.protein, 0)} von ${de(targets.protein, 0)} g · Fett ${de(t.fat, 0)} von ${de(targets.fat, 0)} g · Kohlenhydrate ${de(t.carbs, 0)} von ${de(targets.carbs, 0)} g`,
    );
  }
  return lines.join("\n");
}

export function renderFoodBlock(visible: string, data: FoodData): string {
  return `${FOOD_START}\n${visible}\n\n${DATA_OPEN}\n${JSON.stringify(data)}\n%%\n${FOOD_END}`;
}

export interface FoodBlock {
  start: number;
  end: number;
  visible: string;
  data: FoodData | null;
}

export function findFoodBlock(body: string): FoodBlock | null {
  const s = body.indexOf(FOOD_START);
  if (s < 0) return null;
  const e = body.indexOf(FOOD_END, s + FOOD_START.length);
  if (e < 0) return null;
  const inner = body.slice(s + FOOD_START.length, e);
  const d = inner.indexOf(DATA_OPEN);
  let data: FoodData | null = null;
  let visible = inner;
  if (d >= 0) {
    visible = inner.slice(0, d);
    const after = inner.slice(d + DATA_OPEN.length);
    const close = after.lastIndexOf("%%");
    const json = (close >= 0 ? after.slice(0, close) : after).trim();
    try {
      const parsed = JSON.parse(json) as FoodData;
      if (parsed && Array.isArray(parsed.entries)) data = parsed;
    } catch {
      data = null;
    }
  }
  return { start: s, end: e + FOOD_END.length, visible: visible.replace(/^\r?\n/, "").replace(/\s+$/, ""), data };
}

export const normalizeVisible = (s: string) => s.replace(/\r\n?/g, "\n").replace(/[ \t]+$/gm, "").trim();

/** Day totals and targets as properties; numbers as strings like the rest of the vault ("8.2", "3.02"). */
export function foodFrontmatter(fm: Frontmatter, entries: FoodEntry[], targets: DayTargets | null, met: boolean | null): void {
  const t = totals(entries);
  fm.kcal = String(Math.round(t.kcal));
  fm.protein = t.protein.toFixed(1);
  fm.fett = t.fat.toFixed(1);
  fm.kohlenhydrate = t.carbs.toFixed(1);
  if (t.fiber !== null) fm.ballaststoffe = t.fiber.toFixed(1);
  else delete fm.ballaststoffe;
  if (targets) {
    fm.ziel_kcal = String(Math.round(targets.kcal));
    fm.ziel_protein = String(Math.round(targets.protein));
    fm.ziel_fett = String(Math.round(targets.fat));
    fm.ziel_kohlenhydrate = String(Math.round(targets.carbs));
  }
  fm.erreicht = met === true;
}

export function newFoodNote(date: string, entries: FoodEntry[], targets: DayTargets | null, met: boolean | null, hash: string): string {
  const t = totals(entries);
  const fm = [
    `kcal: "${Math.round(t.kcal)}"`,
    `protein: "${t.protein.toFixed(1)}"`,
    `fett: "${t.fat.toFixed(1)}"`,
    `kohlenhydrate: "${t.carbs.toFixed(1)}"`,
    ...(t.fiber !== null ? [`ballaststoffe: "${t.fiber.toFixed(1)}"`] : []),
    ...(targets
      ? [
          `ziel_kcal: "${Math.round(targets.kcal)}"`,
          `ziel_protein: "${Math.round(targets.protein)}"`,
          `ziel_fett: "${Math.round(targets.fat)}"`,
          `ziel_kohlenhydrate: "${Math.round(targets.carbs)}"`,
        ]
      : []),
    `erreicht: ${met === true ? "true" : "false"}`,
  ];
  const visible = renderFoodVisible(date, entries, targets, met);
  return `---\n${fm.join("\n")}\n---\n${renderFoodBlock(visible, { v: 1, entries, targets, met, hash })}\n`;
}

// MARK: Runs

const RUN_STEM = /^(\d{4}-\d{2}-\d{2})(?:[ _-]\(?(\d{1,2})\)?)?$/;

export function runDateFromStem(stem: string): string | null {
  const m = RUN_STEM.exec(stem);
  return m ? m[1] : null;
}

/** 1 for "2026-11-01", 2 for "2026-11-01-2": order of runs on the same day. */
export function runOrdinal(stem: string): number {
  const m = RUN_STEM.exec(stem);
  return m && m[2] ? Number(m[2]) : 1;
}

/** "00:16:29", "16:29"; a number counts as seconds (YAML 1.1 reads 00:16:29 as 989). */
export function runSeconds(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v) && v > 0) return Math.round(v);
  if (typeof v !== "string") return null;
  const parts = v.trim().split(":").map(Number);
  if (parts.some((p) => !Number.isFinite(p) || p < 0)) return null;
  if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
  if (parts.length === 2) return parts[0] * 60 + parts[1];
  return null;
}

export function runDistance(v: unknown): number | null {
  const n = typeof v === "number" ? v : typeof v === "string" ? Number(v.replace(",", ".")) : NaN;
  return Number.isFinite(n) && n > 0 && n < 1000 ? n : null;
}

export function newRunNote(distance: string, time: string, runId: string, routeLink: string | null): string {
  return `---\ndistance: "${distance}"\ntime: ${time}\ntagwerk_id: ${runId}\n${routeLink ? `route: "[[${routeLink}]]"\n` : ""}---\n`;
}

// MARK: Profile

/** App field -> property name in the profile note. */
export const PROFILE_KEYS: Record<keyof Omit<BodyProfile, "updated">, string> = {
  heightCm: "groesse",
  birthYear: "geburtsjahr",
  sex: "geschlecht",
  bodyFat: "koerperfett",
  targetWeight: "zielgewicht",
  activity: "aktivitaet",
  weeklyRate: "tempo_kg_woche",
  proteinPerKg: "protein_pro_kg",
  fatPercent: "fettanteil",
  tolerance: "toleranz",
  checkProtein: "pruefen_protein",
  checkFat: "pruefen_fett",
  checkCarbs: "pruefen_kh",
  checkFiber: "pruefen_ballaststoffe",
  addRuns: "laeufe_addieren",
};

const NUMERIC: (keyof BodyProfile)[] = ["heightCm", "birthYear", "bodyFat", "targetWeight", "weeklyRate", "proteinPerKg", "fatPercent", "tolerance"];
const BOOLEAN: (keyof BodyProfile)[] = ["checkProtein", "checkFat", "checkCarbs", "checkFiber", "addRuns"];

export function profileToFrontmatter(fm: Frontmatter, p: BodyProfile, today: string): void {
  for (const [field, key] of Object.entries(PROFILE_KEYS) as [keyof BodyProfile, string][]) {
    const v = p[field];
    if (v === null || v === undefined) {
      if (key in fm) fm[key] = null;
    } else if (NUMERIC.includes(field)) {
      fm[key] = field === "birthYear" ? String(Math.round(v as number)) : String(v);
    } else {
      fm[key] = v;
    }
  }
  fm.aktualisiert = today;
}

function num(v: unknown): number | null {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() ? Number(v.replace(",", ".")) : NaN;
  return Number.isFinite(n) ? n : null;
}

/** Reads the note back; missing or broken values fall back to the app's defaults (null here). */
export function profileFromFrontmatter(fm: Frontmatter): BodyProfile | null {
  const height = num(fm[PROFILE_KEYS.heightCm]);
  const year = num(fm[PROFILE_KEYS.birthYear]);
  if (height === null || year === null) return null;
  const p: Record<string, unknown> = {};
  for (const [field, key] of Object.entries(PROFILE_KEYS) as [keyof BodyProfile, string][]) {
    const v = fm[key];
    if (NUMERIC.includes(field)) p[field] = num(v);
    else if (BOOLEAN.includes(field)) p[field] = v === true || v === "true";
    else p[field] = typeof v === "string" ? v.trim() : v ?? null;
  }
  if (p.sex !== "m" && p.sex !== "w") p.sex = "m";
  if (!ACTIVITIES.includes(p.activity as never)) p.activity = "maessig";
  for (const [k, d] of [["weeklyRate", 0.25], ["proteinPerKg", 1.8], ["fatPercent", 27], ["tolerance", 10]] as const) if (p[k] === null) p[k] = d;
  const u = fm.aktualisiert;
  p.updated = typeof u === "string" ? u : u instanceof Date ? u.toISOString().slice(0, 10) : null;
  return p as unknown as BodyProfile;
}

export function newProfileNote(p: BodyProfile, today: string, summary: string | null): string {
  const fm: Frontmatter = {};
  profileToFrontmatter(fm, p, today);
  const lines = Object.entries(fm).map(([k, v]) => {
    if (v === null || v === undefined) return `${k}:`;
    if (typeof v === "boolean") return `${k}: ${v}`;
    if (k === "aktualisiert" || k === "geschlecht" || k === "aktivitaet") return `${k}: ${v}`;
    return `${k}: "${v}"`;
  });
  return `---\n${lines.join("\n")}\n---\n\n${profileBody(summary, today)}`;
}

export const PROFILE_SUMMARY_START = "%% tagwerk:ziele %%";
export const PROFILE_SUMMARY_END = "%% /tagwerk:ziele %%";

export function profileBody(summary: string | null, today: string): string {
  const intro = "# Körperprofil\n\nVon der Tagwerk-App gepflegt. Die Eigenschaften oben lassen sich auch hier ändern; die App rechnet daraus die Tagesziele für Kalorien und Makronährstoffe.\n";
  return `${intro}\n${summaryBlock(summary, today)}\n`;
}

export function summaryBlock(summary: string | null, today: string): string {
  const [y, m, d] = today.split("-");
  const text = summary ? `**Tagesziele, Stand ${d}.${m}.${y}:** ${summary}` : "Noch keine Tagesziele berechnet.";
  return `${PROFILE_SUMMARY_START}\n${text}\n${PROFILE_SUMMARY_END}`;
}

export function upsertSummary(body: string, summary: string | null, today: string): string {
  const s = body.indexOf(PROFILE_SUMMARY_START);
  const e = s >= 0 ? body.indexOf(PROFILE_SUMMARY_END, s) : -1;
  const block = summaryBlock(summary, today);
  if (s >= 0 && e >= 0) return body.slice(0, s) + block + body.slice(e + PROFILE_SUMMARY_END.length);
  const trimmed = body.replace(/\s+$/, "");
  return `${trimmed ? `${trimmed}\n\n` : ""}${block}\n`;
}

