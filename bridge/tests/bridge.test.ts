import { test } from "node:test";
import assert from "node:assert/strict";
import { applyEvent, DEFAULT_FITNESS_FOLDERS, newDailyNote, yamlScalar, type ApplyContext } from "../src/apply";
import { Bridge, emptyState, SNAPSHOT_PATH, type BridgeConfig } from "../src/bridge";
import { DecryptionError, journalHash, open, seal } from "../src/crypto";
import { findJournalBlock, sanitizeFileName, splitFrontmatter, upsertJournal, bodyOutsideJournal } from "../src/markdown";
import { DEFAULT_HABITS, type InboxBatch, type Snapshot } from "../src/protocol";
import { FakeGitHub, FakeVault, REAL } from "./fakes";

const D = "01 Leben/Daily Notes";
const T = "01 Leben/Tasks";
const A = "01 Leben/Termine";
const NOW = new Date(2026, 10, 1, 17, 5, 0); // 1 Nov 2026, local time

function ctxWith(files: Record<string, string>): { ctx: ApplyContext; vault: FakeVault } {
  const vault = new FakeVault(files);
  return { vault, ctx: { vault, folders: { dailyFolder: D, tasksFolder: T, appointmentsFolder: A, ...DEFAULT_FITNESS_FOLDERS, habits: DEFAULT_HABITS }, now: () => NOW } };
}

const ITER = 100_000;
const SALT = new Uint8Array(16).fill(7);

test("crypto round trip, wrong passphrase, wrong kind, tampering", async () => {
  const env = await seal('{"a":"Ä"}', "geheim Ä", "inbox", { salt: SALT, iterations: ITER });
  assert.equal(await open(env, "geheim Ä", "inbox"), '{"a":"Ä"}');
  // NFD input must derive the same key as NFC
  assert.equal(await open(env, "geheim Ä", "inbox"), '{"a":"Ä"}');
  await assert.rejects(open(env, "falsch", "inbox"), DecryptionError);
  await assert.rejects(open(env, "geheim Ä", "snapshot"), DecryptionError);
  const e = JSON.parse(env);
  e.k = "snapshot"; // kind is bound through AAD, flipping it must fail
  await assert.rejects(open(JSON.stringify(e), "geheim Ä", "snapshot"), DecryptionError);
});

test("journal hash normalisation", async () => {
  assert.equal(await journalHash(""), "");
  assert.equal(await journalHash("  \n "), "");
  assert.equal(await journalHash("a\r\nb\n"), await journalHash("a\nb"));
  assert.equal((await journalHash("x")).length, 16);
});

test("markdown helpers", () => {
  const s = splitFrontmatter(REAL.daily0818);
  assert.ok(s.yaml!.includes('rating: "8.4"'));
  assert.equal(s.body, "Kinoabend mit Sam");
  const b1 = upsertJournal(s.body, "Heute gut.", null);
  assert.equal(b1, "Kinoabend mit Sam\n\n%% tagwerk:journal %%\nHeute gut.\n%% /tagwerk:journal %%\n");
  assert.equal(findJournalBlock(b1)!.text, "Heute gut.");
  assert.equal(bodyOutsideJournal(b1), "Kinoabend mit Sam");
  const b2 = upsertJournal(b1, "Neu.", "Alt");
  assert.ok(b2.includes("%% tagwerk:journal %%\nNeu.\n%% /tagwerk:journal %%\n\n> [!quote] Alt\n> Heute gut."));
  assert.equal(sanitizeFileName('Mathe: "Klausur" / Q3?'), "Mathe Klausur Q3");
  assert.equal(sanitizeFileName("..."), "Aufgabe");
  assert.equal(yamlScalar("Praktikum - Bewerbung absenden"), "Praktikum - Bewerbung absenden");
  assert.equal(yamlScalar("Mathe: Klausur"), '"Mathe: Klausur"');
  assert.equal(yamlScalar("2026-11-01 Termin"), '"2026-11-01 Termin"');
  assert.equal(yamlScalar("true"), '"true"');
});

