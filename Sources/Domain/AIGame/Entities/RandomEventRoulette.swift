import Foundation

public enum RandomEventRoulette {
    public static func pick(using r: RandomSource) -> AIGameEvent {
        let n = AIGameEvent.allCases.count
        let raw = r.nextUnit() * Float(n)
        let i = max(0, min(n - 1, Int(raw)))
        return AIGameEvent.allCases[i]
    }
}
