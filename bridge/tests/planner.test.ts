import { test } from "node:test";
import assert from "node:assert/strict";
import { applyEvent, DEFAULT_FITNESS_FOLDERS, type ApplyContext } from "../src/apply";
import { parseDays, parseSchoolNote, recurrenceOf } from "../src/planner";
import { buildSnapshot } from "../src/snapshot";
import { DEFAULT_HABITS, validateEvent, type BridgeEvent } from "../src/protocol";
import { FakeVault } from "./fakes";

const A = "01 Leben/Termine";
const S = DEFAULT_FITNESS_FOLDERS.schoolNotePath;
const NOW = new Date(2026, 10, 2, 17, 0, 0);

function setup(files: Record<string, string> = {}) {
  const vault = new FakeVault(files);
  const ctx: ApplyContext = {
    vault,
    folders: { dailyFolder: "01 Leben/Daily Notes", tasksFolder: "01 Leben/Tasks", appointmentsFolder: A, ...DEFAULT_FITNESS_FOLDERS, habits: DEFAULT_HABITS },
    now: () => NOW,
  };
  return { vault, ctx };
}
const snap = (ctx: ApplyContext) =>
  buildSnapshot(ctx, { snapshotDays: 30, textDays: 10, pluginVersion: "1.2.0", applied: [], errors: [], lastIngestAt: null });

test("weekly lecture becomes a recurring Full Calendar note and comes back in the snapshot", async () => {
  const { vault, ctx } = setup();
  await applyEvent(ctx, {
    id: "evt-uni-0001", ts: "1", type: "appointment.add", apptId: "appt-uni-1", title: "Analysis I", date: "2026-11-02",
    startTime: "10:15", endTime: "11:45", allDay: false, location: "H I", category: "uni", recur: { days: [3, 1], until: "2027-02-12" },
  });
  const path = `${A}/2026-11-02 Analysis I.md`;
  const note = vault.files.get(path)!;
  assert.match(note, /^type: recurring$/m);
  assert.match(note, /^daysOfWeek: \[M, W\]$/m);
  assert.match(note, /^startRecur: 2026-11-02$/m);
  assert.match(note, /^endRecur: 2027-02-12$/m);
  assert.match(note, /^kategorie: uni$/m);
  assert.match(note, /^quelle: Tagwerk$/m);
  assert.doesNotMatch(note, /^date:/m);
  assert.doesNotMatch(note, /type: single/);
  const s = await snap(ctx);
  const a = s.appointments.find((x) => x.apptId === "appt-uni-1")!;
  assert.deepEqual(a.recur, { days: [1, 3], until: "2027-02-12" });
  assert.equal(a.category, "uni");
  assert.equal(a.date, "2026-11-02");
  assert.equal(a.startTime, "10:15");
  assert.equal(a.location, "H I");
  assert.ok(s.features.includes("planner") && s.features.includes("wiki"));
});

