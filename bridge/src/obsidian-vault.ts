import { App, TFile, TFolder, normalizePath, parseYaml } from "obsidian";
import type { Frontmatter, VaultFileStat, VaultPort } from "./vault";

export class ObsidianVault implements VaultPort {
  /** After one unsuccessful wait for Dataview, do not wait again for a while. */
  private dataviewRetryAt = 0;

  constructor(private readonly app: App) {}

  private file(path: string): TFile {
    const f = this.app.vault.getAbstractFileByPath(normalizePath(path));
    if (!(f instanceof TFile)) throw new Error(`Datei nicht gefunden: ${path}`);
    return f;
  }

  async exists(path: string): Promise<boolean> {
    return this.app.vault.getAbstractFileByPath(normalizePath(path)) instanceof TFile;
  }

  async read(path: string): Promise<string> {
    return this.app.vault.read(this.file(path));
  }

  private async ensureFolder(folder: string): Promise<void> {
    if (!folder) return;
    const parts = normalizePath(folder).split("/");
    let cur = "";
    for (const p of parts) {
      cur = cur ? `${cur}/${p}` : p;
      const existing = this.app.vault.getAbstractFileByPath(cur);
      if (!existing) await this.app.vault.createFolder(cur);
      else if (!(existing instanceof TFolder)) throw new Error(`${cur} ist kein Ordner`);
    }
  }

  async create(path: string, content: string): Promise<void> {
    const p = normalizePath(path);
    const slash = p.lastIndexOf("/");
    if (slash > 0) await this.ensureFolder(p.slice(0, slash));
    await this.app.vault.create(p, content);
  }

  async process(path: string, fn: (content: string) => string): Promise<void> {
    await this.app.vault.process(this.file(path), fn);
  }

  async processFrontMatter(path: string, fn: (fm: Frontmatter) => void): Promise<void> {
    await this.app.fileManager.processFrontMatter(this.file(path), fn);
  }

  async list(folder: string): Promise<string[]> {
    const f = this.app.vault.getAbstractFileByPath(normalizePath(folder));
    if (!(f instanceof TFolder)) return [];
    return f.children.filter((c): c is TFile => c instanceof TFile && c.extension === "md").map((c) => c.path);
  }

  async listFiles(folder: string): Promise<VaultFileStat[]> {
    const root = this.app.vault.getAbstractFileByPath(normalizePath(folder));
    if (!(root instanceof TFolder)) return [];
    const out: VaultFileStat[] = [];
    const walk = (f: TFolder) => {
      for (const c of f.children) {
        if (c instanceof TFolder) walk(c);
        else if (c instanceof TFile) out.push({ path: c.path, mtime: c.stat.mtime, size: c.stat.size });
      }
    };
    walk(root);
    return out;
  }

  async readBinary(path: string): Promise<Uint8Array> {
    return new Uint8Array(await this.app.vault.readBinary(this.file(path)));
  }

  /** Dataview's own renderer, if the plugin is installed and enabled. Waits (up to 30 s) until Dataview has indexed the vault. */
  async renderDataview(query: string, path: string): Promise<string | null> {
    const plugins = (this.app as unknown as { plugins?: { plugins?: Record<string, { api?: unknown }> } }).plugins?.plugins;
    const api = plugins?.dataview?.api as
      | { queryMarkdown?: (q: string, origin?: string) => Promise<{ successful: boolean; value?: string }>; index?: { initialized?: boolean } }
      | undefined;
    if (!api?.queryMarkdown) return null;
    if (api.index && api.index.initialized === false) {
      if (Date.now() < this.dataviewRetryAt) return null;
      const cache = this.app.metadataCache as unknown as { on(name: string, cb: () => void): unknown; offref(ref: unknown): void };
      await new Promise<void>((resolve) => {
        const ref = cache.on("dataview:index-ready", () => {
          cache.offref(ref);
          resolve();
        });
        window.setTimeout(() => {
          cache.offref(ref);
          resolve();
        }, 30_000);
      });
      if (api.index.initialized === false) {
        this.dataviewRetryAt = Date.now() + 10 * 60_000;
        return null;
      }
    }
    const r = await api.queryMarkdown(query, path);
    return r?.successful && typeof r.value === "string" ? r.value : null;
  }

  parseYaml(yaml: string): unknown {
    return parseYaml(yaml);
  }

  async trash(path: string): Promise<void> {
    const f = this.file(path);
    const fm = this.app.fileManager as unknown as { trashFile?: (file: TFile) => Promise<void> };
    if (typeof fm.trashFile === "function") await fm.trashFile(f);
    else await this.app.vault.trash(f, true);
  }
}
