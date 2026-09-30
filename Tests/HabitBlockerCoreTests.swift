import Darwin
import Foundation
import JavaScriptCore

@main
@MainActor
enum HabitBlockerCoreTests {
    private static var failures = 0

    static func main() async {
        testFocusElapsedMinutes()
        testFocusRecordedMinutes()
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
        testAdminShellErrorClassification()
        testPrivilegedScriptSource()
        await testRejectListenerReadiness()

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

    private static func testFocusRecordedMinutes() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let plannedEnd = start.addingTimeInterval(25 * 60)
        expect(
            FocusDuration.recordedMinutes(from: start, plannedEnd: plannedEnd, now: start.addingTimeInterval(601 * 60)) == 25,
            "계획 종료 뒤의 시간(잠자기, 앱 종료, 늦은 암호 입력)은 집중 시간에 넣지 않아야 합니다."
        )
        expect(
            FocusDuration.recordedMinutes(from: start, plannedEnd: plannedEnd, now: start.addingTimeInterval(10 * 60)) == 10,
            "계획 종료 전에 끝내면 실제로 지난 시간만 기록해야 합니다."
        )
        expect(
            FocusDuration.recordedMinutes(from: start, plannedEnd: nil, now: start.addingTimeInterval(40 * 60)) == 40,
            "계획 종료 시각이 없으면 지난 시간을 그대로 기록해야 합니다."
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

        let withLoopback = ProxyBlockService.pacScript(hostnames: ["youtube.com", "localhost", "127.0.0.1", "0.0.0.0", "::1"])
        expect(withLoopback.contains("\"youtube.com\""), "루프백과 함께 넣은 일반 도메인은 남아야 합니다.")
        expect(
            ["localhost", "127.0.0.1", "0.0.0.0", "::1"].allSatisfy { !withLoopback.contains("\"\($0)\"") },
            "루프백 주소는 차단 목록에서 제외해야 합니다."
        )
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
        expect(enableScript.contains("set -e"), "예상치 못한 명령 실패에 대비해 적용 스크립트는 set -e로 시작해야 합니다.")
        expect(enableScript.contains("-setautoproxyurl 'Wi-Fi' '\(pacURL)'"), "서비스 이름을 안전하게 인용해 URL을 설정해야 합니다.")
        expect(enableScript.contains("-setautoproxystate 'Wi-Fi' on"), "자동 프록시를 켜야 합니다.")
        expect(enableScript.contains("'USB 10/100/1000 LAN'"), "공백이 있는 서비스 이름을 인용해야 합니다.")
        expect(enableScript.contains("'Hyun'\\''s LAN'"), "작은따옴표가 있는 서비스 이름을 이스케이프해야 합니다.")
        expect(!enableScript.contains("/etc/hosts"), "관리자 스크립트는 /etc/hosts를 건드리지 않아야 합니다.")
        expect(enableScript.contains("_hb_pac_ok"), "적용 후 우리 PAC이 켜졌는지 같은 스크립트에서 확인해야 합니다.")
        // 적용 줄의 PAC URL에도 같은 문자열이 들어 있으므로, 확인 줄만 골라서 검사한다.
        let verificationLines = enableScript
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("if echo \"$_hb_out\"") }
        expect(verificationLines.count == 3, "적용 확인은 서비스마다 한 번씩 해야 합니다. 실제: \(verificationLines.count)")
        expect(
            verificationLines.allSatisfy {
                $0.contains("'127.0.0.1:\(ProxyBlockService.listenPort)'")
                    && $0.contains("'/proxy-'")
                    && $0.contains("'enabled: yes'")
            },
            "적용 확인은 우리 리스너 주소, PAC 경로, 자동 프록시 켜짐을 모두 확인해야 합니다."
        )
        expect(enableScript.contains(previousPAC), "적용 확인 실패 시 이전 PAC을 같은 권한 세션에서 되돌려야 합니다.")
        expect(enableScript.contains(ProxyBlockService.rollbackMarker), "롤백이 일어났음을 앱이 알아볼 수 있게 스크립트가 표지를 남겨야 합니다.")

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
        for service in ["Thunderbolt Bridge", "Ethernet"] {
            if let clearIndex = disableScript.range(of: "-setautoproxyurl '\(service)' ' '") {
                expect(
                    disableScript[clearIndex.upperBound...].contains("-setautoproxystate '\(service)' off"),
                    "setautoproxyurl은 자동 프록시를 다시 켜므로 \(service)의 URL 삭제 뒤에 off가 와야 합니다."
                )
            } else {
                expect(false, "\(service)의 URL 삭제 명령이 있어야 합니다.")
            }
        }
        expect(disableScript.contains("-setautoproxystate 'Broken LAN' off"), "URL 없이 켜져 있던 비정상 설정은 꺼진 상태로 복원해야 합니다.")
        expect(!disableScript.contains("-setautoproxystate 'Broken LAN' on"), "URL 없는 설정을 켠 상태로 복원하면 안 됩니다.")
        // 백업이 없는 서비스(Ethernet)는 현재 값이 우리 PAC일 때만 지워야 한다. 다른 도구의 자동 프록시는 그대로 둔다.
        let disableLines = disableScript.split(separator: "\n").map(String.init)
        if let clearIndex = disableLines.firstIndex(where: { $0.contains("-setautoproxyurl 'Ethernet' ' '") }),
           let ifIndex = disableLines[..<clearIndex].lastIndex(where: { $0.hasPrefix("if ") }),
           ifIndex > 0,
           let fiIndex = disableLines[clearIndex...].firstIndex(of: "fi") {
            let query = disableLines[ifIndex - 1]
            let condition = disableLines[ifIndex]
            expect(
                query.contains("-getautoproxyurl 'Ethernet'")
                    && condition.contains("'127.0.0.1:\(ProxyBlockService.listenPort)'")
                    && condition.contains("'/proxy-'"),
                "백업이 없는 서비스의 URL 삭제는 그 서비스의 현재 값이 우리 PAC인지 확인하는 if 안에 있어야 합니다."
            )
            expect(
                disableLines[ifIndex...fiIndex].allSatisfy { !$0.contains("'Wi-Fi'") && !$0.contains("'Broken LAN'") },
                "우리 PAC 확인 블록은 해당 서비스만 다뤄야 합니다."
            )
        } else {
            expect(false, "백업이 없는 서비스(Ethernet)의 조건부 URL 삭제 블록이 있어야 합니다.")
        }
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

        let urlMissing: [String: ProxyBlockService.ProxyBackupEntry] = [
            "Wi-Fi": .init(url: " ", enabled: true),
            "Thunderbolt Bridge": .init(url: nil, enabled: false)
        ]
        expect(
            !ProxyBlockService.settingsMatchBackup(current: urlMissing, backup: backup, services: ["Wi-Fi", "Thunderbolt Bridge"]),
            "켜짐 상태가 같아도 이전 PAC URL이 비어 있으면 복원 실패여야 합니다."
        )

        let stateMismatch: [String: ProxyBlockService.ProxyBackupEntry] = [
            "Wi-Fi": .init(url: "http://corp.example/proxy.pac", enabled: false),
            "Thunderbolt Bridge": .init(url: nil, enabled: false)
        ]
        expect(
            !ProxyBlockService.settingsMatchBackup(current: stateMismatch, backup: backup, services: ["Wi-Fi", "Thunderbolt Bridge"]),
            "URL이 같아도 켜짐 상태가 다르면 복원 실패여야 합니다."
        )

        let leftoverOurs: [String: ProxyBlockService.ProxyBackupEntry] = [
            "Ethernet": .init(url: "http://127.0.0.1:47471/proxy-abc.pac", enabled: true)
        ]
        expect(
            !ProxyBlockService.settingsMatchBackup(current: leftoverOurs, backup: [:], services: ["Ethernet"]),
            "백업이 없는 서비스에 우리 PAC이 남아 있으면 실패여야 합니다."
        )

        let leftoverOursDisabled: [String: ProxyBlockService.ProxyBackupEntry] = [
            "Ethernet": .init(url: "http://127.0.0.1:47471/proxy-abc.pac", enabled: false)
        ]
        expect(
            !ProxyBlockService.settingsMatchBackup(current: leftoverOursDisabled, backup: [:], services: ["Ethernet"]),
            "꺼져 있어도 우리 PAC URL이 남아 있으면 실패여야 합니다."
        )

        let leftoverOursBackedUp: [String: ProxyBlockService.ProxyBackupEntry] = [
            "Wi-Fi": .init(url: "http://corp.example/proxy.pac", enabled: true),
            "Thunderbolt Bridge": .init(url: "http://127.0.0.1:47471/proxy-abc.pac", enabled: false)
        ]
        expect(
            !ProxyBlockService.settingsMatchBackup(current: leftoverOursBackedUp, backup: backup, services: ["Wi-Fi", "Thunderbolt Bridge"]),
            "백업에 URL이 없던 서비스에도 우리 PAC URL이 남아 있으면 실패여야 합니다."
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
        // 실행마다 새 suite 이름을 쓰면 ~/Library/Preferences에 빈 plist가 계속 쌓인다.
        // (removePersistentDomain은 내용만 비우고, 파일을 지워도 cfprefsd가 나중에 다시 만든다.)
        // 테스트 전용 고정 이름을 쓰고 시작과 끝에 비운다.
        let defaultsSuite = "com.hyun.habitblocker.tests.proxy-backup"
        let emptySuite = "com.hyun.habitblocker.tests.proxy-backup-empty"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        let emptyDefaults = UserDefaults(suiteName: emptySuite)!
        defaults.removePersistentDomain(forName: defaultsSuite)
        emptyDefaults.removePersistentDomain(forName: emptySuite)
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

    private static func testAdminShellErrorClassification() {
        expect(
            AdminShellError.fromOsascriptOutput("0:17: execution error: 사용자가 취소함. (-128)\n") == .cancelled,
            "암호 창 취소(-128)는 취소로 분류해야 합니다."
        )
        expect(
            AdminShellError.fromOsascriptOutput("0:7484: execution error: User canceled. (-128)") == .cancelled,
            "시스템 언어가 달라도 오류 번호로 취소를 알아봐야 합니다."
        )
        expect(
            AdminShellError.fromOsascriptOutput("0:7484: execution error: \(ProxyBlockService.rollbackMarker) (1)")
                == .commandFailed("\(ProxyBlockService.rollbackMarker) (1)"),
            "그 밖의 실패는 osascript 위치 접두사만 떼고 원문과 오류 번호를 남겨야 합니다."
        )
        expect(
            AdminShellError.fromOsascriptOutput("") == .commandFailed(""),
            "오류 출력이 비어 있으면(osascript가 강제 종료된 경우) 기본 안내를 보여 줘야 합니다."
        )
        expect(
            AdminShellError.cancelled.errorDescription?.contains("-128") == false,
            "취소 안내에는 AppleScript 오류 번호가 보이지 않아야 합니다."
        )
    }

    private static func testPrivilegedScriptSource() {
        let source = AdminShell.privilegedScriptSource(
            "echo \"hi\"",
            prompt: "습관 차단기가 \"차단\"을 바꾸려고 합니다."
        )
        expect(source.hasPrefix("do shell script \"echo \\\"hi\\\"\""), "셸 명령은 AppleScript 문자열로 인용해야 합니다.")
        expect(
            source.contains("with prompt \"습관 차단기가 \\\"차단\\\"을 바꾸려고 합니다.\""),
            "암호 창에 보일 안내 문구를 인용해 함께 넘겨야 합니다."
        )
        expect(source.hasSuffix("with administrator privileges"), "관리자 권한으로 실행해야 합니다.")
    }

    private static func testRejectListenerReadiness() async {
        // 다른 프로그램이 포트를 점유한 상황. 앱 포트(47471)와 겹치지 않게 비어 있는 임시 포트를 쓴다.
        guard let occupied = occupyLoopbackPort() else {
            expect(false, "테스트용 루프백 포트를 잡지 못했습니다.")
            return
        }
        let (occupier, port) = occupied

        do {
            try await ProxyBlockService.ensureRejectListenerReady(port: port)
            expect(false, "포트가 점유되어 있으면 리스너 준비가 실패로 보고되어야 합니다.")
        } catch {
            expect(
                (error as? ProxyBlockService.BlockServiceError) == .listenerUnavailable,
                "포트 점유는 listenerUnavailable로 보고해야 합니다. 실제: \(error)"
            )
        }
        close(occupier)

        do {
            try await ProxyBlockService.ensureRejectListenerReady(port: port)
            try await ProxyBlockService.ensureRejectListenerReady(port: port)
        } catch {
            expect(false, "포트가 비면 리스너를 다시 시작할 수 있어야 합니다. 실제: \(error)")
        }
        ProxyBlockService.stopRejectListener()
    }

    /// 127.0.0.1의 빈 포트 하나를 SO_REUSEPORT 없는 일반 소켓으로 점유하고 (소켓, 포트)를 돌려준다.
    private static func occupyLoopbackPort() -> (Int32, UInt16)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0, listen(fd, 1) == 0 else {
            close(fd)
            return nil
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("실패: \(message)")
        }
    }
}
