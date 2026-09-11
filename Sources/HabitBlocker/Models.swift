import Foundation

struct BlockedSite: Codable, Identifiable, Equatable {
    let id: UUID
    let domain: String

    init(id: UUID = UUID(), domain: String) {
        self.id = id
        self.domain = domain
    }
}

enum HabitActivityKind: String, Codable {
    case focusStarted
    case focusCompleted
    case unlockRequested
    case unblocked
}

struct HabitActivity: Codable, Identifiable {
    let id: UUID
    let kind: HabitActivityKind
    let timestamp: Date
    let minutes: Int?

    init(id: UUID = UUID(), kind: HabitActivityKind, timestamp: Date = Date(), minutes: Int? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.minutes = minutes
    }
}

enum DomainNormalizer {
    static func normalize(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var host = URLComponents(string: candidate)?.host?.lowercased() else { return nil }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }

        guard host.contains("."), host != "localhost", host.allSatisfy({ character in
            character.isLetter || character.isNumber || character == "." || character == "-"
        }) else {
            return nil
        }

        let labels = host.split(separator: ".")
        guard labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return nil }
        return host
    }

    static func hostnames(for domains: [String]) -> [String] {
        var result = Set<String>()
        for domain in domains {
            result.insert(domain)
            if !domain.hasPrefix("www.") {
                result.insert("www.\(domain)")
            }
            if domain == "youtube.com" || domain == "www.youtube.com" {
                result.formUnion(["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "studio.youtube.com", "youtu.be"])
            }
        }
        return result.sorted()
    }
}
