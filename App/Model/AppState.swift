import Foundation
import TagwerkCore

// Persisted app state. Every decoder falls back to defaults for missing keys,
// so app updates that add fields never wipe what is stored on the phone.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    func optional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

/// A local change that the vault has not acknowledged yet.
struct PendingMark: Codable, Hashable {
    var eventId: String
    var at: Date
}

struct DayEntry: Codable, Hashable {
    var date: String
    var habits: [String: Bool] = [:]
    var rating: String?
    var ratingAI: String?
    var ratingSource: RatingSource?
    var ratingReason: String?
    var weight: String?
    var journal: String = ""
    /// journalHash of the vault's journal block as last seen; sent as baseHash.
    var journalBaseHash: String?
    /// Text written in Obsidian outside the managed block (read-only here).
    var note: String?
    /// Local only: which habits the AI ticked, which ones the user set by hand,
    /// and which ones the food targets or a recorded run set.
    var aiHabits: [String] = []
    var manualHabits: [String] = []
    var autoHabits: [String] = []
    var aiProvider: String?
    var lastRatedHash: String?
    /// Field name -> unacknowledged event.
    var pending: [String: PendingMark] = [:]
    var journalDirty = false

    init(date: String) {
        self.date = date
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        habits = c.value(.habits, [:])
        rating = c.optional(.rating)
        ratingAI = c.optional(.ratingAI)
        ratingSource = c.optional(.ratingSource)
        ratingReason = c.optional(.ratingReason)
        weight = c.optional(.weight)
        journal = c.value(.journal, "")
        journalBaseHash = c.optional(.journalBaseHash)
        note = c.optional(.note)
        aiHabits = c.value(.aiHabits, [])
        manualHabits = c.value(.manualHabits, [])
        autoHabits = c.value(.autoHabits, [])
        aiProvider = c.optional(.aiProvider)
        lastRatedHash = c.optional(.lastRatedHash)
        pending = c.value(.pending, [:])
        journalDirty = c.value(.journalDirty, false)
    }

    var ratingValue: Double? { RatingScale.parse(rating) }
    var aiValue: Double? { RatingScale.parse(ratingAI) }
    var weightValue: Double? { weight.flatMap { Double($0) } }
    var doneCount: Int { habits.values.filter { $0 }.count }
    var hasContent: Bool { rating != nil || doneCount > 0 || !journal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isPending: Bool { !pending.isEmpty || journalDirty }
}

struct TaskItem: Codable, Hashable, Identifiable {
    var id: String
    var taskId: String?
    var path: String?
    var title: String
    var created: String
    var date: String?
    var completed: Bool
    var wichtig: Bool
    var notes: String?
    var completedOn: String?
    var pending: [String: PendingMark] = [:]

    init(id: String, taskId: String?, path: String?, title: String, created: String, date: String?, completed: Bool, wichtig: Bool, notes: String?) {
        self.id = id
        self.taskId = taskId
        self.path = path
        self.title = title
        self.created = created
        self.date = date
        self.completed = completed
        self.wichtig = wichtig
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        taskId = c.optional(.taskId)
        path = c.optional(.path)
        title = c.value(.title, "Aufgabe")
        created = c.value(.created, DayKey.today())
        date = c.optional(.date)
        completed = c.value(.completed, false)
        wichtig = c.value(.wichtig, false)
        notes = c.optional(.notes)
        completedOn = c.optional(.completedOn)
        pending = c.value(.pending, [:])
    }

    var isPending: Bool { !pending.isEmpty }

    func quadrant(today: String) -> Quadrant {
        Quadrant.of(date: date, wichtig: wichtig, completed: completed, today: today)
    }
}

struct Appointment: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var date: String
    var startTime: String?
    var endTime: String?
    var allDay: Bool
    var location: String?
    var mailbox: String?
    var from: String?
    var subject: String?
    var receivedAt: Date?
    var path: String?
    var calendarEventId: String?
    var pending: PendingMark?
    /// Planner (plugin 1.2): "klausur", "uni", "schule", "termin".
    var category: String?
    /// School subject of an exam (not the mail subject).
    var schoolSubject: String?
    var recur: Recurrence?
    var notes: String?

