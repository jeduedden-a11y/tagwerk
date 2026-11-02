import yaml from "js-yaml";
import { splitFrontmatter } from "../src/markdown";
import type { Frontmatter, VaultFileStat, VaultPort } from "../src/vault";
import type { Http, HttpRequest, HttpResponse } from "../src/github";
import { createHash } from "node:crypto";

/** In-memory vault. processFrontMatter round-trips YAML like Obsidian does (core schema, empty for null). */
export class FakeVault implements VaultPort {
  files = new Map<string, string>();
  constructor(initial: Record<string, string> = {}) {
    for (const [k, v] of Object.entries(initial)) this.files.set(k, v);
  }
  async exists(p: string) { return this.files.has(p); }
  async read(p: string) {
    const c = this.files.get(p);
    if (c === undefined) throw new Error(`missing ${p}`);
    return c;
  }
  async create(p: string, c: string) {
    if (this.files.has(p)) throw new Error(`exists ${p}`);
    this.files.set(p, c);
  }
  async process(p: string, fn: (c: string) => string) { this.files.set(p, fn(await this.read(p))); }
  async processFrontMatter(p: string, fn: (fm: Frontmatter) => void) {
    const content = await this.read(p);
    const s = splitFrontmatter(content);
    const fm = (s.yaml ? (yaml.load(s.yaml, { schema: yaml.CORE_SCHEMA }) as Frontmatter) : {}) ?? {};
    fn(fm);
    const dumped = yaml
      .dump(fm, { schema: yaml.CORE_SCHEMA, quotingType: '"', lineWidth: -1 })
      .replace(/: null$/gm, ":")
      .trimEnd();
    this.files.set(p, `---\n${dumped}\n---\n${s.body}`);
  }
  async list(folder: string) {
    return [...this.files.keys()].filter((k) => k.startsWith(`${folder}/`) && !k.slice(folder.length + 1).includes("/") && k.endsWith(".md"));
  }
  parseYaml(y: string) { return yaml.load(y, { schema: yaml.CORE_SCHEMA }); }
  /** Binary files (images); text files live in files. */
  bins = new Map<string, Uint8Array>();
  mtimes = new Map<string, number>();
  async listFiles(folder: string): Promise<VaultFileStat[]> {
    const keys = [...this.files.keys(), ...this.bins.keys()].filter((k) => k.startsWith(`${folder}/`));
    return keys.map((k) => ({
      path: k,
      mtime: this.mtimes.get(k) ?? 1,
      size: this.bins.get(k)?.length ?? new TextEncoder().encode(this.files.get(k) ?? "").length,
    }));
  }
  async readBinary(p: string) {
    const b = this.bins.get(p);
    if (b) return b;
    return new TextEncoder().encode(await this.read(p));
  }
  trashed: string[] = [];
  async trash(p: string) {
    if (!this.files.delete(p)) throw new Error(`missing ${p}`);
    this.trashed.push(p);
  }
}

/** In-memory GitHub Contents API. */
export class FakeGitHub {
  files = new Map<string, { sha: string; bytes: Uint8Array }>();
  calls: string[] = [];
  failNextPutWith: number | null = null;

  private sha(bytes: Uint8Array) { return createHash("sha1").update(bytes).update(String(Math.random())).digest("hex"); }

  put(path: string, bytes: Uint8Array) { this.files.set(path, { sha: this.sha(bytes), bytes }); }

  http: Http = async (req: HttpRequest): Promise<HttpResponse> => {
    const u = new URL(req.url);
    const m = /^\/repos\/([^/]+)\/([^/]+)\/contents\/?(.*)$/.exec(u.pathname);
    if (!m) return { status: 404, text: "{}" };
    const path = decodeURIComponent(m[3]);
    this.calls.push(`${req.method} ${path}`);
    if (req.headers.Authorization !== "Bearer test-token") return { status: 401, text: '{"message":"Bad credentials"}' };
    if (req.method === "GET") {
      const f = this.files.get(path);
      if (f) return { status: 200, text: JSON.stringify({ sha: f.sha, encoding: "base64", content: Buffer.from(f.bytes).toString("base64").replace(/(.{60})/g, "$1\n") }) };
      const prefix = path ? `${path}/` : "";
      const children = [...this.files.entries()].filter(([k]) => k.startsWith(prefix) && !k.slice(prefix.length).includes("/"));
      if (children.length || path === "") {
        return { status: 200, text: JSON.stringify(children.map(([k, v]) => ({ name: k.slice(prefix.length), path: k, sha: v.sha, size: v.bytes.length, type: "file" }))) };
      }
      return { status: 404, text: '{"message":"Not Found"}' };
    }
    if (req.method === "PUT") {
      if (this.failNextPutWith) { const s = this.failNextPutWith; this.failNextPutWith = null; return { status: s, text: '{"message":"conflict"}' }; }
      const body = JSON.parse(req.body!);
      const existing = this.files.get(path);
      if (existing && body.sha !== existing.sha) return { status: 409, text: '{"message":"sha mismatch"}' };
      if (!existing && body.sha) return { status: 422, text: '{"message":"sha given for new file"}' };
      const bytes = new Uint8Array(Buffer.from(body.content, "base64"));
      const sha = this.sha(bytes);
      this.files.set(path, { sha, bytes });
      return { status: existing ? 200 : 201, text: JSON.stringify({ content: { sha, path } }) };
    }
    if (req.method === "DELETE") {
      const body = JSON.parse(req.body!);
      const existing = this.files.get(path);
      if (!existing) return { status: 404, text: "{}" };
      if (existing.sha !== body.sha) return { status: 409, text: "{}" };
      this.files.delete(path);
      return { status: 200, text: "{}" };
    }
    return { status: 405, text: "{}" };
  };
}

/** Real notes from the vault (format reference). */
export const REAL = {
  daily0818: `---
tags:
  - /dailynotes
reading: false
writing: true
gym: false
food: true
laufen: false
rating: "8.4"
weight:
---
Kinoabend mit Sam`,
  daily1030: `---
tags:
  - /dailynotes
reading: false
writing: true
gym: true
food: true
laufen: false
rating: "6.3"
weight:
---
`,
  template: `---
reading: false
writing: false
gym: false
food: false
laufen: false
running:
tags:
  - /dailynotes
---
`,
  task: `---
title: Passfotoabholen
created: 2026-07-20
date: 2026-09-25
allDay: true
completed: true
wichtig: true
---

# Passfotoabholen
`,
  taskNoDate: `---
title: Reisegeld
created: 2026-08-18
completed: true
wichtig: true
---

# Reisegeld
`,
  taskOpen: `---
title: Reisepass
created: 2026-07-20
date: 2026-11-04
allDay: true
completed: false
wichtig: true
---

# Reisepass

Beim Amt nachfragen.
`,
};