test("day.patch on an existing note keeps format and other fields", async () => {
  const { ctx, vault } = ctxWith({ [`${D}/2026-08-18.md`]: REAL.daily0818 });
  await applyEvent(ctx, { id: "evt-00000001", ts: "2026-08-18T20:00:00Z", type: "day.patch", date: "2026-08-18", habits: { gym: true }, rating: "7.9", ratingAI: "7.9", ratingSource: "ai", ratingReason: "Kino mit Sam, Schreiben erledigt.", weight: "72.4" });
  const out = vault.files.get(`${D}/2026-08-18.md`)!;
  assert.equal(out, `---
tags:
  - /dailynotes
reading: false
writing: true
gym: true
food: true
laufen: false
rating: "7.9"
weight: "72.4"
rating_ai: "7.9"
rating_source: ai
rating_reason: Kino mit Sam, Schreiben erledigt.
---
Kinoabend mit Sam`);
});

test("day.patch creates a missing note in the vault's own key order", async () => {
  const { ctx, vault } = ctxWith({});
  assert.equal(newDailyNote(DEFAULT_HABITS), "---\ntags:\n  - /dailynotes\nreading: false\nwriting: false\ngym: false\nfood: false\nlaufen: false\nrating:\nweight:\n---\n");
  await applyEvent(ctx, { id: "evt-00000002", ts: "2026-11-01T08:00:00Z", type: "day.patch", date: "2026-11-01", habits: { laufen: true } });
  assert.equal(vault.files.get(`${D}/2026-11-01.md`), "---\ntags:\n  - /dailynotes\nreading: false\nwriting: false\ngym: false\nfood: false\nlaufen: true\nrating:\nweight:\n---\n");
});

test("day.journal insert, update, conflict copy, removal", async () => {
  const { ctx, vault } = ctxWith({ [`${D}/2026-08-18.md`]: REAL.daily0818 });
  const p = `${D}/2026-08-18.md`;
  await applyEvent(ctx, { id: "evt-j1-0000", ts: "1", type: "day.journal", date: "2026-08-18", text: "Erster Text", baseHash: null });
  assert.ok(vault.files.get(p)!.endsWith("Kinoabend mit Sam\n\n%% tagwerk:journal %%\nErster Text\n%% /tagwerk:journal %%\n"));
  assert.ok(vault.files.get(p)!.startsWith(REAL.daily0818.split("Kinoabend")[0]), "frontmatter untouched byte for byte");

  const h1 = await journalHash("Erster Text");
  await applyEvent(ctx, { id: "evt-j2-0000", ts: "2", type: "day.journal", date: "2026-08-18", text: "Zweiter Text", baseHash: h1 });
  assert.ok(vault.files.get(p)!.includes("%% tagwerk:journal %%\nZweiter Text\n%% /tagwerk:journal %%"));
  assert.ok(!vault.files.get(p)!.includes("[!quote]"));

  // Edited in Obsidian meanwhile, app still holds the old hash -> conflict copy stays visible
  vault.files.set(p, vault.files.get(p)!.replace("Zweiter Text", "Am PC ergänzt"));
  await applyEvent(ctx, { id: "evt-j3-0000", ts: "3", type: "day.journal", date: "2026-08-18", text: "Dritter Text", baseHash: await journalHash("Zweiter Text") });
  const c = vault.files.get(p)!;
  assert.ok(c.includes("%% tagwerk:journal %%\nDritter Text\n%% /tagwerk:journal %%"));
  assert.ok(c.includes("> [!quote] Frühere Fassung aus Obsidian, in der App ersetzt am 01.11.2026 17:05\n> Am PC ergänzt"));

  // Empty text removes the block, the rest stays
  await applyEvent(ctx, { id: "evt-j4-0000", ts: "4", type: "day.journal", date: "2026-08-18", text: "", baseHash: await journalHash("Dritter Text") });
  const r = vault.files.get(p)!;
  assert.ok(!r.includes("tagwerk:journal"));
  assert.ok(r.includes("Kinoabend mit Sam"));
});

