import Foundation

/// 구버전이 /etc/hosts에 기록했던 관리 구역을 정리하기 위한 마이그레이션 전용 로직.
/// 현재 버전은 hosts 파일을 수정하지 않는다. 실제 쓰기는 ProxyBlockService의 관리자 스크립트가 담당한다.
enum HostFileService {
    static let beginMarker = "# HabitBlocker BEGIN"
    static let endMarker = "# HabitBlocker END"
    private static let hostsPath = "/etc/hosts"

    static func isLegacySectionPresent() -> Bool {
        guard let content = try? String(contentsOfFile: hostsPath, encoding: .utf8) else { return false }
        return containsManagedSection(content)
    }

    static func containsManagedSection(_ content: String) -> Bool {
        content.range(of: beginMarker) != nil && content.range(of: endMarker) != nil
    }

    /// 관리 구역이 있으면 그것을 제거한 새 내용을, 없으면 nil을 반환한다.
    static func cleanedHostsContent() -> String? {
        guard let content = try? String(contentsOfFile: hostsPath, encoding: .utf8),
              containsManagedSection(content) else { return nil }
        return cleanedHostsContent(from: content)
    }

    static func cleanedHostsContent(from content: String) -> String {
        removingManagedSection(from: content).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
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
}
