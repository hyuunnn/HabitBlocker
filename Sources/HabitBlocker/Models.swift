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

enum FocusDuration {
    static func elapsedMinutes(from start: Date, to end: Date = Date()) -> Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
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

        // URLComponents.host는 IDN을 유니코드로 돌려준다. PAC에는 punycode가 필요하므로
        // ASCII 변환이 되는 호스트만 목록에 넣는다.
        guard asciiHostname(host) != nil else { return nil }
        return host
    }

    private static func asciiHostname(_ host: String) -> String? {
        // URLComponents로 만든 URL.host는 IDN을 ACE로 인코딩해 준다.
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        guard let ascii = components.url?.host?.lowercased(),
              ascii.contains("."),
              ascii.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            return nil
        }
        let labels = ascii.split(separator: ".")
        guard labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else {
            return nil
        }
        return ascii
    }

    static func hostnames(for domains: [String]) -> [String] {
        var result = Set<String>()
        for domain in domains {
            guard let host = asciiHostname(domain) else { continue }
            result.insert(host)
        }
        return result.sorted()
    }
}
