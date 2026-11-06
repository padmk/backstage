// Renders a window as lines of numbered elements, and reports what an action changed.

import AppKit
import ApplicationServices

let defaultMaxElements = 800
let treeDeadlineSeconds: TimeInterval = 10
private let maxDepth = 60
private let silentContainers: Set<String> = ["AXGroup", "AXSplitGroup", "AXLayoutArea", "AXUnknown"]

struct RenderedTree {
  var lines: [String]
  var partialReason: String?
  // What each numbered element was when this tree was rendered.
  var fingerprints: [Int: [String?]] = [:]
}

// FNV-1a over the UTF-8 bytes, the same in every run.
private func digest(_ text: String) -> String {
  var hash: UInt32 = 2_166_136_261
  for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
  return String(hash, radix: 16)
}

private func shortName(_ name: String) -> String {
  name.hasPrefix("AX") ? String(name.dropFirst(2)) : name
}

private func line(for element: AXUIElement, attributes: ElementAttributes, role: String, number: Int, depth: Int, actionNames: [String]) -> String {
  let subrole = attributes.string(kAXSubroleAttribute)
  let isSecure = subrole == "AXSecureTextField"
  var text = String(repeating: "  ", count: depth) + "\(number) \(shortName(role))"
  if let subrole, subrole != "AXUnknown", !isSecure { text += "(\(shortName(subrole)))" }
  if let label = attributes.string(kAXTitleAttribute) ?? attributes.string(kAXDescriptionAttribute) {
    text += " \"\(clamped(label))\""
    // A cut label says how long it is, as a cut value does, so the agent reads the rest with read_text.
    if isClamped(label) { text += " label_length=\(label.utf16.count)" }
  }
  if isSecure {
    text += " secure"
  } else {
    let raw = attributes.value(kAXValueAttribute)
    if let value = describeValue(raw) {
      text += " value=\"\(value)\""
      // A cut value says how long it is, so the agent knows to read the rest with read_text, and carries a digest
      // of all of it, so a change past the visible part still changes the line.
      if let full = raw as? String, isClamped(full) { text += " length=\(full.utf16.count) digest=\(digest(full))" }
    }
  }
  if let placeholder = attributes.string(kAXPlaceholderValueAttribute) { text += " placeholder=\"\(clamped(placeholder))\"" }
  if let identifier = attributes.string(kAXIdentifierAttribute) { text += " id=\"\(clamped(identifier))\"" }
  if attributes.bool(kAXEnabledAttribute) == false { text += " disabled" }
  if attributes.bool(kAXFocusedAttribute) == true { text += " focused" }
  if attributes.bool(kAXSelectedAttribute) == true { text += " selected" }
  if let expanded = attributes.bool(kAXExpandedAttribute) { text += expanded ? " expanded" : " collapsed" }
  // Only an element that has a value can take a new one, and asking the others would cost a round trip each.
  if attributes.value(kAXValueAttribute) != nil, isSettable(element, kAXValueAttribute) { text += " editable" }
  if !actionNames.isEmpty { text += " [\(actionNames.map(shortName).joined(separator: ","))]" }
  return text
}

func renderTree(roots: [AXUIElement], pid: pid_t, table: ElementTable, maxElements: Int, shownToAgent: Bool,
                seconds: TimeInterval = treeDeadlineSeconds) -> RenderedTree {
  var tree = RenderedTree(lines: [], partialReason: nil)
  let deadline = Date().addingTimeInterval(seconds)
  // An element that lists itself or an ancestor among its children, as apps do while the screen is locked, is
  // shown once.
  var visited = Set<AXUIElement>()

  func visit(_ element: AXUIElement, depth: Int) {
    guard tree.partialReason == nil else { return }
    guard visited.insert(element).inserted else { return }
    guard tree.lines.count < maxElements else {
      tree.partialReason = "limit of \(maxElements) elements; read a subtree with root"
      return
    }
    guard Date() < deadline else {
      tree.partialReason = "time limit; the app is slow or the tree is large"
      return
    }
    guard depth <= maxDepth else { return }

    let attributes = ElementAttributes(of: element)
    if attributes.appStoppedAnswering {
      tree.partialReason = "the app stopped answering"
      return
    }
    let kids = attributes.children
    let role = attributes.string(kAXRoleAttribute) ?? "AXUnknown"
    let actionNames = actions(of: element)

    // Containers that say nothing would only add noise.
    let says = attributes.string(kAXTitleAttribute) ?? attributes.string(kAXDescriptionAttribute)
    if silentContainers.contains(role), says == nil, actionNames.isEmpty, describeValue(attributes.value(kAXValueAttribute)) == nil {
      kids.forEach { visit($0, depth: depth) }
      return
    }

    let number = table.number(for: element, pid: pid, shownToAgent: shownToAgent, attributes: attributes)
    tree.fingerprints[number] = fingerprint(from: attributes)
    tree.lines.append(line(for: element, attributes: attributes, role: role, number: number, depth: depth, actionNames: actionNames))
    kids.forEach { visit($0, depth: depth + 1) }
  }

  roots.forEach { visit($0, depth: 0) }
  return tree
}

// MARK: Numbers that last