test("task.create, task.patch by id and by path", async () => {
  const { ctx, vault } = ctxWith({ [`${T}/Reisepass.md`]: REAL.taskOpen, [`${T}/Reisegeld.md`]: REAL.taskNoDate });
  await applyEvent(ctx, { id: "evt-t1-0000", ts: "1", type: "task.create", taskId: "task-uuid-1", title: "Mathe: Klausur vorbereiten", created: "2026-11-01", date: "2026-11-12", wichtig: true, notes: "Analysis, Kapitel 3" });
  assert.equal(vault.files.get(`${T}/Mathe Klausur vorbereiten.md`), `---
title: "Mathe: Klausur vorbereiten"
created: 2026-11-01
date: 2026-11-12
allDay: true
completed: false
wichtig: true
tagwerk_id: task-uuid-1
---

# Mathe: Klausur vorbereiten

Analysis, Kapitel 3
`);
  // Same title again -> numbered file; same taskId again -> ignored
  await applyEvent(ctx, { id: "evt-t2-0000", ts: "2", type: "task.create", taskId: "task-uuid-2", title: "Mathe: Klausur vorbereiten", created: "2026-11-01", wichtig: false });
  assert.ok(vault.files.has(`${T}/Mathe Klausur vorbereiten (2).md`));
  assert.ok(!vault.files.get(`${T}/Mathe Klausur vorbereiten (2).md`)!.includes("allDay"));
  await applyEvent(ctx, { id: "evt-t3-0000", ts: "3", type: "task.create", taskId: "task-uuid-2", title: "Doppelt", created: "2026-11-01", wichtig: false });
  assert.ok(!vault.files.has(`${T}/Doppelt.md`));

  await applyEvent(ctx, { id: "evt-t4-0000", ts: "4", type: "task.patch", taskId: "task-uuid-1", completed: true, date: null });
  const t1 = vault.files.get(`${T}/Mathe Klausur vorbereiten.md`)!;
  assert.ok(t1.includes("completed: true") && !t1.includes("date:") && !t1.includes("allDay"));

  await applyEvent(ctx, { id: "evt-t5-0000", ts: "5", type: "task.patch", path: `${T}/Reisepass.md`, completed: true, title: "Reisepass abholen" });
  const t2 = vault.files.get(`${T}/Reisepass.md`)!;
  assert.ok(t2.includes("completed: true") && t2.includes("title: Reisepass abholen") && t2.includes("# Reisepass abholen") && t2.includes("Beim Amt nachfragen."));

  await assert.rejects(applyEvent(ctx, { id: "evt-t6-0000", ts: "6", type: "task.patch", taskId: "nope", completed: true }), /nicht gefunden/);
});

test("appointment.add writes a Full-Calendar compatible note", async () => {
  const { ctx, vault } = ctxWith({});
  await applyEvent(ctx, { id: "evt-a1-0000", ts: "1", type: "appointment.add", apptId: "appt-1", title: "Teamsitzung", date: "2026-11-12", startTime: "13:30", endTime: "15:00", allDay: false, location: "Raum 204", source: { mailbox: "Schule", from: "Frau Beispiel <sv@schule.example>", subject: "Einladung: Teamsitzung am 12.11.", receivedAt: "2026-11-01T10:03:00Z" } });
  const c = vault.files.get(`${A}/2026-11-12 Teamsitzung.md`)!;
  assert.ok(c.startsWith(`---
title: Teamsitzung
date: 2026-11-12
startTime: "13:30"
endTime: "15:00"
allDay: false
type: single
ort: Raum 204
quelle: E-Mail
postfach: Schule
von: "Frau Beispiel <sv@schule.example>"
betreff: "Einladung: Teamsitzung am 12.11."
erfasst: 2026-11-01
tagwerk_id: appt-1
tags:
  - /termine
---

# Teamsitzung
`), c);
  assert.ok(c.includes("> [!info] Aus einer E-Mail übernommen"));
});

