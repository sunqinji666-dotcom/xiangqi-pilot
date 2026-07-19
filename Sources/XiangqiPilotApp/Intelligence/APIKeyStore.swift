import Foundation
import Security

struct APIKeyStore: Sendable {
    private let service = "com.jacksun.xiangqi-pilot.model-keys"
    private let developmentStore = DevelopmentCredentialStore()

    func save(_ key: String, account: String) throws {
        // Development mode deliberately avoids Keychain interaction on every
        // launch. This keeps the visual pilot usable while the integration is
        // being stabilized. The file is local to this macOS account and never
        // logged or bundled with the app.
        try developmentStore.save(key, account: account)
    }

    func load(account: String) throws -> String? {
        if let cached = try developmentStore.load(account: account), !cached.isEmpty {
            return cached
        }

        // The user supplied an Alibaba export CSV during setup. Import it only
        // when no local development cache exists, then stop touching the CSV.
        // This avoids even the one-time Keychain password dialog.
        if let imported = try developmentStore.importAlibabaExportedKey(), !imported.isEmpty {
            try? developmentStore.save(imported, account: account)
            return imported
        }

        // One-time migration path for the key that was previously stored in
        // Keychain. After a successful read it is cached locally, so later app
        // launches do not query Keychain or show its password dialog.
        guard let key = try loadFromKeychain(account: account), !key.isEmpty else {
            return nil
        }
        try? developmentStore.save(key, account: account)
        return key
    }

    func delete(account: String) throws {
        try developmentStore.delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func loadFromKeychain(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return value
    }
}

/// A temporary local credential cache used only for development. It avoids the
/// repeated Keychain prompt that blocks a visual monitoring loop. The directory
/// and file are restricted to the current account (0700 / 0600).
private struct DevelopmentCredentialStore: Sendable {
    private var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("棋局驾驶舱", isDirectory: true)
            .appendingPathComponent("DevelopmentCredentials", isDirectory: true)
    }

    func load(account: String) throws -> String? {
        let url = credentialURL(for: account)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return String(data: try Data(contentsOf: url), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func save(_ key: String, account: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = credentialURL(for: account)
        try Data(key.utf8).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func delete(account: String) throws {
        let url = credentialURL(for: account)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func importAlibabaExportedKey() throws -> String? {
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: downloads,
            includingPropertiesForKeys: nil
        ) else { return nil }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where
            file.lastPathComponent.hasPrefix("默认业务空间-apiKey-") && file.pathExtension == "csv" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(whereSeparator: { $0.isNewline }) {
                let fields = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.count == 2 else { continue }
                let name = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
                if name == "apiKey" {
                    return fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private func credentialURL(for account: String) -> URL {
        let safeName = account.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? Character(String(scalar))
                : "_"
        }
        return directoryURL.appendingPathComponent(String(safeName), isDirectory: false)
    }
}
