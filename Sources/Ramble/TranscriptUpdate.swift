struct TranscriptUpdate: Sendable {
    let text: String
    let segment: String
    var audioEndMS: Double? = nil
    var isFinal = false
}
