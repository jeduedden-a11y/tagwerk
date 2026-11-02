import SwiftUI
import TagwerkCore
import UIKit

final class BackgroundTaskBox: @unchecked Sendable {
    var id: UIBackgroundTaskIdentifier = .invalid
}

enum AppTab: String, Hashable {
    case heute, planer, aufgaben, fitness, notizen, verlauf
}

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var tab: AppTab
    @State private var showSettings = false
    @State private var interrupted: RecordingSnapshot?
    private let openSettingsAtLaunch: Bool

    init(initialTab: AppTab, openSettings: Bool) {
        _tab = State(initialValue: initialTab)
        openSettingsAtLaunch = openSettings
    }

    var body: some View {
        @Bindable var store = store
        TabView(selection: $tab) {
            Tab("Heute", systemImage: "sun.max.fill", value: AppTab.heute) {
                TodayView(showSettings: $showSettings)
            }
            Tab("Planer", systemImage: "calendar", value: AppTab.planer) {
                PlannerView(showSettings: $showSettings)
            }
            .badge(store.openSuggestions.count)
            Tab("Aufgaben", systemImage: "checklist", value: AppTab.aufgaben) {
                TasksView(showSettings: $showSettings)
            }
            .badge(store.overdueCount)
            Tab("Fitness", systemImage: "figure.run", value: AppTab.fitness) {
                FitnessView(showSettings: $showSettings)
            }
            Tab("Notizen", systemImage: "books.vertical.fill", value: AppTab.notizen) {
                NotesView(showSettings: $showSettings)
            }
            // The iPhone bar holds five tabs. A sixth, even a hidden one, makes the system add "Mehr" and moves
            // Notizen in there, under a second navigation bar. On compact width Verlauf therefore opens from Heute.
            if sizeClass != .compact {
                Tab("Verlauf", systemImage: "chart.bar.fill", value: AppTab.verlauf) {
                    HistoryView(showSettings: $showSettings)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            SyncAccessory(showSettings: $showSettings)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $store.capture) { c in
            FoodCaptureSheet(capture: c)
                .environment(store)
        }
        .sheet(isPresented: $store.showProfile) {
            BodyProfileSheet()
                .environment(store)
        }
        .sheet(item: $store.runEntry) { r in
            RunEntrySheet(request: r)
                .environment(store)
        }
        .fullScreenCover(isPresented: $store.showRecorder) {
            RunRecorderView()
                .environment(store)
        }
        .onChange(of: store.requestedTab) { _, t in
            guard let t else { return }
            withAnimation(.smooth) { show(t) }
            store.requestedTab = nil
        }
        .onChange(of: sizeClass) { _, _ in
            // Split View on the iPad can switch between the two layouts while Verlauf is open.
            if sizeClass == .compact, tab == .verlauf { show(.verlauf) }
            if sizeClass != .compact, store.showHistory {
                store.showHistory = false
                tab = .verlauf
            }
        }
        .onAppear {
            if tab == .verlauf { show(.verlauf) }
        }
        .task {
            // Screenshot runs only (-TWTab einstellungen): a sheet requested before the first frame can be dropped.
            guard openSettingsAtLaunch else { return }
            try? await Task.sleep(for: .milliseconds(400))
            showSettings = true
        }
        .alert("Lauf unterbrochen", isPresented: Binding(get: { interrupted != nil }, set: { if !$0 { interrupted = nil } }), presenting: interrupted) { snap in
            Button("Weiter aufzeichnen") {
                store.recorder.resume(snap)
                store.showRecorder = true
            }
            Button("So speichern") {
                store.addRun(date: DayKey.key(for: snap.start), distanceKm: snap.distance / 1000, seconds: Int(snap.elapsed.rounded()), source: "gps", route: snap.points)
                RecordingSnapshot.clear()
            }
            Button("Verwerfen", role: .destructive) { RecordingSnapshot.clear() }
        } message: { snap in
            Text("Die Aufzeichnung vom \(Format.dayTitle(DayKey.key(for: snap.start))) wurde beendet, als die App geschlossen wurde: \(Format.decimal(RunTime.distance(snap.distance / 1000))) km in \(RunTime.display(Int(snap.elapsed.rounded()))).")
        }
        .overlay(alignment: .top) {
            ToastView()
        }
        .onChange(of: scenePhase) { _, phase in
            handle(phase)
        }
        .task {
            store.scheduleNotifications()
            if !store.isDemo, store.recorder.phase == .idle, let snap = RecordingSnapshot.load() { interrupted = snap }
            Task { await store.loadFoodDatabase() }
            await store.syncNow()
        }
    }

    /// Verlauf is a tab in regular width and a page pushed onto Heute in compact width.
    private func show(_ t: AppTab) {
        if t == .verlauf, sizeClass == .compact {
            tab = .heute
            store.showHistory = true
        } else {
            tab = t
        }
    }

    private func handle(_ phase: ScenePhase) {
        switch phase {
        case .active:
            store.selectedDay = store.selectedDay > store.today ? store.today : store.selectedDay
            Task { await store.syncNow() }
            if let last = store.state.lastMailCheck, Date().timeIntervalSince(last) < 6 * 3600 {
                // checked recently
            } else if !store.configuredMailAccounts.isEmpty {
                Task { await store.checkMail() }
            }
        case .background:
            store.commitAllJournals()
            store.saveNow()
            guard !store.state.outbox.isEmpty else { return }
            let box = BackgroundTaskBox()
            box.id = UIApplication.shared.beginBackgroundTask(withName: "tagwerk-senden") {
                UIApplication.shared.endBackgroundTask(box.id)
            }
            Task {
                await store.push()
                UIApplication.shared.endBackgroundTask(box.id)
            }
        default:
            break
        }
    }
}

/// App-wide status above the tab bar: does the vault have everything?
struct SyncAccessory: View {
    @Environment(Store.self) private var store
    @Binding var showSettings: Bool

    private var connected: Bool { store.isConnected || store.isDemo }

    private var busy: Bool { store.syncPhase == .sending || store.syncPhase == .receiving }

    private var content: (icon: String, title: String, detail: String) {
        if !connected { return ("link.badge.plus", "Mit dem Vault verbinden", "Einmal einrichten, dann landet alles in Obsidian") }
        if busy { return ("arrow.triangle.2.circlepath", "Wird übertragen …", "GitHub-Briefkasten") }
        if case .failed(let message) = store.syncPhase { return ("exclamationmark.triangle.fill", "Übertragung fehlgeschlagen", message) }
        let held = store.heldForPlugin
        if held > 0 && held == store.state.outbox.count {
            return ("puzzlepiece.extension", "\(held) Einträge warten auf das Plugin", "In Obsidian Tagwerk Bridge 1.1 installieren")
        }
        if !store.state.outbox.isEmpty { return ("arrow.up.circle", "\(store.state.outbox.count) Änderungen warten", "Werden gesendet, sobald Netz da ist") }
        let waiting = store.awaitingVault
        if waiting > 0 { return ("clock.arrow.circlepath", "\(waiting) Einträge unterwegs", "Obsidian übernimmt sie beim nächsten Start am PC") }
        let stand = Format.iso(store.state.lastIngestAt) ?? Format.iso(store.state.lastSnapshotAt)
        return ("checkmark.circle.fill", "Alles im Vault", "Stand vom PC: \(Format.relative(stand))")
    }

    var body: some View {
        let c = content
        Button {
            if connected {
                Task { await store.syncNow() }
            } else {
                showSettings = true
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: c.icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(c.icon == "exclamationmark.triangle.fill" ? Color.orange : Color.accentColor)
                    .symbolEffect(.pulse, isActive: busy)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(c.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(connected ? "Jetzt synchronisieren" : "Öffnet die Einstellungen")
    }
}
