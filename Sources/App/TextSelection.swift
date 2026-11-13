// Reading and selecting text by what it says, so an agent can read a long value in full and replace or insert at
// an exact place with type_text instead of rewriting the whole value. Accessibility counts text in UTF-16 units.

import AppKit
import ApplicationServices

// Where text occurs between prefix and suffix, as UTF-16 ranges of the text alone. The search compares UTF-16 units
// as given, so an accent written as its own character never lands inside another one.
private func occurrences(of text: String, in value: String, prefix: String, suffix: String) -> [NSRange] {
  let haystack = value as NSString
  let needle = prefix + text + suffix
  var found: [NSRange] = []
  var from = 0
  while from < haystack.length {
    let match = haystack.range(of: needle, options: .literal, range: NSRange(location: from, length: haystack.length - from))
    guard match.location != NSNotFound else { break }
    found.append(NSRange(location: match.location + (prefix as NSString).length, length: (text as NSString).length))
    from = match.location + 1
  }
  return found
}

private func selectedRange(of element: AXUIElement) -> CFRange? {
  guard let value = axValue(attribute(element, kAXSelectedTextRangeAttribute)) else { return nil }
  var range = CFRange()
  return AXValueGetValue(value, .cfRange, &range) ? range : nil
}

func selectText(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  let element = try session.table.element(integer(params, "element"), pid: app.pid)
  let text = try nonEmptyString(params, "text")
  let prefix = params["prefix"] as? String ?? ""
  let suffix = params["suffix"] as? String ?? ""
  let place = params["place"] as? String ?? "select"
  guard ["select", "before", "after"].contains(place) else {
    throw HelperError(code: "invalid_request", message: "place must be select, before or after.")
  }
  guard stringAttribute(element, kAXSubroleAttribute) != "AXSecureTextField" else {
    throw HelperError(code: "invalid_request", message: "Text in a secure field cannot be selected.")
  }
  // A one-line field has a selection only while it has the app's focus. Focusing it inside the app does not bring
  // the app forward.
  if !isSettable(element, kAXSelectedTextRangeAttribute), isSettable(element, kAXFocusedAttribute) {
    try setAXAttribute(element, kAXFocusedAttribute, kCFBooleanTrue)
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
  let start = match.location
  let length = match.length
  var range: CFRange
  switch place {
  case "before": range = CFRange(location: start, length: 0)
  case "after": range = CFRange(location: start + length, length: 0)
  default: range = CFRange(location: start, length: length)
  }
  guard let rangeValue = AXValueCreate(.cfRange, &range) else {
    throw HelperError(code: "action_failed", message: "Could not describe the range.")
  }
  let outcome = try setAXAttribute(element, kAXSelectedTextRangeAttribute, rangeValue)
  guard outcome == .success else { throw axFailure(outcome, "selecting the text") }
  // Typing into a selection the app did not take would change the wrong text, so an unconfirmed one stops here.
  guard let now = selectedRange(of: element), now.location == range.location, now.length == range.length else {
    throw HelperError(code: "action_failed", message: "The app did not confirm the selection, so nothing should be typed into it. Read the state and try again.")
  }
  return ["delivery": "accessibility", "verified": true, "selection": ["start": range.location, "length": range.length] as JSON]
}

// The whole text of an element, or a part of it, where the tree shows only its start. Offsets count UTF-16 units,
// as select_text reports them.
private let maxReadLength = 50_000

func readText(app: AppIdentity, params: JSON, session: ApprovalSession) throws -> JSON {
  let element = try session.table.element(integer(params, "element"), pid: app.pid)
  guard stringAttribute(element, kAXSubroleAttribute) != "AXSecureTextField" else {
    throw HelperError(code: "invalid_request", message: "A secure field's value is never shown.")
  }
  // An element without a text value, such as a message bubble that carries its text as the label, gives its label,
  // the one the tree shows.
  let value: String
  var source = "value"
  if let text = stringAttribute(element, kAXValueAttribute) {
    value = text
  } else if let label = stringAttribute(element, kAXTitleAttribute) ?? stringAttribute(element, kAXDescriptionAttribute) {
    value = label
    source = "label"
  } else if textAttribute(element, kAXValueAttribute) != nil {
    value = ""
  } else {
    throw HelperError(code: "no_text", message: "This element has no text value and no label.")
  }
  let units = Array(value.utf16)
  let requested = min(max(params["start"] as? Int ?? 0, 0), units.count)
  let length = min(max(params["length"] as? Int ?? maxReadLength, 0), maxReadLength, units.count - requested)
  // A cut inside a surrogate pair would not decode: the start moves back and the end forward to whole characters.
  var start = requested
  if start > 0, start < units.count, UTF16.isTrailSurrogate(units[start]) { start -= 1 }
  var end = min(requested + length, units.count)
  if end < units.count, end > 0, UTF16.isTrailSurrogate(units[end]) { end += 1 }
  let text = String(decoding: units[start..<end], as: UTF16.self)
  var result: JSON = ["text": text, "start": start, "length": end - start, "total": units.count, "source": source]
  if end < units.count { result["more"] = true }
  return result
}
