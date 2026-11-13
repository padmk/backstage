// Captures one window, at one image pixel per window point so its coordinates work with click_at, and with
// recognizeText also the text in the image.

import AppKit
import ApplicationServices
import ScreenCaptureKit

private let captureTimeoutSeconds = 15

private struct CapturedWindow: Sendable {
  let png: Data
  let image: CGImage
  let title: String
}
private let maxFrameDifference: CGFloat = 24

func captureWindow(pid: pid_t, window: AXUIElement, recognizeText: Bool = false) throws -> JSON {
  try requirePermission(.screenRecording, for: "A screenshot")
  guard let target = frame(of: window) else {
    throw HelperError(code: "action_failed", message: "The window has no position.")
  }
  let title = stringAttribute(window, kAXTitleAttribute)
  let outcome = AsyncOutcome<CapturedWindow>()
  Task.detached {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
      let difference = { (candidate: SCWindow) -> CGFloat in
        abs(candidate.frame.minX - target.minX) + abs(candidate.frame.minY - target.minY)
          + abs(candidate.frame.width - target.width) + abs(candidate.frame.height - target.height)
      }
      let matches = content.windows
        .filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && difference($0) <= maxFrameDifference }
      // Windows at the same place are told apart by title; an unresolved tie must not show the wrong one.
      // Hidden windows of the same size (such as Chromium's) are dropped next.
      let exact = matches.filter { $0.title == title }
      let onScreen = matches.filter(\.isOnScreen)
      let picked = exact.count == 1 ? exact[0]
        : matches.count == 1 ? matches[0]
        : onScreen.count == 1 ? onScreen[0] : nil
      guard let match = picked else {
        throw HelperError(code: "window_not_found", message: "The window could not be matched for capture (\(matches.count) candidates).")
      }
      let configuration = SCStreamConfiguration()
      configuration.width = Int(match.frame.width)
      configuration.height = Int(match.frame.height)
      configuration.showsCursor = false
      let filter = SCContentFilter(desktopIndependentWindow: match)
      let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
      guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw HelperError(code: "action_failed", message: "The image could not be encoded.")
      }
      outcome.set(.success(CapturedWindow(png: data, image: image, title: match.title ?? "")))
    } catch {
      outcome.set(.failure(error))
    }
  }
  guard let result = outcome.wait(until: .now() + .seconds(captureTimeoutSeconds)) else {
    throw HelperError(code: "timeout", message: "The capture did not finish in time.")
  }
  let captured = try result.get()
  let image = captured.image
  let reply: JSON = ["png_base64": captured.png.base64EncodedString(), "width": image.width, "height": image.height, "title": captured.title]
  return recognizeText ? addingRecognizedText(to: reply, image: image) : reply
}
