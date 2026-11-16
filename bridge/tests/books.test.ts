import { test } from "node:test";
import assert from "node:assert/strict";
import yaml from "js-yaml";
import { applyEvent, DEFAULT_FITNESS_FOLDERS, type ApplyContext } from "../src/apply";
import { bookCoverName, bookNotePath, cardHasIsbn } from "../src/books";
import { open } from "../src/crypto";
import { GitHubRepo } from "../src/github";
import { splitFrontmatter } from "../src/markdown";
import { DEFAULT_HABITS, FEATURES, isIsbn13, validateEvent, type BookAddEvent } from "../src/protocol";
import { emptyWikiState, exportWiki, unpackWiki, WIKI_INDEX, type WikiManifest } from "../src/wiki";
import { FakeGitHub, FakeVault } from "./fakes";

const NOW = new Date(2026, 10, 16, 18, 0, 0);
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
const COVER_B64 = Buffer.from(JPEG).toString("base64");

function ctxWith(files: Record<string, string>): { ctx: ApplyContext; vault: FakeVault } {
  const vault = new FakeVault(files);
  return { vault, ctx: { vault, folders: { dailyFolder: "D", tasksFolder: "T", appointmentsFolder: "A", ...DEFAULT_FITNESS_FOLDERS, habits: DEFAULT_HABITS }, now: () => NOW } };
}

let counter = 0;
function book(extra: Partial<BookAddEvent> = {}): BookAddEvent {
  counter++;
  return {
    id: `evt-book-${String(counter).padStart(4, "0")}`,
    ts: "2026-11-16T17:00:00.000Z",
    type: "book.add",
    isbn13: "9780441172719",
    isbn10: "0441172717",
    title: "Dune",
    author: "Frank Herbert",
    description: "Arrakis, the desert planet.",
    pages: 604,
    publisher: "Ace",
    published: "2005/08/02",
    categories: ["Science Fiction", "Classics"],
    link: "https://openlibrary.org/isbn/9780441172719",
    cover: COVER_B64,
    ...extra,
  };
}

test("book.add is announced, and ISBNs and fields are validated", () => {
  assert.ok((FEATURES as readonly string[]).includes("buecher"));
  for (const ok of ["9780441172719", "9780141036144", "9780226320618"]) assert.ok(isIsbn13(ok), ok);
  for (const bad of ["9780441172710", "1234567890123", "978044117271", "97804411727190", "abc", 9780441172719]) assert.ok(!isIsbn13(bad), String(bad));
  assert.doesNotThrow(() => validateEvent(book()));
  assert.doesNotThrow(() => validateEvent(book({ cover: null, isbn10: null, pages: null, categories: null })));
  assert.throws(() => validateEvent(book({ isbn13: "9780441172710" })), /isbn13/);
  assert.throws(() => validateEvent(book({ isbn10: "12" })), /isbn10/);
  assert.throws(() => validateEvent(book({ title: " " })), /title/);
  assert.throws(() => validateEvent(book({ author: "a\nb" })), /author/);
  assert.throws(() => validateEvent(book({ pages: 0 })), /pages/);
  assert.throws(() => validateEvent(book({ categories: ["a, b"] })), /categories/);
  assert.throws(() => validateEvent(book({ cover: "not base64!" })), /cover/);
});

test("file names follow the book-search plugin", () => {
  const rodrik = { title: "Economics Rules: The Rights and Wrongs of the Dismal Science", author: "Dani Rodrik" };
  assert.equal(bookNotePath("Bücher", rodrik), "Bücher/Economics Rules The Rights and Wrongs of the Dismal Science - Dani Rodrik.md");
  assert.equal(bookCoverName(rodrik), "Economics Rules The Rights and Wrongs of the Dismal Science — Dani Rodrik.jpg");
  const hegel = { title: "Phänomenologie des Geistes Reclams Universal-Bibliothek", author: "Georg W. Bertram" };
  assert.equal(bookNotePath("Bücher/", hegel), "Bücher/Phänomenologie des Geistes Reclams Universal-Bibliothek - Georg W Bertram.md");
  assert.equal(bookCoverName(hegel), "Phänomenologie des Geistes Reclams Universal-Bibliothek — Georg W. Bertram.jpg");
  const faust = { title: "Faust. Der Tragödie Erster Teil", author: "Johann Wolfgang von Goethe" };
  assert.equal(bookNotePath("Bücher", faust), "Bücher/Faust Der Tragödie Erster Teil - Johann Wolfgang von Goethe.md");
  assert.equal(bookCoverName(faust), "Faust. Der Tragödie Erster Teil — Johann Wolfgang von Goethe.jpg");
});

