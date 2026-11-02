import EventKit
import SwiftUI
import TagwerkCore

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft = AppSettings()
    @State private var token = ""
    @State private var passphrase = ""
    @State private var claudeKey = ""
    @State private var untisAddress = ""
    @State private var untisPassword = ""
    @State private var untisResult: String?
    @State private var untisTesting = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var calendars: [EKCalendar] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                vaultSection
                aiSection
                mailSection
                untisSection
                notesSection
                calendarSection
                notificationSection
                Section {
                    TextField("Vorname", text: $draft.userName)
                        .textContentType(.givenName)
                } header: {
                    Text("Du")
                } footer: {
                    Text("Nur für die Formulierung der KI-Begründung.")
                }
                Section {
                    LabeledContent("Plugin im Vault", value: store.state.pluginVersion ?? "noch kein Stand")
                    if !store.state.bridgeFeatures.contains("planner") {
                        Text("Planer-Einträge, Klausuren und die Notizen brauchen Tagwerk Bridge 1.2 in Obsidian. Bis dahin bleiben neue Einträge auf dem Gerät und gehen danach automatisch raus.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("Lebensmittel gemerkt", value: "\(store.state.foodLibrary.count)")
                } header: {
                    Text("Fitness")
                } footer: {
                    Text("Barcodes: Open Food Facts, offene Datenbank (ODbL), ohne Schlüssel; gefundene Produkte bleiben auf dem iPhone. Lebensmittel ohne Barcode: \(FoodDatabase.attribution) Bild- und Texterkennung laufen auf dem Gerät.")
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    if !store.state.bridgeErrors.isEmpty {
                        DisclosureGroup("Meldungen vom Plugin (\(store.state.bridgeErrors.count))") {
                            ForEach(store.state.bridgeErrors.suffix(10).reversed(), id: \.self) { e in
                                Text(e.message).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        save()
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Nur einmal laden. Beim Zurückkehren aus einem Unterbildschirm (Postfach) feuert
                // onAppear erneut und würde die eben eingegebenen Werte wieder verwerfen.
                if !loaded {
                    draft = store.state.settings
                    untisAddress = draft.untis.server
                    loaded = true
                }
                if CalendarService.shared.hasAccess { calendars = CalendarService.shared.calendars() }
            }
        }
    }

    private func placeholder(_ key: String, _ empty: String) -> String {
        store.keychain.has(key) ? "gespeichert" : empty
    }

    private var vaultSection: some View {
        Section {
            TextField("GitHub-Benutzername", text: $draft.github.owner)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Daten-Repo", text: $draft.github.repo)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(placeholder(SecretKey.githubToken, "Zugriffstoken (github_pat_…)"), text: $token)
            SecureField(placeholder(SecretKey.passphrase, "Passphrase wie im Obsidian-Plugin"), text: $passphrase)
            Button {
                testing = true
                save()
                Task {
                    testResult = await store.testConnection()
                    testing = false
                }
            } label: {
                HStack {
                    Text("Verbindung prüfen")
                    if testing { Spacer(); ProgressView() }
                }
            }
            .disabled(testing)
            if let testResult {
                Text(testResult).font(.footnote).foregroundStyle(.secondary)
            }
            LabeledContent("Zuletzt gesendet", value: Format.relative(store.state.lastPush))
            LabeledContent("Stand vom PC", value: Format.relative(Format.iso(store.state.lastIngestAt) ?? Format.iso(store.state.lastSnapshotAt)))
            LabeledContent("Noch nicht im Vault", value: "\(store.state.outbox.count + store.awaitingVault)")
            if let error = store.state.lastSyncError {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Vault-Verbindung")
        } footer: {
            Text("Fein granuliertes Token nur für das private Daten-Repo, Berechtigung Contents: Lesen und Schreiben. Die Passphrase muss exakt der im Obsidian-Plugin entsprechen; GitHub sieht nur verschlüsselte Daten.")
        }
    }

    private var aiSection: some View {
        Section {
            LabeledContent("Aktiv", value: AIRouter(settings: draft, keychain: store.keychain).statusText)
            Toggle("Apple Intelligence verwenden", isOn: $draft.useAppleIntelligence)
            Text(AppleIntelligence.statusDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
            SecureField(placeholder(SecretKey.claudeKey, "Claude-API-Schlüssel (sk-ant-…)"), text: $claudeKey)
            TextField("Modell", text: $draft.claudeModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("Nach dem Schreiben automatisch bewerten", isOn: $draft.autoRate)
            Toggle("Mails zur Terminerkennung an Claude senden", isOn: $draft.sendMailsToClaude)
        } header: {
            Text("KI-Bewertung")
        } footer: {
            Text("Reihenfolge: Apple Intelligence auf dem Gerät, sonst Claude, sonst eine Formel aus deinen Gewohnheiten. An Claude gehen der Tagebuchtext, abgehakte Gewohnheiten, Gewicht und als Maßstab bis zu 14 frühere Tage mit deiner Bewertung; bei Mails nur solche, in denen ein Datum steht. Deine eigene Bewertung überschreibt die KI immer.")
        }
    }

    private var mailSection: some View {
        Section {
            ForEach($draft.mailAccounts) { $account in
                NavigationLink {
                    MailAccountEditor(account: $account)
                } label: {
                    LabeledContent(account.name, value: account.username.isEmpty ? "nicht eingerichtet" : account.username)
                }
            }
            Stepper("Zeitraum: \(draft.mailLookbackDays) Tage", value: $draft.mailLookbackDays, in: 3...60)
        } header: {
            Text("Postfächer")
        } footer: {
            Text("Abruf nur lesend per IMAP, nichts wird als gelesen markiert. Gmail braucht ein App-Passwort: Google-Konto, Sicherheit, Bestätigung in zwei Schritten, App-Passwörter. IONOS: imap.ionos.de, Benutzername ist die volle Adresse.")
        }
    }

    private var untisSection: some View {
        Section {
            TextField("Adresse, z. B. schule.webuntis.com", text: $untisAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onChange(of: untisAddress) { _, v in
                    let parsed = UntisConfig.parse(v)
                    draft.untis.server = parsed.server
                    if let school = parsed.school, draft.untis.school.isEmpty || v.contains("://") { draft.untis.school = school }
                }
            TextField("Schule (Kürzel in WebUntis)", text: $draft.untis.school)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Benutzername", text: $draft.untis.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
            SecureField(placeholder(SecretKey.untisPassword, "Passwort"), text: $untisPassword)
                .textContentType(.password)
            Button {
                untisTesting = true
                saveUntis()
                Task {
                    untisResult = await store.testUntis()
                    untisTesting = false
                    if store.untisReady { await store.refreshUntis(force: true) }
                }
            } label: {
                HStack {
                    Text("Anmeldung prüfen")
                    if untisTesting { Spacer(); ProgressView() }
                }
            }
            .disabled(untisTesting || draft.untis.server.isEmpty || draft.untis.username.isEmpty)
            if let untisResult {
                Text(untisResult)
                    .font(.footnote)
                    .foregroundStyle(untisResult.hasPrefix("Verbunden") ? Color.green : Color.orange)
            }
        } header: {
            Text("WebUntis")
        } footer: {
            Text("Füge die Adresse aus dem Browser ein, mit der du deinen Stundenplan öffnest. Das Passwort bleibt im Schlüsselbund dieses Geräts. Tagwerk liest nur: Stundenplan, Entfall, Klausuren und Mitteilungen. Geht die Anmeldung über einen Schul- oder Microsoft-Login, funktioniert sie hier nicht.")
        }
    }

    private var notesSection: some View {
        Section {
            LabeledContent("Notizen offline", value: store.wiki.isEmpty ? "noch keine" : "\(store.wiki.notes.count)")
            if let g = store.wiki.generatedAt {
                LabeledContent("Stand vom PC", value: Format.relative(g))
            }
            Button("Alle Notizen neu laden") {
                Task { await store.syncWiki(force: true) }
            }
            .disabled(store.wiki.syncing || !store.isConnected)
        } header: {
            Text("Notizen")
        } footer: {
            Text("Das Plugin legt den Wiki-Ordner verschlüsselt im Daten-Repo ab; die App lädt nur geänderte Teile und hält alles auf dem Gerät. Ändern kannst du die Notizen nur in Obsidian.")
        }
    }

    private func saveUntis() {
        draft.untis.server = draft.untis.server.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.untis.school = draft.untis.school.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.untis.username = draft.untis.username.trimmingCharacters(in: .whitespacesAndNewlines)
        store.state.settings.untis = draft.untis
        if !untisPassword.isEmpty {
            store.keychain.set(untisPassword, for: SecretKey.untisPassword)
            untisPassword = ""
        }
        store.resetUntisSession()
    }

    private var calendarSection: some View {
        Section {
            Toggle("Übernommene Termine in den Kalender", isOn: $draft.calendarExport)
            if draft.calendarExport {
                if calendars.isEmpty {
                    Button("Zugriff auf Kalender erlauben") {
                        Task {
                            if await CalendarService.shared.requestAccess() { calendars = CalendarService.shared.calendars() }
                        }
                    }
                } else {
                    Picker("Kalender", selection: $draft.calendarIdentifier) {
                        Text("Standardkalender").tag(String?.none)
                        ForEach(calendars, id: \.calendarIdentifier) { c in
                            Text(c.title).tag(Optional(c.calendarIdentifier))
                        }
                    }
                }
            }
        } header: {
            Text("Kalender")
        } footer: {
            Text("Zum Beispiel dein iCloud-Kalender „SV“ oder „Termine“. Er erscheint dann auch in Full Calendar in Obsidian.")
        }
    }

    private var notificationSection: some View {
        Section {
            Toggle("Abends an den Tag erinnern", isOn: $draft.dailyReminder)
            if draft.dailyReminder {
                DatePicker("Uhrzeit", selection: minutesBinding(\.dailyReminderMinutes), displayedComponents: .hourAndMinute)
            }
            DatePicker("Fällige Aufgaben um", selection: minutesBinding(\.taskReminderMinutes), displayedComponents: .hourAndMinute)
        } header: {
            Text("Mitteilungen")
        } footer: {
            Text("Die abendliche Erinnerung entfällt, sobald der Tag Einträge hat. Das App-Symbol zeigt die Zahl überfälliger Aufgaben.")
        }
        .environment(\.locale, germanLocale)
    }

    private func minutesBinding(_ path: WritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let m = draft[keyPath: path]
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                draft[keyPath: path] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }

    private func save() {
        draft.github.owner = draft.github.owner.trimmingCharacters(in: .whitespaces)
        draft.github.repo = draft.github.repo.trimmingCharacters(in: .whitespaces)
        saveUntis()
        store.state.settings = draft
        if !token.isEmpty { store.keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: SecretKey.githubToken) }
        if !passphrase.isEmpty { store.keychain.set(passphrase, for: SecretKey.passphrase) }
        if !claudeKey.isEmpty { store.keychain.set(claudeKey.trimmingCharacters(in: .whitespacesAndNewlines), for: SecretKey.claudeKey) }
        token = ""
        passphrase = ""
        claudeKey = ""
        store.state.snapshotEtag = nil
        store.saveNow()
        store.scheduleNotifications()
        Task { await store.syncNow() }
    }
}

struct MailAccountEditor: View {
    @Environment(Store.self) private var store
    @Binding var account: IMAPAccount
    @State private var password = ""
    @State private var result: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                Toggle("Abrufen", isOn: $account.enabled)
                TextField("Name", text: $account.name)
            }
            Section {
                TextField("Server", text: $account.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Port", value: $account.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                TextField("Benutzername (volle Adresse)", text: $account.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                SecureField(store.keychain.has(SecretKey.mailPassword(account.id)) ? "gespeichert" : "Passwort bzw. App-Passwort", text: $password)
                    .textContentType(.password)
                TextField("Ordner", text: $account.mailbox)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("TLS auf Port 993. Gmail: imap.gmail.com mit App-Passwort. IONOS: imap.ionos.de mit dem Passwort der Adresse.")
            }
            Section {
                Button {
                    testing = true
                    if !password.isEmpty { store.keychain.set(password, for: SecretKey.mailPassword(account.id)) }
                    let acc = account
                    let pw = password.isEmpty ? (store.keychain.get(SecretKey.mailPassword(account.id)) ?? "") : password
                    Task {
                        do {
                            try await IMAPClient.test(account: acc, password: pw)
                            result = "Anmeldung erfolgreich, Ordner \(acc.mailbox) lesbar."
                        } catch {
                            result = error.localizedDescription
                        }
                        testing = false
                    }
                } label: {
                    HStack {
                        Text("Verbindung testen")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(testing || account.host.isEmpty || account.username.isEmpty)
                if let result {
                    Text(result).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(account.name)
        .onDisappear {
            if !password.isEmpty { store.keychain.set(password, for: SecretKey.mailPassword(account.id)) }
        }
    }
}
