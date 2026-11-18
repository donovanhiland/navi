import CoreGraphics
import Foundation
import Testing

@testable import NaviCapture

@MainActor
@Suite struct AnnotateTextTests {
    private func makeModel() throws -> AnnotateModel {
        let context = try #require(CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        return AnnotateModel(base: image, scale: 1)
    }

    private func click(_ model: AnnotateModel, at point: CGPoint) {
        model.pointerDown(at: point)
        model.pointerUp(from: point, to: point)
    }

    private func type(_ text: String, at point: CGPoint, in model: AnnotateModel) {
        model.tool = .text
        click(model, at: point)
        model.textEdit?.text = text
    }

    @Test func clickingAwayKeepsTheTextAndSelectsItWithThePointer() throws {
        let model = try makeModel()
        type("Hello", at: CGPoint(x: 50, y: 50), in: model)
        click(model, at: CGPoint(x: 300, y: 250))
        #expect(model.textEdit == nil)
        #expect(model.tool == .select)
        let mark = try #require(model.document.annotations.last)
        #expect(mark.text == "Hello")
        #expect(model.selection == mark.id)
    }

    @Test func pickingTheTextToolOpensNoBoxUntilAClick() throws {
        let model = try makeModel()
        model.pointerMoved(to: CGPoint(x: 120, y: 80))
        model.tool = .text
        #expect(model.textEdit == nil)
        click(model, at: CGPoint(x: 200, y: 150))
        let edit = try #require(model.textEdit)
        #expect(edit.point.x == 200)
        #expect(abs(edit.point.y + edit.fontSize * TextLayout.lineHeight / 2 - 150) < 0.01)
        model.tool = .arrow
        #expect(model.textEdit == nil)
        #expect(model.document.annotations.isEmpty)
    }

    @Test func emptyTextBoxMovesToTheNextClick() throws {
        let model = try makeModel()
        model.tool = .text
        click(model, at: CGPoint(x: 50, y: 50))
        click(model, at: CGPoint(x: 200, y: 100))
        #expect(model.textEdit?.point.x == 200)
        #expect(model.textEdit.map { $0.point.y < 100 && $0.point.y + $0.fontSize > 100 } == true)
        #expect(model.document.annotations.isEmpty)
    }

    @Test func textCanBeDraggedWithTheTextTool() throws {
        let model = try makeModel()
        type("Drag me", at: CGPoint(x: 50, y: 50), in: model)
        model.finishText()
        model.tool = .text
        let mark = try #require(model.document.annotations.last)
        let grab = CGPoint(x: mark.bounds.midX, y: mark.bounds.midY)
        let drop = CGPoint(x: grab.x + 100, y: grab.y + 60)
        model.pointerDown(at: grab)
        model.pointerDragged(from: grab, to: drop)
        model.pointerUp(from: grab, to: drop)
        let moved = try #require(model.document.annotations.first { $0.id == mark.id })
        #expect(moved.start == CGPoint(x: mark.start.x + 100, y: mark.start.y + 60))
        #expect(model.textEdit == nil)
        #expect(model.tool == .select)
    }

    @Test func clickingSelectedTextEditsIt() throws {
        let model = try makeModel()
        type("Edit me", at: CGPoint(x: 50, y: 50), in: model)
        model.finishText()
        let mark = try #require(model.document.annotations.last)
        #expect(model.selection == mark.id)
        click(model, at: CGPoint(x: mark.bounds.midX, y: mark.bounds.midY))
        #expect(model.textEdit?.id == mark.id)
        #expect(model.textEdit?.text == "Edit me")
    }

    @Test func everyToolHasItsOwnKey() {
        let keys = AnnotationTool.allCases.map(\.shortcut)
        #expect(Set(keys).count == keys.count)
        for tool in AnnotationTool.allCases {
            #expect(AnnotationTool.forShortcut(String(tool.shortcut)) == tool)
            #expect(AnnotationTool.forShortcut(String(tool.shortcut).uppercased()) == tool)
        }
        #expect(AnnotationTool.forShortcut("z") == nil)
        #expect(AnnotationTool.forShortcut("ab") == nil)
    }

    @Test func typedTextKeepsItsPlaceAndStyleAfterCommit() throws {
        let model = try makeModel()
        type("Same", at: CGPoint(x: 40, y: 60), in: model)
        let edit = try #require(model.textEdit)
        let frame = try #require(model.editingFrame)
        model.finishText()
        let saved = try #require(model.document.annotations.last)
        #expect(saved.start == edit.point)
        #expect(saved.fontSize == edit.fontSize)
        #expect(saved.color == edit.color)
        #expect(saved.text == "Same")
        #expect(saved.bounds == frame)
    }

