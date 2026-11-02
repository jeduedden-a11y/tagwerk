import { App, PluginSettingTab, Setting } from "obsidian";
import type TagwerkBridgePlugin from "./main";
import type { HabitConfig } from "./protocol";

const fmt = (iso: string | null) => {
  if (!iso) return "noch nie";
  const d = new Date(iso);
  return d.toLocaleString("de-DE", { dateStyle: "short", timeStyle: "short" });
};

export class TagwerkSettingTab extends PluginSettingTab {
  constructor(app: App, private readonly plugin: TagwerkBridgePlugin) {
    super(app, plugin);
  }

  override display(): void {
    const { containerEl } = this;
    const p = this.plugin;
    const s = p.settings;
    containerEl.empty();
    containerEl.addClass("tagwerk-settings");

    containerEl.createEl("p", {
      cls: "setting-item-description",
      text: "Die Tagwerk-App legt jede Änderung verschlüsselt in einem privaten GitHub-Repo ab. Dieses Plugin holt sie ab, schreibt sie Feld für Feld in den Vault und legt den aktuellen Stand verschlüsselt zurück.",
    });

    new Setting(containerEl).setName("GitHub-Briefkasten").setHeading();
    new Setting(containerEl)
      .setName("Besitzer")
      .setDesc("Dein GitHub-Benutzername.")
      .addText((t) => t.setPlaceholder("benutzername").setValue(s.owner).onChange(async (v) => {
        s.owner = v.trim();
        await p.saveSettings();
      }));
    new Setting(containerEl)
      .setName("Repository")
      .setDesc("Privates Repo, das nur als Briefkasten dient.")
      .addText((t) => t.setPlaceholder("tagwerk-daten").setValue(s.repo).onChange(async (v) => {
        s.repo = v.trim();
        await p.saveSettings();
      }));
    new Setting(containerEl)
      .setName("Branch")
      .addText((t) => t.setPlaceholder("main").setValue(s.branch).onChange(async (v) => {
        s.branch = v.trim() || "main";
        await p.saveSettings();
      }));

    const storage = p.secrets ? "Wird im Schlüsselbund des Betriebssystems gespeichert, nicht im Vault." : "Achtung: Diese Obsidian-Version hat keinen Schlüsselbund-Speicher, das Token landet in data.json im Vault. Obsidian aktualisieren.";
    new Setting(containerEl)
      .setName("Zugriffstoken")
      .setDesc(`Fein granuliertes Token, nur für dieses Repo, Berechtigung Contents: Lesen und Schreiben. ${storage}`)
      .addText((t) => {
        t.inputEl.type = "password";
        t.setPlaceholder(p.getToken() ? "gespeichert" : "github_pat_…");
        t.onChange(async (v) => {
          if (v.trim()) await p.setToken(v);
        });
      });

    new Setting(containerEl).setName("Verschlüsselung").setHeading();
    new Setting(containerEl)
      .setName("Passphrase")
      .setDesc("Muss exakt der Passphrase in der App entsprechen. Ohne sie kann niemand, auch GitHub nicht, die Einträge lesen. Geht sie verloren, sind nur die noch nicht übertragenen Einträge verloren, der Vault selbst bleibt unberührt.")
      .addText((t) => {
        t.inputEl.type = "password";
        t.setPlaceholder(p.getPassphrase() ? "gespeichert" : "lange Passphrase");
        t.onChange(async (v) => {
          if (v) await p.setPassphrase(v);
        });
      });

    new Setting(containerEl).setName("Ordner im Vault").setHeading();
    const folder = (name: string, key: "dailyFolder" | "tasksFolder" | "appointmentsFolder" | "runsFolder" | "routesFolder" | "foodFolder" | "profilePath", desc: string) =>
      new Setting(containerEl).setName(name).setDesc(desc).addText((t) => t.setValue(s[key]).onChange(async (v) => {
        s[key] = v.trim().replace(/\/+$/, "");
        await p.saveSettings();
      }));
    folder("Daily Notes", "dailyFolder", "Dateiname JJJJ-MM-TT.md");
    folder("Aufgaben", "tasksFolder", "Flacher Ordner, Frontmatter title/created/date/allDay/completed/wichtig");
    folder("Termine aus Mails", "appointmentsFolder", "Eine Notiz je Termin, kompatibel mit Full Calendar (Full note)");
    folder("Läufe", "runsFolder", "Eine Notiz je Lauf, JJJJ-MM-TT.md mit distance und time, wie es das Lauf-Diagramm liest");
    folder("Laufrouten", "routesFolder", "GPX-Dateien der in der App aufgezeichneten Läufe");
    folder("Ernährung", "foodFolder", "Eine Notiz je Tag mit Mahlzeiten, Summen und Zielen");
    folder("Körperprofil", "profilePath", "Notiz mit Größe, Körperfett, Zielgewicht und den Prüfregeln");

    new Setting(containerEl).setName("Gewohnheiten").setHeading();
    containerEl.createEl("p", {
      cls: "setting-item-description",
      text: "Schlüssel = Feldname im Frontmatter. Soll pro Woche und Gewicht wie im Habits-Dashboard; Toleranz = größte Lücke in Tagen, die eine Serie noch fortsetzt.",
    });
    s.habits.forEach((h, i) => this.habitRow(containerEl, h, i));
    let newKey = "";
    new Setting(containerEl)
      .setName("Gewohnheit hinzufügen")
      .addText((t) => t.setPlaceholder("schluessel").onChange((v) => (newKey = v.trim())))
      .addButton((b) => b.setButtonText("Hinzufügen").onClick(async () => {
        if (!/^[A-Za-z0-9_-]{1,40}$/.test(newKey) || s.habits.some((h) => h.key === newKey)) return;
        s.habits.push({ key: newKey, label: newKey, color: "#8E8E93", perWeek: 3, weight: 1, toleranceDays: 1, aliveDays: 1, symbol: "checkmark.circle" });
        await p.saveSettings();
        this.display();
      }));

    new Setting(containerEl).setName("Synchronisation").setHeading();
    new Setting(containerEl)
      .setName("Intervall")
      .setDesc("Minuten zwischen zwei Abrufen, solange Obsidian läuft.")
      .addSlider((sl) => sl.setLimits(1, 60, 1).setValue(s.intervalMinutes).setDynamicTooltip().onChange(async (v) => {
        s.intervalMinutes = v;
        await p.saveSettings();
        p.restartInterval();
      }));
    const st = s.state;
    new Setting(containerEl)
      .setName("Status")
      .setDesc(`Letzte Synchronisation: ${fmt(st.lastSyncAt)}. Letzte übernommene Einträge: ${fmt(st.lastIngestAt)}. ${p.lastReport ? p.lastReport.message : ""}`)
      .addButton((b) => b.setButtonText("Verbindung testen").onClick(() => void p.testConnection()))
      .addButton((b) => b.setCta().setButtonText("Jetzt synchronisieren").onClick(async () => {
        await p.syncNow(true);
        this.display();
      }));
    if (st.errors.length) {
      const box = containerEl.createDiv({ cls: "tagwerk-errors" });
      box.createEl("div", { cls: "setting-item-name", text: "Letzte Fehler" });
      const ul = box.createEl("ul");
      for (const e of st.errors.slice(-8).reverse()) ul.createEl("li", { text: `${fmt(e.at)}: ${e.message}` });
      new Setting(containerEl).addButton((b) => b.setButtonText("Fehlerliste leeren").onClick(async () => {
        st.errors = [];
        await p.saveSettings();
        this.display();
      }));
    }
  }

