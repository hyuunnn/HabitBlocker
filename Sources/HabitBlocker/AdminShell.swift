import Foundation

enum AdminShellError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message):
            return message.isEmpty
                ? "관리자 권한 요청이 취소되었거나 시스템 설정을 변경할 수 없습니다."
                : message
        }
    }
}

/// 관리자 권한이 필요한 셸 명령을 osascript로 실행하는 얇은 래퍼.
enum AdminShell {
    static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    @discardableResult
    static func run(_ source: String) async throws -> String {
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
                throw AdminShellError.commandFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return output
        }.value
    }
}
