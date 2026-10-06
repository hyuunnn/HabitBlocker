import Foundation

/// AI가 켜져 있는 동안 판단 프로세스를 하나 유지한다. 호출마다 모델을 다시 올리지 않는다.
enum LayaClassifier {
    private static let engine = LayaEngine()

    static func prepare() async -> String? {
        await engine.prepare()
    }

    static func stop() {
        engine.stop()
    }

    static func driftProbability(context: FrontContext, goal: String) async -> Double? {
        let state = context.stateText + "\n목표: \(goal)"
        return await engine.driftProbability(state: state)
    }
}

private final class LayaEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var reader: Thread?
    private var generation = 0
    private var ready = false
    private var failed = false
    private var nextID = 0
    private var waiters: [Int: (Double?) -> Void] = [:]
    private var buffer = Data()

    func prepare() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.prepareSync())
            }
        }
    }

    private func prepareSync() -> String? {
        lock.lock()
        let alreadyRunning = process?.isRunning == true && ready
        lock.unlock()
        if alreadyRunning { return nil }

        do {
            let python = try ensurePython()
            return try start(python: python)
        } catch {
            lock.lock()
            failed = true
            lock.unlock()
            return error.localizedDescription
        }
    }

    func stop() {
        lock.lock()
        generation += 1
        let running = process
        process = nil
        input = nil
        ready = false
        failed = false
        let pending = waiters
        waiters.removeAll()
        buffer.removeAll()
        lock.unlock()
        running?.terminate()
        pending.values.forEach { $0(nil) }
    }

    func driftProbability(state: String) async -> Double? {
        await withCheckedContinuation { continuation in
            self.send(state: state) { value in
                continuation.resume(returning: value)
            }
        }
    }

    private func send(state: String, resume: @escaping (Double?) -> Void) {
        lock.lock()
        let canAsk = process?.isRunning == true && ready && !failed
        guard canAsk else {
            lock.unlock()
            resume(nil)
            return
        }
        nextID += 1
        let id = nextID
        waiters[id] = resume
        let handle = input
        lock.unlock()

        guard let handle, let data = try? JSONSerialization.data(withJSONObject: ["id": id, "state": state]) else {
            finish(id: id, drift: nil)
            return
        }
        var line = data
        line.append(0x0A)
        do {
            try handle.write(contentsOf: line)
        } catch {
            finish(id: id, drift: nil)
        }
    }

    private func ensurePython() throws -> URL {
        let python = LayaPaths.python
        if FileManager.default.isExecutableFile(atPath: python.path), try importsLaya(python) {
            return python
        }
        guard let uv = LayaPaths.uvExecutable() else {
            throw LayaEngineError("로컬 런타임을 만들 uv를 찾지 못했습니다.")
        }
        let runtime = LayaPaths.support.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: LayaPaths.support, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: python.path) {
            let created = Process()
            created.executableURL = uv
            created.arguments = ["venv", runtime.path, "--python", "3.12"]
            try run(created, timeout: 180, what: "로컬 런타임을 만들지 못했습니다.")
        }
        let install = Process()
        install.executableURL = uv
        install.arguments = ["pip", "install", "--python", python.path, "laya[onnx]"]
        try run(install, timeout: 1800, what: "laya[onnx]를 설치하지 못했습니다.")
        guard try importsLaya(python) else {
            throw LayaEngineError("설치 뒤에도 laya를 불러오지 못했습니다.")
        }
        return python
    }

    private func importsLaya(_ python: URL) throws -> Bool {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", "import laya"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func start(python: URL) throws -> String? {
        guard let script = LayaPaths.script() else {
            throw LayaEngineError("판단 스크립트를 찾지 못했습니다.")
        }
        try FileManager.default.createDirectory(at: LayaPaths.huggingface, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = python
        process.arguments = [script.path]
        process.environment = mergedEnvironment()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = try errorLogHandle()
        try process.run()

        lock.lock()
        generation += 1
        let token = generation
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.ready = false
        self.failed = false
        lock.unlock()

        let output = outputPipe.fileHandleForReading
        reader = Thread { [weak self] in
            self?.readLoop(output, token: token)
        }
        reader?.start()

        let ready = waitUntilReady(timeout: 1200)
        if !ready {
            stop()
            throw LayaEngineError("모델을 올리는 데 실패했습니다. 네트워크와 디스크 공간을 확인하세요.")
        }
        return nil
    }

    private func errorLogHandle() throws -> FileHandle {
        let url = LayaPaths.support.appendingPathComponent("laya-resident.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    private func mergedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HOME"] = LayaPaths.huggingface.path
        environment["HF_HUB_CACHE"] = LayaPaths.huggingface.appendingPathComponent("hub").path
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        environment["HABITBLOCKER_MODEL"] = FocusPolicy.defaultModelID
        environment["HABITBLOCKER_ONNX"] = LayaPaths.onnx.path
        environment["PYTHONWARNINGS"] = "ignore"
        return environment
    }

    private func waitUntilReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let isReady = ready
            let isFailed = failed
            let running = process?.isRunning == true
            lock.unlock()
            if isReady { return true }
            if isFailed || !running { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    private func readLoop(_ handle: FileHandle, token: Int) {
        while true {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: 4096), !read.isEmpty else { break }
                chunk = read
            } catch {
                break
            }
            lock.lock()
            buffer.append(chunk)
            let lines = takeLines()
            lock.unlock()
            for line in lines {
                handleLine(line)
            }
        }
        lock.lock()
        let current = generation == token
        if current {
            failed = true
        }
        let pending = current ? waiters : [:]
        if current {
            waiters.removeAll()
        }
        lock.unlock()
        pending.values.forEach { $0(nil) }
    }

    private func takeLines() -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let piece = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let text = String(data: piece, encoding: .utf8) {
                lines.append(text)
            }
        }
        return lines
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if object["ready"] as? Bool == true {
            lock.lock()
            ready = true
            lock.unlock()
            return
        }
        if object["ready"] as? Bool == false {
            lock.lock()
            failed = true
            ready = false
            lock.unlock()
            return
        }
        guard let id = object["id"] as? Int else { return }
        let drift = object["drift"] as? Double ?? (object["drift"] as? Int).map(Double.init)
        finish(id: id, drift: object["error"] == nil ? drift : nil)
    }

    private func finish(id: Int, drift: Double?) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        waiter?(drift)
    }

    private func run(_ process: Process, timeout: TimeInterval, what: String) throws {
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            throw LayaEngineError(what)
        }
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LayaEngineError(detail?.isEmpty == false ? "\(what) \(detail ?? "")" : what)
        }
    }
}

private enum LayaPaths {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hyun.habitblocker", isDirectory: true)
    }

    static var python: URL {
        support.appendingPathComponent("runtime/bin/python3")
    }

    static var onnx: URL {
        support.appendingPathComponent("runtime/laya-multilingual.onnx")
    }

    static var huggingface: URL {
        support.appendingPathComponent("huggingface", isDirectory: true)
    }

    static func uvExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func script() -> URL? {
        if let bundled = Bundle.main.url(forResource: "laya_resident", withExtension: "py") {
            return bundled
        }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts/laya_resident.py")
        if FileManager.default.fileExists(atPath: dev.path) {
            return dev
        }
        return nil
    }
}

private struct LayaEngineError: LocalizedError {
    var errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
