import Foundation

struct ThingsRequest {
    static let bundleID = "com.culturedcode.ThingsMac"
    private static let callback = "things3ramble://callback"

    enum Result: Equatable {
        case success(Int)
        case rejected
        case canceled
        case unconfirmed
    }

    let id = UUID().uuidString
    let tasks: [SpokenTask]

    func url(token: String) throws -> URL {
        let operations = tasks.map { task -> [String: Any] in
            var attributes: [String: Any] = ["title": task.title]
            attributes["notes"] = task.notes
            attributes["when"] = task.when
            attributes["deadline"] = task.deadline
            if !task.checklist.isEmpty {
                attributes["checklist-items"] = task.checklist.map {
                    ["type": "checklist-item", "attributes": ["title": $0]]
                }
            }
            return ["type": "to-do", "operation": "create", "attributes": attributes]
        }
        let data = try JSONSerialization.data(withJSONObject: operations)
        var components = URLComponents(string: "things:///json")!
        components.queryItems = [
            URLQueryItem(name: "data", value: String(decoding: data, as: UTF8.self)),
            URLQueryItem(name: "auth-token", value: token),
            URLQueryItem(name: "x-success", value: "\(Self.callback)/success/\(id)"),
            URLQueryItem(name: "x-error", value: "\(Self.callback)/error/\(id)"),
            URLQueryItem(name: "x-cancel", value: "\(Self.callback)/cancel/\(id)"),
        ]
        // Some query decoders interpret a literal plus as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw RambleError("Não foi possível montar o link do Things.") }
        return url
    }

    func result(for url: URL) -> Result? {
        guard url.scheme == "things3ramble", url.host == "callback",
              url.lastPathComponent == id, url.pathComponents.count == 3 else { return nil }

        switch url.pathComponents[1] {
        case "success":
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "x-things-ids" }?.value
            guard let value, let ids = try? JSONDecoder().decode([String].self, from: Data(value.utf8)),
                  ids.count == tasks.count, Set(ids).count == ids.count,
                  ids.allSatisfy({ !$0.isEmpty }) else { return .unconfirmed }
            return .success(ids.count)
        case "error": return .rejected
        case "cancel": return .canceled
        default: return nil
        }
    }
}