    init(id: String, title: String, date: String, startTime: String?, endTime: String?, allDay: Bool, location: String?,
         mailbox: String? = nil, from: String? = nil, subject: String? = nil, receivedAt: Date? = nil, path: String? = nil) {
        self.id = id
        self.title = title
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.allDay = allDay
        self.location = location
        self.mailbox = mailbox
        self.from = from
        self.subject = subject
        self.receivedAt = receivedAt
        self.path = path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.value(.title, "Termin")
        date = try c.decode(String.self, forKey: .date)
        startTime = c.optional(.startTime)
        endTime = c.optional(.endTime)
        allDay = c.value(.allDay, true)
        location = c.optional(.location)
        mailbox = c.optional(.mailbox)
        from = c.optional(.from)
        subject = c.optional(.subject)
        receivedAt = c.optional(.receivedAt)
        path = c.optional(.path)
        calendarEventId = c.optional(.calendarEventId)
        pending = c.optional(.pending)
        category = c.optional(.category)
        schoolSubject = c.optional(.schoolSubject)
        recur = c.optional(.recur)
        notes = c.optional(.notes)
    }
}

enum SuggestionStatus: String, Codable {
    case open, accepted, dismissed
}

struct Suggestion: Codable, Hashable, Identifiable {
    var id: String
    var mailbox: String
    var subject: String
    var from: String
    var receivedAt: Date
    var title: String
    var date: String
    var startTime: String?
    var endTime: String?
    var allDay: Bool
    var location: String?
    var confidence: Double
    var context: String
    var status: SuggestionStatus = .open

    init(id: String, mailbox: String, subject: String, from: String, receivedAt: Date, title: String, date: String, startTime: String?,
         endTime: String?, allDay: Bool, location: String?, confidence: Double, context: String) {
        self.id = id
        self.mailbox = mailbox
        self.subject = subject
        self.from = from
        self.receivedAt = receivedAt
        self.title = title
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.allDay = allDay
        self.location = location
        self.confidence = confidence
        self.context = context
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        mailbox = c.value(.mailbox, "")
        subject = c.value(.subject, "")
        from = c.value(.from, "")
        receivedAt = c.value(.receivedAt, Date())
        title = c.value(.title, "Termin")
        date = try c.decode(String.self, forKey: .date)
        startTime = c.optional(.startTime)
        endTime = c.optional(.endTime)
        allDay = c.value(.allDay, true)
        location = c.optional(.location)
        confidence = c.value(.confidence, 0.5)
        context = c.value(.context, "")
        status = c.value(.status, .open)
    }
}

/// The food log of one day as the app holds it.
struct FoodDayState: Codable, Hashable {
    var date: String
    var entries: [FoodEntry] = []
    var targets: DayTargets?
    var met: Bool?
    /// Last food.day event not yet acknowledged by the plugin.
    var pending: PendingMark?

    init(date: String) {
        self.date = date
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        entries = c.value(.entries, [])
        targets = c.optional(.targets)
        met = c.optional(.met)
        pending = c.optional(.pending)
    }

    var totals: Nutrients { entries.reduce(Nutrients.zero) { $0 + $1.nutrients } }
}

/// A food the user used or saved, for one-tap re-adding and offline barcode lookups.
struct LibraryItem: Codable, Hashable, Identifiable {
    var item: FoodItem
    var uses: Int = 0
    var lastUsed: Date?
    var lastGrams: Double?
    var id: String { item.id }

    init(item: FoodItem, uses: Int = 0, lastUsed: Date? = nil, lastGrams: Double? = nil) {
        self.item = item
        self.uses = uses
        self.lastUsed = lastUsed
        self.lastGrams = lastGrams
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(FoodItem.self, forKey: .item)
        uses = c.value(.uses, 0)
        lastUsed = c.optional(.lastUsed)
        lastGrams = c.optional(.lastGrams)
    }
}

struct MailCursor: Codable, Hashable {
    var uidValidity: UInt32?
    var seenUIDs: [UInt32] = []
    var lastCheck: Date?
    var lastError: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uidValidity = c.optional(.uidValidity)
        seenUIDs = c.value(.seenUIDs, [])
        lastCheck = c.optional(.lastCheck)
        lastError = c.optional(.lastError)
    }
}

