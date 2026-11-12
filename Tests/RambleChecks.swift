import AVFAudio
import Foundation

@main
enum RambleChecks {
    static func main() throws {
        try testLiveFragmentsAreCombinedAndOnlyTheCommittedTurnCanFinish()
        try testValidatesDatesAndKeepsExplicitTaskDetails()
        try testThingsUsesACreateBatchAndConfirmsTheMatchingIDs()
        try testConvertsStereoInputToRealtimePCM()
        testMeterKeepsRecentLevelsInOrder()
        print("5 verificações passaram.")
    }

    private static func require<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) -> T {
        guard let value else { preconditionFailure("Valor ausente", file: file, line: line) }
        return value
    }

    private static func testLiveFragmentsAreCombinedAndOnlyTheCommittedTurnCanFinish() throws {
        func event(_ type: String, _ id: String, _ fields: [String: String] = [:]) throws -> TranscriptEvent {
            let object = ["type": type, "item_id": id].merging(fields) { _, new in new }
            return try JSONDecoder().decode(TranscriptEvent.self, from: JSONSerialization.data(withJSONObject: object))
        }

        var turn = TranscriptTurn()
        let first = try event(TranscriptEvent.delta, "capture", ["delta": "Enviar"])
        let second = try event(TranscriptEvent.delta, "capture", ["delta": " o contrato"])
        precondition(turn.apply(first).partial == "Enviar")
        precondition(turn.apply(second).partial == "Enviar o contrato")

        let otherFinal = try event(TranscriptEvent.completed, "other", ["transcript": "Outro trecho"])
        precondition(turn.apply(otherFinal).final == nil)
        let completed = try event(TranscriptEvent.completed, "capture", ["transcript": "Enviar o contrato à Marina."])
        precondition(turn.apply(completed).final == nil)
        let commit = try event(TranscriptEvent.committed, "capture")
        precondition(turn.apply(commit).final == "Enviar o contrato à Marina.")
    }

    private static func testValidatesDatesAndKeepsExplicitTaskDetails() throws {
        let task = SpokenTask(title: "  Preparar  café ", notes: " Usar o pó novo.\n\n- Limpar a bancada. ",
                              deadline: "2026-02-30", when: "2026-11-13@07:30", checklist: [" Comprar filtro ", ""])
        let other = SpokenTask(title: "Telefonar", notes: nil, deadline: "2026-11-16", when: "2026-11-13@26:00", checklist: [])
        let data = try JSONEncoder().encode(["tasks": [task, task, other]])
        let response = try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "output": [["type": "message", "content": [["type": "output_text", "text": String(decoding: data, as: UTF8.self)]]]],
        ])
        let tasks = try OpenAI.decodeTasks(response)
        precondition(tasks == [
            SpokenTask(title: "Preparar café", notes: "Usar o pó novo.\n\n- Limpar a bancada.",
                       deadline: nil, when: "2026-11-13@07:30", checklist: ["Comprar filtro"]),
            SpokenTask(title: "Telefonar", notes: nil, deadline: "2026-11-16", when: nil, checklist: []),
        ])
    }

    private static func testThingsUsesACreateBatchAndConfirmsTheMatchingIDs() throws {
        let tasks = [
            SpokenTask(title: "Revisar A+B & café", notes: "50%\nÀ tarde.", deadline: "2026-11-17",
                       when: nil, checklist: ["Separar A+B"]),
            SpokenTask(title: "Ligar para a gráfica", notes: nil, deadline: nil, when: "2026-11-12@09:30", checklist: []),
        ]
        let area = ThingsDestination(id: "work-area-id", name: "Work", isProject: false)
        let batch = ThingsRequest(tasks: tasks, destinations: [tasks[0].previewKey: area])
        let url = try batch.url(token: "fake+&token")
        precondition(url.scheme == "things")
        precondition(url.path == "/json")
        precondition(!url.absoluteString.contains("+"))
        let components = require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        precondition(items["auth-token"] == "fake+&token")
        let payload = require(items["data"])
        let operations = require(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: Any]])
        precondition(operations.count == 2)
        precondition(operations.allSatisfy { $0["type"] as? String == "to-do" && $0["operation"] as? String == "create" })
        let first = require(operations[0]["attributes"] as? [String: Any])
        precondition(first["title"] as? String == tasks[0].title)
        precondition(first["notes"] as? String == tasks[0].notes)
        precondition(first["deadline"] as? String == tasks[0].deadline)
        precondition(first["list-id"] as? String == area.id)
        let checklist = require(first["checklist-items"] as? [[String: Any]])
        precondition(checklist[0]["type"] as? String == "checklist-item")
        precondition((checklist[0]["attributes"] as? [String: String])?["title"] == "Separar A+B")
        let second = require(operations[1]["attributes"] as? [String: String])
        precondition(second["when"] == tasks[1].when)
        precondition(second["list-id"] == nil)

        let success = require(items["x-success"])
        var callback = require(URLComponents(string: success))
        callback.queryItems = [URLQueryItem(name: "x-things-ids", value: #"["first","second"]"#)]
        precondition(batch.result(for: require(callback.url)) == .success(2))

        callback.queryItems = [URLQueryItem(name: "x-things-ids", value: #"["first","first"]"#)]
        precondition(batch.result(for: require(callback.url)) == .unconfirmed)
        precondition(ThingsRequest(tasks: tasks).result(for: require(callback.url)) == nil)

        let canceled = require(items["x-cancel"].flatMap(URL.init(string:)))
        precondition(batch.result(for: canceled) == .canceled)
    }

    private static func testConvertsStereoInputToRealtimePCM() throws {
        let source = require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let target = require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true))
        let converter = require(AVAudioConverter(from: source, to: target))
        let buffer = require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 2_048))
        buffer.frameLength = 2_048
        let channels = require(buffer.floatChannelData)
        for frame in 0..<2_048 {
            let tone = 0.25 * sin(Float(frame) * 0.08)
            channels[0][frame] = tone
            channels[1][frame] = tone
        }

        let result = try AudioCapture.convert(buffer, with: converter)
        precondition(result.format == target)
        precondition((900...1_088).contains(result.frameLength))
        let samples = require(result.int16ChannelData?.pointee)
        precondition(UnsafeBufferPointer(start: samples, count: Int(result.frameLength)).contains { $0 > 2_000 })
    }

    private static func testMeterKeepsRecentLevelsInOrder() {
        let meter = VoiceMeter()
        precondition(meter.levels == Array(repeating: 0, count: VoiceMeter.barCount))
        let samples = (0...VoiceMeter.barCount).map { Float($0) / Float(VoiceMeter.barCount) }
        for sample in samples { meter.update(sample) }
        precondition(meter.levels == Array(samples.suffix(VoiceMeter.barCount)))
    }
}
