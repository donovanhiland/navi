import Foundation
import Testing

@testable import NaviCapture

@Suite struct SaveFolderTests {
    private let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
    private let desktop = URL(filePath: "/Users/tester/Desktop", directoryHint: .isDirectory)

    private func resolve(override: URL? = nil, system: String?, existing: Set<String>) -> String {
        SaveFolder.resolve(override: override, systemLocation: system, home: home) {
            existing.contains($0.path)
        }.path
    }

    @Test func overrideWinsOverSystem() {
        let override = URL(filePath: "/Volumes/Work/Shots", directoryHint: .isDirectory)
        let path = resolve(override: override, system: "~/Pictures/Shots", existing: ["/Users/tester/Pictures/Shots"])
        #expect(path == "/Volumes/Work/Shots")
    }

    @Test func tildePathExpandsAgainstHome() {
        let path = resolve(system: "~/Pictures/Shots", existing: ["/Users/tester/Pictures/Shots"])
        #expect(path == "/Users/tester/Pictures/Shots")
    }

    @Test func absoluteSystemPathIsUsed() {
        let path = resolve(system: "  /Volumes/Shots \n", existing: ["/Volumes/Shots"])
        #expect(path == "/Volumes/Shots")
    }

    @Test func missingSystemFolderFallsBackToDesktop() {
        let path = resolve(system: "~/Pictures/Gone", existing: [])
        #expect(path == desktop.path)
    }

    @Test func nilEmptyAndWhitespaceSystemFallBackToDesktop() {
        #expect(resolve(system: nil, existing: ["/Users/tester"]) == desktop.path)
        #expect(resolve(system: "", existing: [""]) == desktop.path)
        #expect(resolve(system: " \t\n", existing: [" \t\n"]) == desktop.path)
    }

    @Test func relativeSystemPathFallsBackToDesktop() {
        let path = resolve(system: "Pictures/Shots", existing: ["Pictures/Shots"])
        #expect(path == desktop.path)
    }
}
