// Captures one window, at one image pixel per window point so its coordinates work with click_at, and with
// recognizeText also the text in the image.

import AppKit
import ApplicationServices
import ScreenCaptureKit

private let captureTimeoutSeconds = 15
private let maxFrameDifference: CGFloat = 24

func captureWindow(pid: pid_t, window: AXUIElement, recognizeText: Bool = false) throws -> JSON {
  try requirePermission(.screenRecording, for: "A screenshot")
  guard let target = frame(of: window) else {
    throw HelperError(code: "action_failed", message: "The window has no position.")
  }
  let title = stringAttribute(window, kAXTitleAttribute)
  let done = DispatchSemaphore(value: 0)
  var outcome: Result<(JSON, CGImage), Error> = .failure(HelperError(code: "action_failed", message: "No screenshot."))

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
      outcome = .success((["png_base64": data.base64EncodedString(), "width": image.width, "height": image.height, "title": match.title ?? ""], image))
    } catch {
      outcome = .failure(error)
    }
    done.signal()
  }
  guard done.wait(timeout: .now() + .seconds(captureTimeoutSeconds)) == .success else {
    throw HelperError(code: "timeout", message: "The capture did not finish in time.")
  }
  let (reply, image) = try outcome.get()
  return recognizeText ? addingRecognizedText(to: reply, image: image) : reply
}