    @Test func typingPastTheRightEdgeWrapsInsideTheImage() throws {
        let model = try makeModel()
        type("one two three four five six seven eight nine ten", at: CGPoint(x: 250, y: 40), in: model)
        let frame = try #require(model.editingFrame)
        #expect(frame.maxX <= 400)
        #expect(frame.height > 2 * model.textEdit!.fontSize * TextLayout.lineHeight)
        model.finishText()
        let saved = try #require(model.document.annotations.last)
        #expect(abs((saved.textWidth ?? 0) - (400 - saved.start.x)) < 0.01)
        #expect(saved.bounds.maxX <= 400)
        #expect(abs(saved.bounds.height - frame.height) < 0.5)
    }

    @Test func textStartedAtTheRightEdgeStillHasRoom() throws {
        let model = try makeModel()
        model.tool = .text
        click(model, at: CGPoint(x: 395, y: 40))
        let edit = try #require(model.textEdit)
        #expect(400 - edit.point.x >= edit.fontSize * 8 - 0.01)
    }

    @Test func shortTextGrowsWithItsWords() throws {
        let model = try makeModel()
        type("Hi", at: CGPoint(x: 20, y: 20), in: model)
        let short = try #require(model.editingFrame)
        model.textEdit?.text = "Hi there"
        let long = try #require(model.editingFrame)
        #expect(long.width > short.width)
        #expect(long.height == short.height)
        model.finishText()
        #expect(model.document.annotations.last?.textWidth == nil)
    }

    @Test func narrowingTheBoxWrapsTheText() throws {
        let model = try makeModel()
        type("Wrap these words", at: CGPoint(x: 20, y: 20), in: model)
        model.finishText()
        let mark = try #require(model.selectedMark)
        let oneLine = mark.bounds
        let edge = mark.point(of: .right)
        #expect(mark.handle(at: edge, tolerance: 4) == .right)
        model.pointerDown(at: edge)
        let target = CGPoint(x: oneLine.minX + oneLine.width / 2, y: edge.y)
        model.pointerDragged(from: edge, to: target)
        model.pointerUp(from: edge, to: target)
        let narrow = try #require(model.selectedMark)
        #expect(abs((narrow.textWidth ?? 0) - oneLine.width / 2) < 0.01)
        #expect(abs(narrow.bounds.width - oneLine.width / 2) < 0.01)
        #expect(narrow.bounds.height > oneLine.height)
        #expect(narrow.start == mark.start)
    }

    @Test func draggingTheLeftEdgeKeepsTheRightEdge() throws {
        let model = try makeModel()
        type("Left edge", at: CGPoint(x: 60, y: 20), in: model)
        model.finishText()
        let mark = try #require(model.selectedMark)
        let resized = mark.resized(.left, to: CGPoint(x: mark.bounds.minX + 10, y: 0))
        #expect(resized.bounds.maxX == mark.bounds.maxX)
        #expect(resized.start.x == mark.start.x + 10)
    }

    @Test func draggingACornerScalesTheFont() throws {
        let model = try makeModel()
        type("Scale", at: CGPoint(x: 20, y: 20), in: model)
        model.finishText()
        let mark = try #require(model.selectedMark)
        let frame = mark.bounds
        let bigger = mark.resized(.end, to: CGPoint(x: frame.minX + frame.width * 2, y: frame.minY + frame.height * 2))
        #expect(abs(bigger.fontSize - mark.fontSize * 2) < 0.01)
        #expect(bigger.start == mark.start)
        let topLeft = mark.resized(.start, to: CGPoint(x: frame.maxX - frame.width / 2, y: frame.maxY - frame.height / 2))
        #expect(abs(topLeft.fontSize - mark.fontSize / 2) < 0.01)
        #expect(abs(topLeft.bounds.maxX - mark.bounds.maxX) <= 4)
    }

    @Test func textSizeAndColorChangeTheTextBeingTyped() throws {
        let model = try makeModel()
        type("Style", at: CGPoint(x: 20, y: 20), in: model)
        model.textSize = .extraLarge
        model.color = RGBA(red: 0, green: 0, blue: 1)
        #expect(model.textEdit?.fontSize == TextSize.extraLarge.rawValue)
        #expect(model.textEdit?.color == RGBA(red: 0, green: 0, blue: 1))
        model.finishText()
        let mark = try #require(model.document.annotations.last)
        #expect(mark.fontSize == TextSize.extraLarge.rawValue)
        #expect(mark.color == RGBA(red: 0, green: 0, blue: 1))
    }

