import Foundation
import Security

struct Credentials: Codable {
    let openAIKey: String
    let thingsToken: String

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.raphaelkieling.things3ramble",
            kSecAttrAccount as String: "Credenciais",
        ]
    }

    static func load() throws -> Credentials? {
        var query = Self.query
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else {
            throw RambleError("Não foi possível ler as credenciais salvas nas Chaves do macOS.")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        let query = Self.query as CFDictionary
        if openAIKey.isEmpty && thingsToken.isEmpty {
            let status = SecItemDelete(query)
            if status != errSecItemNotFound { try Self.check(status) }
            return
        }
        guard !openAIKey.isEmpty, !thingsToken.isEmpty else {
            throw RambleError("Preencha os dois campos ou deixe os dois vazios para apagar as credenciais.")
        }

        let value = [kSecValueData as String: try JSONEncoder().encode(self)]
        let status = SecItemUpdate(query, value as CFDictionary)
        if status == errSecItemNotFound {
            try Self.check(SecItemAdd(Self.query.merging(value) { _, new in new } as CFDictionary, nil))
        } else {
            try Self.check(status)
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw RambleError("Não foi possível acessar as Chaves do macOS (código \(status)).")
        }
    }
}
