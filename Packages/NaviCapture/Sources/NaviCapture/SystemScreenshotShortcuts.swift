import Foundation
import os

@MainActor
public enum SystemScreenshotShortcuts {
    static let defaults: [String: [String: Any]] = [
        "28": entry(enabled: true, parameters: [51, 20, 1_179_648]),
        "29": entry(enabled: true, parameters: [51, 20, 1_441_792]),
        "30": entry(enabled: true, parameters: [52, 21, 1_179_648]),
        "31": entry(enabled: true, parameters: [52, 21, 1_441_792]),
        "184": entry(enabled: true, parameters: [53, 23, 1_179_648]),
    ]

    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString
    private static let backupKey = "capture.systemShortcutsBackup"
    private static let logger = Logger(subsystem: "com.donovanhiland.navi", category: "SystemShortcuts")

    public static var isTakenOver: Bool { UserDefaults.standard.dictionary(forKey: backupKey) != nil }

    public static func takeOver() {
        let (updated, fresh) = disabling(Array(defaults.keys), in: read())
        let old = UserDefaults.standard.dictionary(forKey: backupKey) ?? [:]
        UserDefaults.standard.set(merging(old: old, fresh: fresh), forKey: backupKey)
        write(updated)
    }

    public static func giveBack() {
        guard let backup = UserDefaults.standard.dictionary(forKey: backupKey) else { return }
        write(restoring(backup, in: read()))
        UserDefaults.standard.removeObject(forKey: backupKey)
    }

    static func disabling(_ ids: [String], in hotKeys: [String: Any]) -> (hotKeys: [String: Any], backup: [String: Any]) {
        var hotKeys = hotKeys
        var backup: [String: Any] = [:]
        for id in ids {
            let old = hotKeys[id] as? [String: Any]
            backup[id] = old ?? [String: Any]()
            var new = old ?? defaults[id] ?? [:]
            new["enabled"] = false
            hotKeys[id] = new
        }
        return (hotKeys, backup)
    }

    static func merging(old: [String: Any], fresh: [String: Any]) -> [String: Any] {
        old.merging(fresh) { kept, _ in kept }
    }

    static func restoring(_ backup: [String: Any], in hotKeys: [String: Any]) -> [String: Any] {
        var hotKeys = hotKeys
        for (id, old) in backup {
            if let old = old as? [String: Any], !old.isEmpty {
                hotKeys[id] = old
            } else {
                hotKeys[id] = nil
            }
        }
        return hotKeys
    }

    private static func entry(enabled: Bool, parameters: [Int]) -> [String: Any] {
        ["enabled": enabled, "value": ["parameters": parameters, "type": "standard"]]
    }

    private static func read() -> [String: Any] {
        CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }

    private static func write(_ hotKeys: [String: Any]) {
        CFPreferencesSetValue(key, hotKeys as CFDictionary, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
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
            logger.error("Could not apply shortcut settings: \(error.localizedDescription)")
        }
    }
}
