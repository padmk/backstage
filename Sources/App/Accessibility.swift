// Reading the macOS Accessibility API, and the numbers that let agents refer to elements.

import AppKit
import ApplicationServices
import Synchronization

let maxTextLength = 300

// Whether macOS trusts this app with Accessibility, showing its prompt when it does not. The key is the value of
// kAXTrustedCheckOptionPrompt, a C global variable that strict concurrency checking does not let Swift read.
func isTrustedAskingForAccessibility() -> Bool {
  AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
  var value: AnyObject?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

// An attribute's value as the app answered: a value, nothing (the element lacks the attribute or it has no value),
// or no answer the caller can trust. Checks that refuse what they cannot see tell the last two apart. Observed on
// macOS 27.2 in Finder, Signal and Brave: elements without children answer kAXChildren with an empty list or, also
// in a batched read, noValue (-25212); an application element answers kAXParent with noValue or
// attributeUnsupported (-25205). Both are absent here, so ordinary trees and menus read in full.
enum AttributeRead {
  case value(AnyObject)
  case absent
  case unreadable(AXError)

  init(_ result: AXError, _ value: AnyObject?) {
    switch result {
    case .success: self = value.map(AttributeRead.value) ?? .absent
    case .noValue, .attributeUnsupported: self = .absent
    default: self = .unreadable(result)
    }
  }
}

func readAttribute(_ element: AXUIElement, _ name: String) -> AttributeRead {
  var value: AnyObject?
  let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
  return AttributeRead(result, value)
}

// A Core Foundation value as its type, or nil when it is of another. Swift cannot check a cast to a Core Foundation
// type, so the type ids are compared first; this is the one place that casts to one.
func cfCast<T: AnyObject>(_ value: AnyObject?, to type: T.Type, typeID: CFTypeID) -> T? {
  guard let value, CFGetTypeID(value) == typeID else { return nil }
  return (value as! T) // swiftlint:disable:this force_cast
}

// An attribute that holds an element, such as a window or a parent.
func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
  cfCast(attribute(element, name), to: AXUIElement.self, typeID: AXUIElementGetTypeID())
}

func axValue(_ value: AnyObject?) -> AXValue? { cfCast(value, to: AXValue.self, typeID: AXValueGetTypeID()) }

func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
  guard let text = attribute(element, name) as? String, !text.isEmpty else { return nil }
  return text
}

// Unlike stringAttribute, this tells an empty text from no text.
func textAttribute(_ element: AXUIElement, _ name: String) -> String? {
  attribute(element, name) as? String
}

func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool {
  (attribute(element, name) as? Bool) ?? false
}

func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
  var settable = DarwinBoolean(false)
  return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
}

// Raising a window would bring it over the user's work, so agents neither see that action nor can run it.
private let unavailableActions: Set<String> = ["AXShowDefaultUI", "AXShowAlternateUI", kAXRaiseAction]

func actions(of element: AXUIElement) -> [String] {
  var names: CFArray?
  guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
  return ((names as? [String]) ?? []).filter { !unavailableActions.contains($0) }
}

func frame(of element: AXUIElement) -> CGRect? {
  guard let positionValue = attribute(element, kAXPositionAttribute),
    let sizeValue = attribute(element, kAXSizeAttribute)
  else { return nil }
  var position = CGPoint.zero
  var size = CGSize.zero
  guard let positionValue = axValue(positionValue), let sizeValue = axValue(sizeValue),
    AXValueGetValue(positionValue, .cgPoint, &position),
    AXValueGetValue(sizeValue, .cgSize, &size)
  else { return nil }
  return CGRect(origin: position, size: size)
}

private func flattened(_ text: String) -> String {
  text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\"", with: "\\\"")
}

func clamped(_ text: String) -> String {
  let flat = flattened(text)
  return flat.count > maxTextLength ? String(flat.prefix(maxTextLength)) + "…" : flat
}

