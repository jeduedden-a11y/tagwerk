import { test } from "node:test";
import assert from "node:assert/strict";
import { applyEvent, DEFAULT_FITNESS_FOLDERS, type ApplyContext } from "../src/apply";
import { findLearnBlock, learnHash, upsertLearnBlock } from "../src/learn";
import { DEFAULT_HABITS, FEATURES, learnPathProblem, validateEvent, type LearnNoteEvent } from "../src/protocol";
import { FakeVault } from "./fakes";

const NOW = new Date(2026, 10, 8, 19, 30, 0); // 8 Nov 2026, local time
const P = "02 Wiki/Mathematik/11 Analysis I/Supremum und Infimum.md";
const ID = "5f0c2a8e-1b7d-4c3e-9f61-2d7a0b9c4e11";
const ID2 = "0b1d7e44-93aa-4f0c-8c55-61e2f3a9d002";
const SOURCE = "Lernwerk, Lektion »Supremum und Infimum«";
const ORIGIN = `*${SOURCE}, Stand 08.11.2026*`;

function ctxWith(files: Record<string, string>): { ctx: ApplyContext; vault: FakeVault } {
  const vault = new FakeVault(files);
  return { vault, ctx: { vault, folders: { dailyFolder: "D", tasksFolder: "T", appointmentsFolder: "A", ...DEFAULT_FITNESS_FOLDERS, habits: DEFAULT_HABITS }, now: () => NOW } };
}

let counter = 0;
function note(text: string, extra: Partial<LearnNoteEvent> = {}): LearnNoteEvent {
  counter++;
  return {
    id: `evt-learn-${String(counter).padStart(4, "0")}`,
    ts: "2026-11-08T18:30:00.000Z",
    type: "learn.note",
    path: P,
    title: "Supremum und Infimum",
    block: `lernwerk-${ID}`,
    heading: "Eigene Notizen",
    text,
    source: SOURCE,
    created: "2026-11-07",
    frontmatter: { tags: ["wiki02/Mathematik", "lernwerk"], type: "note", status: "growing" },
    ...extra,
  };
}

const blockOf = async (id: string, text: string) => {
  const inner = `${text}\n\n${ORIGIN}`;
  return `%% lernwerk:${id} ${await learnHash(inner)} %%\n${inner}\n%% /lernwerk:${id} %%`;
};

test("learn.note is announced and validated", () => {
  assert.ok((FEATURES as readonly string[]).includes("lernen"));
  assert.doesNotThrow(() => validateEvent(note("x")));
  assert.equal(learnPathProblem(P), null);
  assert.equal(learnPathProblem("02 Wiki/Ökonomik/01 Mikroökonomik/Konsumenten- und Produzentenrente.md"), null);
  for (const bad of [".obsidian/plugins/tagwerk-bridge/main.md", "../außerhalb.md", "02 Wiki/../../x.md", "/02 Wiki/x.md", "02 Wiki/x.txt", "02 Wiki//x.md", "C:/x.md", "02 Wiki/a\\b.md", "02 Wiki/ x.md"]) {
    assert.throws(() => validateEvent(note("x", { path: bad })), /path/, bad);
  }
  assert.throws(() => validateEvent(note("x", { block: "fremd-123" })), /block/);
  assert.throws(() => validateEvent(note("x", { heading: "# Notizen" })), /heading/);
  assert.throws(() => validateEvent(note("x", { created: "2026-13-01" })), /created/);
  assert.throws(() => validateEvent(note("x", { frontmatter: { tags: ["zwei Wörter"] } })), /tags/);
  assert.throws(() => validateEvent(note("x", { source: "a\nb" })), /source/);
});

test("learn.note creates a missing note in the format of the vault", async () => {
  const { ctx, vault } = ctxWith({});
  await applyEvent(ctx, note("Das Supremum muss nicht in $M$ liegen.\r\n\r\nBeispiel: $(0,1)$."));
  assert.equal(
    vault.files.get(P),
    `---
title: Supremum und Infimum
tags:
  - wiki02/Mathematik
  - lernwerk
type: note
created: 2026-11-07
updated: 2026-11-08
status: growing
---

## Eigene Notizen

${await blockOf(ID, "Das Supremum muss nicht in $M$ liegen.\n\nBeispiel: $(0,1)$.")}
`,
  );
});

