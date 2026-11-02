import { Notice, Plugin, requestUrl, TAbstractFile } from "obsidian";
import { DEFAULT_FITNESS_FOLDERS, type ApplyContext, type FolderSettings } from "./apply";
import { Bridge, emptyState, SNAPSHOT_PATH, type BridgeConfig, type BridgeState, type SyncReport } from "./bridge";
import { open } from "./crypto";
import { GitHubRepo, type Http } from "./github";
import { ObsidianVault } from "./obsidian-vault";
import { DEFAULT_HABITS, type HabitConfig } from "./protocol";
import { TagwerkSettingTab } from "./settings-tab";

export interface TagwerkSettings {
  owner: string;
  repo: string;
  branch: string;
  dailyFolder: string;
  tasksFolder: string;
  appointmentsFolder: string;
  runsFolder: string;
  routesFolder: string;
  foodFolder: string;
  profilePath: string;
  schoolNotePath: string;
  /** Folder the app shows under "Notizen"; empty switches the copy off. */
  wikiFolder: string;
  wikiEnabled: boolean;
  intervalMinutes: number;
  snapshotDays: number;
  textDays: number;
  habits: HabitConfig[];
  /** Only used when Obsidian has no SecretStorage (older than 1.11.4). */
  tokenFallback: string;
  passphraseFallback: string;
  state: BridgeState;
}

export const DEFAULT_SETTINGS: TagwerkSettings = {
  owner: "",
  repo: "tagwerk-daten",
  branch: "main",
  dailyFolder: "01 Leben/Daily Notes",
  tasksFolder: "01 Leben/Tasks",
  appointmentsFolder: "01 Leben/Termine",
  ...DEFAULT_FITNESS_FOLDERS,
  wikiFolder: "02 Wiki",
  wikiEnabled: true,
  intervalMinutes: 5,
  snapshotDays: 400,
  textDays: 60,
  habits: DEFAULT_HABITS,
  tokenFallback: "",
  passphraseFallback: "",
  state: emptyState(),
};

const TOKEN_ID = "tagwerk-github-token";
const PASS_ID = "tagwerk-passphrase";

const obsidianHttp: Http = async (req) => {
  const r = await requestUrl({ url: req.url, method: req.method, headers: req.headers, body: req.body, throw: false });
  return { status: r.status, text: r.text };
};

interface SecretStore {
  getSecret(id: string): string | null;
  setSecret(id: string, secret: string): void;
}

export default class TagwerkBridgePlugin extends Plugin {
  declare settings: TagwerkSettings;
  bridge!: Bridge;
  lastReport: SyncReport | null = null;
  private statusEl!: HTMLElement;
  private intervalId: number | null = null;
  private watchTimer: number | null = null;
  private lastNoticeMessage = "";

  get secrets(): SecretStore | null {
    const s = (this.app as unknown as { secretStorage?: SecretStore }).secretStorage;
    return s && typeof s.getSecret === "function" ? s : null;
  }

  getToken(): string {
    return (this.secrets?.getSecret(TOKEN_ID) ?? "") || this.settings.tokenFallback;
  }

  getPassphrase(): string {
    return (this.secrets?.getSecret(PASS_ID) ?? "") || this.settings.passphraseFallback;
  }

  async setToken(v: string): Promise<void> {
    if (this.secrets) {
      this.secrets.setSecret(TOKEN_ID, v.trim());
      this.settings.tokenFallback = "";
    } else this.settings.tokenFallback = v.trim();
    await this.saveSettings();
  }

  async setPassphrase(v: string): Promise<void> {
    if (this.secrets) {
      this.secrets.setSecret(PASS_ID, v);
      this.settings.passphraseFallback = "";
    } else this.settings.passphraseFallback = v;
    await this.saveSettings();
  }

  folders(): FolderSettings {
    return {
      dailyFolder: this.settings.dailyFolder,
      tasksFolder: this.settings.tasksFolder,
      appointmentsFolder: this.settings.appointmentsFolder,
      runsFolder: this.settings.runsFolder,
      routesFolder: this.settings.routesFolder,
      foodFolder: this.settings.foodFolder,
      profilePath: this.settings.profilePath,
      schoolNotePath: this.settings.schoolNotePath,
      habits: this.settings.habits,
    };
  }

  config(): BridgeConfig {
    return {
      owner: this.settings.owner.trim(),
      repo: this.settings.repo.trim(),
      branch: this.settings.branch.trim() || "main",
      token: this.getToken(),
      passphrase: this.getPassphrase(),
      snapshotDays: this.settings.snapshotDays,
      textDays: this.settings.textDays,
      wikiFolder: this.settings.wikiEnabled ? this.settings.wikiFolder.trim() : "",
    };
  }

