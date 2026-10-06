import Foundation

/// AI on/off가 차단을 어디에 적용하는지를 정한다. 사이트 이름이나 제목 규칙은 여기 없다.
enum FocusPolicy {
    static let driftThreshold = 0.80
    static let sustainSeconds: TimeInterval = 2
    static let defaultModelID = "convaiinnovations/laya-multilingual"

    struct Enforcement: Equatable {
        var applyPac: Bool
        var clearPac: Bool
        var judge: Bool
    }

    struct CoverDecision: Equatable {
        var visible: Bool
        var driftSince: Date?
    }

    static func canEditGoal(blockingEnabled: Bool) -> Bool {
        !blockingEnabled
    }

    static func enforcement(aiEnabled: Bool, blockingEnabled: Bool) -> Enforcement {
        if !blockingEnabled {
            return Enforcement(applyPac: false, clearPac: true, judge: false)
        }
        if aiEnabled {
            return Enforcement(applyPac: false, clearPac: true, judge: true)
        }
        return Enforcement(applyPac: true, clearPac: false, judge: false)
    }

    /// 주소가 필요하지만 읽지 못했거나 확률이 없거나 기준 미만이면 가리지 않는다.
    static func cover(
        aiEnabled: Bool,
        blockingEnabled: Bool,
        addressReadable: Bool,
        driftProbability: Double?,
        driftSince: Date?,
        now: Date
    ) -> CoverDecision {
        let judging = enforcement(aiEnabled: aiEnabled, blockingEnabled: blockingEnabled).judge
        guard judging, addressReadable, let driftProbability, driftProbability >= driftThreshold else {
            return CoverDecision(visible: false, driftSince: nil)
        }
        let started = driftSince ?? now
        let elapsed = now.timeIntervalSince(started)
        return CoverDecision(visible: elapsed >= sustainSeconds, driftSince: started)
    }
}
