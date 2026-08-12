import Darwin
import Foundation

@main
enum HabitBlockerCoreTests {
    private static var failures = 0

    static func main() {
        testDomainNormalization()
        testHostnameExpansion()
        testManagedSectionRemoval()
        testDesiredHostsContent()

        if failures == 0 {
            print("✅ HabitBlocker core tests passed")
        } else {
            print("❌ \(failures) core test(s) failed")
            exit(1)
        }
    }

    private static func testDomainNormalization() {
        expect(
            DomainNormalizer.normalize(" https://WWW.YouTube.com/watch?v=abc ") == "www.youtube.com",
            "URL에서 소문자 도메인을 추출해야 합니다."
        )
        expect(
            DomainNormalizer.normalize("youtube.com") == "youtube.com",
            "스킴 없는 도메인을 처리해야 합니다."
        )
        expect(
            DomainNormalizer.normalize("localhost") == nil,
            "localhost는 차단 도메인으로 허용하지 않아야 합니다."
        )
        expect(
            DomainNormalizer.normalize("not a domain") == nil,
            "공백이 있는 잘못된 입력을 거부해야 합니다."
        )
    }

    private static func testHostnameExpansion() {
        let expectedYouTubeHosts: Set<String> = [
            "youtube.com",
            "www.youtube.com",
            "m.youtube.com",
            "music.youtube.com",
            "studio.youtube.com",
            "youtu.be"
        ]
        expect(
            Set(DomainNormalizer.hostnames(for: ["youtube.com"])) == expectedYouTubeHosts,
            "YouTube 등록은 알려진 보조 도메인도 함께 확장해야 합니다."
        )
        expect(
            DomainNormalizer.hostnames(for: ["example.com"]) == ["example.com", "www.example.com"],
            "일반 도메인은 루트와 www 호스트를 생성해야 합니다."
        )
    }

    private static func testManagedSectionRemoval() {
        let hosts = """
        127.0.0.1 localhost
        # HabitBlocker BEGIN
        127.0.0.1 youtube.com
        ::1 youtube.com
        # HabitBlocker END
        ::1 localhost
        """
        let cleaned = HostFileService.removingManagedSection(from: hosts)

        expect(!cleaned.contains("HabitBlocker"), "관리 섹션 표식을 제거해야 합니다.")
        expect(!cleaned.contains("youtube.com"), "관리 섹션의 도메인 규칙을 제거해야 합니다.")
        expect(cleaned.contains("127.0.0.1 localhost"), "기존 IPv4 hosts 항목을 보존해야 합니다.")
        expect(cleaned.contains("::1 localhost"), "기존 IPv6 hosts 항목을 보존해야 합니다.")
    }

    private static func testDesiredHostsContent() {
        let existing = """
        127.0.0.1 localhost
        # HabitBlocker BEGIN
        127.0.0.1 old.example
        # HabitBlocker END
        """
        let blocked = HostFileService.desiredHostsContent(
            shouldBlock: true,
            domains: ["youtube.com"],
            currentContent: existing
        )
        let unblocked = HostFileService.desiredHostsContent(
            shouldBlock: false,
            domains: ["youtube.com"],
            currentContent: blocked
        )

        expect(occurrences(of: "# HabitBlocker BEGIN", in: blocked) == 1, "관리 섹션은 하나만 존재해야 합니다.")
        expect(blocked.contains("127.0.0.1 youtube.com"), "IPv4 차단 규칙을 생성해야 합니다.")
        expect(blocked.contains("::1 www.youtube.com"), "IPv6 www 차단 규칙을 생성해야 합니다.")
        expect(!blocked.contains("old.example"), "이전 관리 규칙을 교체해야 합니다.")
        expect(!unblocked.contains("HabitBlocker"), "차단 해제 시 관리 섹션을 모두 제거해야 합니다.")
        expect(unblocked.contains("127.0.0.1 localhost"), "차단 해제 후 기존 항목을 유지해야 합니다.")
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("실패: \(message)")
        }
    }
}
