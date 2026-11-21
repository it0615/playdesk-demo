import Foundation

struct KeyMapping: Codable, Identifiable, Equatable {
    var id = UUID()
    var key: String
    var x: Int
    var y: Int
}

struct MacroStep: Codable, Identifiable, Equatable {
    var id = UUID()
    var x: Int
    var y: Int
}

struct ClickMacro: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var steps: [MacroStep]
    var repeatCount: Int
    var repeatForever = false
    var continueInBackground = false
    var intervalMs: Int
    var referenceWidth: Int
    var referenceHeight: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, steps, repeatCount, repeatForever, continueInBackground,
             intervalMs, referenceWidth, referenceHeight
    }

    init(id: UUID = UUID(), name: String, steps: [MacroStep], repeatCount: Int,
         repeatForever: Bool = false, continueInBackground: Bool = false,
         intervalMs: Int, referenceWidth: Int, referenceHeight: Int) {
        self.id = id
        self.name = name
        self.steps = steps
        self.repeatCount = repeatCount
        self.repeatForever = repeatForever
        self.continueInBackground = continueInBackground
        self.intervalMs = intervalMs
        self.referenceWidth = referenceWidth
        self.referenceHeight = referenceHeight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        steps = try container.decode([MacroStep].self, forKey: .steps)
        repeatCount = try container.decode(Int.self, forKey: .repeatCount)
        repeatForever = try container.decodeIfPresent(Bool.self, forKey: .repeatForever) ?? false
        continueInBackground = try container.decodeIfPresent(Bool.self, forKey: .continueInBackground) ?? false
        intervalMs = try container.decode(Int.self, forKey: .intervalMs)
        referenceWidth = try container.decode(Int.self, forKey: .referenceWidth)
        referenceHeight = try container.decode(Int.self, forKey: .referenceHeight)
    }
}

struct GameProfile: Codable, Identifiable, Equatable {
    var package: String
    var name: String?
    var mappings: [KeyMapping]
    var macros: [ClickMacro]
    var id: String { package }

    init(package: String, name: String? = nil, mappings: [KeyMapping], macros: [ClickMacro] = []) {
        self.package = package
        self.name = name
        self.mappings = mappings
        self.macros = macros
    }

    private enum CodingKeys: String, CodingKey { case package, name, mappings, macros }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        package = try container.decode(String.self, forKey: .package)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        mappings = try container.decodeIfPresent([KeyMapping].self, forKey: .mappings) ?? []
        macros = try container.decodeIfPresent([ClickMacro].self, forKey: .macros) ?? []
    }
}

struct ProfileStore {
    let url: URL

    init(url: URL? = nil) {
        if let url = url { self.url = url; return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.url = support.appendingPathComponent("AdFreeAndroidLauncher/profiles.json")
    }

    func load() throws -> [GameProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([GameProfile].self, from: Data(contentsOf: url))
    }

    // Codable accepts unknown keys on read but would drop them on write.
    // Refuse a lossy downgrade instead of guessing how to migrate newer data.
    private func validateWritableSchema(_ data: Data) throws {
        func checkKeys(_ value: [String: Any], allowed: Set<String>) throws {
            guard Set(value.keys).isSubset(of: allowed) else {
                throw NSError(domain: "PlayDesk.ProfileStore", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "현재 버전이 지원하지 않는 프로필 필드가 있습니다."])
            }
        }
        let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        for profile in entries {
            try checkKeys(profile, allowed: ["package", "name", "mappings", "macros"])
            for mapping in profile["mappings"] as? [[String: Any]] ?? [] {
                try checkKeys(mapping, allowed: ["id", "key", "x", "y"])
            }
            for macro in profile["macros"] as? [[String: Any]] ?? [] {
                try checkKeys(macro, allowed: ["id", "name", "steps", "repeatCount", "repeatForever",
                                               "continueInBackground", "intervalMs", "referenceWidth", "referenceHeight"])
                for step in macro["steps"] as? [[String: Any]] ?? [] {
                    try checkKeys(step, allowed: ["id", "x", "y"])
                }
            }
        }
    }

    func save(_ profiles: [GameProfile]) throws {
        // A failed initial load leaves the model empty. Do not let a later save
        // destroy an unreadable or newer-format file that may still be recoverable.
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                _ = try load()
                let data = try Data(contentsOf: url)
                try validateWritableSchema(data)
            }
            catch {
                throw NSError(domain: "PlayDesk.ProfileStore", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "기존 프로필을 읽을 수 없어 저장하지 않았습니다. 원본 파일을 백업하고 복구한 뒤 다시 시도하세요.",
                    NSUnderlyingErrorKey: error
                ])
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: url, options: .atomic)
    }
}
