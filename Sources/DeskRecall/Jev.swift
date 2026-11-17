import Foundation
import Security

/// TypeSafe Jev: a decision model. It takes state plus typed questions and returns typed answers
/// with calibrated probabilities, which is what the fuzzy parts of arranging need
/// ("which saved profile is this setup closest to?", "which saved slot is this window?").
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
    static var apiKey: String? {
        get {
            if let env = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !env.isEmpty { return env }
            if loaded { return stored }
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Config.keychainService,
                                        kSecAttrAccount as String: Config.keychainAccount, kSecReturnData as String: true]
            var out: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &out)
            // Remember only a definite answer; a keychain that is locked right now is asked again next time.
            loaded = status == errSecSuccess || status == errSecItemNotFound
            guard status == errSecSuccess, let data = out as? Data else { return nil }
            stored = String(data: data, encoding: .utf8)
            return stored
        }
        set {
            stored = (newValue?.isEmpty ?? true) ? nil : newValue
            loaded = true
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Config.keychainService,
                                       kSecAttrAccount as String: Config.keychainAccount]
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            SecItemAdd(base.merging([kSecValueData as String: Data(newValue.utf8)]) { $1 } as CFDictionary, nil)
        }
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
