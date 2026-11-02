import { fromB64, toB64 } from "./crypto";

export interface HttpRequest {
  url: string;
  method: "GET" | "PUT" | "DELETE" | "POST";
  headers: Record<string, string>;
  body?: string;
}

export interface HttpResponse {
  status: number;
  text: string;
}

export type Http = (req: HttpRequest) => Promise<HttpResponse>;

export class GitHubError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
    this.name = "GitHubError";
  }
}

export interface RepoEntry {
  name: string;
  path: string;
  sha: string;
  size: number;
  type: "file" | "dir" | string;
}

export interface RepoFile {
  sha: string;
  bytes: Uint8Array;
}

const API = "https://api.github.com";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Minimal GitHub Contents API client. One commit per write; retries on conflicts. */
export class GitHubRepo {
  constructor(
    private readonly http: Http,
    private readonly owner: string,
    private readonly repo: string,
    private readonly token: string,
    private readonly branch = "main",
    private readonly retryDelayMs = 800,
  ) {}

  private url(path: string, query = ""): string {
    const p = path.split("/").filter(Boolean).map(encodeURIComponent).join("/");
    return `${API}/repos/${encodeURIComponent(this.owner)}/${encodeURIComponent(this.repo)}/contents/${p}${query}`;
  }

  private headers(): Record<string, string> {
    return {
      Authorization: `Bearer ${this.token}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "Content-Type": "application/json",
      "User-Agent": "tagwerk-bridge",
    };
  }

  private async call(req: HttpRequest, okStatuses: number[], allow404 = false): Promise<HttpResponse | null> {
    let last: HttpResponse | null = null;
    for (let attempt = 0; attempt < 4; attempt++) {
      const res = await this.http(req);
      if (okStatuses.includes(res.status)) return res;
      if (allow404 && res.status === 404) return null;
      last = res;
      if (res.status === 401) throw new GitHubError("GitHub lehnt das Token ab (401). Token prüfen oder erneuern.", 401);
      if (res.status === 403 && !/rate limit/i.test(res.text)) {
        throw new GitHubError("GitHub verweigert den Zugriff (403). Hat das Token Lesen und Schreiben für Contents auf genau dieses Repo?", 403);
      }
      if (res.status === 404) throw new GitHubError(`Nicht gefunden (404): ${req.url}. Stimmen Besitzer und Repo-Name?`, 404);
      const retryable = res.status === 409 || res.status === 422 || res.status === 429 || res.status >= 500 || res.status === 403;
      if (!retryable) break;
      await sleep(this.retryDelayMs * (attempt + 1));
    }
    throw new GitHubError(`GitHub-Fehler ${last?.status}: ${last?.text.slice(0, 300)}`, last?.status ?? 0);
  }

  async list(dir: string): Promise<RepoEntry[]> {
    const res = await this.call({ url: this.url(dir, `?ref=${encodeURIComponent(this.branch)}`), method: "GET", headers: this.headers() }, [200], true);
    if (!res) return [];
    const data = JSON.parse(res.text);
    if (!Array.isArray(data)) return [];
    return data as RepoEntry[];
  }

  async get(path: string): Promise<RepoFile | null> {
    const res = await this.call({ url: this.url(path, `?ref=${encodeURIComponent(this.branch)}`), method: "GET", headers: this.headers() }, [200], true);
    if (!res) return null;
    const data = JSON.parse(res.text) as { sha: string; content?: string; encoding?: string };
    if (data.encoding !== "base64" || typeof data.content !== "string") {
      throw new GitHubError(`Unerwartetes Format für ${path}`, 200);
    }
    return { sha: data.sha, bytes: fromB64(data.content) };
  }

  /** Creates or updates a file and returns the new blob sha. */
  async put(path: string, bytes: Uint8Array, message: string, sha?: string): Promise<string> {
    const body = JSON.stringify({ message, content: toB64(bytes), branch: this.branch, ...(sha ? { sha } : {}) });
    const res = await this.call({ url: this.url(path), method: "PUT", headers: this.headers(), body }, [200, 201]);
    const data = JSON.parse(res!.text) as { content: { sha: string } };
    return data.content.sha;
  }

  async delete(path: string, sha: string, message: string): Promise<void> {
    const body = JSON.stringify({ message, sha, branch: this.branch });
    await this.call({ url: this.url(path), method: "DELETE", headers: this.headers(), body }, [200], true);
  }
}