test("book.add writes the card and the cover", async () => {
  const { ctx, vault } = ctxWith({});
  await applyEvent(ctx, book());
  const path = "Bücher/Dune - Frank Herbert.md";
  const note = await vault.read(path);
  const fm = yaml.load(splitFrontmatter(note).yaml ?? "", { schema: yaml.CORE_SCHEMA }) as Record<string, unknown>;
  assert.equal(fm["Title"], "Dune");
  assert.equal(fm["Author"], "Frank Herbert");
  assert.equal(fm["isbn 13"], "9780441172719");
  assert.equal(fm["isbn 10"], "0441172717");
  assert.equal(fm["Total Pages"], "604");
  assert.equal(fm["Publisher"], "Ace");
  assert.equal(fm["Categories"], "Science Fiction, Classics");
  assert.equal(fm["Cover"], "[[Dune — Frank Herbert.jpg]]");
  assert.equal(fm["Read"], false);
  assert.equal(fm["Date read"], "");
  assert.deepEqual(fm["Tags"], ["frank_herbert", "dune"]);
  assert.deepEqual(vault.bins.get("Cover/Dune — Frank Herbert.jpg"), JPEG);
});

test("book.add quotes values YAML would misread and works without a cover", async () => {
  const { ctx, vault } = ctxWith({});
  await applyEvent(ctx, book({
    isbn13: "9780226320618",
    isbn10: null,
    title: "Economics Rules: The Rights and Wrongs",
    author: "Dani Rodrik",
    description: 'He said "no".\nSecond line.',
    cover: null,
    pages: null,
    published: null,
    categories: null,
  }));
  const note = await vault.read("Bücher/Economics Rules The Rights and Wrongs - Dani Rodrik.md");
  const fm = yaml.load(splitFrontmatter(note).yaml ?? "", { schema: yaml.CORE_SCHEMA }) as Record<string, unknown>;
  assert.equal(fm["Title"], "Economics Rules: The Rights and Wrongs");
  assert.equal(fm["Description"], 'He said "no". Second line.');
  assert.equal(fm["Cover"], "");
  assert.equal(fm["Total Pages"], "");
  assert.equal(vault.bins.size, 0);
});

test("book.add leaves a book alone that is in the folder already", async () => {
  const card = '---\nTitle: Dune\nAuthor: Frank Herbert\nisbn 10: "0441172717"\nisbn 13: "9780441172719"\nRead: true\n---\n';
  const { ctx, vault } = ctxWith({ "Bücher/Dune - Frank Herbert.md": card });
  await applyEvent(ctx, book());
  assert.equal(await vault.read("Bücher/Dune - Frank Herbert.md"), card);
  assert.equal(vault.bins.size, 0);
  // the card of another book does not block the new one
  const { ctx: ctx2, vault: vault2 } = ctxWith({ "Bücher/Anderes.md": '---\nisbn 13: "9780141036144"\n---\n' });
  await applyEvent(ctx2, book());
  assert.ok(vault2.files.has("Bücher/Dune - Frank Herbert.md"));
  // sending the same event twice (retry) does not duplicate anything
  await applyEvent(ctx2, book());
  assert.equal([...vault2.files.keys()].filter((k) => k.startsWith("Bücher/")).length, 2);
  assert.ok(cardHasIsbn(card, "9780441172719", null));
  assert.ok(cardHasIsbn(card, "9780000000002", "0441172717"));
  assert.ok(!cardHasIsbn(card, "9780141036144", null));
});

test("wiki copy takes the book folders along and keeps the inbox in the vault", async () => {
  const vault = new FakeVault({
    "02 Wiki/Mathematik/Ableitung.md": "# Ableitung\n",
    "02 Wiki/Physik/Kraft.md": "# Kraft\n",
    "Bücher/Dune - Frank Herbert.md": "---\nTitle: Dune\n---\n",
    "Bücher/_Inbox/Dune.txt": "Volltext, bleibt im Vault",
    "Bücher/.versteckt.md": "x",
    "Physik/Fremd.md": "gleicher Ordnername wie im Wiki: wird übersprungen",
    "01 Leben/Privat.md": "nicht dabei",
  });
  vault.bins.set("Cover/Dune — Frank Herbert.jpg", JPEG);
  vault.bins.set("Cover/_alt/Alt.jpg", JPEG);
  const gh = new FakeGitHub();
  const repo = new GitHubRepo(gh.http, "o", "r", "test-token", "main", 1);
  const opts = { folder: "02 Wiki", extraFolders: ["Bücher", "Cover", "Physik", "Gibt es nicht", ""], passphrase: "pw", seal: { salt: new Uint8Array(16).fill(7), iterations: 100_000 }, now: NOW, force: false };
  const r = await exportWiki(vault, repo, emptyWikiState(), opts);
  assert.equal(r.files, 4);
  const index = gh.files.get(WIKI_INDEX);
  assert.ok(index);
  const m = await unpackWiki<WikiManifest>(await open(new TextDecoder().decode(index.bytes), "pw", "wiki"));
  assert.equal(m.root, "02 Wiki");
  assert.deepEqual(m.files.map((f) => f.p), [
    "Bücher/Dune - Frank Herbert.md",
    "Cover/Dune — Frank Herbert.jpg",
    "Mathematik/Ableitung.md",
    "Physik/Kraft.md",
  ]);
});
