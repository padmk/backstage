// Reading and selecting text by what it says, so an agent can read a long value in full and replace or insert at
// an exact place with type_text instead of rewriting the whole value. Accessibility counts text in UTF-16 units.

import ApplicationServices

private func occurrences(of text: String, in value: String, prefix: String, suffix: String) -> [Range<String.Index>] {
  var found: [Range<String.Index>] = []
  var searchStart = value.startIndex
  let needle = prefix + text + suffix
  while let match = value.range(of: needle, range: searchStart..<value.endIndex) {
    let start = value.index(match.lowerBound, offsetBy: prefix.count)
    found.append(start..<value.index(start, offsetBy: text.count))
    searchStart = value.index(after: match.lowerBound)
  }
  return found
}

private func selectedRange(of element: AXUIElement) -> CFRange? {
  guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
  var range = CFRange()
  return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
}

func selectText(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  let element = try session.table.element(integer(params, "element"), pid: app.pid)
  let text = try string(params, "text")
  let prefix = params["prefix"] as? String ?? ""
  let suffix = params["suffix"] as? String ?? ""
  let place = params["place"] as? String ?? "select"
  guard !text.isEmpty else { throw HelperError(code: "invalid_request", message: "text is empty.") }
  guard ["select", "before", "after"].contains(place) else {
    throw HelperError(code: "invalid_request", message: "place must be select, before or after.")
  }
  guard stringAttribute(element, kAXSubroleAttribute) != "AXSecureTextField" else {
    throw HelperError(code: "invalid_request", message: "Text in a secure field cannot be selected.")
  }
  // A one-line field has a selection only while it has the app's focus. Focusing it inside the app does not bring
  // the app forward.
  if !isSettable(element, kAXSelectedTextRangeAttribute), isSettable(element, kAXFocusedAttribute) {
    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    sleep(seconds: 0.05)
  }
  guard let value = textAttribute(element, kAXValueAttribute), isSettable(element, kAXSelectedTextRangeAttribute) else {
    throw HelperError(code: "not_settable", message: "This element has no text selection that can be set.")
  }
  let matches = occurrences(of: text, in: value, prefix: prefix, suffix: suffix)
  guard let match = matches.first else {
    throw HelperError(code: "text_not_found", message: "The element's text does not contain that text\(prefix.isEmpty && suffix.isEmpty ? "" : " with that prefix and suffix").")
  }
  guard matches.count == 1 else {
    throw HelperError(code: "ambiguous_text", message: "The text occurs \(matches.count) times. Add prefix or suffix text around it so it occurs once.")
  }
  let start = value.utf16.distance(from: value.utf16.startIndex, to: match.lowerBound.samePosition(in: value.utf16) ?? value.utf16.startIndex)
  let length = text.utf16.count
  var range: CFRange
  switch place {
  case "before": range = CFRange(location: start, length: 0)
  case "after": range = CFRange(location: start + length, length: 0)
  default: range = CFRange(location: start, length: length)
  }
  guard let rangeValue = AXValueCreate(.cfRange, &range) else {
    throw HelperError(code: "action_failed", message: "Could not describe the range.")
  }
  let outcome = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
  guard outcome == .success else { throw axFailure(outcome, "selecting the text") }
  let now = selectedRange(of: element)
  let verified = now.map { $0.location == range.location && $0.length == range.length } ?? false
  return ["delivery": "accessibility", "verified": verified, "selection": ["start": range.location, "length": range.length] as JSON]
}

// The whole text of an element, or a part of it, where the tree shows only its start. Offsets count UTF-16 units,
// as select_text reports them.
private let maxReadLength = 50_000

func readText(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  let element = try session.table.element(integer(params, "element"), pid: app.pid)
  guard stringAttribute(element, kAXSubroleAttribute) != "AXSecureTextField" else {
    throw HelperError(code: "invalid_request", message: "A secure field's value is never shown.")
  }
  guard let value = textAttribute(element, kAXValueAttribute) else {
    throw HelperError(code: "no_text", message: "This element has no text value. Its label is in the tree.")
  }
  let units = Array(value.utf16)
  let start = min(max(params["start"] as? Int ?? 0, 0), units.count)
  let length = min(max(params["length"] as? Int ?? maxReadLength, 0), maxReadLength, units.count - start)
  // A cut inside a character pair would not decode, so the end moves back to a whole character.
  var end = start + length
  while end > start, end < units.count, UTF16.isTrailSurrogate(units[end]) { end -= 1 }
  let text = String(decoding: units[start..<end], as: UTF16.self)
  var result: JSON = ["text": text, "start": start, "length": end - start, "total": units.count]
  if end < units.count { result["more"] = true }
  return result
}
