import { test } from "node:test";
import assert from "node:assert/strict";
import { open } from "../src/crypto";
import { GitHubRepo } from "../src/github";
import { bucketFor, emptyWikiState, exportWiki, unpackWiki, WIKI_INDEX, type WikiBucketFile, type WikiManifest } from "../src/wiki";
import { FakeGitHub, FakeVault } from "./fakes";

const W = "02 Wiki";
const PASS = "test passphrase";
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);

function setup() {
  const vault = new FakeVault({
    [`${W}/Mathematik/Ableitung.md`]: "# Ableitung\n\n$$f'(x) = \\lim_{h \\to 0} \\frac{f(x+h)-f(x)}{h}$$\n\nSiehe [[Integral]].\n",
    [`${W}/Mathematik/Integral.md`]: "# Integral\n\n> [!tip] Merksatz\n> Fläche unter dem Graphen.\n",
    [`${W}/Mathematik/Index.md`]: "# Index\n\n```dataview\nLIST FROM \"02 Wiki/Mathematik\"\n```\n",
    [`${W}/Physik/_assets/Feld.svg`]: "<svg xmlns=\"http://www.w3.org/2000/svg\"><text fill=\"#fff\">E</text></svg>",
    [`${W}/.obsidian/x.json`]: "{}",
    [`${W}/Physik/_to_delete/Alt.md`]: "alt",
    [`${W}/Physik/Plan.canvas`]: "{}",
    "01 Leben/Privat.md": "nicht im Wiki",
  });
  vault.bins.set(`${W}/Datalinks/Bild.png`, PNG);
  const gh = new FakeGitHub();
  const repo = new GitHubRepo(gh.http, "o", "r", "test-token", "main", 1);
  const render = async (q: string) => (q.includes("LIST") ? "- [[Ableitung]]\n- [[Integral]]" : null);
  const opts = (force = false, now = new Date(2026, 10, 2, 17, 0, 0)) => ({
    folder: W, passphrase: PASS, seal: { salt: new Uint8Array(16).fill(7), iterations: 100_000 }, now, force,
  });
  return { vault, gh, repo, render, opts };
}

async function read<T>(gh: FakeGitHub, path: string): Promise<T> {
  const f = gh.files.get(path);
  assert.ok(f, `${path} fehlt`);
  return unpackWiki<T>(await open(new TextDecoder().decode(f.bytes), PASS, "wiki"));
}

test("wiki export: index, buckets, dataview rendered, private and unsupported files left out", async () => {
  const { vault, gh, repo, render, opts } = setup();
  const state = emptyWikiState();
  const r = await exportWiki(vault, repo, state, opts(), render);
  assert.equal(r.files, 5);
  const m = await read<WikiManifest>(gh, WIKI_INDEX);
  assert.equal(m.root, W);
  assert.deepEqual(m.files.map((f) => f.p), [
    "Datalinks/Bild.png", "Mathematik/Ableitung.md", "Mathematik/Index.md", "Mathematik/Integral.md", "Physik/_assets/Feld.svg",
  ]);
  assert.ok(!m.files.some((f) => f.p.includes("_to_delete") || f.p.startsWith(".obsidian") || f.p.endsWith(".canvas")));
  const index = m.files.find((f) => f.p === "Mathematik/Index.md")!;
  assert.equal(index.b, bucketFor("Mathematik/Index.md", true));
  assert.ok(index.b.startsWith("d"));
  for (const b of m.buckets) assert.ok(gh.files.has(`wiki/${b.id}.tw`), `Bucket ${b.id} hochgeladen`);

  const dv = await read<{ files: WikiBucketFile[] }>(gh, `wiki/${index.b}.tw`);
  const rendered = dv.files.find((f) => f.p === "Mathematik/Index.md")!;
  assert.match(rendered.d, /- \[\[Ableitung\]\]/);
  assert.doesNotMatch(rendered.d, /```dataview/);

  const pngInfo = m.files.find((f) => f.p === "Datalinks/Bild.png")!;
  const png = (await read<{ files: WikiBucketFile[] }>(gh, `wiki/${pngInfo.b}.tw`)).files.find((f) => f.p === "Datalinks/Bild.png")!;
  assert.equal(png.t, "b64");
  assert.deepEqual(new Uint8Array(Buffer.from(png.d, "base64")), PNG);
});

test("wiki export uploads only what changed", async () => {
  const { vault, gh, repo, render, opts } = setup();
  const state = emptyWikiState();
  await exportWiki(vault, repo, state, opts(), render);
  const puts = () => gh.calls.filter((c) => c.startsWith("PUT")).length;
  const before = puts();

  const again = await exportWiki(vault, repo, state, opts(false, new Date(2026, 10, 2, 17, 30)), render);
  assert.ok(again.skipped);
  assert.equal(puts(), before);

  vault.files.set(`${W}/Mathematik/Integral.md`, "# Integral\n\nNeu.\n");
  vault.mtimes.set(`${W}/Mathematik/Integral.md`, 5);
  const third = await exportWiki(vault, repo, state, opts(false, new Date(2026, 10, 2, 18, 0)), render);
  assert.equal(third.skipped, false);
  // The changed bucket and the index; the dataview bucket renders the same list again and is not uploaded.
  assert.equal(puts() - before, 2);
  const m = await read<WikiManifest>(gh, WIKI_INDEX);
  const b = m.files.find((f) => f.p === "Mathematik/Integral.md")!.b;
  const content = (await read<{ files: WikiBucketFile[] }>(gh, `wiki/${b}.tw`)).files.find((f) => f.p === "Mathematik/Integral.md")!;
  assert.equal(content.d, "# Integral\n\nNeu.\n");

  // Within ten minutes nothing happens unless forced.
  vault.mtimes.set(`${W}/Mathematik/Integral.md`, 6);
  const throttled = await exportWiki(vault, repo, state, { ...opts(false, new Date(2026, 10, 2, 18, 5)), minIntervalMs: 600_000 }, render);
  assert.ok(throttled.skipped);

  // An emptied bucket is deleted.
  vault.bins.delete(`${W}/Datalinks/Bild.png`);
  const pngBucket = m.files.find((f) => f.p === "Datalinks/Bild.png")!.b;
  const alone = m.files.filter((f) => f.b === pngBucket).length === 1;
  const last = await exportWiki(vault, repo, state, opts(true, new Date(2026, 10, 2, 19, 0)), render);
  if (alone) {
    assert.equal(last.deleted, 1);
    assert.ok(!gh.files.has(`wiki/${pngBucket}.tw`));
  }
  const m2 = await read<WikiManifest>(gh, WIKI_INDEX);
  assert.ok(!m2.files.some((f) => f.p === "Datalinks/Bild.png"));
});
