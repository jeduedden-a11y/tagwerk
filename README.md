# Tagwerk

iPhone-App für Gewohnheiten, Tagebuch, Tagesbewertung, Aufgaben, Termine aus E-Mails, Läufe und Ernährung. Alles, was du in der App einträgst, landet in deinem Obsidian-Vault, und zwar im Format, das deine Daily Notes, dein Habits-Dashboard, das Rating-Diagramm, das Aufgaben-Board und das Lauf-Diagramm schon verwenden.

```
iPhone (Tagwerk)                       GitHub (privat)                PC (Obsidian)
─────────────────                      ───────────────                ──────────────
Gewohnheit abhaken  ─┐                                               ┌─> 01 Leben/Daily Notes/JJJJ-MM-TT.md
Tagebuch, Rating     ├─ verschlüsselt ─> tagwerk-daten/inbox/*.tw ──┤   01 Leben/Tasks/*.md
Aufgaben, Termine   ─┘                                               └─> 01 Leben/Termine/*.md
        ^                                                                       │
        └──────────── verschlüsselt <── tagwerk-daten/snapshot.tw <── Plugin "Tagwerk Bridge"
```

Die App ist die Erfassungsoberfläche, der Vault bleibt die Quelle der Wahrheit. Die App schickt keine ganzen Dateien, sondern einzelne Feldänderungen („gym: true am 1.11.“). Das Plugin setzt genau diese Felder; alles andere in der Notiz bleibt unberührt. Was du am PC in Obsidian änderst, sieht die App beim nächsten Abgleich.

## Warum der Umweg über GitHub

Eine eigene iPhone-App kann den Vault-Ordner in OneDrive nicht direkt beschreiben: OneDrive gibt unter iOS nur einzelne Dateien frei, keine Ordner. Das private Repo `tagwerk-daten` dient deshalb als Briefkasten. Jede Übertragung bestätigt der Server sofort; das Plugin quittiert jede übernommene Änderung, und die App zeigt unten über der Tab-Leiste, ob alles im Vault angekommen ist. Der Inhalt jeder Datei ist mit AES-256-GCM verschlüsselt (Schlüssel per PBKDF2 aus deiner Passphrase). GitHub sieht nur Chiffretext; erkennbar bleiben lediglich Zeitpunkt und Größe der Übertragungen.

## Einrichtung

### 1. GitHub

1. Repo **`tagwerk`** (dieses hier) baut die App in der Cloud. Jeder Push auf `main` erzeugt unter **Releases › latest** die Datei `Tagwerk.ipa` und `tagwerk-bridge.zip`.
2. Repo **`tagwerk-daten`**: privat, mit README angelegt.
3. Zwei fein granulierte Zugriffstoken anlegen (*Settings › Developer settings › Personal access tokens › Fine-grained tokens*), eins fürs iPhone, eins für den PC:
   - *Repository access*: **Only select repositories › tagwerk-daten**
   - *Permissions › Repository permissions › Contents*: **Read and write**
   - Ablaufdatum nach Wahl, danach in App und Plugin erneuern.
4. Eine lange **Passphrase** ausdenken. Sie steht nur in der App (Schlüsselbund des iPhones) und im Plugin (Schlüsselbund von Windows). Geht sie verloren, sind nur die noch nicht übertragenen Einträge weg; der Vault selbst ist nie verschlüsselt.

### 2. Obsidian-Plugin

1. Inhalt von `tagwerk-bridge.zip` nach `.obsidian/plugins/tagwerk-bridge/` im Vault kopieren (`main.js`, `manifest.json`, `styles.css`).
2. Obsidian › Einstellungen › Community-Plugins › **Tagwerk Bridge** aktivieren.
3. In den Plugin-Einstellungen GitHub-Benutzername, `tagwerk-daten`, Token und Passphrase eintragen, dann **Verbindung testen** und **Jetzt synchronisieren**.

Das Plugin holt neue Einträge beim Start von Obsidian und danach alle fünf Minuten, solange Obsidian läuft. Die Statusleiste unten zeigt den letzten Abgleich; ein Klick darauf synchronisiert sofort.

### 3. App aufs iPhone (ohne Mac)

