import Foundation

struct SoundGate: Equatable, Sendable {
    static let margin: Float = 12
    static let lowestFloor: Float = -60
    static let highestFloor: Float = -50

    private(set) var floor: Float = .infinity

    var threshold: Float {
        min(max(floor, Self.lowestFloor), Self.highestFloor) + Self.margin
    }

    mutating func isSound(decibels: Float) -> Bool {
        floor = min(floor, decibels)
        return decibels > threshold
    }
}