struct AppSettings: Codable, Hashable {
    var github = GitHubConfig(owner: "", repo: "tagwerk-daten")
    var userName = ""
    var claudeModel = "claude-haiku-5-5"
    var useAppleIntelligence = true
    var autoRate = true
    var sendMailsToClaude = true
    var mailAccounts: [IMAPAccount] = [.gmail(), .ionos()]
    var mailLookbackDays = 14
    var calendarExport = true
    var calendarIdentifier: String?
    var dailyReminder = true
    var dailyReminderMinutes = 21 * 60
    var taskReminderMinutes = 8 * 60
    var deviceSalt = TagwerkCrypto.randomBytes(16).base64EncodedString()
    var dismissedReminderPrompt = false
    var untis = UntisConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        github = c.value(.github, d.github)
        userName = c.value(.userName, d.userName)
        claudeModel = c.value(.claudeModel, d.claudeModel)
        useAppleIntelligence = c.value(.useAppleIntelligence, d.useAppleIntelligence)
        autoRate = c.value(.autoRate, d.autoRate)
        sendMailsToClaude = c.value(.sendMailsToClaude, d.sendMailsToClaude)
        mailAccounts = c.value(.mailAccounts, d.mailAccounts)
        mailLookbackDays = c.value(.mailLookbackDays, d.mailLookbackDays)
        calendarExport = c.value(.calendarExport, d.calendarExport)
        calendarIdentifier = c.optional(.calendarIdentifier)
        dailyReminder = c.value(.dailyReminder, d.dailyReminder)
        dailyReminderMinutes = c.value(.dailyReminderMinutes, d.dailyReminderMinutes)
        taskReminderMinutes = c.value(.taskReminderMinutes, d.taskReminderMinutes)
        deviceSalt = c.value(.deviceSalt, d.deviceSalt)
        dismissedReminderPrompt = c.value(.dismissedReminderPrompt, false)
        untis = c.value(.untis, d.untis)
    }
}

struct AppState: Codable {
    var days: [String: DayEntry] = [:]
    var tasks: [TaskItem] = []
    var appointments: [Appointment] = []
    var suggestions: [Suggestion] = []
    var mailCursors: [String: MailCursor] = [:]
    var outbox: [OutgoingEvent] = []
    var habits: [HabitConfig] = HabitConfig.defaults
    var settings = AppSettings()
    var lastPush: Date?
    var lastPull: Date?
    var lastSnapshotAt: String?
    var lastIngestAt: String?
    var snapshotEtag: String?
    var bridgeErrors: [BridgeError] = []
    var lastSyncError: String?
    var lastMailCheck: Date?
    /// Event families the vault's plugin announced in its last snapshot.
    var bridgeFeatures: [String] = []
    var pluginVersion: String?
    var runs: [RunRecord] = []
    /// Run id -> unacknowledged create, patch or delete.
    var runPending: [String: PendingMark] = [:]
    /// Runs deleted on the phone that the vault still has.
    var deletedRuns: [String: PendingMark] = [:]
    var food: [String: FoodDayState] = [:]
    var profile: BodyProfile?
    var profilePending: PendingMark?
    var foodLibrary: [LibraryItem] = []
    /// Planner: WebUntis cache, the user's own marks, deletions not yet acknowledged.
    var untis = UntisCache()
    var schoolOverrides: [String: SchoolOverride] = [:]
    var overridePending: [String: PendingMark] = [:]
    var deletedAppointments: [String: PendingMark] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = c.value(.days, [:])
        tasks = c.value(.tasks, [])
        appointments = c.value(.appointments, [])
        suggestions = c.value(.suggestions, [])
        mailCursors = c.value(.mailCursors, [:])
        outbox = c.value(.outbox, [])
        habits = c.value(.habits, HabitConfig.defaults)
        settings = c.value(.settings, AppSettings())
        lastPush = c.optional(.lastPush)
        lastPull = c.optional(.lastPull)
        lastSnapshotAt = c.optional(.lastSnapshotAt)
        lastIngestAt = c.optional(.lastIngestAt)
        snapshotEtag = c.optional(.snapshotEtag)
        bridgeErrors = c.value(.bridgeErrors, [])
        lastSyncError = c.optional(.lastSyncError)
        lastMailCheck = c.optional(.lastMailCheck)
        bridgeFeatures = c.value(.bridgeFeatures, [])
        pluginVersion = c.optional(.pluginVersion)
        runs = c.value(.runs, [])
        runPending = c.value(.runPending, [:])
        deletedRuns = c.value(.deletedRuns, [:])
        food = c.value(.food, [:])
        profile = c.optional(.profile)
        profilePending = c.optional(.profilePending)
        foodLibrary = c.value(.foodLibrary, [])
        untis = c.value(.untis, UntisCache())
        schoolOverrides = c.value(.schoolOverrides, [:])
        overridePending = c.value(.overridePending, [:])
        deletedAppointments = c.value(.deletedAppointments, [:])
    }
}
