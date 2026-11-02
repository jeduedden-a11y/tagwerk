import { test } from "node:test";
import assert from "node:assert/strict";
import { applyEvent, DEFAULT_FITNESS_FOLDERS, type ApplyContext } from "../src/apply";
import { findFoodBlock, profileFromFrontmatter, runSeconds, totals } from "../src/fitness";
import { splitFrontmatter } from "../src/markdown";
import { buildSnapshot } from "../src/snapshot";
import { DEFAULT_HABITS, validateEvent, type BodyProfile, type FoodEntry } from "../src/protocol";
import { FakeVault } from "./fakes";

const R = DEFAULT_FITNESS_FOLDERS.runsFolder;
const G = DEFAULT_FITNESS_FOLDERS.routesFolder;
const F = DEFAULT_FITNESS_FOLDERS.foodFolder;
const P = DEFAULT_FITNESS_FOLDERS.profilePath;
const NOW = new Date(2026, 10, 1, 19, 30, 0);

function ctxWith(files: Record<string, string>): { ctx: ApplyContext; vault: FakeVault } {
  const vault = new FakeVault(files);
  return {
    vault,
    ctx: { vault, folders: { dailyFolder: "01 Leben/Daily Notes", tasksFolder: "01 Leben/Tasks", appointmentsFolder: "01 Leben/Termine", ...DEFAULT_FITNESS_FOLDERS, habits: DEFAULT_HABITS }, now: () => NOW },
  };
}

/** The format of the existing run notes, byte for byte (values synthetic). */
const VAULT_RUN = '---\ndistance: "3.00"\ntime: 00:15:47\n---\n';

const oats: FoodEntry = { id: "e1", time: "07:40", meal: "fruehstueck", name: "Hafer Flocken", itemId: "bls:x", source: "bls", grams: 80, unit: "g", per100: { kcal: 348, protein: 13.5, fat: 6.7, carbs: 55.7, fiber: 10 } };
const skyr: FoodEntry = { id: "e2", time: "12:15", meal: "mittag", name: "Skyr | Natur", brand: "Marke", source: "barcode", grams: 250, unit: "g", per100: { kcal: 64, protein: 11, fat: 0.2, carbs: 4 } };
const targets = { kcal: 2700, protein: 140, fat: 80, carbs: 340, fiber: 30, tolerance: 10 };

const profile: BodyProfile = { heightCm: 178, birthYear: 1996, sex: "m", bodyFat: 17.5, targetWeight: 80, activity: "maessig", weeklyRate: 0.25, proteinPerKg: 1.8, fatPercent: 27, tolerance: 10, checkProtein: true, checkFat: false, checkCarbs: false, checkFiber: false, addRuns: true };

test("run.add writes the vault's run format; same day gets -2; idempotent; GPX next to it", async () => {
  const { ctx, vault } = ctxWith({ [`${R}/2026-11-01.md`]: VAULT_RUN });
  await applyEvent(ctx, { id: "r-0001-aaaa", ts: "1", type: "run.add", runId: "run-uuid-0001", date: "2026-11-01", distance: "5.02", time: "00:27:13", source: "manuell" });
  assert.equal(vault.files.get(`${R}/2026-11-01-2.md`), '---\ndistance: "5.02"\ntime: 00:27:13\ntagwerk_id: run-uuid-0001\n---\n');
  assert.equal(vault.files.get(`${R}/2026-11-01.md`), VAULT_RUN, "existing note untouched");
  await applyEvent(ctx, { id: "r-0002-aaaa", ts: "2", type: "run.add", runId: "run-uuid-0001", date: "2026-11-01", distance: "5.02", time: "00:27:13" });
  assert.equal([...vault.files.keys()].filter((k) => k.startsWith(R)).length, 2, "same runId is not written twice");

  const gpx = '<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="Tagwerk"><trk><trkseg></trkseg></trk></gpx>';
  await applyEvent(ctx, { id: "r-0003-aaaa", ts: "3", type: "run.add", runId: "run-uuid-0002", date: "2026-11-02", distance: "10.40", time: "00:55:01", source: "gps", gpx });
  assert.equal(vault.files.get(`${G}/2026-11-02.gpx`), gpx);
  assert.equal(vault.files.get(`${R}/2026-11-02.md`), '---\ndistance: "10.40"\ntime: 00:55:01\ntagwerk_id: run-uuid-0002\nroute: "[[2026-11-02.gpx]]"\n---\n');
});

