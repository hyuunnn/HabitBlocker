import Darwin
import Foundation
import JavaScriptCore

@main
enum HabitBlockerCoreTests {
    private static var failures = 0

    static func main() {
        testFocusElapsedMinutes()
        testDomainNormalization()
        testHostnameEncoding()
        testPacScriptGeneration()
        testPacScriptMatching()
        testNetworkServiceNameParsing()
        testAutoProxyEntryParsing()
        testAdminScriptGeneration()
        testProxyBackupMerge()
        testRestoreSettingsMatch()
        testProxyBackupPersistence()
        testPacRequestDetection()

        if failures == 0 {
            print("✅ HabitBlocker core tests passed")
        } else {
            print("❌ \(failures) core test(s) failed")
            exit(1)
        }
    }

    private static func testFocusElapsedMinutes() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        expect(
            FocusDuration.elapsedMinutes(from: start, to: start.addingTimeInterval(10 * 60)) == 10,
            "10분은 10분으로 기록해야 합니다."
        )
        expect(
            FocusDuration.elapsedMinutes(from: start, to: start.addingTimeInterval(10 * 60 + 59)) == 10,
            "10분 59초는 10분으로 내려야 합니다."
        )
        expect(
            FocusDuration.elapsedMinutes(from: start, to: start.addingTimeInterval(25 * 60)) == 25,
            "끝까지 유지한 설정 시간은 그대로 기록해야 합니다."
        )
        expect(
            FocusDuration.elapsedMinutes(from: start, to: start.addingTimeInterval(-30)) == 0,
            "시작보다 이른 시각은 0분이어야 합니다."
        )
    }

    private static func testDomainNormalization() {
        expect(
            DomainNormalizer.normalize(" https://WWW.YouTube.com/watch?v=abc ") == "youtube.com",
            "URL에서 소문자 도메인을 추출하고 선행 www를 제거해야 합니다."
        )
        expect(
            DomainNormalizer.normalize("youtube.com") == "youtube.com",
            "스킴 없는 도메인을 처리해야 합니다."
        )
        expect(
            DomainNormalizer.normalize("www.reddit.com") == "reddit.com",
            "선행 www는 루트 도메인으로 정규화해야 합니다."
        )
        expect(
            DomainNormalizer.normalize("localhost") == nil,
            "localhost는 차단 도메인으로 허용하지 않아야 합니다."
        )
        expect(
            DomainNormalizer.normalize("not a domain") == nil,
            "공백이 있는 잘못된 입력을 거부해야 합니다."
        )
        expect(
            DomainNormalizer.normalize("한글도메인.com") == "한글도메인.com",
            "국제화 도메인은 목록 표시용 유니코드로 정규화해야 합니다."
        )
        expect(
            DomainNormalizer.normalize("xn--bj0bj3i97fq8o5lq.com") == "한글도메인.com",
            "punycode 입력도 같은 유니코드 호스트로 정규화해야 합니다."
        )
        expect(
            DomainNormalizer.normalize("내도메인.한국") == "내도메인.한국",
            "한글 TLD가 잘리면 안 됩니다."
        )
        expect(
            DomainNormalizer.normalize("https://xn--220b31d95hq8o.xn--3e0b707e/") == "내도메인.한국",
            "한글 TLD punycode URL도 같은 호스트로 정규화해야 합니다."
        )
    }

    private static func testHostnameEncoding() {
        expect(
            DomainNormalizer.hostnames(for: ["youtube.com"]) == ["youtube.com"],
            "ASCII 도메인은 그대로 PAC 호스트가 되어야 합니다."
        )
        expect(
            DomainNormalizer.hostnames(for: ["한글도메인.com"]) == ["xn--bj0bj3i97fq8o5lq.com"],
            "국제화 도메인은 PAC용 punycode로 변환해야 합니다."
        )
        expect(
            DomainNormalizer.hostnames(for: ["한글도메인.com", "xn--bj0bj3i97fq8o5lq.com"]) == ["xn--bj0bj3i97fq8o5lq.com"],
            "같은 호스트의 유니코드와 punycode는 하나로 합쳐야 합니다."
        )
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
            hostnames: DomainNormalizer.hostnames(for: ["youtube.com", "example.com", "한글도메인.com"])
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
        expect(proxyFor("youtu.be") == "DIRECT", "등록하지 않은 별도 도메인은 직접 연결해야 합니다.")
        expect(proxyFor("example.com") == blockedResult, "일반 등록 도메인을 차단해야 합니다.")
        expect(proxyFor("docs.example.com") == blockedResult, "일반 도메인의 하위 도메인도 차단해야 합니다.")
        expect(proxyFor("YOUTUBE.COM") == blockedResult, "대문자 호스트를 소문자로 정규화해야 합니다.")
        expect(proxyFor("youtube.com.") == blockedResult, "끝의 점이 있는 FQDN도 차단해야 합니다.")

        expect(proxyFor("notyoutube.com") == "DIRECT", "접미사 오탐(notyoutube.com)을 방지해야 합니다.")
        expect(proxyFor("example.com.evil.net") == "DIRECT", "접미사 오탐(example.com.evil.net)을 방지해야 합니다.")
        expect(proxyFor("google.com") == "DIRECT", "미등록 도메인은 직접 연결해야 합니다.")
        expect(proxyFor("xn--bj0bj3i97fq8o5lq.com") == blockedResult, "브라우저가 넘기는 punycode 호스트를 차단해야 합니다.")
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
            names == ["Wi-Fi", "USB 10/100/1000 LAN"],
            "헤더·오류·비활성 서비스는 빼고 활성 서비스 이름만 남겨야 합니다. 실제: \(names)"
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

        let previousPAC = "http://127.0.0.1:18473/proxy.pac"
        let enableScript = ProxyBlockService.buildAdminScript(
            services: ["Wi-Fi", "USB 10/100/1000 LAN", "Hyun's LAN"],
            pacURLString: pacURL,
            restore: ["Wi-Fi": .init(url: previousPAC, enabled: true)]
        )
        expect(enableScript.contains("set -e"), "적용 스크립트는 실패 시 중단해야 합니다.")
        expect(enableScript.contains("-setautoproxyurl 'Wi-Fi' '\(pacURL)'"), "서비스 이름을 안전하게 인용해 URL을 설정해야 합니다.")
        expect(enableScript.contains("-setautoproxystate 'Wi-Fi' on"), "자동 프록시를 켜야 합니다.")
        expect(enableScript.contains("'USB 10/100/1000 LAN'"), "공백이 있는 서비스 이름을 인용해야 합니다.")
        expect(enableScript.contains("'Hyun'\\''s LAN'"), "작은따옴표가 있는 서비스 이름을 이스케이프해야 합니다.")
        expect(!enableScript.contains("/etc/hosts"), "관리자 스크립트는 /etc/hosts를 건드리지 않아야 합니다.")
        expect(enableScript.contains("_hb_pac_ok"), "적용 후 우리 PAC이 켜졌는지 같은 스크립트에서 확인해야 합니다.")
        expect(enableScript.contains("enabled: yes"), "적용 확인은 URL뿐 아니라 자동 프록시가 켜진 상태여야 한다.")
        expect(enableScript.contains("/proxy-"), "적용 확인은 우리 PAC 경로를 포함해야 한다.")
        expect(enableScript.contains(previousPAC), "적용 확인 실패 시 이전 PAC을 같은 권한 세션에서 되돌려야 합니다.")
        expect(enableScript.contains("previous proxy settings were restored"), "롤백이 일어났음을 스크립트가 남겨야 합니다.")

        let restore: [String: ProxyBlockService.ProxyBackupEntry] = [
            "Wi-Fi": .init(url: "http://127.0.0.1:18473/proxy.pac", enabled: true),
            "Thunderbolt Bridge": .init(url: nil, enabled: false),
            "Broken LAN": .init(url: nil, enabled: true)
        ]
        let disableScript = ProxyBlockService.buildAdminScript(
            services: ["Wi-Fi", "Thunderbolt Bridge", "Broken LAN", "Ethernet"],
            pacURLString: nil,
            restore: restore
        )
        expect(disableScript.contains("-setautoproxystate 'Wi-Fi' on"), "백업이 있던 서비스는 이전 상태를 복원해야 합니다.")
        expect(disableScript.contains("-setautoproxyurl 'Wi-Fi' 'http://127.0.0.1:18473/proxy.pac'"), "이전 PAC URL을 복원해야 합니다.")
        expect(disableScript.contains("-setautoproxystate 'Thunderbolt Bridge' off"), "사용 중이 아니던 설정은 꺼진 상태로 복원해야 합니다.")
        expect(disableScript.contains("-setautoproxyurl 'Thunderbolt Bridge' ' '"), "URL이 없던 서비스에도 남은 우리 PAC URL은 지워야 합니다.")
        if let clearIndex = disableScript.range(of: "-setautoproxyurl 'Thunderbolt Bridge' ' '") {
            expect(
                disableScript[clearIndex.upperBound...].contains("-setautoproxystate 'Thunderbolt Bridge' off"),
                "setautoproxyurl은 자동 프록시를 다시 켜므로 URL 삭제 뒤에 off가 와야 합니다."
            )
        }
        expect(disableScript.contains("-setautoproxystate 'Broken LAN' off"), "URL 없이 켜져 있던 비정상 설정은 꺼진 상태로 복원해야 합니다.")
        expect(!disableScript.contains("-setautoproxystate 'Broken LAN' on"), "URL 없는 설정을 켠 상태로 복원하면 안 됩니다.")
        expect(disableScript.contains("127.0.0.1:\(ProxyBlockService.listenPort)"), "백업이 없는 서비스는 우리 PAC인지 확인한 뒤에만 지워야 합니다.")
        expect(!disableScript.contains("-setautoproxystate 'Ethernet' on"), "백업이 없는 서비스를 켜면 안 됩니다.")
        expect(enableScript.contains("|| true"), "서비스 하나의 실패가 전체 적용을 중단시키지 않아야 합니다.")
        expect(!disableScript.contains("/etc/hosts"), "해제 스크립트도 /etc/hosts를 건드리지 않아야 합니다.")
    }

    private static func testProxyBackupMerge() {
        let ourPAC = "http://127.0.0.1:47471/proxy-abc.pac"
        let existing: [String: ProxyBlockService.ProxyBackupEntry] = [
            "Wi-Fi": .init(url: "http://corp.example/proxy.pac", enabled: true)
        ]
        let current: [String: ProxyBlockService.ProxyBackupEntry] = [
            "Wi-Fi": .init(url: ourPAC, enabled: true),
            "Ethernet": .init(url: nil, enabled: false)
        ]
        let merged = ProxyBlockService.mergingProxyBackup(existing: existing, current: current)

        expect(merged["Wi-Fi"]?.url == "http://corp.example/proxy.pac", "이미 우리 PAC이 켜진 서비스는 이전 사용자 설정을 덮지 않아야 합니다.")
        expect(merged["Ethernet"]?.enabled == false, "우리 PAC이 아닌 현재 값은 백업에 합쳐야 합니다.")
    }

    private static func testRestoreSettingsMatch() {
        let backup: [String: ProxyBlockService.ProxyBackupEntry] = [
            "Wi-Fi": .init(url: "http://corp.example/proxy.pac", enabled: true),
            "Thunderbolt Bridge": .init(url: nil, enabled: false)
        ]
        let restored: [String: ProxyBlockService.ProxyBackupEntry] = [
            "Wi-Fi": .init(url: "http://corp.example/proxy.pac", enabled: true),
            "Thunderbolt Bridge": .init(url: nil, enabled: false)
        ]
        expect(
            ProxyBlockService.settingsMatchBackup(current: restored, backup: backup, services: ["Wi-Fi", "Thunderbolt Bridge"]),
            "백업과 같은 프록시 설정은 복원 성공으로 보아야 합니다."
        )

        let missingPrevious: [String: ProxyBlockService.ProxyBackupEntry] = [
            "Wi-Fi": .init(url: " ", enabled: false),
            "Thunderbolt Bridge": .init(url: nil, enabled: false)
        ]
        expect(
            !ProxyBlockService.settingsMatchBackup(current: missingPrevious, backup: backup, services: ["Wi-Fi", "Thunderbolt Bridge"]),
            "이전 PAC URL이 비어 있으면 복원 실패여야 합니다."
        )

        let leftoverOurs: [String: ProxyBlockService.ProxyBackupEntry] = [
            "Ethernet": .init(url: "http://127.0.0.1:47471/proxy-abc.pac", enabled: true)
        ]
        expect(
            !ProxyBlockService.settingsMatchBackup(current: leftoverOurs, backup: [:], services: ["Ethernet"]),
            "백업이 없는 서비스에 우리 PAC이 남아 있으면 실패여야 합니다."
        )
        expect(
            ProxyBlockService.settingsMatchBackup(current: [:], backup: backup, services: ["USB LAN"]),
            "지금은 없는 서비스 때문에 복원 전체를 실패로 보면 안 됩니다."
        )
        expect(
            !ProxyBlockService.settingsMatchBackup(current: [:], backup: backup, services: ["Wi-Fi"]),
            "백업이 있는 서비스 상태를 읽지 못하면 복원 실패여야 합니다."
        )
    }

    private static func testProxyBackupPersistence() {
        let defaultsSuite = "HabitBlockerProxyBackupTests-\(UUID().uuidString)"
        let emptySuite = "HabitBlockerProxyBackupEmpty-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        let emptyDefaults = UserDefaults(suiteName: emptySuite)!
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HabitBlocker-proxy-backup-\(UUID().uuidString).json")
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            emptyDefaults.removePersistentDomain(forName: emptySuite)
            try? FileManager.default.removeItem(at: fileURL)
        }

        let backup: [String: ProxyBlockService.ProxyBackupEntry] = [
            "Wi-Fi": .init(url: "http://corp.example/proxy.pac", enabled: true)
        ]
        ProxyBlockService.saveProxyBackup(backup, defaults: defaults, fileURL: fileURL)

        let fromFile = ProxyBlockService.readProxyBackup(defaults: emptyDefaults, fileURL: fileURL)
        expect(fromFile["Wi-Fi"]?.url == "http://corp.example/proxy.pac", "UserDefaults가 비어도 파일 백업을 읽어야 합니다.")

        let missingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("HabitBlocker-proxy-backup-missing-\(UUID().uuidString).json")
        let fromDefaults = ProxyBlockService.readProxyBackup(defaults: defaults, fileURL: missingFile)
        expect(fromDefaults["Wi-Fi"]?.enabled == true, "파일이 없으면 UserDefaults 백업을 읽어야 합니다.")

        ProxyBlockService.clearProxyBackup(defaults: defaults, fileURL: fileURL)
        expect(
            ProxyBlockService.readProxyBackup(defaults: defaults, fileURL: fileURL).isEmpty,
            "백업 삭제는 파일과 UserDefaults를 모두 지워야 합니다."
        )
        expect(!(FileManager.default.fileExists(atPath: fileURL.path)), "백업 파일이 삭제되어야 합니다.")
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
            ProxyBlockService.isPacRequest("GET /proxy-abc123.pac?t=1 HTTP/1.1"),
            "쿼리스트링이 있는 PAC 요청도 인식해야 합니다."
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
