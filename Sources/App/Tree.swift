// Renders a window as lines of numbered elements, and reports what an action changed.

import AppKit
import ApplicationServices

let defaultMaxElements = 800
let treeDeadlineSeconds: TimeInterval = 10
private let maxDepth = 60
private let silentContainers: Set<String> = ["AXGroup", "AXSplitGroup", "AXLayoutArea", "AXUnknown"]

let usedUpNumbers = "this session has given out every element number of its range; start a new session"

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

// A label or value as a line shows it. A cut one says how long it is, so the agent reads the rest with read_text,
// and carries a digest of all of it, so a change past the visible part still changes the line.
func quoted(_ text: String, lengthKey: String) -> String {
  let shown = "\"\(clamped(text))\""
  return isClamped(text) ? shown + " \(lengthKey)=\(text.utf16.count) digest=\(digest(text))" : shown
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
    text += " " + quoted(label, lengthKey: "label_length")
  }
  if isSecure {
    text += " secure"
  } else {
    let raw = attributes.value(kAXValueAttribute)
    if let full = raw as? String, !full.isEmpty {
      text += " value=" + quoted(full, lengthKey: "length")
    } else if let value = describeValue(raw) {
      text += " value=\"\(value)\""
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

// `attributesOf` reads an element; the tests pass a stand-in.
func renderTree(roots: [AXUIElement], pid: pid_t, table: ElementTable, maxElements: Int, shownToAgent: Bool,
                seconds: TimeInterval = treeDeadlineSeconds,
                attributesOf: (AXUIElement) -> ElementAttributes = ElementAttributes.init(of:)) -> RenderedTree {
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
    // Every limit marks the tree partial, so a text that is missing below it does not pass for gone.
    guard depth <= maxDepth else {
      tree.partialReason = "depth limit of \(maxDepth) levels; read a deeper subtree with root"
      return
    }

    let attributes = attributesOf(element)
    if attributes.appStoppedAnswering {
      tree.partialReason = "the app stopped answering"
      return
    }
    let kids = attributes.children
    let role = attributes.string(kAXRoleAttribute) ?? "AXUnknown"
    let actionNames = actions(of: element)

    // Containers that say nothing would only add noise.
    let says = attributes.string(kAXTitleAttribute) ?? attributes.string(kAXDescriptionAttribute)
    let unreadKids = "the app did not give an element's children"
    if silentContainers.contains(role), says == nil, actionNames.isEmpty, describeValue(attributes.value(kAXValueAttribute)) == nil {
      if attributes.childrenUnreadable {
        tree.partialReason = unreadKids
        return
      }
      kids.forEach { visit($0, depth: depth) }
      return
    }

    guard let number = table.number(for: element, pid: pid, shownToAgent: shownToAgent, attributes: attributes) else {
      tree.partialReason = usedUpNumbers
      return
    }
    tree.fingerprints[number] = fingerprint(from: attributes)
    tree.lines.append(line(for: element, attributes: attributes, role: role, number: number, depth: depth, actionNames: actionNames))
    if attributes.childrenUnreadable {
      tree.partialReason = unreadKids
      return
    }
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

// The lines without their element numbers, in order.
func content(of lines: [String]) -> [String] {
  lines.map { line in
    guard let parsed = parse(line) else { return line }
    return String(repeating: "  ", count: parsed.depth) + parsed.content
  }
}

// The element number a line starts with.
func number(ofLine line: String) -> Int? { parse(line)?.number }

// What changed between two reads, by what the lines say. Apps such as System Settings hand out new elements for
// unchanged ones, which gives them new numbers; such a line is no change, and comes back under `renumbered` with the
// number to use now.
func changeReport(before: [String], after: [String]) -> JSON {
  let beforeSet = Set(before)
  let afterSet = Set(after)
  let beforeContent = content(of: before)
  let afterContent = content(of: after)
  // What the lines that did not stay exactly the same say, counted on each side.
  var beforeLeft: [String: Int] = [:]
  var afterLeft: [String: Int] = [:]
  for (line, text) in zip(before, beforeContent) where !afterSet.contains(line) { beforeLeft[text, default: 0] += 1 }
  for (line, text) in zip(after, afterContent) where !beforeSet.contains(line) { afterLeft[text, default: 0] += 1 }
  var added: [String] = []
  var renumbered: [String] = []
  for (line, text) in zip(after, afterContent) where !beforeSet.contains(line) {
    if let left = beforeLeft[text], left > 0 {
      beforeLeft[text] = left - 1
      renumbered.append(line)
    } else {
      added.append(line)
    }
  }
  var removed: [String] = []
  for (line, text) in zip(before, beforeContent) where !afterSet.contains(line) {
    if let left = afterLeft[text], left > 0 {
      afterLeft[text] = left - 1
    } else {
      removed.append(line)
    }
  }
  let limit = 40
  let trimmed = { (lines: [String]) in lines.prefix(limit).map { $0.trimmingCharacters(in: .whitespaces) } }
  var report: JSON = ["changed": !(added.isEmpty && removed.isEmpty), "added": trimmed(added), "removed": trimmed(removed)]
  if added.count > limit || removed.count > limit { report["more_changes"] = true }
  if !renumbered.isEmpty { report["renumbered"] = trimmed(renumbered) }
  if renumbered.count > limit { report["more_renumbered"] = true }
  return report
}
