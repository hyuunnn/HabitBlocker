import Darwin
import Foundation
import JavaScriptCore

@main
enum HabitBlockerCoreTests {
    private static var failures = 0

    static func main() {
        testDomainNormalization()
        testHostnameExpansion()
        testManagedSectionRemoval()
        testCleanedHostsContent()
        testPacScriptGeneration()
        testPacScriptMatching()
        testNetworkServiceNameParsing()
        testAutoProxyEntryParsing()
        testAdminScriptGeneration()
        testPacRequestDetection()

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

    private static func testCleanedHostsContent() {
        let hosts = """
        127.0.0.1 localhost
        # HabitBlocker BEGIN
        127.0.0.1 youtube.com
        ::1 www.youtube.com
        # HabitBlocker END
        ::1 broadcasthost
        """
        let cleaned = HostFileService.cleanedHostsContent(from: hosts)

        expect(HostFileService.containsManagedSection(hosts), "관리 섹션이 있으면 감지해야 합니다.")
        expect(!HostFileService.containsManagedSection(cleaned), "정리된 내용에는 관리 섹션이 없어야 합니다.")
        expect(!cleaned.contains("youtube.com"), "이전 차단 규칙을 제거해야 합니다.")
        expect(cleaned.contains("127.0.0.1 localhost") && cleaned.contains("::1 broadcasthost"), "기존 항목을 유지해야 합니다.")
        expect(cleaned.hasSuffix("\n"), "정리된 내용은 개행으로 끝나야 합니다.")
        expect(HostFileService.cleanedHostsContent(from: cleaned) == cleaned, "정리 작업은 멱등해야 합니다.")
    }

    private static func testPacScriptGeneration() {
        let script = ProxyBlockService.pacScript(hostnames: ["youtube.com", "example.com"])

        expect(script.contains("function FindProxyForURL"), "PAC 진입점 함수를 포함해야 합니다.")
        expect(script.contains("PROXY 127.0.0.1:\(ProxyBlockService.listenPort)"), "차단 프록시 주소를 포함해야 합니다.")
        expect(script.contains("return \"DIRECT\""), "미등록 도메인은 직접 연결해야 합니다.")
        expect(script.contains("\"example.com\""), "등록 도메인을 포함해야 합니다.")
        expect(!script.contains("\"localhost\"") && !script.contains("\"127.0.0.1\""), "루프백 주소는 차단 목록에서 제외해야 합니다.")
    }

    private static func testPacScriptMatching() {
        let script = ProxyBlockService.pacScript(
            hostnames: DomainNormalizer.hostnames(for: ["youtube.com", "example.com"])
        )
        guard let context = JSContext() else {
            expect(false, "JavaScriptCore 컨텍스트를 만들 수 없습니다.")
            return
        }
        context.evaluateScript(script)
        guard let findProxy = context.objectForKeyedSubscript("FindProxyForURL") else {
            expect(false, "PAC 스크립트에 FindProxyForURL 함수가 있어야 합니다.")
            return
        }

        func proxyFor(_ host: String) -> String {
            findProxy.call(withArguments: ["https://\(host)/", host])?.toString() ?? "NO-RESULT"
        }

        let blockedResult = "PROXY 127.0.0.1:\(ProxyBlockService.listenPort)"
        expect(proxyFor("youtube.com") == blockedResult, "루트 도메인을 차단해야 합니다.")
        expect(proxyFor("www.youtube.com") == blockedResult, "www 하위 도메인을 차단해야 합니다.")
        expect(proxyFor("v.youtube.com") == blockedResult, "임의의 하위 도메인을 접미사 규칙으로 차단해야 합니다.")
        expect(proxyFor("youtu.be") == blockedResult, "YouTube 보조 도메인을 차단해야 합니다.")
        expect(proxyFor("example.com") == blockedResult, "일반 등록 도메인을 차단해야 합니다.")
        expect(proxyFor("docs.example.com") == blockedResult, "일반 도메인의 하위 도메인도 차단해야 합니다.")
        expect(proxyFor("YOUTUBE.COM") == blockedResult, "대문자 호스트를 소문자로 정규화해야 합니다.")
        expect(proxyFor("youtube.com.") == blockedResult, "끝의 점이 있는 FQDN도 차단해야 합니다.")

        expect(proxyFor("notyoutube.com") == "DIRECT", "접미사 오탐(notyoutube.com)을 방지해야 합니다.")
        expect(proxyFor("example.com.evil.net") == "DIRECT", "접미사 오탐(example.com.evil.net)을 방지해야 합니다.")
        expect(proxyFor("google.com") == "DIRECT", "미등록 도메인은 직접 연결해야 합니다.")
    }

    private static func testNetworkServiceNameParsing() {
        let sample = """
        An asterisk (*) denotes that a network service is disabled.
        Wi-Fi
        *Thunderbolt Bridge

        ** Error: The parameters were not valid.
        USB 10/100/1000 LAN
        """
        let names = ProxyBlockService.networkServiceNames(fromListOutput: sample)

        expect(
            names == ["Wi-Fi", "Thunderbolt Bridge", "USB 10/100/1000 LAN"],
            "헤더·오류·비활성 표식을 걸러내고 서비스 이름만 남겨야 합니다. 실제: \(names)"
        )
    }

    private static func testAutoProxyEntryParsing() {
        expect(
            ProxyBlockService.extractURL(from: "URL: http://127.0.0.1:47471/proxy-abc.pac") == "http://127.0.0.1:47471/proxy-abc.pac",
            "URL 접두사가 붙은 출력에서 URL을 추출해야 합니다."
        )
        expect(
            ProxyBlockService.extractURL(from: "<file:///tmp/proxy.pac>") == "file:///tmp/proxy.pac",
            "꺾쇠로 감싼 URL을 추출해야 합니다."
        )
        expect(ProxyBlockService.extractURL(from: "Enabled: Yes") == nil, "URL이 아닌 줄은 거부해야 합니다.")
        expect(
            ProxyBlockService.isHabitBlockerPacURL("http://127.0.0.1:47471/proxy-abc.pac"),
            "자기 PAC URL을 인식해야 합니다."
        )
        expect(
            !ProxyBlockService.isHabitBlockerPacURL("http://127.0.0.1:18473/proxy.pac"),
            "다른 도구의 PAC URL을 자기 것으로 오판하지 않아야 합니다."
        )
    }

    private static func testAdminScriptGeneration() {
        let pacURL = "http://127.0.0.1:47471/proxy-abc123.pac"

        let enableScript = ProxyBlockService.buildAdminScript(
            services: ["Wi-Fi", "USB 10/100/1000 LAN", "Hyun's LAN"],
            pacURLString: pacURL,
            restore: [:],
            hostsCleanupContent: nil
        )
        expect(enableScript.contains("set -e"), "적용 스크립트는 실패 시 중단해야 합니다.")
        expect(enableScript.contains("-setautoproxyurl 'Wi-Fi' '\(pacURL)'"), "서비스 이름을 안전하게 인용해 URL을 설정해야 합니다.")
        expect(enableScript.contains("-setautoproxystate 'Wi-Fi' on"), "자동 프록시를 켜야 합니다.")
        expect(enableScript.contains("'USB 10/100/1000 LAN'"), "공백이 있는 서비스 이름을 인용해야 합니다.")
        expect(enableScript.contains("'Hyun'\\''s LAN'"), "작은따옴표가 있는 서비스 이름을 이스케이프해야 합니다.")
        expect(!enableScript.contains("/etc/hosts"), "hosts 정리가 필요 없으면 hosts를 건드리지 않아야 합니다.")

        let restore: [String: ProxyBlockService.ProxyBackupEntry] = [
            "Wi-Fi": .init(url: "http://127.0.0.1:18473/proxy.pac", enabled: true),
            "Thunderbolt Bridge": .init(url: nil, enabled: false),
            "Broken LAN": .init(url: nil, enabled: true)
        ]
        let disableScript = ProxyBlockService.buildAdminScript(
            services: ["Wi-Fi", "Thunderbolt Bridge", "Broken LAN", "Ethernet"],
            pacURLString: nil,
            restore: restore,
            hostsCleanupContent: nil
        )
        expect(disableScript.contains("-setautoproxystate 'Wi-Fi' on"), "백업이 있던 서비스는 이전 상태를 복원해야 합니다.")
        expect(disableScript.contains("-setautoproxyurl 'Wi-Fi' 'http://127.0.0.1:18473/proxy.pac'"), "이전 PAC URL을 복원해야 합니다.")
        expect(disableScript.contains("-setautoproxystate 'Thunderbolt Bridge' off"), "사용 중이 아니던 설정은 꺼진 상태로 복원해야 합니다.")
        expect(disableScript.contains("-setautoproxystate 'Broken LAN' off"), "URL 없이 켜져 있던 비정상 설정은 꺼진 상태로 복원해야 합니다.")
        expect(!disableScript.contains("-setautoproxystate 'Broken LAN' on"), "URL 없는 설정을 켠 상태로 복원하면 안 됩니다.")
        expect(disableScript.contains("-setautoproxystate 'Ethernet' off"), "백업이 없는 서비스는 자동 프록시를 끕니다.")
        expect(!disableScript.contains("-setautoproxystate 'Ethernet' on"), "백업이 없는 서비스를 켜면 안 됩니다.")
        expect(enableScript.contains("|| true"), "서비스 하나의 실패가 전체 적용을 중단시키지 않아야 합니다.")

        let cleanupScript = ProxyBlockService.buildAdminScript(
            services: [],
            pacURLString: nil,
            restore: [:],
            hostsCleanupContent: "127.0.0.1 localhost\n"
        )
        expect(cleanupScript.contains("/etc/hosts"), "hosts 정리 내용이 있으면 반영해야 합니다.")
        expect(cleanupScript.contains("base64 -D"), "hosts 내용은 base64로 전달해야 합니다.")
        expect(cleanupScript.contains("dscacheutil -flushcache"), "hosts 정리 후 DNS 캐시를 비워야 합니다.")
    }

    private static func testPacRequestDetection() {
        expect(
            ProxyBlockService.isPacRequest("GET /proxy-abc123.pac HTTP/1.1"),
            "원본 형식 PAC 요청을 인식해야 합니다."
        )
        expect(
            ProxyBlockService.isPacRequest("GET http://127.0.0.1:47471/proxy-abc123.pac HTTP/1.1"),
            "절대 형식 PAC 요청을 인식해야 합니다."
        )
        expect(
            !ProxyBlockService.isPacRequest("CONNECT youtube.com:443 HTTP/1.1"),
            "CONNECT 요청은 PAC 요청이 아니어야 합니다."
        )
        expect(
            !ProxyBlockService.isPacRequest("GET http://proxy-x.pac/ HTTP/1.1"),
            "경로가 아니라 호스트에 proxy 문자가 있는 요청은 PAC 요청이 아니어야 합니다."
        )
        expect(
            !ProxyBlockService.isPacRequest("GET /index.html HTTP/1.1"),
            "일반 GET 요청은 PAC 요청이 아니어야 합니다."
        )
        expect(
            !ProxyBlockService.isPacRequest("garbage"),
            "형식이 맞지 않는 요청은 PAC 요청이 아니어야 합니다."
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("실패: \(message)")
        }
    }
}
