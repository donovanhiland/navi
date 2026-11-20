import CoreGraphics
import Darwin

enum SyntheticKey {
    static let marker: Int64 = 0x4E41_5649

    static func mark(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    static func isNavi(userData: Int64?, processID: Int64? = nil) -> Bool {
        userData == marker || processID == Int64(getpid())
    }

    static func isNavi(_ event: CGEvent?) -> Bool {
        guard let event else { return false }
        return isNavi(
            userData: event.getIntegerValueField(.eventSourceUserData),
            processID: event.getIntegerValueField(.eventSourceUnixProcessID)
        )
    }
}
