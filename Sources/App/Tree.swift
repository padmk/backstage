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
}

private func shortName(_ name: String) -> String {
  name.hasPrefix("AX") ? String(name.dropFirst(2)) : name
}

private func line(for element: AXUIElement, role: String, number: Int, depth: Int, actionNames: [String]) -> String {
  let subrole = stringAttribute(element, kAXSubroleAttribute)
  let isSecure = subrole == "AXSecureTextField"
  var text = String(repeating: "  ", count: depth) + "\(number) \(shortName(role))"
  if let subrole, subrole != "AXUnknown", !isSecure { text += "(\(shortName(subrole)))" }
  if let label = stringAttribute(element, kAXTitleAttribute) ?? stringAttribute(element, kAXDescriptionAttribute) {
    text += " \"\(clamped(label))\""
  }
  if isSecure {
    text += " secure"
  } else if let value = describeValue(attribute(element, kAXValueAttribute)) {
    text += " value=\"\(value)\""
  }
  if let placeholder = stringAttribute(element, kAXPlaceholderValueAttribute) { text += " placeholder=\"\(clamped(placeholder))\"" }
  if let identifier = stringAttribute(element, kAXIdentifierAttribute) { text += " id=\"\(clamped(identifier))\"" }
  if attribute(element, kAXEnabledAttribute) as? Bool == false { text += " disabled" }
  if boolAttribute(element, kAXFocusedAttribute) { text += " focused" }
  if boolAttribute(element, kAXSelectedAttribute) { text += " selected" }
  if let expanded = attribute(element, kAXExpandedAttribute) as? Bool { text += expanded ? " expanded" : " collapsed" }
  if isSettable(element, kAXValueAttribute) { text += " editable" }
  if !actionNames.isEmpty { text += " [\(actionNames.map(shortName).joined(separator: ","))]" }
  return text
}

func renderTree(roots: [AXUIElement], pid: pid_t, table: ElementTable, maxElements: Int, shownToAgent: Bool) -> RenderedTree {
  var tree = RenderedTree(lines: [], partialReason: nil)
  let deadline = Date().addingTimeInterval(treeDeadlineSeconds)

  func visit(_ element: AXUIElement, depth: Int) {
    guard tree.partialReason == nil else { return }
    guard tree.lines.count < maxElements else {
      tree.partialReason = "limit of \(maxElements) elements; read a subtree with root"
      return
    }
    guard Date() < deadline else {
      tree.partialReason = "time limit; the app is slow or the tree is large"
      return
    }
    guard depth <= maxDepth else { return }

    var childrenValue: AnyObject?
    let childrenResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
    if childrenResult == .cannotComplete {
      tree.partialReason = "the app stopped answering"
      return
    }
    let kids = (childrenValue as? [AXUIElement]) ?? []
    let role = stringAttribute(element, kAXRoleAttribute) ?? "AXUnknown"
    let actionNames = actions(of: element)

    // Containers that say nothing would only add noise.
    let says = stringAttribute(element, kAXTitleAttribute) ?? stringAttribute(element, kAXDescriptionAttribute)
    if silentContainers.contains(role), says == nil, actionNames.isEmpty, describeValue(attribute(element, kAXValueAttribute)) == nil {
      kids.forEach { visit($0, depth: depth) }
      return
    }

    let number = table.number(for: element, pid: pid, shownToAgent: shownToAgent)
    tree.lines.append(line(for: element, role: role, number: number, depth: depth, actionNames: actionNames))
    kids.forEach { visit($0, depth: depth + 1) }
  }

  roots.forEach { visit($0, depth: 0) }
  return tree
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

// Compares the last read of an app with its state after an action, waiting briefly for the change.
struct LastRead {
  var request: JSON
  var lines: [String]
  var isPartial: Bool
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
