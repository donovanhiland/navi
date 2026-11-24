#if DEBUG
import Foundation

enum DemoScript {
    static let launchKey = "NaviDemo"
    static let raw = "um so I think we should uh move the launch to thursday and like send the beta to the team tonight"
    static let cleaned = "I think we should move the launch to Thursday and send the beta to the team tonight."
    static let wordStep: Duration = .milliseconds(260)
    static let cleanupTime: Duration = .milliseconds(900)

    static var isOn: Bool { UserDefaults.standard.bool(forKey: launchKey) }

    static var words: [String] { raw.split(separator: " ").map(String.init) }

    static func level(at step: Int) -> Double {
        let wave = 0.55 + 0.35 * sin(Double(step) * 0.9) + 0.1 * cos(Double(step) * 2.3)
        return min(max(wave, 0.15), 1)
    }
}
#endif
