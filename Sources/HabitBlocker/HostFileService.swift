import Foundation

enum HostFileService {
    private static let beginMarker = "# HabitBlocker BEGIN"
    private static let endMarker = "# HabitBlocker END"
    private static let hostsPath = "/etc/hosts"

    static func isManagedBlockActive() -> Bool {
        guard let content = try? String(contentsOfFile: hostsPath, encoding: .utf8) else { return false }
        return content.range(of: beginMarker) != nil && content.range(of: endMarker) != nil
    }

    static func updateHosts(shouldBlock: Bool, domains: [String]) async throws {
        guard !shouldBlock || !DomainNormalizer.hostnames(for: domains).isEmpty else {
            throw HostFileError.emptyDomainList
        }

        let current = try String(contentsOfFile: hostsPath, encoding: .utf8)
        let desired = desiredHostsContent(shouldBlock: shouldBlock, domains: domains, currentContent: current)

        let encoded = Data(desired.utf8).base64EncodedString()
        let shellCommand = "set -e; printf %s \(encoded) | /usr/bin/base64 -D > /etc/hosts; /usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder || true"
        let appleScript = "do shell script \(appleScriptString(shellCommand)) with administrator privileges"
        _ = try await runAppleScript(appleScript)
    }

    static func desiredHostsContent(shouldBlock: Bool, domains: [String], currentContent: String) -> String {
        let withoutManagedSection = removingManagedSection(from: currentContent)
        let baseContent = withoutManagedSection.trimmingCharacters(in: .whitespacesAndNewlines)

        guard shouldBlock else {
            return baseContent + "\n"
        }

        let hostnames = DomainNormalizer.hostnames(for: domains)
        guard !hostnames.isEmpty else {
            return baseContent + "\n"
        }

        let rules = hostnames.flatMap { ["127.0.0.1 \($0)", "::1 \($0)"] }.joined(separator: "\n")
        let section = [
            beginMarker,
            "# 이 구역은 습관 차단기가 관리합니다.",
            rules,
            endMarker
        ].joined(separator: "\n")
        return baseContent + "\n\n" + section + "\n"
    }

    static func removingManagedSection(from content: String) -> String {
        var result: [String] = []
        var skipping = false

        for line in content.components(separatedBy: .newlines) {
            if line == beginMarker {
                skipping = true
                continue
            }
            if line == endMarker {
                skipping = false
                continue
            }
            if !skipping {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func runAppleScript(_ source: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw HostFileError.commandFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return output
        }.value
    }
}

enum HostFileError: LocalizedError {
    case emptyDomainList
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyDomainList:
            return "차단할 도메인이 없습니다."
        case let .commandFailed(message):
            return message.isEmpty ? "관리자 권한 요청이 취소되었거나 hosts 파일을 변경할 수 없습니다." : message
        }
    }
}
