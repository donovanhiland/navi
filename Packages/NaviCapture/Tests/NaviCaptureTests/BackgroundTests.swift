import CoreGraphics
import Foundation
import Testing

@testable import NaviCapture

@Suite struct BackgroundTests {
    @Test func canvasAddsPadding() {
        let size = BackgroundLayout.canvasSize(content: CGSize(width: 100, height: 50), padding: 10, ratio: nil)
        #expect(size == CGSize(width: 120, height: 70))
    }

    @Test func canvasGrowsToTheAspectRatio() {
        let wide = BackgroundLayout.canvasSize(content: CGSize(width: 100, height: 100), padding: 0, ratio: 16.0 / 9)
        #expect(wide == CGSize(width: 178, height: 100))
        let tall = BackgroundLayout.canvasSize(content: CGSize(width: 100, height: 100), padding: 0, ratio: 9.0 / 16)
        #expect(tall == CGSize(width: 100, height: 178))
    }

    @Test func autoBalanceEvensOutMargins() {
        let rect = AutoBalance.balancedRect(width: 100, height: 100) { x, y in
            (10 ..< 30).contains(x) && (20 ..< 40).contains(y) ? (0, 0, 0, 255) : (255, 255, 255, 255)
        }
        #expect(rect == CGRect(x: 0, y: 10, width: 40, height: 40))
    }

    @Test func autoBalanceKeepsAPlainImage() {
        let rect = AutoBalance.balancedRect(width: 10, height: 10) { _, _ in (1, 2, 3, 255) }
        #expect(rect == CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    @Test func styleRoundTripsThroughJSON() throws {
        var style = BackgroundStyle()
        style.fill = .solid(.red)
        style.aspect = .square
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(BackgroundStyle.self, from: data) == style)
    }
}
