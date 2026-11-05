// Reading the macOS Accessibility API, and the numbers that let agents refer to elements.

import AppKit
import ApplicationServices

let maxTextLength = 300

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
  var value: AnyObject?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

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
    let sizeValue = attribute(element, kAXSizeAttribute),
    CFGetTypeID(positionValue) == AXValueGetTypeID(),
    CFGetTypeID(sizeValue) == AXValueGetTypeID()
  else { return nil }
  var position = CGPoint.zero
  var size = CGSize.zero
  guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
  else { return nil }
  return CGRect(origin: position, size: size)
}

func clamped(_ text: String) -> String {
  let flat = text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\"", with: "\\\"")
  return flat.count > maxTextLength ? String(flat.prefix(maxTextLength)) + "…" : flat
}

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
    return HelperError(code: "permission_missing", message: "Accessibility is not granted to Backstage. Ask the user to open Backstage and allow it on the Permissions tab.")
  case .cannotComplete:
    return HelperError(code: "outcome_unknown", message: "The app did not answer while \(doing). The action may have worked, for example if it opened a dialog. Read the state before trying again.")
  default:
    return HelperError(code: "action_failed", message: "\(doing) failed (AX error \(result.rawValue)).")
  }
}

func requireAccessibility() throws {
  guard AXIsProcessTrusted() else {
    throw HelperError(code: "permission_missing", message: "Accessibility is not granted to Backstage. Ask the user to open Backstage and allow it on the Permissions tab.")
  }
}

func windows(of application: AXUIElement) -> [AXUIElement] {
  (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

// Electron builds its accessibility tree only when asked to, and asynchronously.
private var preparedProcesses = Set<pid_t>()
private let preparedLock = NSLock()

func prepareAccessibility(of application: AXUIElement, pid: pid_t) {
  let isNew = preparedLock.withLock { preparedProcesses.insert(pid).inserted }
  guard isNew else { return }
  let outcome = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
  guard outcome == .success else { return }
  let deadline = Date().addingTimeInterval(2)
  while windows(of: application).isEmpty, Date() < deadline { sleep(seconds: 0.1) }
  sleep(seconds: 0.2)
}

private let maxRememberedElements = 20000
private let rolesIdentifiedByValue: Set<String> = [kAXStaticTextRole, kAXCellRole, kAXRowRole]

// What an element is, without its value. A list may reuse an element for another row, and a number must not
// silently come to mean something else than what the agent read.
private func fingerprint(of element: AXUIElement) -> [String?] {
  let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute]
  var parts = names.map { stringAttribute(element, $0) }
  // These show their content only as a value.
  if rolesIdentifiedByValue.contains(parts[0] ?? "") { parts.append(describeValue(attribute(element, kAXValueAttribute))) }
  return parts
}

// Numbers stay the same for the same element across reads, so an agent can compare states. They belong
// to one session and one app, so a number cannot reach another app.
final class ElementTable {
  private struct Entry {
    let pid: pid_t
    let element: AXUIElement
    var fingerprint: [String?]
  }

  private let lock = NSLock()
  private var numbersByHash: [CFHashCode: [(element: AXUIElement, number: Int)]] = [:]
  private var entries: [Int: Entry] = [:]
  private var nextNumber = 1

  // What an element is counts from what the agent saw, so a read it did not see never updates that.
  func number(for element: AXUIElement, pid: pid_t, shownToAgent: Bool) -> Int {
    let seen = fingerprint(of: element)
    let hash = CFHash(element)
    return lock.withLock {
      if let known = numbersByHash[hash]?.first(where: { CFEqual($0.element, element) }) {
        if shownToAgent { entries[known.number]?.fingerprint = seen }
        return known.number
      }
      if entries.count >= maxRememberedElements { forgetOldest() }
      let number = nextNumber
      nextNumber += 1
      numbersByHash[hash, default: []].append((element, number))
      entries[number] = Entry(pid: pid, element: element, fingerprint: seen)
      return number
    }
  }

  private func forgetOldest() {
    let kept = entries.keys.sorted().suffix(maxRememberedElements / 2)
    entries = Dictionary(uniqueKeysWithValues: kept.map { ($0, entries[$0]!) })
    numbersByHash = [:]
    for (number, entry) in entries {
      numbersByHash[CFHash(entry.element), default: []].append((entry.element, number))
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
