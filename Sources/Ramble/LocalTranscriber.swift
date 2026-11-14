import AVFAudio
import CoreMedia
import Foundation
import Speech

@available(macOS 26, *)
struct LocalTranscriber {
    let format: AVAudioFormat
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber

    static func prepare(locale: Locale, vocabulary: [String] = [], download: Bool = true) async throws -> Self? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            guard download else { throw RambleError("Modelo de voz da Apple ainda não instalado para este idioma.") }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw RambleError(tr("Não foi possível preparar a transcrição local."))
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: vocabulary]
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)
        return Self(format: format, analyzer: analyzer, transcriber: transcriber)
    }

    func run(
        audio: AsyncThrowingStream<CapturedAudio, Error>,
        onPartial: @escaping @Sendable (TranscriptUpdate) async -> Void
    ) async throws -> String {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    let inputs = audio.map { AnalyzerInput(buffer: $0.buffer) }
                    if let end = try await analyzer.analyzeSequence(inputs) {
                        try await analyzer.finalizeAndFinish(through: end)
                    } else {
                        await analyzer.cancelAndFinishNow()
                    }
                    return nil
                }
                group.addTask {
                    var segments: [(range: CMTimeRange, text: String)] = []
                    var transcript = ""
                    for try await result in transcriber.results {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        // The transcriber revises earlier partial results for the same audio range.
                        segments.removeAll { $0.range.intersection(result.range).duration > .zero }
                        if !text.isEmpty { segments.append((result.range, text)) }
                        segments.sort { $0.range.start < $1.range.start }
                        let updated = segments.map(\.text).joined(separator: " ")
                        if updated != transcript || result.isFinal {
                            transcript = updated
                            await onPartial(TranscriptUpdate(
                                text: updated, segment: String(result.range.start.seconds),
                                audioEndMS: result.range.end.seconds * 1_000, isFinal: result.isFinal
                            ))
                        }
                    }
                    return transcript
                }

                do {
                    var transcript = ""
                    for try await result in group {
                        if let result { transcript = result }
                    }
                    return transcript
                } catch {
                    group.cancelAll()
                    await analyzer.cancelAndFinishNow()
                    throw error
                }
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
