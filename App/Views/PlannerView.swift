import SwiftUI
import TagwerkCore

enum PlannerStyle {
    static let palette = ["#5B8DEF", "#34C759", "#FF9F0A", "#AF52DE", "#FF6482", "#30B0C7", "#A2845E", "#5AC8FA", "#D4A72C", "#BF5AF2", "#2FB37E", "#7D7AFF"]

    static func color(_ e: PlannerEntry) -> Color {
        switch e.kind {
        case .exam, .klausur: return Color(hex: "#E5484D")
        case .uni: return Color(hex: "#5856D6")
        case .appointment: return Color(hex: "#0FA3B1")
        case .suggestion: return .gray
        case .event: return Color(hex: "#F76B15")
        case .holiday: return Color(hex: "#30A46C")
        case .lesson:
            let key = e.short ?? e.title
            let sum = key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
            return Color(hex: palette[abs(sum) % palette.count])
        }
    }

    static func badge(_ e: PlannerEntry, compact: Bool = false) -> String? {
        switch e.mark {
        case .cancelledBySchool: return "Entfall"
        case .cancelledByMe: return e.kind == .lesson ? "Entfall" : "fällt aus"
        case .absent(let r): return compact ? "fehlt" : r
        case .uni: return "Uni"
        case .present: return compact ? nil : "da"
        case .changed: return compact ? nil : "geändert"
        case .none: break
        }
        switch e.kind {
        case .exam, .klausur: return compact ? nil : "Klausur"
        case .suggestion: return "Vorschlag"
        default: return nil
        }
    }

    static func time(_ e: PlannerEntry) -> String {
        guard let s = e.start else { return "ganztägig" }
        guard let end = e.end else { return Planner.clock(s) }
        return "\(Planner.clock(s))–\(Planner.clock(end))"
    }

    /// Visible hours: at least 7 to 17, widened to fit everything.
    static func hours(_ entries: [PlannerEntry]) -> ClosedRange<Int> {
        let starts = entries.compactMap(\.start)
        let ends = entries.compactMap { $0.end ?? $0.start }
        let lo = min(7, (starts.min() ?? 7 * 60) / 60)
        let hi = max(17, Int((Double(ends.max() ?? 17 * 60) / 60).rounded(.up)))
        return max(0, lo)...min(24, max(hi, lo + 1))
    }

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, d. MMMM"
        return f
    }()

    static func weekLabel(_ monday: String) -> String {
        guard let d = DayKey.date(monday) else { return monday }
        var cal = Calendar(identifier: .iso8601)
        cal.locale = Locale(identifier: "de_DE")
        let kw = cal.component(.weekOfYear, from: d)
        let sunday = DayKey.date(Planner.adding(6, to: monday)) ?? d
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "d."
        let g = DateFormatter()
        g.locale = Locale(identifier: "de_DE")
        g.dateFormat = "d. MMM"
        return "KW \(kw) · \(f.string(from: d))–\(g.string(from: sunday))"
    }

    static let weekdayShort = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
}

