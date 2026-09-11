import CryptoKit
import Foundation
import Network

/// /etc/hosts 대신 시스템 프록시 자동 설정(PAC)으로 도메인을 차단하는 엔진.
///
/// 동작 방식:
/// 1. 앱이 차단 도메인 목록으로 PAC 스크립트를 만들어 메모리에 보관하고,
///    로컬호스트 전용 리스너가 `http://127.0.0.1:<port>/proxy-<hash>.pac` 로 서빙한다.
/// 2. PAC은 차단 도메인만 `PROXY 127.0.0.1:<port>` 로 보내고 나머지는 `DIRECT` 다.
/// 3. 리스너는 차단 대상으로 온 요청(CONNECT/HTTP)에 403 차단 화면을 응답한다.
/// 4. 네트워크 서비스의 프록시 자동 설정 URL은 networksetup으로 켜고 끈다(관리자 권한).
///
/// 시스템 파일은 일절 수정하지 않고, 설정이 잘못되어도 최악은 "차단 안 됨"이다.
enum ProxyBlockService {
    static let listenPort: UInt16 = 47471

    private static let networkSetupPath = "/usr/sbin/networksetup"
    private static let pacPathPrefix = "/proxy-"
    private static let pacPathSuffix = ".pac"
    private static let proxyBackupKey = "proxyAutoConfigBackup"
    private static let lastAppliedDomainsKey = "lastAppliedBlockDomains"

    private static var listener: NWListener?
    private static let listenerQueue = DispatchQueue(label: "com.hyun.habitblocker.reject-listener")
    private static let pacLock = NSLock()
    private static var storedPacScript: String?

    struct ProxyBackupEntry: Codable, Equatable {
        let url: String?
        let enabled: Bool
    }

    enum BlockServiceError: LocalizedError {
        case emptyDomainList
        case networkServicesUnavailable
        case applyNotVerified
        case clearNotVerified

        var errorDescription: String? {
            switch self {
            case .emptyDomainList:
                return "차단할 도메인이 없습니다."
            case .networkServicesUnavailable:
                return "네트워크 서비스 목록을 가져올 수 없습니다."
            case .applyNotVerified:
                return "프록시 규칙 적용을 확인하지 못했습니다. 네트워크 서비스 구성이 바뀌지 않았는지 확인하고 다시 시도하세요."
            case .clearNotVerified:
                return "차단 해제를 확인하지 못했습니다. 시스템 설정 > 네트워크 > 프록시에서 자동 프록시 구성 상태를 확인하세요."
            }
        }
    }

    // MARK: - PAC 스크립트

    static func pacScript(hostnames: [String], port: UInt16 = listenPort) -> String {
        let loopbackLiterals: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]
        var seen = Set<String>()
        var domains: [String] = []
        for hostname in hostnames {
            let lowered = hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !lowered.isEmpty, !loopbackLiterals.contains(lowered), seen.insert(lowered).inserted else { continue }
            domains.append(lowered)
        }
        domains.sort()