func isClamped(_ text: String) -> Bool { flattened(text).count > maxTextLength }

func describeValue(_ value: AnyObject?) -> String? {
  switch value {
  case let text as String: return text.isEmpty ? nil : clamped(text)
  case let number as NSNumber: return number.stringValue
  default: return nil
  }
}

func axFailure(_ result: AXError, _ doing: String) -> HelperError {
  switch result {
  case .invalidUIElement:
    return HelperError(code: "stale_element", message: "The element is gone. Read the window state again.")
  case .apiDisabled:
    return HelperError(code: "permission_missing", message: "Accessibility is not granted to Backstage. Ask the user to open Backstage and allow it on the Setup tab.")
  case .cannotComplete:
    return HelperError(code: "outcome_unknown", message: "The app did not answer while \(doing). The action may have worked, for example if it opened a dialog. Read the state before trying again.")
  default:
    return HelperError(code: "action_failed", message: "\(doing) failed (AX error \(result.rawValue)).")
  }
}

// Where a press reply carries the error the app answered with although the press may have worked.
let appErrorKey = "app_error"

// The reply to a press. Apps built with SwiftUI answer a press that opens or closes a sheet with a plain failure
// although it took effect, so that failure is reported with the press and the change report settles it: `acting`
// turns it into action_failed when nothing changed, and run_actions stops at it.
func pressReply(_ result: AXError, _ doing: String, _ reply: JSON) throws -> JSON {
  if result == .success { return reply }
  guard result == .failure else { throw axFailure(result, doing) }
  var reply = reply
  reply["verified"] = false
  reply[appErrorKey] = "The app reported an error while \(doing) (AX error \(result.rawValue)). Some apps, such as those built with SwiftUI, report one for a press that worked."
  return reply
}

func requireAccessibility() throws {
  guard AXIsProcessTrusted() else {
    throw HelperError(code: "permission_missing", message: "Accessibility is not granted to Backstage. Ask the user to open Backstage and allow it on the Setup tab.")
  }
}