struct PlannerView: View {
    @Environment(Store.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var showSettings: Bool
    @State private var weekMode: Bool? = UserDefaults.standard.string(forKey: "TWPlanner").map { $0 == "woche" }
    @State private var selected: PlannerEntry?
    @State private var draft: PlannerDraft?
    @State private var showList = false
    @State private var showMessages = false

    private var isWeek: Bool { weekMode ?? (sizeClass == .regular) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PlannerHeader(isWeek: isWeek)
                if isWeek {
                    PlannerWeekView(onSelect: { selected = $0 }, onPickDay: { day in
                        store.plannerDay = day
                        withAnimation(.smooth) { weekMode = false }
                    })
                } else {
                    PlannerDayView(day: store.plannerDay, showSettings: $showSettings, onSelect: { selected = $0 })
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Planer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(item: $selected) { e in
                PlannerEntrySheet(entry: e, onNewExam: { d in
                    selected = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { draft = d }
                })
                .environment(store)
            }
            .sheet(item: $draft) { d in
                PlannerEditor(draft: d)
                    .environment(store)
            }
            .sheet(isPresented: $showList) {
                AppointmentsView(showSettings: $showSettings)
                    .environment(store)
            }
            .sheet(isPresented: $showMessages) {
                UntisMessagesView()
                    .environment(store)
            }
            .task(id: store.plannerDay) { await store.refreshUntis(around: store.plannerDay) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Picker("Ansicht", selection: Binding(get: { isWeek }, set: { v in withAnimation(.smooth) { weekMode = v } })) {
                Text("Tag").tag(false)
                Text("Woche").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button { draft = newDraft(.termin) } label: { Label("Termin", systemImage: "calendar.badge.plus") }
                Button { draft = newDraft(.uni) } label: { Label("Uni-Veranstaltung", systemImage: "graduationcap") }
                Button { draft = newDraft(.klausur) } label: { Label("Klausur", systemImage: "pencil.and.list.clipboard") }
            } label: {
                Label("Neu", systemImage: "plus")
            }
            Menu {
                Button { showMessages = true } label: {
                    let unread = store.state.untis.unreadMessages
                    Label(unread > 0 ? "Mitteilungen (\(unread) neu)" : "Mitteilungen", systemImage: "envelope")
                }
                Button { showList = true } label: {
                    let n = store.openSuggestions.count
                    Label(n > 0 ? "Termine und Vorschläge (\(n))" : "Termine und Vorschläge", systemImage: "list.bullet")
                }
                Button {
                    Task { await store.refreshUntis(around: store.plannerDay, force: true) }
                } label: {
                    Label("Stundenplan neu laden", systemImage: "arrow.clockwise")
                }
                Button { showSettings = true } label: { Label("Einstellungen", systemImage: "gearshape") }
            } label: {
                Label("Mehr", systemImage: store.state.untis.unreadMessages > 0 ? "ellipsis.circle.fill" : "ellipsis.circle")
            }
        }
    }

    private func newDraft(_ kind: PlannerDraft.Kind) -> PlannerDraft {
        var d = PlannerDraft()
        d.kind = kind
        let day = DayKey.date(store.plannerDay) ?? Date()
        let cal = Calendar.current
        let hour = max(8, min(18, cal.component(.hour, from: Date()) + 1))
        let start = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        d.date = day
        d.start = start
        d.end = start.addingTimeInterval(kind == .uni ? 90 * 60 : kind == .klausur ? 90 * 60 : 60 * 60)
        d.until = day.addingTimeInterval(15 * 7 * 86_400)
        d.weekdays = [Planner.weekday(store.plannerDay)]
        return d
    }
}

struct PlannerHeader: View {
    @Environment(Store.self) private var store
    let isWeek: Bool

    var body: some View {
        let monday = Planner.monday(of: store.plannerDay)
        VStack(spacing: 8) {
            HStack {
                Button { shift(-7) } label: { Image(systemName: "chevron.left").frame(width: 34, height: 34) }
                    .accessibilityLabel("Vorige Woche")
                Spacer()
                VStack(spacing: 1) {
                    Text(PlannerStyle.weekLabel(monday))
                        .font(.subheadline.weight(.semibold))
                    if store.untisInFlight {
                        Text("Lade WebUntis …").font(.caption2).foregroundStyle(.secondary)
                    } else if let err = store.state.untis.lastError {
                        Text(err).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                    }
                }
                Spacer()
                Button { shift(7) } label: { Image(systemName: "chevron.right").frame(width: 34, height: 34) }
                    .accessibilityLabel("Nächste Woche")
            }
            .buttonStyle(.borderless)
            if !isWeek {
                PlannerDayStrip(monday: monday)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func shift(_ days: Int) {
        withAnimation(.smooth) { store.plannerDay = Planner.adding(days, to: store.plannerDay) }
    }
}

struct PlannerDayStrip: View {
    @Environment(Store.self) private var store
    let monday: String

    var body: some View {
        let days = Planner.week(of: monday)
        let weekendUsed = days.suffix(2).contains { !store.plannerEntries(on: $0).isEmpty } || Planner.weekday(store.plannerDay) > 5
        let shown = weekendUsed ? days : Array(days.prefix(5))
        HStack(spacing: 6) {
            ForEach(shown, id: \.self) { d in
                PlannerDayButton(day: d, selected: d == store.plannerDay, isToday: d == store.today, entries: store.plannerEntries(on: d)) {
                    withAnimation(.smooth) { store.plannerDay = d }
                }
            }
        }
    }
}

struct PlannerDayButton: View {
    let day: String
    let selected: Bool
    let isToday: Bool
    let entries: [PlannerEntry]
    let action: () -> Void

    var body: some View {
        let exam = entries.contains { $0.isExam && !$0.isOff }
        let off = entries.contains { $0.kind == .lesson && $0.isOff }
        Button(action: action) {
            VStack(spacing: 3) {
                Text(PlannerStyle.weekdayShort[Planner.weekday(day) - 1])
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : .secondary)
                Text(String(Int(day.suffix(2)) ?? 0))
                    .font(.callout.weight(isToday ? .bold : .semibold))
                    .foregroundStyle(selected ? Color.white : isToday ? Color.accentColor : Color.primary)
                HStack(spacing: 3) {
                    Circle().fill(exam ? Color(hex: "#E5484D") : Color.clear).frame(width: 5, height: 5)
                    Circle().fill(off ? Color.orange : Color.clear).frame(width: 5, height: 5)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(selected ? Color.accentColor : Color.clear, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PlannerStyle.dayFormat.string(from: DayKey.date(day) ?? Date()))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PlannerDayView: View {
    @Environment(Store.self) private var store
    let day: String
    @Binding var showSettings: Bool
    let onSelect: (PlannerEntry) -> Void

    var body: some View {
        let entries = store.plannerEntries(on: day)
        let allDay = entries.filter(\.isAllDay)
        let timed = entries.filter { !$0.isAllDay }
        let hours = PlannerStyle.hours(timed)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(PlannerStyle.dayFormat.string(from: DayKey.date(day) ?? Date()))
                    .font(.title3.weight(.bold))
                    .padding(.top, 6)
                if !store.untisReady && !store.isDemo {
                    PlannerConnectCard(showSettings: $showSettings)
                }
                ForEach(allDay) { e in
                    PlannerAllDayChip(entry: e)
                        .onTapGesture { onSelect(e) }
                }
                if entries.isEmpty {
                    Text(store.untisReady ? "Nichts eingetragen." : "Ohne WebUntis zeigt der Planer nur deine Termine.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
                PlannerTimeline(entries: timed, hours: hours, hourHeight: 62, compact: false, showLabels: true,
                                isToday: day == store.today, onSelect: onSelect)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.refreshUntis(around: day, force: true) }
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { v in
                guard abs(v.translation.width) > 80, abs(v.translation.width) > abs(v.translation.height) * 2 else { return }
                withAnimation(.smooth) { store.plannerDay = Planner.adding(v.translation.width < 0 ? 1 : -1, to: day) }
            }
        )
    }
}

struct PlannerConnectCard: View {
    @Binding var showSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Stundenplan aus WebUntis", systemImage: "calendar.day.timeline.left")
            Text("Melde dich einmal mit deinem WebUntis-Zugang an. Dann stehen Unterricht, Entfall, Vertretungen und Klausuren der Schule hier, zusammen mit deinen Terminen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("WebUntis einrichten") { showSettings = true }
                .buttonStyle(.borderedProminent)
        }
        .card()
    }
}

struct PlannerAllDayChip: View {
    let entry: PlannerEntry
    var compact = false

    var body: some View {
        let tint = PlannerStyle.color(entry)
        HStack(spacing: 6) {
            Image(systemName: entry.kind == .holiday ? "sun.horizon.fill" : entry.isExam ? "pencil.and.list.clipboard" : "calendar")
                .font(.caption)
            Text(entry.title)
                .font(compact ? .caption2.weight(.semibold) : .subheadline.weight(.semibold))
                .strikethrough(entry.isOff)
                .lineLimit(compact ? 2 : 1)
            Spacer(minLength: 0)
            if !compact, let b = PlannerStyle.badge(entry) {
                Text(b).font(.caption2.weight(.bold))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 4 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.14), in: .rect(cornerRadius: 10))
        .contentShape(.rect)
    }
}

struct PlannerTimeline: View {
    @Environment(Store.self) private var store
    let entries: [PlannerEntry]
    let hours: ClosedRange<Int>
    let hourHeight: CGFloat
    let compact: Bool
    let showLabels: Bool
    let isToday: Bool
    let onSelect: (PlannerEntry) -> Void

    var body: some View {
        let cols = Planner.columns(entries)
        let height = CGFloat(hours.upperBound - hours.lowerBound) * hourHeight
        GeometryReader { geo in
            let labelWidth: CGFloat = showLabels ? 44 : 0
            let width = max(10, geo.size.width - labelWidth)
            ZStack(alignment: .topLeading) {
                ForEach(Array(hours), id: \.self) { h in
                    PlannerHourLine(hour: h, showLabel: showLabels)
                        .offset(y: CGFloat(h - hours.lowerBound) * hourHeight)
                }
                ForEach(entries) { e in
                    let c = cols[e.id] ?? (index: 0, count: 1)
                    let frame = blockFrame(e, column: c, width: width)
                    PlannerBlock(entry: e, compact: compact)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: labelWidth + frame.minX, y: frame.minY)
                        .onTapGesture { onSelect(e) }
                }
                if isToday, let now = nowMinutes(), now >= hours.lowerBound * 60, now <= hours.upperBound * 60 {
                    PlannerNowLine()
                        .frame(width: width + 6)
                        .offset(x: labelWidth - 6, y: CGFloat(now - hours.lowerBound * 60) / 60 * hourHeight - 4)
                }
            }
        }
        .frame(height: height + 10)
    }

    private func blockFrame(_ e: PlannerEntry, column: (index: Int, count: Int), width: CGFloat) -> CGRect {
        let start = e.start ?? hours.lowerBound * 60
        let end = max(e.end ?? start + 30, start + 15)
        let y = CGFloat(start - hours.lowerBound * 60) / 60 * hourHeight
        let h = max(CGFloat(end - start) / 60 * hourHeight - 2, compact ? 20 : 26)
        let colWidth = width / CGFloat(max(1, column.count))
        return CGRect(x: CGFloat(column.index) * colWidth, y: y + 1, width: max(8, colWidth - 3), height: h)
    }

    private func nowMinutes() -> Int? {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        guard let h = c.hour, let m = c.minute else { return nil }
        return h * 60 + m
    }
}

struct PlannerHourLine: View {
    let hour: Int
    let showLabel: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if showLabel {
                Text(String(format: "%02d:00", hour))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 0.5)
        }
        .frame(height: 12)
        .offset(y: -6)
    }
}

struct PlannerNowLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Rectangle().fill(Color.red).frame(height: 1.5)
        }
        .accessibilityHidden(true)
    }
}

struct PlannerBlock: View {
    let entry: PlannerEntry
    let compact: Bool

    var body: some View {
        let tint = PlannerStyle.color(entry)
        let off = entry.isOff
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(compact ? (entry.short ?? entry.title) : entry.title)
                    .font(compact ? .caption2.weight(.semibold) : .subheadline.weight(.semibold))
                    .strikethrough(off)
                    .lineLimit(compact ? 2 : 1)
                Spacer(minLength: 0)
                if let b = PlannerStyle.badge(entry, compact: compact) {
                    Text(b)
                        .font(.system(size: compact ? 9 : 11, weight: .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(tint.opacity(0.22), in: .capsule)
                }
            }
            if !compact {
                Text([PlannerStyle.time(entry), entry.detail].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let room = entry.period?.room {
                Text(room)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, compact ? 4 : 8)
        .padding(.vertical, compact ? 3 : 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tint.opacity(off ? 0.07 : 0.17), in: .rect(cornerRadius: 8))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                .fill(tint.opacity(off ? 0.4 : 1))
                .frame(width: 3)
        }
        .overlay {
            if entry.kind == .suggestion || entry.mark == .changed {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: entry.kind == .suggestion ? [4, 3] : []))
                    .foregroundStyle(entry.kind == .suggestion ? tint : Color.orange)
            }
        }
        .foregroundStyle(off ? Color.secondary : Color.primary)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Details und eigene Markierung")
    }
}

struct PlannerWeekView: View {
    @Environment(Store.self) private var store
    let onSelect: (PlannerEntry) -> Void
    let onPickDay: (String) -> Void

    var body: some View {
        let all = Planner.week(of: store.plannerDay)
        let weekendUsed = all.suffix(2).contains { !store.plannerEntries(on: $0).isEmpty }
        let days = weekendUsed ? all : Array(all.prefix(5))
        let perDay = days.map { store.plannerEntries(on: $0) }
        let hours = PlannerStyle.hours(perDay.joined().filter { !$0.isAllDay })
        ScrollView {
            VStack(spacing: 6) {
                HStack(alignment: .top, spacing: 4) {
                    Color.clear.frame(width: 40, height: 1)
                    ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                        PlannerWeekColumnHeader(day: d, isToday: d == store.today, allDay: perDay[i].filter(\.isAllDay),
                                                onPick: { onPickDay(d) }, onSelect: onSelect)
                    }
                }
                HStack(alignment: .top, spacing: 4) {
                    PlannerHourLabels(hours: hours, hourHeight: 56)
                        .frame(width: 40)
                    ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                        PlannerTimeline(entries: perDay[i].filter { !$0.isAllDay }, hours: hours, hourHeight: 56, compact: true,
                                        showLabels: false, isToday: d == store.today, onSelect: onSelect)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .refreshable { await store.refreshUntis(around: store.plannerDay, force: true) }
    }
}

struct PlannerWeekColumnHeader: View {
    let day: String
    let isToday: Bool
    let allDay: [PlannerEntry]
    let onPick: () -> Void
    let onSelect: (PlannerEntry) -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button(action: onPick) {
                VStack(spacing: 0) {
                    Text(PlannerStyle.weekdayShort[Planner.weekday(day) - 1])
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(String(Int(day.suffix(2)) ?? 0))
                        .font(.callout.weight(.bold))
                        .foregroundStyle(isToday ? Color.accentColor : Color.primary)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            ForEach(allDay) { e in
                PlannerAllDayChip(entry: e, compact: true)
                    .onTapGesture { onSelect(e) }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct PlannerHourLabels: View {
    let hours: ClosedRange<Int>
    let hourHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(Array(hours), id: \.self) { h in
                Text(String(format: "%02d", h))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .offset(y: CGFloat(h - hours.lowerBound) * hourHeight - 7)
            }
        }
        .frame(height: CGFloat(hours.upperBound - hours.lowerBound) * hourHeight + 10, alignment: .top)
    }
}
