import Foundation

/// 노트북에서 돌릴 수 있는 Clef-flash 9B 양자화만 둔다.
/// 27B 의사결정 모델과 원본 BF16(약 18GB)은 16GB 메모리에서 브라우저와 함께 두지 못한다.
struct LocalModelSpec: Equatable, Identifiable {
    let id: String
    let name: String
    let detail: String
    let fileName: String
    let downloadURL: URL
    let byteSize: Int64
    let recommended: Bool

    var sizeText: String {
        ModelCatalog.byteText(byteSize)
    }
}

enum ModelCatalog {
    /// llama.cpp가 Qwen3.5(qwen35)를 읽는 빌드. Clef-flash 언어 타워 GGUF를 이 버전으로 고정한다.
    static let llamaRelease = "b10780"
    static let serverPort: UInt16 = 47472
    static let contextTokens = 2048

    static let specs: [LocalModelSpec] = [
        LocalModelSpec(
            id: "clef-flash-iq4",
            name: "Clef Flash 가벼움",
            detail: "4비트 경량 · 16GB에서 가장 여유 있습니다. 판단이 조금 거칠 수 있습니다.",
            fileName: "clef-flash-IQ4_XS.gguf",
            downloadURL: URL(string: "https://huggingface.co/NANI-Nithin/clef-flash-GGUF/resolve/main/clef-flash-IQ4_XS.gguf")!,
            byteSize: 5_196_440_800,
            recommended: false
        ),
        LocalModelSpec(
            id: "clef-flash-q4",
            name: "Clef Flash 기본",
            detail: "4비트 · 일반 노트북의 기본값입니다. 주소와 제목으로 집중과 딴짓을 가릅니다.",
            fileName: "clef-flash-Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/NANI-Nithin/clef-flash-GGUF/resolve/main/clef-flash-Q4_K_M.gguf")!,
            byteSize: 5_629_109_472,
            recommended: true
        ),
        LocalModelSpec(
            id: "clef-flash-q5",
            name: "Clef Flash 정밀",
            detail: "5비트 · 기본보다 조금 더 정확합니다. 16GB에서는 다른 앱과 메모리를 나눕니다.",
            fileName: "clef-flash-Q5_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/NANI-Nithin/clef-flash-GGUF/resolve/main/clef-flash-Q5_K_M.gguf")!,
            byteSize: 6_467_970_272,
            recommended: false
        ),
    ]

    static var recommendedID: String {
        specs.first { $0.recommended }?.id ?? specs[0].id
    }

    static func spec(id: String) -> LocalModelSpec? {
        specs.first { $0.id == id }
    }

    static var runtimeArchiveName: String {
        #if arch(arm64)
        return "llama-\(llamaRelease)-bin-macos-arm64.tar.gz"
        #else
        return "llama-\(llamaRelease)-bin-macos-x64.tar.gz"
        #endif
    }

    static var runtimeDownloadURL: URL {
        URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/\(llamaRelease)/\(runtimeArchiveName)")!
    }

    /// 16GB 머신에서 8GB 프롬프트 캐시와 긴 컨텍스트를 켜면 브라우저가 밀린다.
    static func serverArguments(modelPath: String, port: UInt16) -> [String] {
        [
            "-m", modelPath,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-c", String(contextTokens),
            "-ngl", "99",
            "-np", "1",
            "--cache-ram", "0",
            "--ctx-checkpoints", "0",
            "--no-webui",
            "--cors-origins", "localhost",
            "--reasoning", "off",
            "--reasoning-budget", "0",
        ]
    }

    static func byteText(_ bytes: Int64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        return String(format: "%.1fGB", gib)
    }

    static func isUsableModelFile(at url: URL, expectedBytes: Int64) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = try? handle.read(upToCount: 4)
        guard magic == Data("GGUF".utf8) else { return false }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let lower = expectedBytes * 98 / 100
        let upper = expectedBytes * 102 / 100
        return size >= lower && size <= upper
    }
}

enum SupportPaths {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("HabitBlocker", isDirectory: true)
    }

    static var modelsDirectory: URL {
        root.appendingPathComponent("Models", isDirectory: true)
    }

    static var runtimeDirectory: URL {
        root.appendingPathComponent("Runtime", isDirectory: true)
    }

    static var serverLog: URL {
        root.appendingPathComponent("llama-server.log")
    }

    static func modelFile(_ spec: LocalModelSpec) -> URL {
        modelsDirectory.appendingPathComponent(spec.fileName)
    }

    static func prepare() throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
    }
}
