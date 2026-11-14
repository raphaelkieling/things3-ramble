import AVFAudio
import Foundation

private struct Clip: Decodable {
    let id: String
    let language: String
    let text: String
    let anchor: String
    let terms: [String]
    let absent: [String]
}

private struct Sample: Codable, Sendable {
    let ms: Double
    let text: String
    var audioEndMS: Double? = nil
    var enterMS: Double? = nil
}

private actor Partials {
    var values: [Sample] = []
    func append(_ sample: Sample) { values.append(sample) }
}

private struct Result: Encodable {
    let clip: String
    let timing: CaptureTiming.Record
    var transcript: String? = nil
    var tasks: [SpokenTask]? = nil
    var error: String? = nil
}

@main
struct Bench {
    private static let primary = ExtractionProfile()
    private static let candidate = ExtractionProfile(model: "gpt-5.6-luna", serviceTier: "default", effort: "none")
    private static let date = ISO8601DateFormatter().date(from: "2026-11-11T15:00:00Z")!

    static func main() async throws {
        let root = URL(fileURLWithPath: "Benchmarks", isDirectory: true)
        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: root.appendingPathComponent("corpus.json")))
        let args = ProcessInfo.processInfo.arguments
        let count = args.dropFirst().first.flatMap(Int.init) ?? 2
        guard count > 0 else { throw RambleError("Informe um número positivo de repetições.") }
        let download = args.contains("--download")
        let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        let api = key.map { OpenAI(apiKey: $0) }
        if key == nil { print("Sem OPENAI_API_KEY: etapas na nuvem serão omitidas.") }
        let output = root.appendingPathComponent("results.jsonl")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }
        let encoder = JSONEncoder()
        func save(_ result: Result) throws {
            try file.write(contentsOf: encoder.encode(result) + Data([10]))
            print("\(result.clip) \(result.timing.transcriber) \(result.timing.strategy) \(result.timing.vocabulary ? "+voc" : "-voc"): \(result.error ?? "ok")")
        }

        var seen = Set<String>()
        for pass in 0..<count {
            for clip in clips {
                let providers = args.contains("--openai-only") ? ["gpt"] : (key == nil ? ["apple"] : ["apple", "gpt"])
                var match: [Sample]?
                for provider in providers {
                    if provider == "gpt", key == nil { throw RambleError("Defina OPENAI_API_KEY para testar GPT.") }
                    for hints in (pass.isMultiple(of: 2) ? [false, true] : [true, false]) {
                        let first = seen.insert("\(provider)/\(clip.language)").inserted
                        let timing = CaptureTiming(transcriber: provider, model: api == nil ? "—" : primary.model,
                                                   language: clip.language, strategy: "transcription", first: first, vocabulary: hints)
                        do {
                            let folder = root.appendingPathComponent("audio")
                            let url = folder.appendingPathComponent(clip.id + ".wav")
                            let mark = try String(contentsOf: url.deletingPathExtension().appendingPathExtension("end"), encoding: .utf8)
                            let audioEnd = Double(mark.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                            let (text, samples) = try await withDeadline(.seconds(50)) {
                                try await transcribe(clip, url: url, vocab: hints ? clip.terms + clip.absent : [],
                                                     provider: provider, key: key, timing: timing, audioEnd: audioEnd, download: download)
                            }
                            if !hints, provider == "apple" || match == nil { match = samples }
                            var tasks: [SpokenTask]?
                            if let api, !text.isEmpty {
                                do {
                                    tasks = try await extract(api, text: text, timing: timing, segment: "final", profile: primary)
                                } catch {
                                    timing.mark("extraction_failure")
                                    try save(Result(clip: clip.id, timing: timing.record, transcript: text, error: error.localizedDescription))
                                    continue
                                }
                            }
                            timing.mark("success")
                            try save(Result(clip: clip.id, timing: timing.record, transcript: text, tasks: tasks))
                        } catch {
                            timing.mark("failure")
                            try save(Result(clip: clip.id, timing: timing.record, error: error.localizedDescription))
                        }
                    }
                }
                guard let api else { continue }
                for profile in [primary, candidate] {
                    let timing = CaptureTiming(transcriber: "reference", model: profile.model, language: clip.language,
                                               strategy: "final", first: seen.insert(profile.model).inserted, vocabulary: false)
                    try save(await score(api, clip: clip, timing: timing, profile: profile, samples: []))
                }
                if let match, !match.isEmpty {
                    for strategy in ["current", "pause", "final"] {
                        let timing = CaptureTiming(transcriber: "replay", model: primary.model, language: clip.language,
                                                   strategy: strategy, first: false, vocabulary: false)
                        try save(await score(api, clip: clip, timing: timing, profile: primary, samples: match))
                    }
                }
            }
        }
    }

    private static func withDeadline<T: Sendable>(_ limit: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: limit)
                throw RambleError("Tempo limite do transcritor.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func transcribe(_ clip: Clip, url: URL, vocab: [String], provider: String, key: String?,
                                   timing: CaptureTiming, audioEnd: Double, download: Bool) async throws -> (String, [Sample]) {
        var local: LocalTranscriber?
        if provider == "apple" {
            local = try await LocalTranscriber.prepare(locale: RambleLanguage(rawValue: clip.language)!.speechLocale, vocabulary: vocab, download: download)
            guard local != nil else { throw RambleError("Apple Speech indisponível para este idioma.") }
        }
        let source = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let format = local?.format ?? source.processingFormat
        guard let converter = AVAudioConverter(from: source.processingFormat, to: format) else {
            throw RambleError("Formato de áudio incompatível.")
        }
        let audio = AsyncThrowingStream<CapturedAudio, Error>.makeStream()
        let partials = Partials()
        let onPartial: @Sendable (TranscriptUpdate) async -> Void = { update in
            let now = ContinuousClock.now
            let ms = milliseconds(timing.started.duration(to: now))
            let anchored = contains(update.text, clip.anchor)
            await partials.append(Sample(ms: ms, text: update.text, audioEndMS: anchored ? audioEnd : nil))
            if anchored {
                timing.mark(update.isFinal ? "segment_final" : "segment_partial",
                            segment: clip.id, audioEndMS: audioEnd, at: now, once: true)
            }
        }
        async let feeding: Void = feed(source, converter: converter, audio: audio.continuation, timing: timing)
        let text: String
        if let local {
            timing.mark("ready")
            text = try await local.run(audio: audio.stream, onPartial: onPartial)
        } else {
            text = try await RealtimeTranscriber(apiKey: key!, vocabulary: vocab)
                .run(audio: audio.stream, onReady: { timing.mark("ready") }, onPartial: onPartial)
        }
        try await feeding
        if contains(text, clip.anchor) {
            timing.mark("segment_final", segment: clip.id, audioEndMS: audioEnd, once: true)
        }
        timing.mark("final_transcript")
        let samples = await partials.values
        let record = timing.record.events
        let enter = record.first { $0.name == "enter" }!.ms
        let origin = record.first { $0.name == "first_buffer" }!.ms
        let replay = samples.filter { $0.ms < enter }.map { Sample(ms: $0.ms - origin, text: $0.text, audioEndMS: $0.audioEndMS) }
        let final = record.first { $0.name == "final_transcript" }!.ms
        return (text, replay + [Sample(ms: final - origin, text: text, enterMS: enter - origin)])
    }

    private static func feed(_ file: AVAudioFile, converter: AVAudioConverter,
                             audio: AsyncThrowingStream<CapturedAudio, Error>.Continuation, timing: CaptureTiming) async throws {
        let origin = ContinuousClock.now
        timing.mark("first_buffer", at: origin)
        var frames = 0
        do {
            while file.framePosition < file.length {
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2_400)!
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                frames += Int(buffer.frameLength)
                try await ContinuousClock().sleep(until: origin.advanced(by: .seconds(Double(frames) / file.processingFormat.sampleRate)))
                let pcm = try AudioCapture.convert(buffer, with: converter)
                if pcm.frameLength > 0 { audio.yield(CapturedAudio(buffer: pcm)) }
            }
            timing.mark("enter")
            audio.finish()
        } catch {
            audio.finish(throwing: error)
            throw error
        }
    }

    private static func extract(_ api: OpenAI, text: String, timing: CaptureTiming, segment: String,
                                profile: ExtractionProfile) async throws -> [SpokenTask] {
        timing.mark("extract_start", segment: segment)
        let result = try await api.extract(from: text, today: date, profile: profile)
        timing.mark("extract_end", segment: segment, usage: result.usage)
        return result.tasks
    }

    private static func score(_ api: OpenAI, clip: Clip, timing: CaptureTiming,
                              profile: ExtractionProfile, samples: [Sample]) async -> Result {
        do {
            var tasks: [SpokenTask] = []
            var lastText = ""
            if let final = samples.last, let end = final.enterMS {
                let stream = Array(samples.dropLast())
                let origin = timing.started
                timing.mark("audio_origin", at: origin)
                if timing.strategy != "final" {
                    var consumed = 0
                    while consumed < stream.count {
                        let next = stream[consumed]
                        let now = max(next.ms, milliseconds(origin.duration(to: .now)))
                        var due = now + (timing.strategy == "pause" ? 700 : lastText.isEmpty ? 180 : 600)
                        if timing.strategy == "pause" {
                            for sample in stream[consumed...] where sample.ms > now {
                                guard sample.ms < due else { break }
                                due = sample.ms + 700
                            }
                        }
                        guard due < end else { break }
                        let batch = stream[consumed...].prefix { $0.ms <= due }
                        guard let latest = batch.last else { break }
                        consumed += batch.count
                        guard latest.text != lastText else { continue }
                        try await ContinuousClock().sleep(until: origin.advanced(by: .seconds(due / 1_000)))
                        lastText = latest.text
                        let id = String(latest.ms)
                        timing.mark("transcript", segment: id, audioEndMS: latest.audioEndMS, at: origin.advanced(by: .seconds(latest.ms / 1_000)))
                        do {
                            let updated = try await withDeadline(.seconds((end - due) / 1_000)) {
                                try await extract(api, text: latest.text, timing: timing, segment: id, profile: profile)
                            }
                            if updated != tasks { timing.mark("preview_ready", segment: id) }
                            tasks = updated
                        } catch {
                            timing.mark("preview_failure", segment: id)
                            lastText = ""
                            if milliseconds(origin.duration(to: .now)) >= end { break }
                        }
                    }
                }
                let enter = origin.advanced(by: .seconds(end / 1_000))
                try await ContinuousClock().sleep(until: enter)
                timing.mark("enter", at: enter)
                try await ContinuousClock().sleep(until: origin.advanced(by: .seconds(final.ms / 1_000)))
                timing.mark("final_transcript")
            } else {
                timing.mark("enter")
            }
            let final = samples.last?.text ?? clip.text
            if final != lastText {
                tasks = try await extract(api, text: final, timing: timing, segment: "final", profile: profile)
            }
            timing.mark("final_ready")
            timing.mark("success")
            return Result(clip: clip.id, timing: timing.record, transcript: final, tasks: tasks)
        } catch {
            timing.mark("failure")
            return Result(clip: clip.id, timing: timing.record, error: error.localizedDescription)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }

    private static func contains(_ text: String, _ phrase: String) -> Bool {
        text.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