        let domainList = domains.map { jsString($0) }.joined(separator: ", ")
        let proxy = "PROXY 127.0.0.1:\(port)"
        return """
        // 습관 차단기(HabitBlocker) 자동 프록시 스크립트
        function FindProxyForURL(url, host) {
          host = String(host || "").toLowerCase();
          if (host.charAt(host.length - 1) === ".") {
            host = host.slice(0, -1);
          }
          var blocked = [\(domainList)];
          for (var i = 0; i < blocked.length; i++) {
            var domain = blocked[i];
            if (host === domain) {
              return "\(proxy)";
            }
            var suffix = "." + domain;
            if (host.length > suffix.length && host.slice(host.length - suffix.length) === suffix) {
              return "\(proxy)";
            }
          }
          return "DIRECT";
        }
        """
    }

    /// 차단 목록으로 PAC 스크립트를 만들어 리스너가 서빙하도록 준비하고, 그 PAC URL을 반환한다.
    @discardableResult
    static func preparePacScript(domains: [String]) -> String {
        let script = pacScript(hostnames: DomainNormalizer.hostnames(for: domains))
        pacLock.lock()
        storedPacScript = script
        pacLock.unlock()
        return pacURLString(for: script)
    }

    static func pacURLString(for script: String) -> String {
        "http://127.0.0.1:\(listenPort)\(pacPathPrefix)\(md5Hex(script))\(pacPathSuffix)"
    }

    /// PAC 요청 판별. 원본 형식(`GET /proxy-x.pac HTTP/1.1`)과 절대 형식(`GET http://127.0.0.1:.../proxy-x.pac HTTP/1.1`)을 모두 지원한다.
    static func isPacRequest(_ firstLine: String) -> Bool {
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0].uppercased() == "GET" else { return false }

        var target = String(parts[1])
        if let schemeRange = target.range(of: "://") {
            guard let pathIndex = target[schemeRange.upperBound...].firstIndex(of: "/") else { return false }
            target = String(target[pathIndex...])
        }
        return target.hasPrefix(pacPathPrefix) && target.hasSuffix(pacPathSuffix)
    }

    private static func jsString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func md5Hex(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 로컬 리스너

    @discardableResult
    static func startRejectListener() -> Bool {
        if listener != nil { return true }
        guard let port = NWEndpoint.Port(rawValue: listenPort) else { return false }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: port)

        guard let rejectListener = try? NWListener(using: parameters) else { return false }

        rejectListener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                if state == .ready {
                    receiveThenAnswer(connection)
                }
                if case .failed = state {
                    connection.cancel()
                }
            }
            connection.start(queue: listenerQueue)
            prepareRejectionTimeout(connection)
        }

        // 리스너가 나중에 죽으면 isListenerRunning이 거짓말을 하지 않도록 정리한다.
        rejectListener.stateUpdateHandler = { [weak rejectListener] state in
            if case .failed = state {
                DispatchQueue.main.async {
                    if listener === rejectListener {
                        listener = nil
                    }
                }
            }
        }

        rejectListener.start(queue: listenerQueue)
        listener = rejectListener
        return true
    }

    static func stopRejectListener() {
        listener?.cancel()
        listener = nil
    }

    static var isListenerRunning: Bool { listener != nil }

    private static func prepareRejectionTimeout(_ connection: NWConnection) {
        // 요청 없이 연결만 유지하는 로컬 클라이언트를 정리한다. 응답 후 cancel은 멱등하다.
        listenerQueue.asyncAfter(deadline: .now() + 15) {
            connection.cancel()
        }
    }

    private static func receiveThenAnswer(_ connection: NWConnection) {
        readRequest(connection, accumulated: Data())
    }

    /// 요청 헤더가 패킷에 걸쳐 나뉘어 도착해도 첫 줄이 끝날 때까지 모아서 판정한다.
    /// 첫 줄이 불완전한 채 답하면 PAC 요청을 403으로 오답해 차단이 풀리는 fail-open이 생긴다.
    private static func readRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if buffer.range(of: Data([0x0A])) != nil {
                answer(connection, request: buffer)
                return
            }

            guard error == nil, !isComplete, buffer.count < 16384 else {
                connection.cancel()
                return
            }
            readRequest(connection, accumulated: buffer)
        }
    }

    private static func answer(_ connection: NWConnection, request: Data) {
        let requestText = String(data: request.prefix(4096), encoding: .utf8)
            ?? String(data: request.prefix(4096), encoding: .isoLatin1)
            ?? ""
        let firstLine = requestText.components(separatedBy: .newlines).first ?? ""

        if isPacRequest(firstLine), let script = currentPacScript() {
            send(httpResponse(status: "200 OK", contentType: "application/x-ns-proxy-autoconfig", body: script), on: connection)
        } else {
            send(blockPageResponse, on: connection)
        }
    }

    private static func send(_ text: String, on connection: NWConnection) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func currentPacScript() -> String? {
        pacLock.lock()
        defer { pacLock.unlock() }
        return storedPacScript
    }

    private static func httpResponse(status: String, contentType: String, body: String) -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private static let blockPageBody = """
    <!doctype html><html><head><meta charset="utf-8"><title>습관 차단기</title></head><body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:#faf7f2;font-family:-apple-system,'Apple SD Gothic Neo',sans-serif;color:#3d3229"><div style="text-align:center;padding:24px"><div style="font-size:56px">&#128737;&#65039;</div><h1 style="font-size:22px;margin:12px 0 6px">이 사이트는 차단되어 있어요</h1><p style="font-size:14px;margin:0;color:#8a7f72">습관 차단기가 이 도메인 접속을 막았습니다. 정말 필요하면 메뉴 막대의 습관 차단기에서 해제하세요.</p></div></body></html>
    """

    private static let blockPageResponse = httpResponse(
        status: "403 Forbidden",
        contentType: "text/html; charset=utf-8",
        body: blockPageBody
    )

    // MARK: - 시스템 프록시 상태 (읽기는 관리자 권한 불필요)

    static func isBlockActive() -> Bool {
        if HostFileService.isLegacySectionPresent() { return true }
        for service in listNetworkServices() {
            if let entry = currentAutoProxyEntry(for: service),
               entry.enabled, let url = entry.url, isHabitBlockerPacURL(url) {
                return true
            }
        }
        return false
    }

    static func networkServiceNames(fromListOutput output: String) -> [String] {
        var names: [String] = []
        for rawLine in output.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lowered = line.lowercased()
            if lowered.contains("denotes that a network service is disabled") { continue }
            if lowered.hasPrefix("** error") { continue }
            if line.hasPrefix("*") { line.removeFirst() }
            if line.isEmpty { continue }
            names.append(line)
        }
        return names
    }

    static func isHabitBlockerPacURL(_ urlString: String) -> Bool {
        let lowered = urlString.lowercased()
        return lowered.contains("127.0.0.1:\(listenPort)") && lowered.contains(pacPathPrefix)
    }

    /// `-getautoproxyurl` 출력 한 줄에서 URL을 뽑아낸다. `URL:` 접두사와 꺾쇠 감싸기를 모두 처리한다.
    static func extractURL(from line: String) -> String? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("url:") {
            trimmed = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
        }
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        guard trimmed.contains("://") else { return nil }
        return trimmed
    }

    static func currentAutoProxyEntry(for service: String) -> ProxyBackupEntry? {
        guard let output = runNetworkSetup(["-getautoproxyurl", service]) else { return nil }

        var enabled = false
        var url: String?
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lowered = line.lowercased()
            if lowered.hasPrefix("enabled:") {
                enabled = lowered.contains("yes")
            } else {
                url = extractURL(from: line) ?? url
            }
        }
        return ProxyBackupEntry(url: url, enabled: enabled)
    }

    static func listNetworkServices() -> [String] {
        guard let output = runNetworkSetup(["-listallnetworkservices"]) else { return [] }
        return networkServiceNames(fromListOutput: output)
    }

    private static func runNetworkSetup(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: networkSetupPath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return nil
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: outputData, encoding: .utf8)
    }

    // MARK: - 차단 적용 / 해제

    static func apply(shouldBlock: Bool, domains: [String]) async throws {
        let hostnames = DomainNormalizer.hostnames(for: domains)
        guard !shouldBlock || !hostnames.isEmpty else { throw BlockServiceError.emptyDomainList }

        let services = listNetworkServices()
        guard !services.isEmpty else { throw BlockServiceError.networkServicesUnavailable }

        if shouldBlock {
            let pacURLString = preparePacScript(domains: domains)

            var backup = readProxyBackup()
            for service in services {
                guard let current = currentAutoProxyEntry(for: service) else { continue }
                if let url = current.url, isHabitBlockerPacURL(url) { continue }
                backup[service] = current
            }

            let script = buildAdminScript(
                services: services,
                pacURLString: pacURLString,
                restore: [:],
                hostsCleanupContent: HostFileService.cleanedHostsContent()
            )
            try await AdminShell.run("do shell script \(AdminShell.appleScriptString(script)) with administrator privileges")
            // 암호 취소 등으로 스크립트가 실행되지 않았으면 백업도 남기지 않는다.
            saveProxyBackup(backup)
            startRejectListener()

            guard hasOurPacEnabled() else { throw BlockServiceError.applyNotVerified }
            saveLastAppliedDomains(domains)
        } else {
            let script = buildAdminScript(
                services: services,
                pacURLString: nil,
                restore: readProxyBackup(),
                hostsCleanupContent: HostFileService.cleanedHostsContent()
            )
            try await AdminShell.run("do shell script \(AdminShell.appleScriptString(script)) with administrator privileges")

            guard !isBlockActive() else { throw BlockServiceError.clearNotVerified }
            clearProxyBackup()
            clearLastAppliedDomains()
            stopRejectListener()
        }
    }

    /// 실제로 어딘가에 우리 PAC이 켜져 있는지. 레거시 hosts와 무관하게 프록시 상태만 본다.
    private static func hasOurPacEnabled() -> Bool {
        for service in listNetworkServices() {
            guard let entry = currentAutoProxyEntry(for: service),
                  entry.enabled, let url = entry.url else { continue }
            if isHabitBlockerPacURL(url) { return true }
        }
        return false
    }

    /// networksetup 명령 스크립트 생성. pacURLString이 nil이면 해제(또는 백업 복원)한다.
    static func buildAdminScript(services: [String],
                                 pacURLString: String?,
                                 restore: [String: ProxyBackupEntry],
                                 hostsCleanupContent: String?) -> String {
        var lines = ["set -e"]

        if let hostsCleanupContent {
            let encoded = Data(hostsCleanupContent.utf8).base64EncodedString()
            lines.append("printf %s \(encoded) | /usr/bin/base64 -D > /etc/hosts")
            lines.append("/usr/bin/dscacheutil -flushcache")
            lines.append("/usr/bin/killall -HUP mDNSResponder || true")
        }

        // 서비스 하나가 실패해도 나머지를 계속 적용한다. 성공 여부는 apply()가 실제 시스템 상태로 판정한다.
        let tolerate = " 2>/dev/null || true"
        let networksetup = shellQuoted(networkSetupPath)
        for service in services {
            let serviceArgument = shellQuoted(service)
            if let pacURLString {
                lines.append("\(networksetup) -setautoproxyurl \(serviceArgument) \(shellQuoted(pacURLString))\(tolerate)")
                lines.append("\(networksetup) -setautoproxystate \(serviceArgument) on\(tolerate)")
            } else if let entry = restore[service], let url = entry.url, !url.isEmpty {
                lines.append("\(networksetup) -setautoproxyurl \(serviceArgument) \(shellQuoted(url))\(tolerate)")
                lines.append("\(networksetup) -setautoproxystate \(serviceArgument) \(entry.enabled ? "on" : "off")\(tolerate)")
            } else if restore[service] != nil {
                // URL 없이 '켜짐'이던 비정상 설정은 꺼진 상태로 복원한다.
                lines.append("\(networksetup) -setautoproxystate \(serviceArgument) off\(tolerate)")
            } else {
                lines.append("\(networksetup) -setautoproxystate \(serviceArgument) off\(tolerate)")
                lines.append("\(networksetup) -setautoproxyurl \(serviceArgument) ' '\(tolerate)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 로컬 저장

    static func readProxyBackup(defaults: UserDefaults = .standard) -> [String: ProxyBackupEntry] {
        guard let data = defaults.data(forKey: proxyBackupKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ProxyBackupEntry].self, from: data)) ?? [:]
    }

    static func saveProxyBackup(_ backup: [String: ProxyBackupEntry], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(backup) else { return }
        defaults.set(data, forKey: proxyBackupKey)
    }

    static func clearProxyBackup(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: proxyBackupKey)
    }

    /// 마지막으로 차단에 성공한 도메인 목록. 앱 재실행 시 PAC을 즉시 재구성하기 위해 사용한다.
    static func lastAppliedDomains(defaults: UserDefaults = .standard) -> [String]? {
        defaults.stringArray(forKey: lastAppliedDomainsKey)
    }

    static func saveLastAppliedDomains(_ domains: [String], defaults: UserDefaults = .standard) {
        defaults.set(domains, forKey: lastAppliedDomainsKey)
    }

    static func clearLastAppliedDomains(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: lastAppliedDomainsKey)
    }
}
