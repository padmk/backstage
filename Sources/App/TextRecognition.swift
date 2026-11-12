// Text recognized in a screenshot, on this Mac with Vision, for views that show no elements. It only describes the
// image: nothing clicks by it, and a recognized change does not prove that an action worked.

import CoreGraphics
import Foundation
import Vision

private let maxRecognizedLines = 200
// A warm recognition takes a fraction of a second; the first one after a boot or an update loads Vision's models,
// which took about 15 seconds when measured.
private let recognitionTimeoutSeconds: TimeInterval = 30
// Left of the request's deadline for encoding and sending the reply.
private let recognitionReserveSeconds: TimeInterval = 1
private let minRecognitionSeconds: TimeInterval = 0.5

struct RecognizedLine: Equatable {
  let text: String
  let confidence: Double
  // In image pixels from the top left, which are window points in a screenshot.
  let frame: CGRect

  var json: JSON {
    ["text": text, "confidence": (confidence * 100).rounded() / 100,
     "frame": [Int(frame.minX.rounded()), Int(frame.minY.rounded()), Int(frame.width.rounded()), Int(frame.height.rounded())]]
  }
}

// The lines in the image, top to bottom and left to right within a row, without empty ones.
func recognizeText(in image: CGImage) async throws -> [RecognizedLine] {
  var request = RecognizeTextRequest()
  request.recognitionLevel = .accurate
  request.automaticallyDetectsLanguage = true
  let size = CGSize(width: image.width, height: image.height)
  let observations = try await request.perform(on: image)
  let lines = observations.compactMap { observation -> RecognizedLine? in
    guard let best = observation.topCandidates(1).first else { return nil }
    let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
      .map { $0.toImageCoordinates(size, origin: .upperLeft) }
    let xs = corners.map(\.x)
    let ys = corners.map(\.y)
    let frame = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    return RecognizedLine(text: text, confidence: Double(min(max(best.confidence, 0), 1)), frame: frame)
  }
  return readingOrder(lines)
}

// Lines whose middles lie within half a line's height of a row's first line share that row.
func readingOrder(_ lines: [RecognizedLine]) -> [RecognizedLine] {
  var rows: [[RecognizedLine]] = []
  for line in lines.sorted(by: { $0.frame.midY < $1.frame.midY }) {
    if let first = rows.last?.first, line.frame.midY - first.frame.midY < min(first.frame.height, line.frame.height) / 2 {
      rows[rows.count - 1].append(line)
    } else {
      rows.append([line])
    }
  }
  return rows.flatMap { $0.sorted { $0.frame.minX < $1.frame.minX } }
}

// Adds the recognized lines to a screenshot reply. Recognition runs off the request's thread and within its
// deadline; when it fails or runs out of time, the image still comes back, with text_error.
func addingRecognizedText(to reply: JSON, image: CGImage) -> JSON {
  var reply = reply
  let timeLeft = currentConnection()?.deadline.map { $0.timeIntervalSinceNow - recognitionReserveSeconds }
  let limit = min(recognitionTimeoutSeconds, timeLeft ?? recognitionTimeoutSeconds)
  guard limit >= minRecognitionSeconds else {
    reply["text_error"] = "timeout: No time was left to recognize text."
    return reply
  }
  let done = DispatchSemaphore(value: 0)
  let outcome = RecognitionOutcome()
  let task = Task.detached {
    do {
      outcome.set(.success(try await recognizeText(in: image)))
    } catch {
      outcome.set(.failure(error))
    }
    done.signal()
  }
  // A cancelled request stops waiting at once, so it does not hold the app's lock while recognition runs on.
  let stopWatching = currentConnection()?.onCancel {
    outcome.set(.failure(HelperError(code: "cancelled", message: "The request was cancelled.")))
    task.cancel()
    done.signal()
  }
  defer { stopWatching?() }
  guard done.wait(timeout: .now() + limit) == .success else {
    task.cancel()
    reply["text_error"] = "timeout: Text recognition did not finish in time."
    return reply
  }
  switch outcome.get() {
  case .success(let lines):
    reply["text"] = lines.prefix(maxRecognizedLines).map(\.json)
    if lines.count > maxRecognizedLines { reply["text_truncated"] = true }
  case .failure(let error as HelperError):
    reply["text_error"] = "\(error.code): \(error.message)"
  case .failure(let error):
    reply["text_error"] = "action_failed: Text recognition failed: \(error.localizedDescription)"
  case nil:
    reply["text_error"] = "action_failed: Text recognition gave no result."
  }
  return reply
}

private final class RecognitionOutcome: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<[RecognizedLine], Error>?

  func set(_ result: Result<[RecognizedLine], Error>) { lock.withLock { value = result } }
  func get() -> Result<[RecognizedLine], Error>? { lock.withLock { value } }
}