// While the screen is locked the app answers with itself in place of each window, which is no window.
func windows(of application: AXUIElement) -> [AXUIElement] {
  ((attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []).filter { !CFEqual($0, application) }
}

// Electron builds its accessibility tree only when asked to, and asynchronously.
private let preparedProcesses = Mutex(Set<pid_t>())

func prepareAccessibility(of application: AXUIElement, pid: pid_t) {
  let isNew = preparedProcesses.withLock { $0.insert(pid).inserted }
  guard isNew else { return }
  // Not through the effect gate: it only lets the app be read, and reads precede every effect.
  let outcome = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
  guard outcome == .success else { return }
  let deadline = Date().addingTimeInterval(2)
  while windows(of: application).isEmpty, Date() < deadline { sleep(seconds: 0.1) }
  sleep(seconds: 0.2)
}

private let maxRememberedElements = 20000
private let rolesIdentifiedByValue: Set<String> = [kAXStaticTextRole, kAXCellRole, kAXRowRole]

// The attributes a tree line and a fingerprint need, asked for in one call: each separate call is a round trip
// to the app, and an app such as Notes answers slowly.
private let lineAttributeNames = [
  kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
  kAXPlaceholderValueAttribute, kAXIdentifierAttribute, kAXEnabledAttribute, kAXFocusedAttribute,
  kAXSelectedAttribute, kAXExpandedAttribute, kAXChildrenAttribute,
]

struct ElementAttributes {
  private var values: [String: AnyObject] = [:]
  // The app did not answer, so the element's children are unknown.
  private(set) var appStoppedAnswering = false
  // The app answered the element's children with an error other than having none, so they are unknown.
  private(set) var childrenUnreadable = false

  init(of element: AXUIElement) {
    var answer: CFArray?
    let outcome = AXUIElementCopyMultipleAttributeValues(element, lineAttributeNames as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &answer)
    if outcome == .cannotComplete {
      appStoppedAnswering = true
      return
    }
    guard outcome == .success, let list = answer as? [AnyObject], list.count == lineAttributeNames.count else {
      // Some elements refuse a batch; asking one by one still works for them.
      for name in lineAttributeNames {
        switch readAttribute(element, name) {
        case .value(let value): values[name] = value
        case .absent: break
        case .unreadable: if name == kAXChildrenAttribute { childrenUnreadable = true }
        }
      }
      return
    }
    for (name, value) in zip(lineAttributeNames, list) {
      // An attribute the element lacks comes back as an error value, and so does one the app could not give.
      if let errorValue = axValue(value), AXValueGetType(errorValue) == .axError {
        var error = AXError.success
        _ = AXValueGetValue(errorValue, .axError, &error)
        if name == kAXChildrenAttribute, case .unreadable = AttributeRead(error, nil) { childrenUnreadable = true }
        continue
      }
      values[name] = value
    }
  }

  // Attributes as given, for the tests of what reads them.
  init(values: [String: AnyObject], childrenUnreadable: Bool = false) {
    self.values = values
    self.childrenUnreadable = childrenUnreadable
  }

  func value(_ name: String) -> AnyObject? { values[name] }
  func string(_ name: String) -> String? {
    guard let text = values[name] as? String, !text.isEmpty else { return nil }
    return text
  }
  func bool(_ name: String) -> Bool? { values[name] as? Bool }
  var children: [AXUIElement] { (values[kAXChildrenAttribute] as? [AXUIElement]) ?? [] }
}

// What an element is, without its value. A list may reuse an element for another row, and a number must not
// silently come to mean something else than what the agent read.
func fingerprint(of element: AXUIElement) -> [String?] {
  fingerprint(from: ElementAttributes(of: element))
}

func fingerprint(from attributes: ElementAttributes) -> [String?] {
  let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute]
  var parts = names.map { attributes.string($0) }
  // These show their content only as a value, which counts in full, so a change past what the tree shows counts too.
  if rolesIdentifiedByValue.contains(parts[0] ?? "") {
    switch attributes.value(kAXValueAttribute) {
    case let text as String where !text.isEmpty: parts.append("\(text.utf16.count):\(text.hashValue)")
    case let number as NSNumber: parts.append(number.stringValue)
    default: parts.append(nil)
    }
  }
  return parts
}

// Numbers stay the same for the same element across reads, so an agent can compare states. They belong
// to one session and one app, so a number cannot reach another app.
final class ElementTable {
  private struct Entry {
    let pid: pid_t
    let element: AXUIElement
    var fingerprint: [String?]
    // When a read last met the element, so eviction keeps the ones still in use, such as a window's frame.
    var seenAt: Int
  }

  private let lock = NSLock()
  private var numbersByHash: [CFHashCode: [(element: AXUIElement, number: Int)]] = [:]
  private var entries: [Int: Entry] = [:]
  private var nextNumber = 1
  // Where the session's range ends; nil for a command that gives none, which numbers without end.
  private var limit: Int?
  private var reads = 0

  // The number the next new element gets, so a read can tell the numbers it gave out.
  var nextFreeNumber: Int { lock.withLock { nextNumber } }

  // Gives an element the number another one had, for an app that handed out a new element for an unchanged one.
  // Only when the old element no longer answers, and keeping what the agent was shown of it, so an element whose
  // content changed is still refused as stale.
  func carryNumber(_ old: Int, over new: Int, pid: pid_t) -> Bool {
    lock.withLock {
      // The whole of what the element is must match, not only its line, which can hide part of a label.
      guard old != new, let previous = entries[old], let current = entries[new], previous.pid == pid, current.pid == pid,
        previous.fingerprint == current.fingerprint else { return false }
      var role: CFTypeRef?
      guard AXUIElementCopyAttributeValue(previous.element, kAXRoleAttribute as CFString, &role) == .invalidUIElement else { return false }
      entries[new] = nil
      entries[old] = Entry(pid: pid, element: current.element, fingerprint: previous.fingerprint, seenAt: current.seenAt)
      for (hash, number) in [(CFHash(previous.element), old), (CFHash(current.element), new)] {
        numbersByHash[hash]?.removeAll { $0.number == number }
        if numbersByHash[hash]?.isEmpty == true { numbersByHash[hash] = nil }
      }
      numbersByHash[CFHash(current.element), default: []].append((current.element, old))
      return true
    }
  }

