// Text recognition on screenshots, run on images drawn in memory with known text at known places, so no window is
// captured and no permission is needed.

import AppKit
import CoreText
import Foundation
import Testing

@testable import App

private struct DrawnLine {
  let text: String
  // Top left of the line's box, in points from the image's top left.
  let origin: CGPoint
}

private let imageSize = CGSize(width: 900, height: 420)

// Dark text on a light background; returns the image and each line's box from the top left.
private func drawnImage(_ lines: [DrawnLine]) throws -> (CGImage, [CGRect]) {
  let context = try #require(CGContext(data: nil, width: Int(imageSize.width), height: Int(imageSize.height), bitsPerComponent: 8,
                                       bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1))
  context.fill(CGRect(origin: .zero, size: imageSize))
  let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 48, nil)
  var boxes: [CGRect] = []
  for line in lines {
    let attributed = NSAttributedString(string: line.text, attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1),
    ])
    let typeset = CTLineCreateWithAttributedString(attributed)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(typeset, &ascent, &descent, nil))
    // Core Graphics counts from the bottom left and draws at the baseline.
    context.textPosition = CGPoint(x: line.origin.x, y: imageSize.height - line.origin.y - ascent)
    CTLineDraw(typeset, context)
    boxes.append(CGRect(x: line.origin.x, y: line.origin.y, width: width, height: ascent + descent))
  }
  return (try #require(context.makeImage()), boxes)
}

@Suite struct TextRecognitionTests {
  @Test func findsDrawnLinesWhereTheyWereDrawnTopToBottom() async throws {
    // Listed out of order, so the reply's order comes from the recognition, not from drawing.
    let lines = [
      DrawnLine(text: "Invoice total 4721", origin: CGPoint(x: 60, y: 300)),
      DrawnLine(text: "Quarterly report", origin: CGPoint(x: 60, y: 40)),
      DrawnLine(text: "Shipping address", origin: CGPoint(x: 220, y: 170)),
    ]
    let (image, boxes) = try drawnImage(lines)
    let found = try await recognizeText(in: image)

    #expect(found.map(\.text) == ["Quarterly report", "Shipping address", "Invoice total 4721"])
    let expected = [boxes[1], boxes[2], boxes[0]]
    for (line, box) in zip(found, expected) {
      #expect(line.confidence > 0 && line.confidence <= 1, "\(line.text): \(line.confidence)")
      // Vision's box hugs the glyphs, the drawn box spans ascent and descent: a few points apart.
      let tolerance: CGFloat = 16
      #expect(abs(line.frame.minX - box.minX) < tolerance, "\(line.text): \(line.frame) vs \(box)")
      #expect(abs(line.frame.midY - box.midY) < tolerance, "\(line.text): \(line.frame) vs \(box)")
      #expect(abs(line.frame.width - box.width) < 2 * tolerance, "\(line.text): \(line.frame) vs \(box)")
      #expect(line.frame.height > 20 && line.frame.height < 80, "\(line.text): \(line.frame)")
    }
  }

  @Test func ordersOneRowLeftToRight() async throws {
    let (image, _) = try drawnImage([
      DrawnLine(text: "Cancel", origin: CGPoint(x: 560, y: 180)),
      DrawnLine(text: "Save", origin: CGPoint(x: 80, y: 184)),
    ])
    #expect(try await recognizeText(in: image).map(\.text) == ["Save", "Cancel"])
  }

  @Test func findsNothingInAnEmptyImage() async throws {
    let (image, _) = try drawnImage([])
    #expect(try await recognizeText(in: image).isEmpty)
  }

  @Test func givesFramesAsWholePointsAndConfidenceToTwoPlaces() {
    let line = RecognizedLine(text: "Done", confidence: 0.876, frame: CGRect(x: 10.4, y: 20.6, width: 99.5, height: 30.2))
    #expect(line.json["text"] as? String == "Done")
    #expect(line.json["confidence"] as? Double == 0.88)
    #expect(line.json["frame"] as? [Int] == [10, 21, 100, 30])
  }
}