    @Test func editingOldTextKeepsItsStyleAndSizeButtonsFollowIt() throws {
        let model = try makeModel()
        model.textSize = .large
        type("Old", at: CGPoint(x: 20, y: 20), in: model)
        model.finishText()
        model.textSize = .small
        let mark = try #require(model.selectedMark)
        #expect(mark.fontSize == TextSize.small.rawValue)
        click(model, at: CGPoint(x: mark.bounds.midX, y: mark.bounds.midY))
        #expect(model.textEdit?.fontSize == TextSize.small.rawValue)
        #expect(model.textSize == .small)
        #expect(model.showsTextStyle)
    }

    @Test func colorChangeKeepsAScaledFontSize() throws {
        let model = try makeModel()
        type("Keep", at: CGPoint(x: 20, y: 20), in: model)
        model.finishText()
        let mark = try #require(model.selectedMark)
        let corner = mark.point(of: .end)
        model.pointerDown(at: corner)
        let target = CGPoint(x: mark.bounds.minX + mark.bounds.width * 1.5, y: corner.y)
        model.pointerDragged(from: corner, to: target)
        model.pointerUp(from: corner, to: target)
        let scaled = try #require(model.selectedMark).fontSize
        model.color = RGBA(red: 0, green: 1, blue: 0)
        #expect(model.selectedMark?.fontSize == scaled)
        #expect(model.selectedMark?.color == RGBA(red: 0, green: 1, blue: 0))
    }

    @Test func shortTextCanStillBeClickedAndDragged() throws {
        let model = try makeModel()
        type("Hi", at: CGPoint(x: 100, y: 100), in: model)
        model.finishText()
        let mark = try #require(model.selectedMark)
        let middle = CGPoint(x: mark.bounds.midX, y: mark.bounds.midY)
        #expect(mark.handle(at: middle, tolerance: 10) == nil)
        click(model, at: middle)
        #expect(model.textEdit?.id == mark.id)
        model.finishText()
        let drop = CGPoint(x: middle.x + 50, y: middle.y + 30)
        model.pointerDown(at: middle)
        model.pointerDragged(from: middle, to: drop)
        model.pointerUp(from: middle, to: drop)
        let moved = try #require(model.document.annotations.first { $0.id == mark.id })
        #expect(moved.start == CGPoint(x: mark.start.x + 50, y: mark.start.y + 30))
        #expect(moved.fontSize == mark.fontSize)
    }

    @Test func draggingACornerInwardAlongOneSideShrinks() throws {
        let model = try makeModel()
        type("Shrink me", at: CGPoint(x: 20, y: 20), in: model)
        model.finishText()
        let mark = try #require(model.selectedMark)
        let corner = mark.point(of: .end)
        let smaller = mark.resized(.end, to: CGPoint(x: corner.x - mark.bounds.width / 2, y: corner.y))
        #expect(smaller.fontSize < mark.fontSize)
        #expect(smaller.start == mark.start)
    }

    @Test func textHandlesReachPastTheBoxEvenOnShortText() throws {
        let model = try makeModel()
        type("Hi", at: CGPoint(x: 100, y: 100), in: model)
        model.finishText()
        let mark = try #require(model.selectedMark)
        let right = mark.point(of: .right)
        #expect(mark.handle(at: CGPoint(x: right.x + 8, y: right.y), tolerance: 10) == .right)
        let corner = mark.point(of: .end)
        #expect(mark.handle(at: CGPoint(x: corner.x + 6, y: corner.y + 6), tolerance: 10) == .end)
        #expect(model.handlePointer(at: CGPoint(x: right.x + 8, y: right.y)) == .resize(.right))
        #expect(model.handleSpots.count == mark.handles.count)
    }

    @Test func oldMarkupWithoutAWrapWidthStillLoads() throws {
        let json = #"{"annotations":[{"id":"6F1C3A52-3C1B-4D8B-9E7A-2B1F0C9D8E7A","kind":"text","start":[10,10],"end":[10,10],"points":[],"color":{"red":1,"green":0,"blue":0,"alpha":1},"lineWidth":0,"text":"Hi","fontSize":20}],"nextCounter":1}"#
        let document = try JSONDecoder().decode(AnnotationDocument.self, from: Data(json.utf8))
        #expect(document.annotations.first?.textWidth == nil)
    }
}