test("run.patch corrects values and moves deleted runs to the trash", async () => {
  const { ctx, vault } = ctxWith({ [`${R}/2026-10-20.md`]: VAULT_RUN });
  await applyEvent(ctx, { id: "r-0010-aaaa", ts: "1", type: "run.add", runId: "run-uuid-0010", date: "2026-11-01", distance: "4.00", time: "00:22:00" });
  await applyEvent(ctx, { id: "r-0011-aaaa", ts: "2", type: "run.patch", runId: "run-uuid-0010", distance: "4.20" });
  assert.match(vault.files.get(`${R}/2026-11-01.md`)!, /distance: "4\.20"/);
  await applyEvent(ctx, { id: "r-0012-aaaa", ts: "3", type: "run.patch", path: `${R}/2026-10-20.md`, time: "00:16:01" });
  assert.equal(runSeconds(splitFrontmatter(vault.files.get(`${R}/2026-10-20.md`)!).yaml!.split("time: ")[1].trim().replace(/"/g, "")), 961);
  await applyEvent(ctx, { id: "r-0013-aaaa", ts: "4", type: "run.patch", runId: "run-uuid-0010", deleted: true });
  assert.ok(!vault.files.has(`${R}/2026-11-01.md`));
  assert.deepEqual(vault.trashed, [`${R}/2026-11-01.md`]);
  await applyEvent(ctx, { id: "r-0014-aaaa", ts: "5", type: "run.patch", runId: "run-uuid-0010", deleted: true });
  await assert.rejects(applyEvent(ctx, { id: "r-0015-aaaa", ts: "6", type: "run.patch", runId: "gibt-es-nicht", distance: "1.00" }), /Lauf nicht gefunden/);
});

test("run events are validated", () => {
  assert.throws(() => validateEvent({ id: "r-0020-aaaa", ts: "1", type: "run.add", runId: "run-uuid-0020", date: "2026-11-01", distance: "5", time: "00:20:00" }), /distance/);
  assert.throws(() => validateEvent({ id: "r-0021-aaaa", ts: "1", type: "run.add", runId: "run-uuid-0021", date: "2026-11-01", distance: "5.00", time: "20:00" }), /time/);
  assert.throws(() => validateEvent({ id: "r-0022-aaaa", ts: "1", type: "run.add", runId: "run-uuid-0022", date: "2026-11-01", distance: "5.00", time: "00:00:00" }), /time/);
  assert.throws(() => validateEvent({ id: "r-0023-aaaa", ts: "1", type: "run.add", runId: "run-uuid-0023", date: "2026-11-01", distance: "5.00", time: "00:20:00", gpx: "keine gpx" }), /gpx/);
});

test("food.day writes totals as properties and a managed block; Obsidian edits stay visible", async () => {
  const { ctx, vault } = ctxWith({});
  const p = `${F}/2026-11-01.md`;
  await applyEvent(ctx, { id: "f-0001-aaaa", ts: "1", type: "food.day", date: "2026-11-01", entries: [oats], targets, met: false });
  const c1 = vault.files.get(p)!;
  assert.ok(c1.startsWith('---\nkcal: "278"\nprotein: "10.8"\nfett: "5.4"\nkohlenhydrate: "44.6"\nballaststoffe: "8.0"\nziel_kcal: "2700"\nziel_protein: "140"\nziel_fett: "80"\nziel_kohlenhydrate: "340"\nerreicht: false\n---\n%% tagwerk:food %%\n# Ernährung 01.11.2026\n'), c1);
  assert.ok(c1.includes("| 07:40 | Frühstück | Hafer Flocken | 80 g | 278 | 10,8 | 5,4 | 44,6 |"));
  assert.ok(c1.includes("> [!warning] Ziel nicht erreicht"));
  assert.deepEqual(findFoodBlock(splitFrontmatter(c1).body)!.data!.entries, [oats]);

  // Second write: replaces the block, keeps text written below it, updates the properties
  vault.files.set(p, c1 + "\nNotiz vom PC.\n");
  await applyEvent(ctx, { id: "f-0002-aaaa", ts: "2", type: "food.day", date: "2026-11-01", entries: [oats, skyr], targets, met: true });
  const c2 = vault.files.get(p)!;
  assert.ok(c2.includes('kcal: "438"') && c2.includes("erreicht: true"), c2);
  assert.ok(c2.includes("| 12:15 | Mittagessen | Skyr / Natur (Marke) | 250 g | 160 | 27,5 | 0,5 | 10,0 |"), "pipe in names escaped");
  assert.ok(c2.includes("> [!success] Ziel erreicht"));
  assert.ok(c2.includes("Notiz vom PC."));
  assert.ok(!c2.includes("[!quote]"));
  assert.equal((c2.match(/%% tagwerk:food %%/g) ?? []).length, 1);

  // Edited inside the block in Obsidian: the old version is quoted below, nothing disappears silently
  vault.files.set(p, c2.replace("| 07:40 | Frühstück | Hafer Flocken", "| 07:45 | Frühstück | Haferflocken mit Zimt"));
  await applyEvent(ctx, { id: "f-0003-aaaa", ts: "3", type: "food.day", date: "2026-11-01", entries: [skyr], targets, met: false });
  const c3 = vault.files.get(p)!;
  assert.ok(c3.includes("> [!quote] Am PC geänderte Fassung, von der App ersetzt am 01.11.2026 19:30"));
  assert.ok(c3.includes("> | 07:45 | Frühstück | Haferflocken mit Zimt"));
  assert.ok(!c3.split("[!quote]")[0].includes("Hafer"), "new block only has the new entries");

  // Next write after that is clean again (the quote stays where it is)
  await applyEvent(ctx, { id: "f-0004-aaaa", ts: "4", type: "food.day", date: "2026-11-01", entries: [], targets, met: false });
  const c4 = vault.files.get(p)!;
  assert.equal((c4.match(/\[!quote\]/g) ?? []).length, 1);
  assert.ok(c4.includes("Keine Einträge.") && c4.includes('kcal: "0"'));

  // An empty day that has no note yet creates none
  await applyEvent(ctx, { id: "f-0005-aaaa", ts: "5", type: "food.day", date: "2026-11-02", entries: [], targets: null, met: null });
  assert.ok(!vault.files.has(`${F}/2026-11-02.md`));
});

test("food.day is validated", () => {
  const bad = { ...oats, meal: "brunch" } as unknown as FoodEntry;
  assert.throws(() => validateEvent({ id: "f-0010-aaaa", ts: "1", type: "food.day", date: "2026-11-01", entries: [bad] }), /Mahlzeit/);
  const huge = { ...oats, per100: { kcal: 5000, protein: 1, fat: 1, carbs: 1 } };
  assert.throws(() => validateEvent({ id: "f-0011-aaaa", ts: "1", type: "food.day", date: "2026-11-01", entries: [huge] }), /kcal/);
  assert.equal(Math.round(totals([oats, skyr]).kcal), 438);
});

test("profile.set writes properties, keeps the user's own ones, and reads back edits from Obsidian", async () => {
  const { ctx, vault } = ctxWith({});
  await applyEvent(ctx, { id: "p-0001-aaaa", ts: "1", type: "profile.set", profile, summary: "Grundumsatz 1.850 kcal · Ziel 2.700 kcal" });
  const c1 = vault.files.get(P)!;
  assert.ok(c1.startsWith('---\ngroesse: "178"\ngeburtsjahr: "1996"\ngeschlecht: m\nkoerperfett: "17.5"\nzielgewicht: "80"\naktivitaet: maessig\n'), c1);
  assert.ok(c1.includes("**Tagesziele, Stand 01.11.2026:** Grundumsatz 1.850 kcal · Ziel 2.700 kcal"));

  // Changed in Obsidian: own property and new body fat value
  vault.files.set(P, c1.replace('koerperfett: "17.5"', 'koerperfett: "13"').replace("---\ngroesse", "---\nnotiz: von Hand\ngroesse"));
  const back = profileFromFrontmatter(new FakeVault().parseYaml(splitFrontmatter(vault.files.get(P)!).yaml!) as Record<string, unknown>)!;
  assert.equal(back.bodyFat, 13);
  assert.equal(back.activity, "maessig");
  assert.equal(back.checkProtein, true);
  assert.equal(back.updated, "2026-11-01");

  await applyEvent(ctx, { id: "p-0002-aaaa", ts: "2", type: "profile.set", profile: { ...profile, bodyFat: null, targetWeight: 82 }, summary: "Ziel 2.800 kcal" });
  const c2 = vault.files.get(P)!;
  assert.ok(c2.includes("notiz: von Hand"), "foreign property kept");
  assert.ok(c2.includes('zielgewicht: "82"'));
  assert.ok(/koerperfett:\s*\n/.test(c2), "cleared value stays as empty property");
  assert.equal((c2.match(/tagwerk:ziele %%/g) ?? []).length, 2, "one summary block");
  assert.ok(c2.includes("Ziel 2.800 kcal") && !c2.includes("Ziel 2.700 kcal"));
  assert.throws(() => validateEvent({ id: "p-0003-aaaa", ts: "1", type: "profile.set", profile: { ...profile, heightCm: 20 } }), /heightCm/);
});

test("snapshot carries runs (vault and app), food days, profile and the feature list", async () => {
  const { ctx } = ctxWith({ [`${R}/2026-10-20.md`]: VAULT_RUN, [`${R}/Lauf Chart.canvas.md`]: "kein Lauf", [`${R}/2026-10-22.md`]: "---\ndistance:\ntime:\n---\n" });
  await applyEvent(ctx, { id: "s-0001-aaaa", ts: "1", type: "run.add", runId: "run-uuid-0100", date: "2026-10-20", distance: "8.51", time: "00:44:50", gpx: "<gpx></gpx>" });
  await applyEvent(ctx, { id: "s-0002-aaaa", ts: "2", type: "food.day", date: "2026-11-01", entries: [oats, skyr], targets, met: false });
  await applyEvent(ctx, { id: "s-0003-aaaa", ts: "3", type: "food.day", date: "2026-08-01", entries: [oats], targets, met: false });
  await applyEvent(ctx, { id: "s-0004-aaaa", ts: "4", type: "profile.set", profile });
  const snap = await buildSnapshot(ctx, { snapshotDays: 400, textDays: 60, pluginVersion: "1.1.0", applied: [], errors: [], lastIngestAt: null });
  assert.deepEqual(snap.features, ["runs", "food", "profile"]);
  assert.deepEqual(snap.runs.map((r) => [r.date, r.distanceKm, r.seconds, r.runId, r.hasRoute]), [
    ["2026-10-20", 3, 947, null, false],
    ["2026-10-20", 8.51, 2690, "run-uuid-0100", true],
  ]);
  assert.equal(snap.runs[0].id, `vault:${R}/2026-10-20.md`);
  assert.deepEqual(snap.foodDays.map((d) => d.date), ["2026-11-01"], "only recent food days travel");
  assert.equal(snap.foodDays[0].entries.length, 2);
  assert.deepEqual(snap.foodDays[0].targets, targets);
  assert.equal(snap.profile?.heightCm, 178);
  assert.equal(snap.profile?.sex, "m");
});
