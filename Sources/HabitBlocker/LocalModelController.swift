import Darwin
import Foundation

enum ModelInstallState: Equatable {
    case missing
    case downloading(Double)
    case ready
}

enum LocalModelError: LocalizedError, Sendable {
    case notEnoughDisk
    case downloadFailed(String)
    case invalidFile
    case runtimeFailed(String)
    case serverExited(String)
    case timedOut(String)
    case inferenceFailed(String)
    case modelMissing
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notEnoughDisk:
            return "디스크 공간이 부족합니다. 모델은 5GB 안팎입니다."
        case let .downloadFailed(message):
            return message.isEmpty ? "모델을 받지 못했습니다." : message
        case .invalidFile:
            return "받은 파일이 모델 형식이 아닙니다. 다시 받아 주세요."
        case let .runtimeFailed(message):
            return message.isEmpty ? "로컬 실행 엔진을 준비하지 못했습니다." : message
        case let .serverExited(message):
            return message.isEmpty ? "모델 서버가 바로 종료되었습니다." : "모델 서버가 종료되었습니다. \(message)"
        case let .timedOut(message):
            return message.isEmpty ? "모델을 불러오는 데 너무 오래 걸렸습니다." : "모델을 불러오는 데 너무 오래 걸렸습니다. \(message)"
        case let .inferenceFailed(message):
            return message.isEmpty ? "모델이 판단을 돌려주지 않았습니다." : message
        case .modelMissing:
            return "선택한 모델 파일이 없습니다."
        case .cancelled:
            return "받기를 취소했습니다."
        }
    }
}

@MainActor
final class LocalModelController: ObservableObject {
    @Published private(set) var installState: [String: ModelInstallState] = [:]
    @Published private(set) var selectedID: String
    @Published private(set) var runtimeReady = false
    @Published private(set) var runtimeProgress: Double?
    @Published private(set) var isBusy = false
    @Published private(set) var banner = ""
    @Published private(set) var bannerIsError = false

    private let selectedKey = "selectedLocalModelID"
    private var process: Process?
    private var logHandle: FileHandle?
    private var port: UInt16?
    private var apiKey: String?
    private var runningModelID: String?
    private var serverReady = false
    private var startTask: Task<Void, Error>?
    private var activeDownload: FileDownload?
    private var busyCount = 0

    init() {
        if let saved = UserDefaults.standard.string(forKey: selectedKey),
           ModelCatalog.spec(id: saved) != nil {
            selectedID = saved
        } else {
            selectedID = ModelCatalog.recommendedID
        }
        refreshFiles()
    }

    var selectedSpec: LocalModelSpec? {
        ModelCatalog.spec(id: selectedID)
    }

    var selectedModelIsReady: Bool {
        isReady(selectedID)
    }

    var statusLine: String {
        guard let spec = selectedSpec else { return "모델을 고르세요." }
        switch installState[spec.id] ?? .missing {
        case .ready:
            return "\(spec.name)을 사용합니다."
        case let .downloading(fraction):
            return "\(spec.name) 받는 중 \(Int((fraction * 100).rounded()))%"
        case .missing:
            return "\(spec.name)을 설정에서 받으세요."
        }
    }

    var isDownloading: Bool {
        if runtimeProgress != nil { return true }
        return installState.values.contains { state in
            if case .downloading = state { return true }
            return false
        }
    }

    func isReady(_ id: String) -> Bool {
        if case .ready = installState[id] { return true }
        return false
    }

    func refreshFiles() {
        try? SupportPaths.prepare()
        removePartials()
        runtimeReady = findServerBinary() != nil
        var next: [String: ModelInstallState] = [:]
        for spec in ModelCatalog.specs {
            if case .downloading = installState[spec.id] {
                next[spec.id] = installState[spec.id]
            } else if ModelCatalog.isUsableModelFile(at: SupportPaths.modelFile(spec), expectedBytes: spec.byteSize) {
                next[spec.id] = .ready
            } else {
                next[spec.id] = .missing
            }
        }
        installState = next
    }