  private habitRow(containerEl: HTMLElement, h: HabitConfig, index: number): void {
    const p = this.plugin;
    const save = async () => p.saveSettings();
    const row = new Setting(containerEl).setName(h.key).setClass("tagwerk-habit");
    row.addText((t) => t.setPlaceholder("Name").setValue(h.label).onChange(async (v) => {
      h.label = v.trim() || h.key;
      await save();
    }));
    row.addColorPicker((c) => c.setValue(h.color).onChange(async (v) => {
      h.color = v.toUpperCase();
      await save();
    }));
    const num = (label: string, get: () => number, set: (n: number) => void, step = "1") =>
      row.addText((t) => {
        t.inputEl.type = "number";
        t.inputEl.step = step;
        t.inputEl.title = label;
        t.inputEl.addClass("tagwerk-num");
        t.setPlaceholder(label).setValue(String(get())).onChange(async (v) => {
          const n = Number(v.replace(",", "."));
          if (Number.isFinite(n) && n >= 0) {
            set(n);
            await save();
          }
        });
      });
    num("Soll pro Woche", () => h.perWeek, (n) => (h.perWeek = n));
    num("Gewicht", () => h.weight, (n) => (h.weight = n), "0.1");
    num("Toleranz (Tage)", () => h.toleranceDays, (n) => {
      h.toleranceDays = Math.max(1, Math.round(n));
      h.aliveDays = Math.max(1, h.toleranceDays === 1 ? 1 : h.toleranceDays - 1);
    });
    row.addExtraButton((b) => b.setIcon("trash").setTooltip("Entfernen").onClick(async () => {
      p.settings.habits.splice(index, 1);
      await save();
      this.display();
    }));
  }
}
