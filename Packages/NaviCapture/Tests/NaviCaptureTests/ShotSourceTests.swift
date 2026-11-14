import CoreGraphics
import Testing

@testable import NaviCapture

@Suite struct ShotSourceTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 400, height: 300)

    @Test func screenShotFillsTheScreenAtTheOrigin() {
        let secondScreen = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let area = ShotSource.screen.editArea(imageSize: secondScreen.size, screenFrame: secondScreen, scale: 2)
        #expect(area == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    @Test func rectShotKeepsItsRect() {
        let rect = CGRect(x: 10, y: 20, width: 300, height: 200)
        #expect(ShotSource.rect(rect).editArea(imageSize: rect.size, screenFrame: screen, scale: 2) == rect)
    }

    @Test func windowShotUsesItsFrameInTopLeftSpace() {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 300)
        let area = ShotSource.window(1, frame: frame).editArea(imageSize: size, screenFrame: screen, scale: 2)
        #expect(area == CGRect(x: 100, y: 400, width: 400, height: 300))
    }

    @Test func windowShotWithoutFrameIsCentered() {
        let area = ShotSource.window(1, frame: nil).editArea(imageSize: size, screenFrame: screen, scale: 2)
        #expect(area == CGRect(x: 520, y: 300, width: 400, height: 300))
    }

    @Test func onlyWindowShotsLockTheFrameAndWaitForTheApp() {
        #expect(!ShotSource.window(1, frame: nil).reframes)
        #expect(ShotSource.window(1, frame: nil).waitsForApp)
        #expect(ShotSource.screen.reframes)
        #expect(!ShotSource.screen.waitsForApp)
        #expect(ShotSource.screen.flashes)
        #expect(ShotSource.rect(.zero).flashes == false)
    }
}
