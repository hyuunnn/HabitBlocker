import Foundation

struct PageSnapshot: Equatable {
    var appName: String
    var bundleID: String
    var windowTitle: String
    var pageURL: String?

    var fingerprint: String {
        [bundleID, pageURL ?? "", windowTitle].joined(separator: "\n")
    }
}

enum FocusLabel: String, Equatable {
    case focus
    case neutral
    case drift

    var korean: String {
        switch self {
        case .focus: return "집중"
        case .neutral: return "중립"
        case .drift: return "딴짓"
        }
    }

    static func parse(_ raw: String) -> FocusLabel? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "focus", "study", "work":
            return .focus
        case "neutral", "unsure", "unknown":
            return .neutral
        case "drift", "distraction", "offtask", "off-task":
            return .drift
        default:
            return nil
        }
    }
}

struct FocusVerdict: Equatable {
    let label: FocusLabel
    let confidence: Double
}

enum BrowserKind: Equatable {
    case chromium(appName: String)
    case safari(appName: String)

    var appName: String {
        switch self {
        case let .chromium(appName), let .safari(appName):
            return appName
        }
    }

    static func resolve(bundleID: String) -> BrowserKind? {
        switch bundleID {
        case "com.google.Chrome", "com.google.Chrome.beta":
            return .chromium(appName: "Google Chrome")
        case "com.google.Chrome.canary":
            return .chromium(appName: "Google Chrome Canary")
        case "com.brave.Browser":
            return .chromium(appName: "Brave Browser")
        case "com.microsoft.edgemac":
            return .chromium(appName: "Microsoft Edge")
        case "company.thebrowser.Browser":
            return .chromium(appName: "Arc")
        case "com.vivaldi.Vivaldi":
            return .chromium(appName: "Vivaldi")
        case "com.operasoftware.Opera":
            return .chromium(appName: "Opera")
        case "com.apple.Safari":
            return .safari(appName: "Safari")
        case "com.apple.SafariTechnologyPreview":
            return .safari(appName: "Safari Technology Preview")
        default:
            return nil
        }
    }
}

enum BrowserScript {
    static func readSource(for kind: BrowserKind) -> String {
        switch kind {
        case let .chromium(appName):
            return """
            tell application "\(escape(appName))"
              if (count of windows) is 0 then error "no window"
              set pageURL to URL of active tab of front window
              set pageTitle to title of active tab of front window
              return pageURL & linefeed & pageTitle
            end tell
            """
        case let .safari(appName):
            return """
            tell application "\(escape(appName))"
              if (count of windows) is 0 then error "no window"
              set pageURL to URL of current tab of front window
              set pageTitle to name of current tab of front window
              return pageURL & linefeed & pageTitle
            end tell
            """
        }
    }

