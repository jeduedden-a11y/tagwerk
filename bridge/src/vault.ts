/**
 * The narrow slice of Obsidian the bridge needs. Production wraps app.vault and
 * app.fileManager (obsidian-vault.ts); tests use an in-memory fake.
 */
export type Frontmatter = Record<string, unknown>;

export interface VaultPort {
  exists(path: string): Promise<boolean>;
  read(path: string): Promise<string>;
  /** Creates the file (and missing parent folders). Fails if it exists. */
  create(path: string, content: string): Promise<void>;
  /** Atomic read-modify-write of the whole file content. fn must be synchronous. */
  process(path: string, fn: (content: string) => string): Promise<void>;
  /** Atomic frontmatter edit via Obsidian's own serializer. */
  processFrontMatter(path: string, fn: (fm: Frontmatter) => void): Promise<void>;
  /** Markdown files directly inside folder (not recursive), as vault paths. */
  list(folder: string): Promise<string[]>;
  /** YAML parser used for reading frontmatter (Obsidian's parseYaml in production). */
  parseYaml(yaml: string): unknown;
  /** Moves a file to the trash the user configured in Obsidian. */
  trash(path: string): Promise<void>;
}
