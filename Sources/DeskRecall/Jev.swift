import Foundation
import Security

/// TypeSafe Jev: a decision model. It takes state plus typed questions and returns typed answers
/// with calibrated probabilities. Optional: with a key it gives a second opinion on the one
/// question the rules can leave open ("which saved slot is this reopened window?").
enum Jev {
    struct Answer {
        var choice: String?                    // Choice questions
        var confidence: Double = 0
        var probabilities: [String: Double] = [:]
        var yes: Double?                       // Noul (yes/no) questions: probability of yes
    }
    enum Failure: Error { case noKey, http(Int, String), malformed }

    /// The user's TypeSafe API key, kept in the login keychain. The app must add the item itself
    /// (menu, or `--store-key`): an item added by another tool makes macOS prompt on every read.
    /// A TYPESAFE_API_KEY environment variable takes precedence, for command-line use.
    /// Read from the keychain once per launch: the menu asks for it every time it opens.
    private static var stored: String?, loaded = false
    /// The keychain item, without its secret.
    private static let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Config.keychainService,
                                              kSecAttrAccount as String: Config.keychainAccount]
    static var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !env.isEmpty { return env }
        if loaded { return stored }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(item.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &out)
        // Remember only a definite answer; a keychain that is locked right now is asked again next time.
        loaded = status == errSecSuccess || status == errSecItemNotFound
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        stored = String(data: data, encoding: .utf8)
        return stored
    }

    /// Whether a key is stored, found without reading it. Asking the keychain for the secret can
    /// make macOS show its permission dialog (after an app update, for one); that is acceptable when
    /// a question is about to be sent to Jev, never just to draw a label or at launch.
    static var hasKey: Bool {
        if let env = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !env.isEmpty { return true }
        if loaded { return stored != nil }
        return SecItemCopyMatching(item as CFDictionary, nil) == errSecSuccess
    }

    /// Puts the key in the keychain; false when the keychain refused. Deletes and adds rather than
    /// updates, so an item first created by another tool ends up owned by this app (no prompts).
    static func store(_ key: String) -> Bool {
        SecItemDelete(item as CFDictionary)
        let saved = SecItemAdd(item.merging([kSecValueData as String: Data(key.utf8)]) { $1 } as CFDictionary, nil) == errSecSuccess
        stored = saved ? key : nil
        loaded = true
        return saved
    }

    /// Takes the key out of the keychain: Settings ▸ Remove, and Uninstall. False when the keychain
    /// refused (locked, say) and the key is therefore still there.
    @discardableResult
    static func remove() -> Bool {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return false }
        stored = nil
        loaded = true
        return true
    }

    static func choice(_ instructions: String, _ options: [String: String]) -> [String: Any] {
        ["type": "choice", "instructions": instructions, "criteria": options]
    }
    static func noul(_ instructions: String) -> [String: Any] {
        ["type": "noul", "instructions": instructions]
    }

    /// One request, any number of questions (they are evaluated in parallel against the same state).
    static func ask(state: Any, questions: [String: [String: Any]]) async throws -> [String: Answer] {
        guard let key = apiKey else { throw Failure.noKey }
        var request = URLRequest(url: Config.jevEndpoint, timeoutInterval: Config.jevTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": Config.jevModel, "state": state, "questions": questions])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.http(status, String(data: data.prefix(300), encoding: .utf8) ?? "") }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> [String: Answer] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: [String: Any]] else { throw Failure.malformed }
        return answers.mapValues { a in
            Answer(choice: a["choice"] as? String,
                   confidence: (a["confidence"] as? NSNumber)?.doubleValue ?? 0,
                   probabilities: (a["probabilities"] as? [String: NSNumber])?.mapValues(\.doubleValue) ?? [:],
                   yes: (a["noul"] as? NSNumber)?.doubleValue)
        }
    }
}