  override async onload(): Promise<void> {
    await this.loadSettings();
    const vault = new ObsidianVault(this.app);
    const folders = () => this.folders();
    const ctx: ApplyContext = {
      vault,
      get folders() {
        return folders();
      },
      now: () => new Date(),
    };
    this.bridge = new Bridge({
      ctx,
      http: obsidianHttp,
      config: () => this.config(),
      state: this.settings.state,
      saveState: () => this.saveSettings(),
      version: this.manifest.version,
      renderDataview: (q, p) => vault.renderDataview(q, p),
    });

    this.statusEl = this.addStatusBarItem();
    this.statusEl.addClass("tagwerk-status");
    this.statusEl.setAttribute("aria-label", "Tagwerk jetzt synchronisieren");
    this.registerDomEvent(this.statusEl, "click", () => void this.syncNow(true));
    this.setStatus("Tagwerk");

    this.addCommand({ id: "sync-now", name: "Jetzt synchronisieren", callback: () => void this.syncNow(true) });
    this.addCommand({ id: "test-connection", name: "Verbindung testen", callback: () => void this.testConnection() });
    this.addSettingTab(new TagwerkSettingTab(this.app, this));

    this.app.workspace.onLayoutReady(() => {
      void this.syncNow(false);
      const onChange = (f: TAbstractFile) => this.onVaultChange(f.path);
      this.registerEvent(this.app.vault.on("modify", onChange));
      this.registerEvent(this.app.vault.on("create", onChange));
      this.registerEvent(this.app.vault.on("delete", onChange));
      this.registerEvent(this.app.vault.on("rename", (f, oldPath) => {
        this.onVaultChange(f.path);
        this.onVaultChange(oldPath);
      }));
    });
    this.restartInterval();
  }

  override onunload(): void {
    if (this.watchTimer) window.clearTimeout(this.watchTimer);
  }

  restartInterval(): void {
    if (this.intervalId !== null) window.clearInterval(this.intervalId);
    const minutes = Math.max(1, Math.min(120, this.settings.intervalMinutes || 5));
    this.intervalId = window.setInterval(() => void this.syncNow(false), minutes * 60_000);
    this.registerInterval(this.intervalId);
  }

  /** Edits made in Obsidian should reach the app too: debounce a snapshot refresh. */
  private onVaultChange(path: string): void {
    const s = this.settings;
    const watched = path === s.profilePath || [s.dailyFolder, s.tasksFolder, s.appointmentsFolder, s.runsFolder, s.foodFolder].some((f) => path.startsWith(`${f}/`));
    if (!watched) return;
    if (this.watchTimer) window.clearTimeout(this.watchTimer);
    this.watchTimer = window.setTimeout(() => void this.syncNow(false), 45_000);
  }

  private setStatus(text: string, error = false): void {
    this.statusEl?.setText(text);
    this.statusEl?.toggleClass("tagwerk-status-error", error);
  }

  async syncNow(manual: boolean): Promise<SyncReport | null> {
    const cfg = this.config();
    if (!cfg.owner || !cfg.token || !cfg.passphrase) {
      this.setStatus("Tagwerk: nicht eingerichtet", true);
      if (manual) new Notice("Tagwerk: Bitte zuerst GitHub-Besitzer, Token und Passphrase in den Einstellungen eintragen.");
      return null;
    }
    this.setStatus("Tagwerk: synchronisiert …");
    try {
      const report = await this.bridge.sync({ forceSnapshot: manual });
      this.lastReport = report;
      const t = new Date();
      const hhmm = `${String(t.getHours()).padStart(2, "0")}:${String(t.getMinutes()).padStart(2, "0")}`;
      this.setStatus(report.ok ? `Tagwerk ${hhmm}` : "Tagwerk: Fehler", !report.ok);
      if (manual || (!report.ok && report.message !== this.lastNoticeMessage)) new Notice(`Tagwerk: ${report.message}`, report.ok ? 4000 : 10000);
      else if (report.appliedEvents > 0) new Notice(`Tagwerk: ${report.message}`, 4000);
      this.lastNoticeMessage = report.ok ? "" : report.message;
      return report;
    } catch (e) {
      const msg = (e as Error).message;
      this.lastReport = { ok: false, appliedEvents: 0, processedFiles: 0, failedEvents: 0, snapshotPublished: false, message: msg };
      this.setStatus("Tagwerk: Fehler", true);
      if (manual || msg !== this.lastNoticeMessage) new Notice(`Tagwerk: ${msg}`, 10000);
      this.lastNoticeMessage = msg;
      return null;
    }
  }

  async testConnection(): Promise<void> {
    const cfg = this.config();
    try {
      const gh = new GitHubRepo(obsidianHttp, cfg.owner, cfg.repo, cfg.token, cfg.branch);
      const root = await gh.list("");
      const snap = await gh.get(SNAPSHOT_PATH);
      let detail = `Repo erreichbar (${root.length} Einträge im Hauptordner).`;
      if (snap) {
        await open(new TextDecoder().decode(snap.bytes), cfg.passphrase, "snapshot");
        detail += " Vorhandener Stand lässt sich mit der Passphrase entschlüsseln.";
      } else detail += " Noch kein Stand vorhanden, er wird bei der ersten Synchronisation angelegt.";
      new Notice(`Tagwerk: ${detail}`, 8000);
    } catch (e) {
      new Notice(`Tagwerk: ${(e as Error).message}`, 10000);
    }
  }

  async loadSettings(): Promise<void> {
    const data = ((await this.loadData()) ?? {}) as Partial<TagwerkSettings>;
    this.settings = {
      ...DEFAULT_SETTINGS,
      ...data,
      habits: Array.isArray(data.habits) && data.habits.length ? data.habits : DEFAULT_HABITS.map((h) => ({ ...h })),
      state: { ...emptyState(), ...(data.state ?? {}) },
    };
  }

  async saveSettings(): Promise<void> {
    await this.saveData(this.settings);
  }
}
