import Foundation
import ImageIO
import TagwerkCore
import UIKit
import Vision

/// Text and image recognition on the device (Vision). Nothing leaves the phone.
enum FoodRecognition {
    struct Candidate: Identifiable, Hashable {
        var label: String
        var term: String
        var confidence: Double
        var items: [FoodItem]
        var id: String { term }
    }

    /// Lines of text, top to bottom, words of a row joined left to right (table rows of a nutrition label).
    static func textLines(in image: UIImage) async -> [String] {
        guard let cg = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE", "en-US"]
            request.usesLanguageCorrection = false
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try VNImageRequestHandler(cgImage: cg, orientation: orientation).perform([request])
                    cont.resume(returning: rows(request.results ?? []))
                } catch {
                    cont.resume(returning: [])
                }
            }
        }
    }

    static func rows(_ obs: [VNRecognizedTextObservation]) -> [String] {
        let items = obs.compactMap { o -> (box: CGRect, text: String)? in
            guard let t = o.topCandidates(1).first?.string else { return nil }
            return (o.boundingBox, t)
        }
        // Vision's origin is bottom left: higher midY means further up.
        let sorted = items.sorted { $0.box.midY > $1.box.midY }
        var rows: [[(box: CGRect, text: String)]] = []
        for it in sorted {
            if let lastRow = rows.last, let ref = lastRow.first, abs(ref.box.midY - it.box.midY) < max(ref.box.height, it.box.height) * 0.6 {
                rows[rows.count - 1].append(it)
            } else {
                rows.append([it])
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
    }

    /// What the classifier sees, mapped to foods of the table. Only suggestions.
    static func classify(_ image: UIImage, index: FoodIndex?) async -> [Candidate] {
        guard let cg = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let observations: [VNClassificationObservation] = await withCheckedContinuation { cont in
            let request = VNClassifyImageRequest()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try VNImageRequestHandler(cgImage: cg, orientation: orientation).perform([request])
                    cont.resume(returning: request.results ?? [])
                } catch {
                    cont.resume(returning: [])
                }
            }
        }
        var out: [Candidate] = []
        var seen = Set<String>()
        for o in observations.sorted(by: { $0.confidence > $1.confidence }) where o.confidence >= 0.04 {
            let id = o.identifier.lowercased()
            if FoodVision.generic.contains(id) { continue }
            var term = FoodVision.german(for: id)
            var items: [FoodItem] = []
            if let term, let index {
                if let a = index.alias(for: term) { items.append(a.item) }
                items += index.search(term, limit: 6).map(\.item).filter { i in !items.contains { $0.id == i.id } }
            } else if let index {
                // Not in the word list: try the English names of the table.
                let english = index.search(id.replacingOccurrences(of: "_", with: " "), limit: 5, english: true).map(\.item)
                if !english.isEmpty {
                    items = english
                    term = english.first?.name
                }
            }
            guard let t = term, !items.isEmpty, !seen.contains(t) else { continue }
            seen.insert(t)
            out.append(Candidate(label: t.prefix(1).uppercased() + t.dropFirst(), term: t, confidence: Double(o.confidence), items: Array(items.prefix(6))))
            if out.count >= 6 { break }
        }
        return out
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