const EXISTING = `---
title: Supremum und Infimum
tags:
  - wiki02/Mathematik
type: note
---

## Definition
Kleinste obere Schranke.

## Eigene Notizen

Eine Zeile, in Obsidian geschrieben.

## Quellen
- Skript, Abschnitt 2.4
`;

test("learn.note appends under the existing heading and leaves the rest of the note alone", async () => {
  const { ctx, vault } = ctxWith({ [P]: EXISTING });
  await applyEvent(ctx, note("Erste Notiz."));
  await applyEvent(ctx, note("Zweite Notiz.", { block: `lernwerk-${ID2}` }));
  const expected = EXISTING.replace(
    "Eine Zeile, in Obsidian geschrieben.\n",
    `Eine Zeile, in Obsidian geschrieben.\n\n${await blockOf(ID, "Erste Notiz.")}\n\n${await blockOf(ID2, "Zweite Notiz.")}\n`,
  );
  assert.equal(vault.files.get(P), expected);

  // An update replaces only its own block, in place.
  await applyEvent(ctx, note("Erste Notiz, überarbeitet."));
  assert.equal(vault.files.get(P), expected.replace(await blockOf(ID, "Erste Notiz."), await blockOf(ID, "Erste Notiz, überarbeitet.")));
});

test("learn.note adds the heading at the end if the note has none", async () => {
  const { ctx, vault } = ctxWith({ [P]: "---\ntitle: X\n---\n## Definition\nText.\n\n\n" });
  await applyEvent(ctx, note("Notiz."));
  assert.equal(vault.files.get(P), `---\ntitle: X\n---\n## Definition\nText.\n\n## Eigene Notizen\n\n${await blockOf(ID, "Notiz.")}\n`);
});

test("headings inside code blocks do not end the section", async () => {
  const body = "## Eigene Notizen\n\n```\n## kein Abschnitt\n```\n";
  const out = upsertLearnBlock(body, { key: ID, heading: "Eigene Notizen", inner: "Notiz.", hash: "0123456789abcdef", conflict: null });
  assert.equal(out, `${body}\n%% lernwerk:${ID} 0123456789abcdef %%\nNotiz.\n%% /lernwerk:${ID} %%\n`);
  assert.equal(findLearnBlock(out, ID)?.inner, "Notiz.");
});

test("a block edited in Obsidian stays visible as a quote when the app replaces it", async () => {
  const { ctx, vault } = ctxWith({});
  await applyEvent(ctx, note("Original."));
  vault.files.set(P, vault.files.get(P)!.replace("Original.", "Original, in Obsidian ergänzt."));
  await applyEvent(ctx, note("Neu aus der App."));
  const out = vault.files.get(P)!;
  assert.ok(out.includes(`${await blockOf(ID, "Neu aus der App.")}\n\n> [!quote] In Obsidian geänderte Fassung, von Lernwerk ersetzt am 08.11.2026 19:30\n> Original, in Obsidian ergänzt.\n>\n> ${ORIGIN}\n`), out);
  // The next update finds an unchanged block: no second quote.
  await applyEvent(ctx, note("Noch einmal neu."));
  assert.equal(vault.files.get(P)!.split("[!quote]").length, 2);
  assert.ok(vault.files.get(P)!.includes(await blockOf(ID, "Noch einmal neu.")));
});

test("an empty text removes the block, and the heading if nothing else is under it", async () => {
  const { ctx, vault } = ctxWith({ [P]: EXISTING });
  await applyEvent(ctx, note("Weg damit."));
  await applyEvent(ctx, note(""));
  assert.equal(vault.files.get(P), EXISTING);

  const fresh = ctxWith({});
  await applyEvent(fresh.ctx, note("Kurz."));
  await applyEvent(fresh.ctx, note("  "));
  const left = fresh.vault.files.get(P)!;
  assert.ok(!left.includes("lernwerk:") && !left.includes("Eigene Notizen"), left);
  assert.ok(left.startsWith("---\ntitle: Supremum und Infimum\n"));

  // Removing from a note that does not exist creates nothing.
  const none = ctxWith({});
  await applyEvent(none.ctx, note(""));
  assert.equal(none.vault.files.size, 0);
});
