import Foundation
import TagwerkCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device model via the Foundation Models framework. Needs an iPhone with Apple Intelligence
/// (15 Pro or newer) with Apple Intelligence switched on; elsewhere the router falls back to Claude.
enum AppleIntelligence {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    static var statusDescription: String {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Bereit, läuft auf dem Gerät."
        case .unavailable(.deviceNotEligible):
            return "Dieses iPhone unterstützt Apple Intelligence nicht."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence ist in den Einstellungen ausgeschaltet."
        case .unavailable(.modelNotReady):
            return "Das Modell wird noch geladen."
        default:
            return "Derzeit nicht verfügbar."
        }
        #else
        return "Auf diesem System nicht verfügbar."
        #endif
    }

    static func rater() -> DayRater? {
        #if canImport(FoundationModels)
        return AppleDayRater()
        #else
        return nil
        #endif
    }

    static func structurer() -> AppointmentStructurer? {
        #if canImport(FoundationModels)
        return AppleStructurer()
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
@Generable
struct GeneratedAssessment {
    @Guide(description: "Tagesbewertung zwischen 0.0 und 10.0 mit einer Nachkommastelle")
    var rating: Double
    @Guide(description: "Ein bis zwei sachliche Sätze auf Deutsch in der zweiten Person")
    var begruendung: String
    @Guide(description: "Schlüssel der Gewohnheiten, die der Text heute eindeutig als erledigt berichtet, sonst eine leere Liste")
    var erkannteGewohnheiten: [String]
}

struct AppleDayRater: DayRater {
    var name: String { "Apple Intelligence" }

    func assess(_ ctx: DayContext) async throws -> DayAssessment {
        let session = LanguageModelSession(instructions: Prompts.ratingInstructions(userName: ctx.userName))
        let response = try await session.respond(to: Prompts.ratingInput(ctx), generating: GeneratedAssessment.self)
        let g = response.content
        let keys = Set(ctx.habits.map(\.key))
        return DayAssessment(rating: min(10, max(0, (g.rating * 10).rounded() / 10)),
                             reason: g.begruendung.trimmingCharacters(in: .whitespacesAndNewlines),
                             detectedHabits: g.erkannteGewohnheiten.filter { keys.contains($0) },
                             weight: nil, provider: name)
    }
}

@Generable
struct GeneratedAppointment {
    @Guide(description: "Kurzer Titel auf Deutsch, höchstens sechs Wörter")
    var titel: String
    @Guide(description: "Datum im Format JJJJ-MM-TT")
    var datum: String
    @Guide(description: "Beginn im Format HH:MM, leer wenn ganztägig")
    var beginn: String
    @Guide(description: "Ende im Format HH:MM, leer wenn unbekannt")
    var ende: String
    var ganztaegig: Bool
    @Guide(description: "Ort, leer wenn unbekannt")
    var ort: String
    @Guide(description: "Sicherheit zwischen 0.0 und 1.0")
    var sicherheit: Double
}

@Generable
struct GeneratedAppointments {
    @Guide(description: "Gefundene Termine, leer wenn die Mail keinen enthält")
    var termine: [GeneratedAppointment]
}

struct AppleStructurer: AppointmentStructurer {
    var name: String { "Apple Intelligence" }

    func structure(_ mail: MailForExtraction) async throws -> [ExtractedAppointment] {
        let session = LanguageModelSession(instructions: Prompts.extractionInstructions)
        var trimmed = mail
        trimmed.text = String(mail.text.prefix(3000))
        let response = try await session.respond(to: Prompts.extractionInput(trimmed), generating: GeneratedAppointments.self)
        func time(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespaces)
            let p = t.split(separator: ":").compactMap { Int($0) }
            guard p.count == 2, (0...23).contains(p[0]), (0...59).contains(p[1]) else { return nil }
            return String(format: "%02d:%02d", p[0], p[1])
        }
        return response.content.termine.compactMap { g in
            guard DayKey.ordinal(g.datum) != nil, !g.titel.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let start = time(g.beginn)
            return ExtractedAppointment(title: g.titel, date: g.datum, startTime: start, endTime: time(g.ende),
                                        allDay: g.ganztaegig || start == nil, location: g.ort.isEmpty ? nil : g.ort,
                                        confidence: min(1, max(0, g.sicherheit)))
        }
    }
}
#endif