function cfg(pass = "Passphrase für Tests"): BridgeConfig {
  return { owner: "demo", repo: "tagwerk-daten", branch: "main", token: "test-token", passphrase: pass, snapshotDays: 400, textDays: 60, iterations: ITER };
}

async function inboxFile(gh: FakeGitHub, name: string, batch: InboxBatch, pass = "Passphrase für Tests") {
  const env = await seal(JSON.stringify(batch), pass, "inbox", { salt: new Uint8Array(16).fill(3), iterations: ITER });
  gh.put(`inbox/${name}`, new TextEncoder().encode(env));
}

test("end to end: inbox -> vault -> snapshot, idempotent, ack", async () => {
  const { ctx, vault } = ctxWith({
    [`${D}/2026-10-30.md`]: REAL.daily1030 + "Abends Kino.",
    [`${D}/2026-08-18.md`]: REAL.daily0818,
    [`${D}/TEMPLATE.md`]: REAL.template,
    [`${T}/Passfotoabholen.md`]: REAL.task,
    [`${T}/Reisepass.md`]: REAL.taskOpen,
  });
  const gh = new FakeGitHub();
  const state = emptyState();
  let saves = 0;
  const bridge = new Bridge({ ctx, http: gh.http, config: () => cfg(), state, saveState: async () => { saves++; }, version: "1.0.0", retryDelayMs: 1 });

  const batch: InboxBatch = {
    schema: 1, device: "iPhone", createdAt: "2026-11-01T16:00:00Z",
    events: [
      { id: "e-0002-aaaa", ts: "2026-11-01T16:00:02Z", type: "day.patch", date: "2026-11-01", rating: "6.8", ratingAI: "6.8", ratingSource: "ai", ratingReason: "Gelaufen, guter Tag." },
      { id: "e-0001-aaaa", ts: "2026-11-01T16:00:01Z", type: "day.patch", date: "2026-11-01", habits: { laufen: true, food: true } },
      { id: "e-0003-aaaa", ts: "2026-11-01T16:00:03Z", type: "day.journal", date: "2026-11-01", text: "5 km gelaufen.", baseHash: null },
      { id: "e-0004-aaaa", ts: "2026-11-01T16:00:04Z", type: "task.create", taskId: "tid-1", title: "Reise bezahlen", created: "2026-11-01", date: "2026-11-03", wichtig: true },
      { id: "e-0005-aaaa", ts: "2026-11-01T16:00:05Z", type: "task.patch", path: `${T}/Reisepass.md`, completed: true },
      { id: "e-0006-aaaa", ts: "2026-11-01T16:00:06Z", type: "task.patch", taskId: "gibt-es-nicht", completed: true },
    ],
  };
  await inboxFile(gh, "2026-11-01T16-00-06Z_a1.tw", batch);

  const r1 = await bridge.sync();
  assert.equal(r1.processedFiles, 1);
  assert.equal(r1.appliedEvents, 5);
  assert.equal(r1.failedEvents, 1);
  assert.equal(r1.ok, false);
  assert.ok(r1.snapshotPublished);
  assert.ok(![...gh.files.keys()].some((k) => k.startsWith("inbox/")), "inbox emptied");
  assert.ok(saves > 0);

  const note = vault.files.get(`${D}/2026-11-01.md`)!;
  assert.ok(note.includes("laufen: true") && note.includes("food: true") && note.includes('rating: "6.8"') && note.includes("rating_source: ai"));
  assert.ok(note.includes("%% tagwerk:journal %%\n5 km gelaufen.\n%% /tagwerk:journal %%"));
  assert.ok(vault.files.get(`${T}/Reisepass.md`)!.includes("completed: true"));
  assert.ok(vault.files.has(`${T}/Reise bezahlen.md`));

  const snapEnv = new TextDecoder().decode(gh.files.get(SNAPSHOT_PATH)!.bytes);
  const snap = JSON.parse(await open(snapEnv, cfg().passphrase, "snapshot")) as Snapshot;
  assert.equal(snap.schema, 1);
  assert.deepEqual(snap.days.map((d) => d.date), ["2026-11-01", "2026-10-30", "2026-08-18"]);
  const today = snap.days[0];
  assert.deepEqual(today.habits, { reading: false, writing: false, gym: false, food: true, laufen: true });
  assert.equal(today.rating, "6.8");
  assert.equal(today.ratingSource, "ai");
  assert.equal(today.journal, "5 km gelaufen.");
  assert.equal(today.journalHash, await journalHash("5 km gelaufen."));
  assert.equal(snap.days[1].note, "Abends Kino.");
  assert.equal(snap.days[2].note, null, "text only inside the textDays window");
  assert.equal(snap.days[2].hasText, false);
  assert.equal(snap.days[1].hasText, true);
  assert.equal(snap.days[2].rating, "8.4", "fields for older days still travel");
  assert.equal(snap.days[1].weight, null);
  assert.ok(snap.applied.includes("e-0001-aaaa") && snap.applied.includes("e-0006-aaaa"));
  assert.equal(snap.errors.length, 1);
  assert.match(snap.errors[0].message, /nicht gefunden/);
  const kb = snap.tasks.find((t) => t.title === "Reise bezahlen")!;
  assert.equal(kb.taskId, "tid-1");
  assert.equal(kb.date, "2026-11-03");
  assert.equal(snap.tasks[0].completed, false, "open tasks first");

  // Same events again (e.g. app retried after a lost response): nothing is applied twice
  const before = vault.files.get(`${D}/2026-11-01.md`);
  await inboxFile(gh, "2026-11-01T16-05-00Z_a2.tw", batch);
  const r2 = await bridge.sync();
  assert.equal(r2.appliedEvents, 0);
  assert.equal(r2.processedFiles, 1);
  assert.equal(vault.files.get(`${D}/2026-11-01.md`), before);

  // No changes -> no new snapshot commit
  const puts = gh.calls.filter((c) => c === `PUT ${SNAPSHOT_PATH}`).length;
  const r3 = await bridge.sync();
  assert.equal(r3.snapshotPublished, false);
  assert.equal(gh.calls.filter((c) => c === `PUT ${SNAPSHOT_PATH}`).length, puts);
});