    func select(_ id: String) {
        guard isReady(id), ModelCatalog.spec(id: id) != nil else { return }
        selectedID = id
        UserDefaults.standard.set(id, forKey: selectedKey)
        banner = ""
        if serverReady, runningModelID != id {
            Task { try? await ensureServer() }
        }
    }

    func download(_ id: String) {
        guard let spec = ModelCatalog.spec(id: id), !isDownloading else { return }
        if isReady(id) { return }
        banner = ""
        bannerIsError = false
        Task {
            do {
                try SupportPaths.prepare()
                try ensureDiskSpace(for: spec.byteSize)
                if findServerBinary() == nil {
                    try await downloadRuntime()
                }
                installState[id] = .downloading(0)
                let partial = SupportPaths.modelFile(spec).appendingPathExtension("partial")
                let downloaded = try await downloadFile(from: spec.downloadURL, to: partial) { [weak self] fraction in
                    Task { @MainActor in
                        self?.installState[id] = .downloading(fraction)
                    }
                }
                let finalURL = SupportPaths.modelFile(spec)
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: downloaded, to: finalURL)
                guard ModelCatalog.isUsableModelFile(at: finalURL, expectedBytes: spec.byteSize) else {
                    try? FileManager.default.removeItem(at: finalURL)
                    throw LocalModelError.invalidFile
                }
                installState[id] = .ready
                select(id)
                setBanner("\(spec.name)을 받았습니다.", error: false)
            } catch is CancellationError {
                installState[id] = .missing
                removePartials()
                setBanner("받기를 취소했습니다.", error: false)
            } catch let error as LocalModelError where error.isCancellation {
                installState[id] = .missing
                removePartials()
                setBanner("받기를 취소했습니다.", error: false)
            } catch {
                if ModelCatalog.isUsableModelFile(at: SupportPaths.modelFile(spec), expectedBytes: spec.byteSize) {
                    installState[id] = .ready
                } else {
                    installState[id] = .missing
                    try? FileManager.default.removeItem(at: SupportPaths.modelFile(spec).appendingPathExtension("partial"))
                }
                setBanner(error.localizedDescription, error: true)
            }
        }
    }

    func cancelDownload() {
        activeDownload?.cancel()
        activeDownload = nil
        runtimeProgress = nil
    }

    func delete(_ id: String) {
        guard let spec = ModelCatalog.spec(id: id) else { return }
        if runningModelID == id {
            stopServer()
        }
        try? FileManager.default.removeItem(at: SupportPaths.modelFile(spec))
        installState[id] = .missing
        if selectedID == id {
            if let replacement = ModelCatalog.specs.first(where: { isReady($0.id) }) {
                select(replacement.id)
            }
        }
        setBanner("\(spec.name)을 지웠습니다.", error: false)
    }

    func deleteRuntime() {
        stopServer()
        try? FileManager.default.removeItem(at: SupportPaths.runtimeDirectory)
        try? SupportPaths.prepare()
        runtimeReady = false
        setBanner("실행 엔진을 지웠습니다. 모델을 다시 받으면 함께 준비합니다.", error: false)
    }

    func ensureServer() async throws {
        if serverReady, runningModelID == selectedID, process?.isRunning == true {
            return
        }
        if let startTask {
            try await startTask.value
            if serverReady, runningModelID == selectedID, process?.isRunning == true {
                return
            }
        }
        let task = Task { try await self.launchServer() }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    func stopServer() {
        serverReady = false
        runningModelID = nil
        port = nil
        apiKey = nil
        let running = process
        process = nil
        logHandle?.closeFile()
        logHandle = nil
        guard let running, running.isRunning else { return }
        let pid = running.processIdentifier
        running.terminate()
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    func judge(appName: String, pageURL: String?, title: String, goal: String) async throws -> FocusVerdict {
        beginBusy()
        defer { endBusy() }
        try await ensureServer()
        guard let port else { throw LocalModelError.serverExited("포트가 없습니다.") }
        let messages = FocusPolicy.messages(goal: goal, appName: appName, pageURL: pageURL, title: title)
        let payload: [String: Any] = [
            "messages": [
                ["role": "system", "content": messages.system],
                ["role": "user", "content": messages.user],
            ],
            "temperature": 0,
            "max_tokens": 128,
            "stream": false,
            "cache_prompt": true,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalModelError.inferenceFailed("응답이 없습니다.")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data.prefix(240), encoding: .utf8) ?? ""
            throw LocalModelError.inferenceFailed("HTTP \(http.statusCode) \(body)")
        }
        guard let content = messageContent(from: data), let verdict = FocusPolicy.parseModelOutput(content) else {
            let body = String(data: data.prefix(240), encoding: .utf8) ?? ""
            throw LocalModelError.inferenceFailed(body)
        }
        return verdict
    }

    func runSamples(goal: String) async throws -> [String] {
        let samples = [
            ("https://www.youtube.com/watch?v=lecture", "미적분 기본 개념 강의 - YouTube"),
            ("https://www.youtube.com/watch?v=game", "스타크래프트 결승 하이라이트 - YouTube"),
        ]
        var lines: [String] = []
        for sample in samples {
            let verdict = try await judge(appName: "Safari", pageURL: sample.0, title: sample.1, goal: goal)
            let percent = Int((verdict.confidence * 100).rounded())
            lines.append("\(FocusPolicy.shortTitle(sample.1)): \(verdict.label.korean) \(percent)%")
        }
        return lines
    }

    private func launchServer() async throws {
        beginBusy()
        defer { endBusy() }
        guard let spec = selectedSpec else { throw LocalModelError.modelMissing }
        let modelURL = SupportPaths.modelFile(spec)
        guard ModelCatalog.isUsableModelFile(at: modelURL, expectedBytes: spec.byteSize) else {
            installState[spec.id] = .missing
            throw LocalModelError.modelMissing
        }
        guard let binary = findServerBinary() else {
            runtimeReady = false
            throw LocalModelError.runtimeFailed("실행 엔진이 없습니다. 모델을 다시 받으세요.")
        }
        guard let port = LoopbackPort.firstAvailable(from: ModelCatalog.serverPort, count: 8) else {
            throw LocalModelError.serverExited("로컬 포트를 열지 못했습니다.")
        }

        stopServer()
        let key = UUID().uuidString
        var arguments = ModelCatalog.serverArguments(modelPath: modelURL.path, port: port)
        arguments += ["--api-key", key]
        let launched = try startProcess(binary: binary, arguments: arguments)
        apiKey = key
        process = launched
        do {
            try await waitUntilReady(process: launched, port: port)
        } catch {
            stopServer()
            throw error
        }
        self.port = port
        self.runningModelID = spec.id
        self.serverReady = true
    }

    private func startProcess(binary: URL, arguments: [String]) throws -> Process {
        FileManager.default.createFile(atPath: SupportPaths.serverLog.path, contents: nil)
        let handle = try FileHandle(forWritingTo: SupportPaths.serverLog)
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = binary.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_LIBRARY_PATH"] = binary.deletingLastPathComponent().path
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        logHandle = handle
        try process.run()
        return process
    }

    private func waitUntilReady(process: Process, port: UInt16) async throws {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            if !process.isRunning {
                throw LocalModelError.serverExited(Self.logTail())
            }
            if await health(port: port) { return }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw LocalModelError.timedOut(Self.logTail())
    }

    private func health(port: UInt16) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            return false
        }
        let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        return text.contains("ok")
    }

    private func downloadRuntime() async throws {
        runtimeProgress = 0
        defer { runtimeProgress = nil }
        let archive = SupportPaths.runtimeDirectory.appendingPathComponent(ModelCatalog.runtimeArchiveName).appendingPathExtension("partial")
        let downloaded = try await downloadFile(from: ModelCatalog.runtimeDownloadURL, to: archive) { [weak self] fraction in
            Task { @MainActor in
                self?.runtimeProgress = fraction
            }
        }
        let extractRoot = SupportPaths.runtimeDirectory
        if FileManager.default.fileExists(atPath: extractRoot.path) {
            let existing = (try? FileManager.default.contentsOfDirectory(at: extractRoot, includingPropertiesForKeys: nil)) ?? []
            for url in existing where url.lastPathComponent != downloaded.lastPathComponent {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try await runTool("/usr/bin/tar", ["-xzf", downloaded.path, "-C", extractRoot.path])
        try? FileManager.default.removeItem(at: downloaded)
        guard let binary = findServerBinary() else {
            throw LocalModelError.runtimeFailed("실행 파일 llama-server를 찾지 못했습니다.")
        }
        try await runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", extractRoot.path])
        try await signRuntime(at: binary.deletingLastPathComponent())
        runtimeReady = true
    }

    private func runtimeBinaries(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var targets: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name == "llama-server" || name.hasSuffix(".dylib") {
                targets.append(url)
            }
        }
        return targets
    }

    private func signRuntime(at directory: URL) async throws {
        let targets = runtimeBinaries(in: directory)
        for url in targets {
            try await runTool("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
        }
    }

    private func downloadFile(from remote: URL, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        let download = FileDownload(destination: destination, onProgress: onProgress)
        activeDownload = download
        defer { activeDownload = nil }
        return try await download.start(url: remote)
    }

    private func ensureDiskSpace(for bytes: Int64) throws {
        try SupportPaths.prepare()
        let values = try SupportPaths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        if available < bytes + 700_000_000 {
            throw LocalModelError.notEnoughDisk
        }
    }

    private func findServerBinary() -> URL? {
        let root = SupportPaths.runtimeDirectory
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "llama-server" {
            return url
        }
        return nil
    }

    private func removePartials() {
        for directory in [SupportPaths.modelsDirectory, SupportPaths.runtimeDirectory] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.lastPathComponent.contains(".partial") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func messageContent(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        if let content = message["content"] as? String,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }
        if let reasoning = message["reasoning_content"] as? String {
            return reasoning
        }
        return nil
    }

    private func beginBusy() {
        busyCount += 1
        isBusy = true
    }

    private func endBusy() {
        busyCount = max(0, busyCount - 1)
        isBusy = busyCount > 0
    }

    private func setBanner(_ message: String, error: Bool) {
        banner = message
        bannerIsError = error
    }

    private static func logTail() -> String {
        guard let data = try? Data(contentsOf: SupportPaths.serverLog) else { return "" }
        let text = String(data: data.suffix(500), encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runTool(_ path: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            try process.run()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let errorText = String(data: errorData.isEmpty ? outputData : errorData, encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                throw LocalModelError.runtimeFailed(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value
    }
}

private extension LocalModelError {
    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

private enum LoopbackPort {
    static func firstAvailable(from start: UInt16, count: Int) -> UInt16? {
        for offset in 0..<count {
            let candidate = start + UInt16(offset)
            if canBind(candidate) { return candidate }
        }
        return nil
    }

    private static func canBind(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var finished = false
    private let lock = NSLock()

    init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func start(url: URL) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("HabitBlocker/1.0", forHTTPHeaderField: "User-Agent")
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.downloadTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let directory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let urlError = error as? URLError
            if urlError?.code == .cancelled {
                finish(.failure(LocalModelError.cancelled))
            } else {
                finish(.failure(LocalModelError.downloadFailed(error.localizedDescription)))
            }
            session.finishTasksAndInvalidate()
            return
        }
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(LocalModelError.downloadFailed("HTTP \(http.statusCode)")))
        } else if FileManager.default.fileExists(atPath: destination.path) {
            finish(.success(destination))
        } else {
            finish(.failure(LocalModelError.downloadFailed("파일을 저장하지 못했습니다.")))
        }
        session.finishTasksAndInvalidate()
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation?.resume(with: result)
        continuation = nil
    }
}
