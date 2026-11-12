import Foundation
import os

@MainActor
public enum SystemFnKey {
    private static let domain = "com.apple.HIToolbox" as CFString
    private static let key = "AppleFnUsageType" as CFString
    private static let backupKey = "dictation.fnUsageBackup"
    private static let logger = Logger(subsystem: "com.donovanhiland.navi", category: "SystemFnKey")

    public static var isTakenOver: Bool { UserDefaults.standard.dictionary(forKey: backupKey) != nil }

    public static func takeOver() {
        let existing = UserDefaults.standard.dictionary(forKey: backupKey).flatMap(Backup.init(storage:))
        let (value, backup) = FnUsage.borrowing(current: read(), existingBackup: existing)
        if existing == nil { UserDefaults.standard.set(backup.storage, forKey: backupKey) }
        write(value)
    }

    public static func giveBack() {
        guard let stored = UserDefaults.standard.dictionary(forKey: backupKey), let backup = Backup(storage: stored) else {
            UserDefaults.standard.removeObject(forKey: backupKey)
            return
        }
        write(FnUsage.restoring(backup))
        UserDefaults.standard.removeObject(forKey: backupKey)
    }

    typealias Backup = FnUsage.Backup

    private static func read() -> Int? {
        CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Int
    }

    private static func write(_ value: Int?) {
        CFPreferencesSetValue(key, value.map { $0 as CFNumber }, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        if !CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) {
            logger.error("Could not save the fn key setting")
        }
        applyNow()
    }

    private static func applyNow() {
        let process = Process()
        process.executableURL = URL(
            filePath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
        )
        process.arguments = ["-u"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("Could not apply the fn key setting: \(error.localizedDescription)")
        }
    }
}

enum FnUsage {
    static let doNothing = 0

    struct Backup: Equatable {
        var previous: Int?

        init(previous: Int?) { self.previous = previous }

        var storage: [String: Any] { previous.map { ["value": $0] } ?? [:] }

        init?(storage: [String: Any]) {
            if let value = storage["value"] as? Int {
                previous = value
            } else if storage.isEmpty {
                previous = nil
            } else {
                return nil
            }
        }
    }

    static func borrowing(current: Int?, existingBackup: Backup?) -> (value: Int, backup: Backup) {
        (doNothing, existingBackup ?? Backup(previous: current))
    }

    static func restoring(_ backup: Backup) -> Int? {
        backup.previous
    }
}
