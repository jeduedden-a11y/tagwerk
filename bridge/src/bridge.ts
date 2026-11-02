import { applyEvent, type ApplyContext } from "./apply";
import { DecryptionError, fromB64, open, randomBytes, seal, sha256Hex, toB64, type SealOptions } from "./crypto";
import { GitHubRepo, type Http } from "./github";
import type { BridgeError, BridgeEvent, InboxBatch, Snapshot } from "./protocol";
import { buildSnapshot } from "./snapshot";

export const INBOX_DIR = "inbox";
export const SNAPSHOT_PATH = "snapshot.tw";

export interface BridgeState {
  applied: string[];
  errors: BridgeError[];
  lastIngestAt: string | null;
  lastSyncAt: string | null;
  lastSnapshotHash: string | null;
  lastSnapshotSha: string | null;
  /** Base64 salt this device uses for the snapshots it writes. */
  deviceSalt: string | null;
}

export const emptyState = (): BridgeState => ({
  applied: [],
  errors: [],
  lastIngestAt: null,
  lastSyncAt: null,
  lastSnapshotHash: null,
  lastSnapshotSha: null,
  deviceSalt: null,
});

export interface BridgeConfig {
  owner: string;
  repo: string;
  branch: string;
  token: string;
  passphrase: string;
  snapshotDays: number;
  textDays: number;
  iterations?: number;
}

export interface SyncReport {
  ok: boolean;
  appliedEvents: number;
  processedFiles: number;
  failedEvents: number;
  snapshotPublished: boolean;
  message: string;
}

export interface BridgeDeps {
  ctx: ApplyContext;
  http: Http;
  config: () => BridgeConfig;
  state: BridgeState;
  saveState: () => Promise<void>;
  version: string;
  retryDelayMs?: number;
}

const MAX_APPLIED = 2000;

export class Bridge {
  private running: Promise<SyncReport> | null = null;

  constructor(private readonly d: BridgeDeps) {}

  private repo(cfg: BridgeConfig): GitHubRepo {
    return new GitHubRepo(this.d.http, cfg.owner, cfg.repo, cfg.token, cfg.branch || "main", this.d.retryDelayMs);
  }

  private salt(): Uint8Array {
    if (!this.d.state.deviceSalt) this.d.state.deviceSalt = toB64(randomBytes(16));
    return fromB64(this.d.state.deviceSalt);
  }

  private record(eventId: string, message: string): void {
    this.d.state.errors.push({ eventId, at: this.d.ctx.now().toISOString(), message });
    if (this.d.state.errors.length > 50) this.d.state.errors.splice(0, this.d.state.errors.length - 50);
  }

  private markApplied(id: string): void {
    this.d.state.applied.push(id);
    if (this.d.state.applied.length > MAX_APPLIED) this.d.state.applied.splice(0, this.d.state.applied.length - MAX_APPLIED);
  }

  /** Serialised: concurrent calls share one run. */
  sync(opts: { forceSnapshot?: boolean } = {}): Promise<SyncReport> {
    if (!this.running) {
      this.running = this.run(opts).finally(() => {
        this.running = null;
      });
    }
    return this.running;
  }

  private async run(opts: { forceSnapshot?: boolean }): Promise<SyncReport> {
    const cfg = this.d.config();
    const report: SyncReport = { ok: true, appliedEvents: 0, processedFiles: 0, failedEvents: 0, snapshotPublished: false, message: "" };
    if (!cfg.owner || !cfg.repo || !cfg.token || !cfg.passphrase) {
      return { ...report, ok: false, message: "Nicht eingerichtet: Repo, Token und Passphrase in den Plugin-Einstellungen eintragen." };
    }
    const gh = this.repo(cfg);

    // 1. Ingest
    const files = (await gh.list(INBOX_DIR))
      .filter((f) => f.type === "file" && f.name.endsWith(".tw"))
      .sort((a, b) => a.name.localeCompare(b.name));

    const appliedSet = new Set(this.d.state.applied);
    for (const f of files) {
      const file = await gh.get(f.path);
      if (!file) continue;
      let batch: InboxBatch;
      try {
        batch = JSON.parse(await open(new TextDecoder().decode(file.bytes), cfg.passphrase, "inbox")) as InboxBatch;
      } catch (e) {
        const msg = e instanceof DecryptionError ? e.message : `Unlesbare Datei ${f.name}: ${(e as Error).message}`;
        this.record(f.name, msg);
        await this.d.saveState();
        return { ...report, ok: false, message: msg };
      }
      const events = [...(batch.events ?? [])].sort((a, b) => (a.ts ?? "").localeCompare(b.ts ?? ""));
      for (const ev of events as BridgeEvent[]) {
        if (!ev?.id || appliedSet.has(ev.id)) continue;
        try {
          await applyEvent(this.d.ctx, ev);
          report.appliedEvents++;
        } catch (e) {
          report.failedEvents++;
          this.record(ev.id, (e as Error).message);
        }
        // Failed events are acknowledged too, so they are not retried forever;
        // the error travels to the app in the snapshot.
        appliedSet.add(ev.id);
        this.markApplied(ev.id);
      }
      this.d.state.lastIngestAt = this.d.ctx.now().toISOString();
      await this.d.saveState();
      await gh.delete(f.path, file.sha, `tagwerk: ${f.name} verarbeitet`);
      report.processedFiles++;
    }

    // 2. Snapshot
    report.snapshotPublished = await this.publish(gh, cfg, opts.forceSnapshot || report.processedFiles > 0);
    this.d.state.lastSyncAt = this.d.ctx.now().toISOString();
    await this.d.saveState();
    report.message =
      report.processedFiles === 0
        ? report.snapshotPublished
          ? "Keine neuen Einträge, Stand an die App übertragen."
          : "Keine neuen Einträge."
        : `${report.appliedEvents} Einträge übernommen${report.failedEvents ? `, ${report.failedEvents} mit Fehler` : ""}.`;
    if (report.failedEvents) report.ok = false;
    return report;
  }

  private async publish(gh: GitHubRepo, cfg: BridgeConfig, force: boolean): Promise<boolean> {
    const snap: Snapshot = await buildSnapshot(this.d.ctx, {
      snapshotDays: cfg.snapshotDays,
      textDays: cfg.textDays,
      pluginVersion: this.d.version,
      applied: this.d.state.applied,
      errors: this.d.state.errors,
      lastIngestAt: this.d.state.lastIngestAt,
    });
    const { generatedAt: _ignored, ...stable } = snap;
    const hash = await sha256Hex(JSON.stringify(stable));
    if (!force && hash === this.d.state.lastSnapshotHash) return false;

    const sealOpts: SealOptions = { salt: this.salt(), iterations: cfg.iterations };
    const envelope = await seal(JSON.stringify(snap), cfg.passphrase, "snapshot", sealOpts);
    const bytes = new TextEncoder().encode(envelope);

    let sha = this.d.state.lastSnapshotSha ?? undefined;
    try {
      sha = await gh.put(SNAPSHOT_PATH, bytes, "tagwerk: Stand aktualisiert", sha);
    } catch {
      // Unknown or stale sha: fetch the current one and retry once.
      const current = await gh.get(SNAPSHOT_PATH);
      sha = await gh.put(SNAPSHOT_PATH, bytes, "tagwerk: Stand aktualisiert", current?.sha);
    }
    this.d.state.lastSnapshotSha = sha;
    this.d.state.lastSnapshotHash = hash;
    return true;
  }
}
