import Foundation

struct TranscriptEvent: Decodable, Sendable {
    static let committed = "input_audio_buffer.committed"
    static let delta = "conversation.item.input_audio_transcription.delta"
    static let completed = "conversation.item.input_audio_transcription.completed"
    static let failed = "conversation.item.input_audio_transcription.failed"

    struct Failure: Decodable, Sendable { let code: String? }

    let type: String
    let itemID: String?
    let delta: String?
    let transcript: String?
    let error: Failure?

    enum CodingKeys: String, CodingKey {
        case type, delta, transcript, error
        case itemID = "item_id"
    }
}

struct TranscriptTurn {
    private var committedID: String?
    private var partials: [String: String] = [:]
    private var finals: [String: String] = [:]

    mutating func apply(_ event: TranscriptEvent) -> (partial: String?, final: String?) {
        guard let id = event.itemID else { return (nil, nil) }

        switch event.type {
        case TranscriptEvent.committed:
            committedID = id
        case TranscriptEvent.delta:
            if let fragment = event.delta, committedID == nil || committedID == id {
                partials[id, default: ""].append(fragment)
                return (partials[id], nil)
            }
        case TranscriptEvent.completed:
            finals[id] = event.transcript ?? ""
        default:
            break
        }
        return (nil, committedID.flatMap { finals[$0] })
    }
}

struct RealtimeTranscriber {
    let apiKey: String

    func run(
        audio: AsyncThrowingStream<Data, Error>,
        onReady: @escaping @Sendable () async -> Void,
        onPartial: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let socket = OpenAI.network.webSocketTask(with: request)
        socket.resume()

        return try await withTaskCancellationHandler {
            defer { socket.cancel(with: .goingAway, reason: nil) }
            do {
                try await Self.send([
                    "type": "session.update",
                    "session": [
                        "type": "transcription",
                        "audio": ["input": [
                            "format": ["type": "audio/pcm", "rate": 24_000],
                            "transcription": ["model": "gpt-live-transcribe", "delay": "minimal"],
                            "turn_detection": NSNull(),
                        ]],
                    ],
                ], to: socket)
                while try await Self.receive(from: socket).type != "session.updated" {
                    try Task.checkCancellation()
                }
                await onReady()

                return try await withThrowingTaskGroup(of: String?.self) { group in
                    group.addTask {
                        var bytes = 0
                        for try await chunk in audio {
                            try Task.checkCancellation()
                            try await Self.send(["type": "input_audio_buffer.append", "audio": chunk.base64EncodedString()], to: socket)
                            bytes += chunk.count
                        }
                        try Task.checkCancellation()
                        // Realtime requires at least 100 ms in the buffer for a commit.
                        if bytes < 4_800 { return "" }
                        try await Self.send(["type": "input_audio_buffer.commit"], to: socket)
                        return nil
                    }
                    group.addTask {
                        var turn = TranscriptTurn()
                        while true {
                            let event = try await Self.receive(from: socket)
                            if event.type == TranscriptEvent.failed {
                                throw RambleError(tr("A OpenAI não conseguiu transcrever a gravação."))
                            }
                            let update = turn.apply(event)
                            if let partial = update.partial { await onPartial(partial) }
                            if let final = update.final { return final.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                    }

                    defer {
                        group.cancelAll()
                        socket.cancel(with: .goingAway, reason: nil)
                    }
                    while let result = try await group.next() {
                        if let result { return result }
                    }
                    throw RambleError(tr("A conexão de áudio foi encerrada."))
                }
            } catch {
                if let status = (socket.response as? HTTPURLResponse)?.statusCode, !(200...299).contains(status), status != 101 {
                    throw OpenAI.httpError(status)
                }
                throw error
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private static func send(_ value: [String: Any], to socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private static func receive(from socket: URLSessionWebSocketTask) async throws -> TranscriptEvent {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .string(let value): data = Data(value.utf8)
        case .data(let value): data = value
        @unknown default: throw RambleError(tr("A OpenAI enviou uma resposta de áudio inválida."))
        }

        let event = try JSONDecoder().decode(TranscriptEvent.self, from: data)
        if event.type == "error" {
            switch event.error?.code {
            case "invalid_api_key": throw OpenAI.httpError(401)
            case "rate_limit_exceeded", "insufficient_quota": throw OpenAI.httpError(429)
            default: throw RambleError(tr("A OpenAI recusou a sessão de transcrição. Confira o acesso ao modelo gpt-live-transcribe."))
            }
        }
        return event
    }
}
