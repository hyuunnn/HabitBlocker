import Foundation

enum AdminShellError: LocalizedError, Equatable {
    /// 관리자 암호 창에서 취소했다(AppleScript 오류 -128).
    case cancelled
    /// 명령이 실패했다. 메시지는 osascript 위치 접두사("0:123: execution error: ")를 뗀 원문이다.
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "관리자 암호 입력이 취소되었습니다."
        case let .commandFailed(message):
            return message.isEmpty
                ? "관리자 권한 요청이 취소되었거나 시스템 설정을 변경할 수 없습니다."
                : message
        }
    }

    /// osascript 오류 출력을 분류한다. 설명 문구는 시스템 언어에 따라 달라지므로
    /// 끝에 붙는 오류 번호로 취소를 판별한다. 예: "0:17: execution error: 사용자가 취소함. (-128)"
    static func fromOsascriptOutput(_ output: String) -> AdminShellError {
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if errorNumber(in: message) == userCanceledErrorNumber {
            return .cancelled
        }
        return .commandFailed(strippingScriptLocation(from: message))
    }

    private static let userCanceledErrorNumber = -128

    private static func errorNumber(in message: String) -> Int? {
        guard message.hasSuffix(")"), let open = message.lastIndex(of: "(") else { return nil }
        return Int(message[message.index(after: open)..<message.index(before: message.endIndex)])
    }

    private static func strippingScriptLocation(from message: String) -> String {
        guard let marker = message.range(of: "execution error: ") else { return message }
        let location = message[..<marker.lowerBound]
        guard location.allSatisfy({ $0.isNumber || $0 == ":" || $0 == " " }) else { return message }
        return String(message[marker.upperBound...])
    }
}

/// 관리자 권한이 필요한 셸 명령을 osascript로 실행하는 얇은 래퍼.
enum AdminShell {
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    /// 관리자 권한 실행용 AppleScript 원문. prompt는 암호 창에 표시되어 무엇을 승인하는지 알려 준다.
    static func privilegedScriptSource(_ shellCommand: String, prompt: String) -> String {
        "do shell script \(appleScriptString(shellCommand)) with prompt \(appleScriptString(prompt)) with administrator privileges"
    }

    @discardableResult
    static func runPrivileged(_ shellCommand: String, prompt: String) async throws -> String {
        try await run(privilegedScriptSource(shellCommand, prompt: prompt))
    }

    @discardableResult
    private static func run(_ source: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw AdminShellError.fromOsascriptOutput(errorOutput)
            }
            return output
        }.value
    }
}
