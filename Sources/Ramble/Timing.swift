import Foundation
import os

final class CaptureTiming: Sendable {
    struct Event: Codable, Sendable {
        let name: String
        let ms: Double
        let segment: String?
        let audioEndMS: Double?
        let inputTokens: Int?
        let outputTokens: Int?
    }

    struct Record: Codable {
        let capture: UUID
        let transcriber: String
        let model: String
        let language: String
        let strategy: String
        let first: Bool
        let vocabulary: Bool
        let events: [Event]
    }

    let id = UUID()
    let started = ContinuousClock.now
    let transcriber: String
    let model: String
    let language: String
    let strategy: String
    let first: Bool
    let vocabulary: Bool
    private let events = OSAllocatedUnfairLock(initialState: [Event]())

    init(transcriber: String, model: String, language: String, strategy: String, first: Bool, vocabulary: Bool) {
        self.transcriber = transcriber
        self.model = model
        self.language = language
        self.strategy = strategy
        self.first = first
        self.vocabulary = vocabulary
        mark("start")
    }

    func mark(_ name: String, segment: String? = nil, audioEndMS: Double? = nil, usage: ExtractionUsage? = nil,
              at instant: ContinuousClock.Instant = .now, once: Bool = false) {
        let elapsed = started.duration(to: instant).components
        let ms = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        events.withLock {
            if once, $0.contains(where: { $0.name == name && $0.segment == segment }) { return }
            $0.append(Event(name: name, ms: ms, segment: segment, audioEndMS: audioEndMS,
                            inputTokens: usage?.input_tokens, outputTokens: usage?.output_tokens))
        }
    }

    var record: Record {
        Record(capture: id, transcriber: transcriber, model: model, language: language, strategy: strategy,
               first: first, vocabulary: vocabulary, events: events.withLock { $0.sorted { $0.ms < $1.ms } })
    }

    static func write(_ record: Record) async {
        do {
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Things 3 Ramble/Timings", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(record.capture.uuidString).appendingPathExtension("json")
            try JSONEncoder().encode(record).write(to: file, options: .atomic)
        } catch {
            Logger(subsystem: "com.raphaelkieling.things3ramble", category: "Timing")
                .error("Could not write timing data")
        }
    }
}