1. Auf dem PC **iTunes und iCloud von Apples Website** installieren, nicht aus dem Microsoft Store. Sideloadly braucht die Treiber dieser Fassungen.
2. [Sideloadly](https://sideloadly.io) installieren, iPhone per Kabel anschließen und dem PC vertrauen.
3. `Tagwerk.ipa` aus **Releases › latest** in Sideloadly ziehen, Apple-ID eintragen, **Start**.
4. Auf dem iPhone: *Einstellungen › Datenschutz & Sicherheit › Entwicklermodus* einschalten (erscheint nach dem ersten Installationsversuch, verlangt einen Neustart), dann *Einstellungen › Allgemein › VPN & Geräteverwaltung* dem eigenen Entwicklerprofil vertrauen.

Mit einer kostenlosen Apple-ID läuft die Signatur nach **7 Tagen** ab. Sideloadly kann automatisch neu signieren, wenn iPhone und PC im selben WLAN sind und der Sideloadly-Dienst läuft; sonst einmal pro Woche neu installieren (die Daten in der App bleiben erhalten). Dauerhaft geht es nur mit dem Apple-Entwicklerprogramm (99 € im Jahr).

### 4. In der App

*Einstellungen* (Zahnrad):

- **Vault-Verbindung**: GitHub-Benutzername, `tagwerk-daten`, Token, Passphrase, **Verbindung prüfen**.
- **KI-Bewertung**: Auf einem iPhone mit Apple Intelligence (15 Pro und neuer) läuft die Bewertung auf dem Gerät, ohne Schlüssel. Auf dem iPhone 14 braucht sie einen Claude-API-Schlüssel ([console.anthropic.com](https://console.anthropic.com) › API Keys, Prepaid-Guthaben). Voreingestellt ist `claude-haiku-5-5`. Ohne Schlüssel schätzt eine Formel aus deinen Gewohnheiten, die den Text nicht lesen kann.
- **Postfächer**: Gmail mit `imap.gmail.com` und einem **App-Passwort** (Google-Konto › Sicherheit › Bestätigung in zwei Schritten › App-Passwörter). Schul-Mail bei IONOS mit `imap.ionos.de`, Benutzername ist die volle Adresse. Abruf nur lesend; nichts wird als gelesen markiert.
- **Kalender**: Übernommene Termine landen zusätzlich in einem Kalender deiner Wahl, etwa „SV“ oder „Termine“ in iCloud. Den sieht dann auch Full Calendar in Obsidian.

## Was wohin geschrieben wird

**Daily Note** `01 Leben/Daily Notes/JJJJ-MM-TT.md`, gleiche Reihenfolge wie bisher; neu sind nur die drei `rating_*`-Felder:

```yaml
---
tags:
  - /dailynotes
reading: false
writing: true
gym: false
food: true
laufen: true
rating: "7.4"            # gültiger Wert, liest dein Rating-Diagramm wie bisher
weight: "71.6"
rating_ai: "7.4"         # Vorschlag der KI
rating_source: ai        # ai oder manual
rating_reason: Du warst laufen und hast Mathe geschafft …
---
%% tagwerk:journal %%
Morgens 5 km am Fluss gelaufen …
%% /tagwerk:journal %%
```

Der Tagebuchtext steht in einem markierten Block; die Markierungen sind in der Leseansicht unsichtbar. Text außerhalb des Blocks gehört dir allein und wird nie angefasst. Hast du den Block am PC geändert und gleichzeitig in der App, bleibt die PC-Fassung als Zitat unter dem Block stehen, statt still überschrieben zu werden.

**Aufgabe** `01 Leben/Tasks/<Titel>.md` mit `title`, `created`, `date`, `allDay`, `completed`, `wichtig` wie bisher, dazu `tagwerk_id`, damit spätere Änderungen aus der App die Datei wiederfinden. Board und Full-Calendar-Kalender funktionieren unverändert.

**Termin** `01 Leben/Termine/JJJJ-MM-TT <Titel>.md` im Full-Note-Format von Full Calendar (`title`, `date`, `startTime`, `endTime`, `allDay`, `type: single`) plus Herkunft (`postfach`, `von`, `betreff`).

**Lauf** `01 Leben/Fittness/Laufen/Laufzeiten/JJJJ-MM-TT.md`, das Format, das `Lauf Chart.canvas` liest:

```yaml
---
distance: "5.02"
time: 00:27:13
tagwerk_id: …            # damit Korrekturen aus der App die Notiz finden
route: "[[2026-11-01.gpx]]"   # nur bei GPS-Aufzeichnung, GPX unter Laufen/Routen
---
```

Ein zweiter Lauf am selben Tag heißt `JJJJ-MM-TT-2.md`. Das Diagramm im Vault erkennt nur reine Datumsnamen; soll es solche Läufe mitzeichnen, muss die Zeile `parseRunDate` dort das Suffix zulassen.

**Ernährung** `01 Leben/Fittness/Ernährung/JJJJ-MM-TT.md`: Tagessummen und Ziele als Eigenschaften (`kcal`, `protein`, `fett`, `kohlenhydrate`, `ziel_kcal` …, `erreicht`), darunter ein verwalteter Block mit Tabelle und Prüfung. Die Daten der App stehen unsichtbar als Kommentar im Block; am PC geänderte Tabellen bleiben als Zitat unter dem Block stehen. **Körperprofil** `01 Leben/Fittness/Körperprofil.md` mit Größe, Geburtsjahr, Körperfett, Zielgewicht, Aktivität und Prüfregeln als Eigenschaften, die sich auch in Obsidian ändern lassen.

## Fitness

- **Läufe**: GPS-Aufzeichnung in der App (läuft bei gesperrtem Bildschirm weiter) oder von Hand. Das Diagramm rechnet wie `Lauf Chart.canvas`: Distanz gegen Pace, Score = 0,65 × Distanz-σ + 0,35 × Pace-σ relativ zum gewählten Zeitraum, Farbskala rot–gelb–grün–blau–lila mit einstellbarer Breite, Mediane, Trendlinie mit r, 3D-Ansicht mit interpolierter Fläche. „laufen“ wird abgehakt.
- **Gewicht**: wie `Gewichtsverlauf.canvas`, Monat oder Jahr, Median gestrichelt, Anstiege grün, Abnahmen rot, Strichstärke nach Änderung.
- **Ernährung**: Grundumsatz nach Katch-McArdle (mit Körperfett) oder Mifflin-St Jeor, mal Aktivitätsfaktor, plus Läufe (ACSM: rund 1 kcal je kg und km), plus Überschuss oder Defizit fürs Zielgewicht (7.700 kcal je kg, höchstens +20 % oder −25 %, nie unter dem Grundumsatz). Protein je kg Körpergewicht, Fett als Energieanteil (mindestens 0,8 g je kg), Rest Kohlenhydrate. „food“ wird abgehakt, wenn Kalorien im Spielraum liegen und die gewählten Makros stimmen; von Hand gesetzte Häkchen haben Vorrang.
- **Erfassen ohne KI-Dienst**: Barcode (VisionKit) mit [Open Food Facts](https://world.openfoodfacts.org) (ODbL, ohne Schlüssel); unbekannte Produkte per Foto der Nährwerttabelle (Texterkennung auf dem Gerät), danach offline gespeichert; Suche und Beschreibung („2 Eier, 1 Scheibe Vollkornbrot“) gegen den Bundeslebensmittelschlüssel; Foto der Mahlzeit mit Bilderkennung auf dem Gerät, die nur Vorschläge macht. Mengen bestätigst du immer selbst.

Lebensmitteltabelle: Max Rubner-Institut (2025): Bundeslebensmittelschlüssel (BLS), Version 4.0 – Deutsche Nährstoffdatenbank. Karlsruhe. DOI [10.25826/Data20251217-134202-0](https://doi.org/10.25826/Data20251217-134202-0), Lizenz CC BY 4.0. `App/Resources/BLS.json` ist ein Auszug von zehn Komponenten, gerundet, Salz aus Natrium berechnet, mit den Errata vom August 2026; erzeugt von `scripts/bls_to_json.py` (Workflow `BLS-Tabelle`).

Neue Ereignistypen schickt die App erst, wenn das Plugin im Stand meldet, dass es sie kennt: Läufe, Ernährung und Profil ab Tagwerk Bridge 1.1, Planer-Einträge, Klausuren und eigene Markierungen ab 1.2. Mit einem älteren Plugin bleiben sie auf dem iPhone und gehen nach dem Update automatisch raus.

## Planer

- **Stundenplan live aus WebUntis**: Die App meldet sich mit Benutzername und Passwort an (JSON-RPC `authenticate`, Passwort im Schlüsselbund) und lädt die Woche über dieselbe REST-Schnittstelle wie die WebUntis-Webseite; fällt die aus, nimmt sie die dokumentierte JSON-RPC-Methode `getTimetable`. Entfall, Raum- und Lehrerwechsel, Klausuren und Veranstaltungen kommen so, wie die Schule sie einträgt. Geladen werden die gewählte Woche und die nächsten zwei; offline zeigt der Planer den letzten Stand.
- **Eigene Markierungen**: Jede Stunde lässt sich für dich auf „Entfall“, „nicht da“ (mit Grund) oder, wenn sich ein Uni-Termin überschneidet, „ich gehe trotzdem hin“ setzen. Überschneidet sich ein Termin der Art `uni` mit Unterricht, zeigt der Planer die Stunde als „Uni“, solange du nichts anderes sagst.
- **Eigene Einträge und Klausuren** landen als Notiz in `01 Leben/Termine`, wiederkehrende im Format von Full Calendar (`type: recurring`, `daysOfWeek`, `startRecur`, `endRecur`), mit `kategorie` (`termin`, `uni`, `klausur`) und bei Klausuren `fach`. Notizen, die du in Obsidian oder im Chat mit Claude dort anlegst, erscheinen ebenso im Planer.
- **Vorschläge**: Daten aus Mails und aus WebUntis-Mitteilungen erscheinen gestrichelt; ein Tipp übernimmt sie in den Vault.

**Stundenplan-Änderungen** `01 Leben/Schule/Stundenplan-Änderungen.md`: Tabelle der eigenen Markierungen, die Daten stehen als Kommentar darunter. Das Plugin schreibt die Notiz bei jeder Änderung neu.

## Notizen

Das Plugin legt den Wiki-Ordner (Standard `02 Wiki`) verschlüsselt unter `wiki/` im Daten-Repo ab: 32 Teile nach einem Hash des Pfads, dazu vier Teile für Notizen mit Dataview-Abfragen, die das Plugin mit Dataview selbst zu Markdown ausrechnet. Nach einer Änderung wird nur der betroffene Teil neu hochgeladen, höchstens alle zehn Minuten. Die App lädt nur Teile, deren Hash sich geändert hat, und hält alles als Dateien auf dem Gerät. Dargestellt wird mit markdown-it und KaTeX (gebündelt, offline): Formeln, Callouts (auch einklappbare), Tabellen, Fußnoten, Aufgabenlisten, Wikilinks mit Abschnitten und eingebettete SVG-, PNG- und HTML-Dateien. DataviewJS, Charts und SMILES gibt es nur in Obsidian; die App zeigt an der Stelle einen Hinweis. Quelle des Renderers: `tools/notes-renderer` (`npm run build` schreibt nach `App/Resources/Notes`).

## KI-Bewertung

Du schreibst frei über den Tag. Die KI schlägt die Zahl auf **deiner** Skala vor und begründet sie in ein bis zwei Sätzen. Als Maßstab bekommt sie bis zu 14 frühere Tage mit deiner eigenen Bewertung, bevorzugt die, bei denen du die KI korrigiert hast. Erkennt sie im Text eine Gewohnheit („5 km gelaufen“), hakt sie diese ab, außer du hast sie an dem Tag selbst gesetzt. Ziehst du den Regler, gilt dein Wert (`rating_source: manual`); die KI überschreibt ihn nie, und „KI-Wert nehmen“ stellt den Vorschlag wieder her.

An Claude gehen: Tagebuchtext, abgehakte Gewohnheiten mit Wochenstand, Gewicht, die heute erledigten Aufgaben und die Kalibrierungstage. Bei Mails nur solche, in denen ein Datum gefunden wurde. Apple Intelligence verarbeitet alles auf dem Gerät.

## Grenzen

- Der Vault wird aktualisiert, wenn Obsidian am PC läuft. Bis dahin hält die App alles und zeigt „unterwegs“.
- Mit kostenloser Apple-ID: Neu-Signieren alle 7 Tage.
- Schul-Mail per IMAP funktioniert mit IONOS und ähnlichen Anbietern, nicht mit Microsoft 365.
- Kein Widget.
- WebUntis-Anmeldung nur mit Benutzername und Passwort; Schulen mit reiner Microsoft- oder IServ-Anmeldung gehen so nicht. Die Schnittstelle der Webseite ist nicht offiziell dokumentiert und kann sich ändern.
- Notizen sind in der App nur lesbar.
- Kein Import aus Apple Health: dafür braucht die App eine Berechtigung, die mit kostenloser Signierung über Sideloadly nicht verlässlich mitkommt.
- Die Bilderkennung schätzt keine Portionsgrößen; ohne großes Sprachmodell geht das auf dem iPhone 14 nicht verlässlich.

## Entwicklung

- `App/` SwiftUI-App (iOS 26), `Packages/TagwerkCore/` testbarer Kern (Verschlüsselung, Protokoll, IMAP, MIME, Terminerkennung, KI-Anbindung), `bridge/` Obsidian-Plugin in TypeScript.
- Das Xcode-Projekt entsteht aus `project.yml` mit [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- `bridge/tests/make-vectors.ts` erzeugt Testvektoren, mit denen der Swift-Kern prüft, dass er Dateien des Plugins byte-genau entschlüsselt und dekodiert.
- Der Workflow `.github/workflows/build.yml` testet beide Seiten, schickt in einem Ende-zu-Ende-Lauf echte verschlüsselte Einträge vom Swift-Kern über die GitHub-API durch das Plugin und wieder zurück, baut die unsignierte IPA und macht Screenshots im Simulator (Startargumente `-TWDemo YES -TWTab heute|fitness|aufgaben|termine|verlauf|einstellungen`, für Fitness zusätzlich `-TWFitness ernaehrung|laufen|gewicht`). Die Screenshots landen im Branch `ci-screenshots`.
