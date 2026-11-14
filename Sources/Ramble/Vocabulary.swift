import Foundation

enum Vocabulary {
    static let preference = "customVocabulary"
    static var current: [String] {
        terms(UserDefaults.standard.string(forKey: preference) ?? "")
    }

    static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let term = line.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, term.count <= 120, !term.contains("<"), !term.contains(">"),
                  seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }
    }
}