private struct NumberedLine {
  let depth: Int
  let number: Int
  let content: String
}

private func parse(_ line: String) -> NumberedLine? {
  let indent = line.prefix { $0 == " " }.count
  let rest = line.dropFirst(indent)
  guard let space = rest.firstIndex(of: " "), let number = Int(rest[..<space]) else { return nil }
  return NumberedLine(depth: indent / 2, number: number, content: String(rest[rest.index(after: space)...]))
}

// Each line's parent, as a line index, from the indentation.
private func parents(_ lines: [NumberedLine]) -> [Int?] {
  var stack: [(depth: Int, index: Int)] = []
  return lines.enumerated().map { index, line in
    while let top = stack.last, top.depth >= line.depth { stack.removeLast() }
    defer { stack.append((line.depth, index)) }
    return stack.last?.index
  }
}

// Some apps, such as System Settings, hand out new elements for unchanged ones on every read, so the elements an
// agent was shown got new numbers and the old ones went stale. A newly numbered element takes back the number of
// the one it replaces, when nothing else could be meant: it has an identifier, its line and its parent are the
// same as in the last complete read of the same place, no other line there or among its new siblings says the
// same, and the old element no longer answers. Anything less certain keeps its new number.
func carryNumbers(_ tree: inout RenderedTree, previous: [String], mintedFrom: Int, table: ElementTable, pid: pid_t) {
  guard tree.partialReason == nil else { return }
  let before = previous.compactMap(parse)
  let beforeParents = parents(before)
  var earlier: [String: [Int]] = [:]
  for (index, line) in before.enumerated() where line.content.contains(" id=\"") {
    let parent = beforeParents[index].map { before[$0].number } ?? 0
    earlier["\(parent)|\(line.content)", default: []].append(line.number)
  }
  var lines = tree.lines.compactMap(parse)
  guard lines.count == tree.lines.count else { return }
  let lineParents = parents(lines)
  var siblings: [String: Int] = [:]
  for (index, line) in lines.enumerated() { siblings["\(lineParents[index] ?? -1)|\(line.content)", default: 0] += 1 }
  var used = Set(lines.map(\.number))
  for index in lines.indices {
    let line = lines[index]
    guard line.number >= mintedFrom, line.content.contains(" id=\""), siblings["\(lineParents[index] ?? -1)|\(line.content)"] == 1 else { continue }
    let parent = lineParents[index].map { lines[$0].number } ?? 0
    guard let candidates = earlier["\(parent)|\(line.content)"], candidates.count == 1, let old = candidates.first,
      !used.contains(old), table.carryNumber(old, over: line.number, pid: pid) else { continue }
    used.insert(old)
    tree.fingerprints[old] = tree.fingerprints.removeValue(forKey: line.number)
    lines[index] = NumberedLine(depth: line.depth, number: old, content: line.content)
    tree.lines[index] = String(repeating: "  ", count: line.depth) + "\(old) \(line.content)"
  }
}

// Open context menus are children of the app rather than of a window.
func openMenus(of application: AXUIElement) -> [AXUIElement] {
  ((attribute(application, kAXChildrenAttribute) as? [AXUIElement]) ?? []).filter {
    stringAttribute($0, kAXRoleAttribute) == "AXMenu"
  }
}

func hasModal(_ window: AXUIElement) -> Bool {
  if boolAttribute(window, "AXModal") { return true }
  let kids = (attribute(window, kAXChildrenAttribute) as? [AXUIElement]) ?? []
  return kids.contains { stringAttribute($0, kAXRoleAttribute) == "AXSheet" }
}

// The last read of an app in a session: what was asked, what it showed, and the element it started from, so a
// later read of the same place can report only what changed.
struct LastRead {
  var request: JSON
  var root: AXUIElement?
  var lines: [String]
  var isPartial: Bool
  // The last report of a change listed only part of it, so the agent has not seen these lines in full.
  var reportedInPart = false

  private static let scopeKeys = ["window", "root", "menu_bar", "menu_extras", "max_elements"]

  // The same place: the same arguments and the same starting element, since window numbers follow window order.
  func covers(_ other: JSON, root otherRoot: AXUIElement?) -> Bool {
    let sameArguments = Self.scopeKeys.allSatisfy { key in
      switch (request[key], other[key]) {
      case (nil, nil): return true
      case let (first?, second?): return "\(first)" == "\(second)"
      default: return false
      }
    }
    guard sameArguments, let root, let otherRoot else { return false }
    return CFEqual(root, otherRoot)
  }
}

func changeReport(before: [String], after: [String]) -> JSON {
  let beforeSet = Set(before)
  let afterSet = Set(after)
  let added = after.filter { !beforeSet.contains($0) }
  let removed = before.filter { !afterSet.contains($0) }
  let limit = 40
  var report: JSON = [
    "changed": !(added.isEmpty && removed.isEmpty),
    "added": added.prefix(limit).map { $0.trimmingCharacters(in: .whitespaces) },
    "removed": removed.prefix(limit).map { $0.trimmingCharacters(in: .whitespaces) },
  ]
  if added.count > limit || removed.count > limit { report["more_changes"] = true }
  return report
}