    static func closeSource(for kind: BrowserKind) -> String {
        switch kind {
        case let .chromium(appName):
            return """
            tell application "\(escape(appName))"
              if (count of windows) is 0 then error "no window"
              close active tab of front window
            end tell
            """
        case let .safari(appName):
            return """
            tell application "\(escape(appName))"
              if (count of windows) is 0 then error "no window"
              close current tab of front window
            end tell
            """
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum FocusPolicy {
    static let defaultGoal = "공부하거나 업무에 집중하기"
    static let defaultThreshold = 0.72

    static func looksLikeBrowser(bundleID: String, appName: String) -> Bool {
        if BrowserKind.resolve(bundleID: bundleID) != nil { return true }
        let haystack = (bundleID + " " + appName).lowercased()
        let tokens = ["firefox", "orion", "chromium", "duckduckgo", "floorp", "librewolf", "waterfox", "dia"]
        return tokens.contains { haystack.contains($0) }
    }

    /// URL이 있으면 호스트만 본다. 주소가 없을 때만 창 제목 끝의 사이트 이름으로 폴백한다.
    static func matchedDomain(isBrowser: Bool, pageURL: String?, title: String, domains: [String]) -> String? {
        guard isBrowser else { return nil }
        let trimmedURL = pageURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedURL.isEmpty {
            guard let host = host(from: trimmedURL) else { return nil }
            return domains.first { hostMatches(host, domain: $0) }
        }
        return domains.first { titleMatches(title, domain: $0) }
    }

    static func shouldClose(verdict: FocusVerdict, threshold: Double) -> Bool {
        verdict.label == .drift && verdict.confidence >= threshold
    }

    static func messages(goal: String, appName: String, pageURL: String?, title: String) -> (system: String, user: String) {
        let resolvedGoal = clipped(goal.isEmpty ? defaultGoal : goal, limit: 160)
        let system = """
        너는 이 컴퓨터 안에서만 동작하는 집중 판정기다. 사용자가 지금 하려는 일과 보고 있는 페이지를 비교해서, 그 페이지가 그 일에 도움이 되는지 판단한다.
        라벨은 셋 중 하나다.
        focus: 공부, 강의, 문서, 업무처럼 지금 하려는 일에 직접 도움이 된다.
        neutral: 어느 쪽인지 불분명하거나, 일과 무관하지만 오락도 아니다.
        drift: 게임, 예능, 숏폼, 스포츠 하이라이트, 쇼핑, 소셜 피드처럼 주의를 빼앗는 딴짓이다.
        같은 사이트라도 제목과 주소로 구분한다. 강의 영상은 focus, 게임 영상은 drift다.
        JSON 한 개만 답한다. 설명은 쓰지 않는다.
        {"label":"focus","confidence":0.0}
        label은 focus, neutral, drift 중 하나고 confidence는 0 이상 1 이하다.
        """
        let user = """
        지금 하려는 일: \(resolvedGoal)
        앱: \(clipped(appName, limit: 80))
        주소: \(clipped(pageURL ?? "알 수 없음", limit: 500))
        제목: \(clipped(title, limit: 300))
        """
        return (system, user)
    }

    static func parseModelOutput(_ text: String) -> FocusVerdict? {
        let stripped = stripThinking(text)
        guard let json = firstJSONObject(in: stripped),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawLabel = object["label"] as? String,
              let label = FocusLabel.parse(rawLabel),
              let confidence = normalizedConfidence(object["confidence"]) else {
            return nil
        }
        return FocusVerdict(label: label, confidence: confidence)
    }

    static func shortTitle(_ title: String, limit: Int = 36) -> String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)) + "…"
    }

    static func host(from pageURL: String) -> String? {
        let trimmed = pageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URLComponents(string: trimmed)?.host, !host.isEmpty else { return nil }
        return host
    }

    static func hostMatches(_ host: String, domain: String) -> Bool {
        let normalizedHost = DomainNormalizer.normalize(host) ?? host.lowercased()
        let normalizedDomain = DomainNormalizer.normalize(domain) ?? domain.lowercased()
        if normalizedHost == normalizedDomain { return true }
        return normalizedHost.hasSuffix("." + normalizedDomain)
    }

    static func siteToken(for domain: String) -> String? {
        let normalized = DomainNormalizer.normalize(domain) ?? domain.lowercased()
        var labels = normalized.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        labels.removeLast()
        if let last = labels.last, ["co", "com", "ac", "or", "ne", "go"].contains(last), labels.count >= 2 {
            labels.removeLast()
        }
        guard let token = labels.last, token.count >= 4 else { return nil }
        return token
    }

    static func titleMatches(_ title: String, domain: String) -> Bool {
        guard let token = siteToken(for: domain) else { return false }
        let lower = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let separators = [" - ", " — ", " – ", " | "]
        return separators.contains { lower.hasSuffix($0 + token) }
    }

    private static func clipped(_ value: String, limit: Int) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit))
    }

    private static func stripThinking(_ text: String) -> String {
        guard let start = text.range(of: "<think>"), let end = text.range(of: "</think>") else {
            return text
        }
        if start.lowerBound < end.lowerBound {
            var copy = text
            copy.removeSubrange(start.lowerBound..<end.upperBound)
            return copy
        }
        return text
    }

    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        for index in text[start...].indices {
            let character = text[index]
            if inString {
                if escape {
                    escape = false
                } else if character == "\\" {
                    escape = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
        }
        return nil
    }

    private static func normalizedConfidence(_ value: Any?) -> Double? {
        guard let number = (value as? NSNumber)?.doubleValue else { return nil }
        if number.isNaN { return nil }
        let scaled = number > 1 && number <= 100 ? number / 100 : number
        return min(1, max(0, scaled))
    }
}
