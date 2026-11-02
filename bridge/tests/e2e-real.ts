/** CI only: the real plugin code against the real GitHub API (see .github/workflows/build.yml). */
import assert from "node:assert/strict";
import { DEFAULT_FITNESS_FOLDERS } from "../src/apply";
import { Bridge, emptyState } from "../src/bridge";
import { GitHubRepo, type Http } from "../src/github";
import { DEFAULT_HABITS } from "../src/protocol";
import { FakeVault, REAL } from "./fakes";

const { E2E_TOKEN: token, E2E_REPO: repoFull, E2E_BRANCH: branch, E2E_DATE: date } = process.env;
if (!token || !repoFull || !branch || !date) throw new Error("E2E_* fehlt");
const [owner, repo] = repoFull.split("/");
const passphrase = "E2E – Passphrase äöü";

const http: Http = async (req) => {
  const r = await fetch(req.url, { method: req.method, headers: req.headers, body: req.body });
  return { status: r.status, text: await r.text() };
};

const D = "01 Leben/Daily Notes";
const vault = new FakeVault({ [`${D}/2026-10-30.md`]: REAL.daily1030, "01 Leben/Tasks/Reisepass.md": REAL.taskOpen });
const bridge = new Bridge({
  ctx: { vault, folders: { dailyFolder: D, tasksFolder: "01 Leben/Tasks", appointmentsFolder: "01 Leben/Termine", ...DEFAULT_FITNESS_FOLDERS, habits: DEFAULT_HABITS }, now: () => new Date() },
  http,
  config: () => ({ owner, repo, branch, token, passphrase, snapshotDays: 400, textDays: 60 }),
  state: emptyState(),
  saveState: async () => {},
  version: "e2e",
});

const report = await bridge.sync();
console.log(report);
assert.equal(report.processedFiles, 1, "eine Inbox-Datei verarbeitet");
assert.equal(report.appliedEvents, 6, "sechs Ereignisse übernommen");
assert.equal(report.failedEvents, 0);
assert.ok(report.snapshotPublished, "Stand veröffentlicht");
const note = vault.files.get(`${D}/${date}.md`)!;
console.log(note);
assert.match(note, /laufen: true/);
assert.match(note, /rating: "7\.1"/);
assert.match(note, /weight: "76\.4"/);
assert.match(note, /%% tagwerk:journal %%\nEnde-zu-Ende: geschrieben mit TagwerkCore, übernommen vom Plugin\.\n%% \/tagwerk:journal %%/);
const task = [...vault.files.entries()].find(([k]) => k.includes("E2E Aufgabe aus Swift"));
assert.ok(task, "Aufgabendatei angelegt");
console.log(task![1]);
const run = vault.files.get(`${DEFAULT_FITNESS_FOLDERS.runsFolder}/${date}.md`);
console.log(run);
assert.equal(run, `---\ndistance: "5.03"\ntime: 00:27:13\ntagwerk_id: swift-e2e-run\nroute: "[[${date}.gpx]]"\n---\n`, "Lauf im Format der Laufzeiten");
assert.ok(vault.files.get(`${DEFAULT_FITNESS_FOLDERS.routesFolder}/${date}.gpx`)?.includes("<gpx"), "Route abgelegt");
const food = vault.files.get(`${DEFAULT_FITNESS_FOLDERS.foodFolder}/${date}.md`)!;
console.log(food);
assert.match(food, /kcal: "438"/);
assert.match(food, /\| 12:15 \| Mittagessen \| Skyr \/ Natur \(Testmarke\) \| 250 g \| 160 \| 27,5 \| 0,5 \| 10,0 \|/);
const prof = vault.files.get(DEFAULT_FITNESS_FOLDERS.profilePath)!;
console.log(prof);
assert.match(prof, /groesse: "178"/);
assert.match(prof, /pruefen_ballaststoffe: true/);
const inbox = await new GitHubRepo(http, owner, repo, token, branch).list("inbox");
assert.equal(inbox.length, 0, "Inbox geleert");
console.log("ok  Plugin-Seite bestanden");
