import Foundation

enum SaveFolder {
    static func resolve(override: URL?, systemLocation: String?, home: URL, isDirectory: (URL) -> Bool) -> URL {
        if let override { return override }
        let desktop = home.appending(path: "Desktop", directoryHint: .isDirectory)
        guard let systemURL = systemURL(from: systemLocation, home: home), isDirectory(systemURL) else {
            return desktop
        }
        return systemURL
    }

    static func systemLocation() -> String? {
        let domain = "com.apple.screencapture" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("location" as CFString, domain) as? String
    }

    private static func systemURL(from location: String?, home: URL) -> URL? {
        guard let trimmed = location?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed == "~" {
            return home
        }
        if trimmed.hasPrefix("~/") {
            return home.appending(path: String(trimmed.dropFirst(2)), directoryHint: .isDirectory)
        }
        guard trimmed.hasPrefix("/") else { return nil }
        return URL(filePath: trimmed, directoryHint: .isDirectory)
    }
}