test("exam with subject, then changed and deleted", async () => {
  const { vault, ctx } = setup();
  await applyEvent(ctx, {
    id: "evt-kl-0001", ts: "1", type: "appointment.add", apptId: "appt-kl-1", title: "Klausur", date: "2026-11-05",
    startTime: "13:45", endTime: "15:15", allDay: false, category: "klausur", subject: "Chemie", notes: "Redoxreaktionen, Elektrochemie",
  });
  const path = `${A}/2026-11-05 Klausur.md`;
  let note = vault.files.get(path)!;
  assert.match(note, /^fach: Chemie$/m);
  assert.match(note, /^ {2}- \/klausur$/m);
  assert.match(note, /^# Klausur \(Chemie\)$/m);
  let a = (await snap(ctx)).appointments.find((x) => x.apptId === "appt-kl-1")!;
  assert.equal(a.subject, "Chemie");
  assert.equal(a.notes, "Redoxreaktionen, Elektrochemie");

  await applyEvent(ctx, { id: "evt-kl-0002", ts: "2", type: "appointment.patch", apptId: "appt-kl-1", startTime: "09:40", endTime: "11:10", location: "A101", notes: "Nur Redox" });
  note = vault.files.get(path)!;
  assert.match(note, /^startTime: "?09:40"?$/m);
  assert.match(note, /^ort: A101$/m);
  a = (await snap(ctx)).appointments.find((x) => x.apptId === "appt-kl-1")!;
  assert.equal(a.startTime, "09:40");
  assert.equal(a.notes, "Nur Redox");

  await applyEvent(ctx, { id: "evt-kl-0003", ts: "3", type: "appointment.patch", apptId: "appt-kl-1", deleted: true });
  assert.ok(!vault.files.has(path));
  assert.deepEqual(vault.trashed, [path]);
  // Deleting again is not an error.
  await applyEvent(ctx, { id: "evt-kl-0004", ts: "4", type: "appointment.patch", apptId: "appt-kl-1", deleted: true });
});

test("own marks for lessons: set, change, clear", async () => {
  const { vault, ctx } = setup();
  const base = { ts: "1", type: "school.override" as const, key: "u:2026-11-05:13:45:ch2", date: "2026-11-05", start: "13:45", end: "15:15", subject: "Chemie" };
  await applyEvent(ctx, { ...base, id: "evt-ov-0001", state: "entfall" });
  let note = vault.files.get(S)!;
  assert.match(note, /\| Do 05\.11\.2026 \| 13:45–15:15 \| Chemie \| Entfall \|/);
  await applyEvent(ctx, { ...base, id: "evt-ov-0002", state: "abwesend", reason: "Uni" });
  await applyEvent(ctx, { ...base, id: "evt-ov-0003", key: "u:2026-11-04:07:50:en3", date: "2026-11-04", start: "07:50", end: "09:20", subject: "Englisch", state: "anwesend" });
  note = vault.files.get(S)!;
  const parsed = parseSchoolNote(note);
  assert.equal(parsed.length, 2);
  assert.equal(parsed.find((p) => p.subject === "Chemie")!.reason, "Uni");
  const s = await snap(ctx);
  assert.deepEqual(s.schoolOverrides.map((o) => o.state).sort(), ["abwesend", "anwesend"]);
  await applyEvent(ctx, { ...base, id: "evt-ov-0004", state: "clear" });
  assert.equal(parseSchoolNote(vault.files.get(S)!).length, 1);
  assert.match(vault.files.get(S)!, /\| Mi 04\.11\.2026 \| 07:50–09:20 \| Englisch \| da, trotz Termin \|/);
});

test("recurring notes written in Obsidian are read", async () => {
  const { ctx } = setup({
    [`${A}/Tutorium.md`]: "---\ntitle: Tutorium Analysis\ntype: recurring\ndaysOfWeek: [T, R]\nstartRecur: 2026-10-20\nendRecur: 2027-02-11\nstartTime: \"16:00\"\nendTime: \"18:00\"\nallDay: false\n---\n",
    [`${A}/Alt.md`]: "---\ntitle: Vorbei\ntype: recurring\ndaysOfWeek: [M]\nstartRecur: 2026-01-01\nendRecur: 2026-03-01\n---\n",
  });
  const s = await snap(ctx);
  assert.deepEqual(s.appointments.map((a) => a.title), ["Tutorium Analysis"]);
  assert.deepEqual(s.appointments[0].recur, { days: [2, 4], until: "2027-02-11" });
  assert.deepEqual(parseDays(["monday", "F"]), [1, 5]);
  assert.equal(recurrenceOf({ type: "single", date: "2026-11-02" }), null);
});

test("validation of planner events", () => {
  const bad = (ev: unknown) => assert.throws(() => validateEvent(ev as BridgeEvent));
  bad({ id: "evt-bad-0001", ts: "1", type: "appointment.add", apptId: "x", title: "A", date: "2026-11-02", allDay: true, recur: { days: [8], until: "2027-01-01" } });
  bad({ id: "evt-bad-0002", ts: "1", type: "appointment.add", apptId: "x", title: "A", date: "2026-11-02", allDay: true, recur: { days: [1], until: "2026-01-01" } });
  bad({ id: "evt-bad-0003", ts: "1", type: "appointment.add", apptId: "x", title: "A", date: "2026-11-02", allDay: true, category: "party" });
  bad({ id: "evt-bad-0004", ts: "1", type: "school.override", key: "k", date: "2026-11-02", start: "25:00", state: "entfall" });
  bad({ id: "evt-bad-0005", ts: "1", type: "school.override", key: "k", date: "2026-11-02", start: "08:00", state: "krank" });
  bad({ id: "evt-bad-0006", ts: "1", type: "appointment.patch", startTime: "08:00" });
});