test("wrong passphrase keeps the inbox file and reports", async () => {
  const { ctx } = ctxWith({});
  const gh = new FakeGitHub();
  const bridge = new Bridge({ ctx, http: gh.http, config: () => cfg("andere"), state: emptyState(), saveState: async () => {}, version: "1", retryDelayMs: 1 });
  await inboxFile(gh, "x.tw", { schema: 1, device: "iPhone", createdAt: "", events: [] });
  const r = await bridge.sync();
  assert.equal(r.ok, false);
  assert.match(r.message, /Passphrase/);
  assert.ok(gh.files.has("inbox/x.tw"));
});

test("stale snapshot sha is recovered", async () => {
  const { ctx } = ctxWith({ [`${D}/2026-10-30.md`]: REAL.daily1030 });
  const gh = new FakeGitHub();
  gh.put(SNAPSHOT_PATH, new TextEncoder().encode("{}"));
  const state = emptyState();
  state.lastSnapshotSha = "veraltet";
  const bridge = new Bridge({ ctx, http: gh.http, config: () => cfg(), state, saveState: async () => {}, version: "1", retryDelayMs: 1 });
  const r = await bridge.sync({ forceSnapshot: true });
  assert.ok(r.snapshotPublished);
  assert.notEqual(state.lastSnapshotSha, "veraltet");
});

test("bad token gives a clear message", async () => {
  const { ctx } = ctxWith({});
  const gh = new FakeGitHub();
  const bridge = new Bridge({ ctx, http: gh.http, config: () => ({ ...cfg(), token: "kaputt" }), state: emptyState(), saveState: async () => {}, version: "1", retryDelayMs: 1 });
  await assert.rejects(bridge.sync(), /Token/);
});