  // The range a connection numbers from, which the command picked above every range this session used before, so
  // numbers go on from its start at the lowest and stop at its end. Numbers already given keep their meaning.
  func startNumbering(at first: Int, limit end: Int?) {
    lock.withLock {
      if first > nextNumber { nextNumber = first }
      if let end, end > first { limit = end }
    }
  }

  // What an element is counts from what the agent saw, so a read it did not see never updates that. Nil once the
  // session's range is used up, since a number past its end may belong to another connection's range.
  func number(for element: AXUIElement, pid: pid_t, shownToAgent: Bool, attributes: ElementAttributes? = nil) -> Int? {
    let seen = attributes.map(fingerprint(from:)) ?? fingerprint(of: element)
    let hash = CFHash(element)
    return lock.withLock {
      reads += 1
      if let known = numbersByHash[hash]?.first(where: { CFEqual($0.element, element) }) {
        if shownToAgent { entries[known.number]?.fingerprint = seen }
        entries[known.number]?.seenAt = reads
        return known.number
      }
      if let limit, nextNumber >= limit { return nil }
      if entries.count >= maxRememberedElements { forgetOldest() }
      let number = nextNumber
      nextNumber += 1
      numbersByHash[hash, default: []].append((element, number))
      entries[number] = Entry(pid: pid, element: element, fingerprint: seen, seenAt: reads)
      return number
    }
  }

  // Keeps the half met most recently, not the newest numbers: apps that hand out new elements for unchanged ones
  // mint numbers on every read, which would otherwise push out the window and its lasting parts.
  private func forgetOldest() {
    let kept = entries.sorted { $0.value.seenAt < $1.value.seenAt }.suffix(maxRememberedElements / 2).map(\.key)
    entries = Dictionary(uniqueKeysWithValues: kept.map { ($0, entries[$0]!) })
    numbersByHash = [:]
    for (number, entry) in entries {
      numbersByHash[CFHash(entry.element), default: []].append((entry.element, number))
    }
  }

  // Forgets the numbers from `first` on that this app's elements got and `kept` does not hold. Only for numbers no
  // agent was shown: a forgotten number is never given out again, and its element gets a new one when met again.
  func forget(numbersFrom first: Int, pid: pid_t, keeping kept: Set<Int>) {
    lock.withLock {
      let gone = entries.filter { $0.key >= first && $0.value.pid == pid && !kept.contains($0.key) }
      for (number, entry) in gone {
        entries[number] = nil
        let hash = CFHash(entry.element)
        numbersByHash[hash]?.removeAll { $0.number == number }
        if numbersByHash[hash]?.isEmpty == true { numbersByHash[hash] = nil }
      }
    }
  }

  // Elements a change report showed the agent, as that report's read saw them, so acting on them right after is not
  // refused as stale, while an element that changed again since then still is.
  func acknowledge(_ seen: [Int: [String?]]) {
    lock.withLock {
      for (number, fingerprint) in seen { entries[number]?.fingerprint = fingerprint }
    }
  }

  func element(_ number: Int, pid: pid_t) throws -> AXUIElement {
    guard let entry = lock.withLock({ entries[number] }), entry.pid == pid else {
      throw HelperError(code: "unknown_element", message: "Element \(number) does not belong to this app in this session. Read the window state.")
    }
    guard fingerprint(of: entry.element) == entry.fingerprint else {
      throw HelperError(code: "stale_element", message: "Element \(number) is no longer what was read. Read the window state again.")
    }
    return entry.element
  }
}
