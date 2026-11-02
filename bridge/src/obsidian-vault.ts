import { App, TFile, TFolder, normalizePath, parseYaml } from "obsidian";
import type { Frontmatter, VaultPort } from "./vault";

export class ObsidianVault implements VaultPort {
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
