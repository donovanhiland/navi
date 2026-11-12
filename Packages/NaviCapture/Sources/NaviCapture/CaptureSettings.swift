import Foundation
import Observation

@MainActor
@Observable
public final class CaptureSettings {
    @ObservationIgnored private let defaults: UserDefaults

    public var hideDesktopIcons: Bool {
        didSet { defaults.set(hideDesktopIcons, forKey: Keys.hideDesktopIcons) }
    }

    public var saveFolderOverride: URL? {
        didSet {
            if let saveFolderOverride {
                defaults.set(saveFolderOverride.path, forKey: Keys.saveFolder)
            } else {
                defaults.removeObject(forKey: Keys.saveFolder)
            }
        }
    }

    public var saveFolder: URL {
        get {
            SaveFolder.resolve(
                override: saveFolderOverride,
                systemLocation: SaveFolder.systemLocation(),
                home: FileManager.default.homeDirectoryForCurrentUser
            ) { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        }
        set { saveFolderOverride = newValue }
    }

    public var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: Keys.copyToClipboard) }
    }

    public var editAfterCapture: Bool {
        didSet { defaults.set(editAfterCapture, forKey: Keys.editAfterCapture) }
    }

    public var autoCloseSeconds: Double {
        didSet { defaults.set(autoCloseSeconds, forKey: Keys.autoCloseSeconds) }
    }

    public var useNaviScreenshotKeys: Bool? {
        didSet { defaults.set(useNaviScreenshotKeys, forKey: Keys.useNaviScreenshotKeys) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hideDesktopIcons = defaults.bool(forKey: Keys.hideDesktopIcons)
        saveFolderOverride = defaults.string(forKey: Keys.saveFolder).map { URL(filePath: $0, directoryHint: .isDirectory) }
        copyToClipboard = defaults.object(forKey: Keys.copyToClipboard) as? Bool ?? true
        editAfterCapture = defaults.bool(forKey: Keys.editAfterCapture)
        autoCloseSeconds = defaults.double(forKey: Keys.autoCloseSeconds)
        useNaviScreenshotKeys = defaults.object(forKey: Keys.useNaviScreenshotKeys) as? Bool
    }

    private enum Keys {
        static let hideDesktopIcons = "capture.hideDesktopIcons"
        static let saveFolder = "capture.saveFolder"
        static let copyToClipboard = "capture.copyToClipboard"
        static let editAfterCapture = "capture.editAfterCapture"
        static let autoCloseSeconds = "capture.autoCloseSeconds"
        static let useNaviScreenshotKeys = "capture.useNaviScreenshotKeys"
    }
}
