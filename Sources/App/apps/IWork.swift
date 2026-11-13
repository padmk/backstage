// Pages and Numbers through their scripting dictionaries. Both share how documents are found, opened, exported
// and closed; each adds what its documents hold.

import Foundation

// Where a document's file is: its path, '' for a document that has no file, or null when the app did not say, which
// reachableDocumentPath refuses.
let documentFile = #"""
  function fileOf(document) {
    let file;
    try { file = document.file(); } catch (error) { return null; }
    if (file === null || file === undefined) return '';
    try { return file.toString(); } catch (error) { return null; }
  }
  """#

private let prelude = #"""
  const App = Application(args.app_id);
  const fail = (code, text) => { throw new Error(code + ': ' + text); };
  // By name or id. The script then holds the document by its id, because Numbers renames a new document from its
  // content as soon as it changes.
  function documentNamed(query) {
    const byId = App.documents.byId(query);
    let found = true;
    try { byId.name(); } catch (error) { found = false; }
    if (found) return byId;
    const matches = App.documents.whose({ name: query });
    const count = matches.length;
    if (count === 0) fail('not_found', 'No open document is named ' + query + '. Use list_documents.');
    if (count > 1) fail('ambiguous', 'Several open documents are named ' + query + '. Give its id.');
    return App.documents.byId(matches[0].id());
  }
  \#(documentFile)
  // The document whose place the helper checked, by id, as long as it is still where the check found it.
  function checkedDocument() {
    const document = App.documents.byId(args.document_id);
    let found = true;
    try { document.name(); } catch (error) { found = false; }
    if (!found) fail('not_found', 'The document was closed meanwhile. Use list_documents.');
    if (fileOf(document) !== args.document_path) fail('action_failed', 'The document was saved elsewhere meanwhile, so nothing was done. Try again.');
    return document;
  }
  function describe(document) {
    return { id: document.id(), name: document.name(), path: fileOf(document), modified: document.modified() };
  }
  """#

// The app is the one runOperation chose, passed as app_id; the definition's own id is the fallback.
private func run(_ body: String, app: String, _ arguments: JSON, name: String, timeout: TimeInterval = 60) throws -> JSON {
  try dictionary(runScript(prelude + body, arguments: arguments.merging(["app_id": app]) { current, _ in current }, target: name, timeout: timeout), from: name)
}

// A document's file as the script read it, checked by the path rule in UserPaths.swift: its path, or "" for a
// document without a file. A document open from elsewhere, such as /tmp or Library, is refused, and so is one
// whose place the app did not give, since it could be anywhere.
func reachableDocumentPath(_ value: Any?, home: String = resolvedHome) throws -> String {
  guard let path = value as? String else {
    throw HelperError(code: "action_failed", message: "The app did not say where this document is saved, so operations do not touch it. Try again in a moment.")
  }
  guard path.isEmpty || reportablePath(path, home: home) != nil else {
    throw HelperError(code: "not_allowed", message: "This document is not in your home folder outside Library, in iCloud Drive or on an external volume, so operations cannot reach it.")
  }
  return path
}

// Finds the document by id or name and checks where it is saved, before a script that acts on it runs: that script
// gets the arguments plus the document's id and checked path, and reaches it through checkedDocument().
private func checkedDocumentArguments(_ arguments: JSON, app: String, name: String) throws -> JSON {
  let found = try run("const document = documentNamed(args.document); return { id: document.id(), path: fileOf(document) };",
                      app: app, ["document": try string(arguments, "document"), "app_id": arguments["app_id"] ?? app], name: name)
  guard let id = found["id"] as? String, !id.isEmpty else { throw HelperError(code: "action_failed", message: "\(name) gave no id for the document.") }
  return arguments.merging(["document_id": id, "document_path": try reachableDocumentPath(found["path"])]) { $1 }
}

private let documentArgument = Argument(name: "document", kind: .string, required: true, description: "Document id or name from list_documents")
private let pathArgument = Argument(name: "path", kind: .string, required: true, description: "Absolute path, or one starting with ~")

// The operations every iWork app has.
private func documentOperations(app: String, name: String) -> [Operation] {
  let list = Operation(name: "list_documents", summary: "List open documents with their files", effect: .reads, arguments: []) { arguments in
    var result = try run("return { documents: App.documents().map(describe) };", app: app, arguments, name: name)
    // A document from outside the reachable set is listed without its path, and so is one whose place the app did
    // not give.
    result["documents"] = (result["documents"] as? [JSON] ?? []).map { document in
      var entry = document
      guard let path = document["path"] as? String else {
        entry["path"] = ""
        entry["path_unknown"] = true
        return entry
      }
      if !path.isEmpty, reportablePath(path) == nil {
        entry["path"] = ""
        entry["outside_reach"] = true
      }
      return entry
    }
    return result
  }
  let open = Operation(name: "open", summary: "Open a file as a document, behind the app you are in", effect: .changes, arguments: [pathArgument]) { arguments in
    let url = try userPath(arguments, followingLink: true)
    var result = try run("changeBegins({ path: args.path }); return describe(App.open(Path(args.path)));", app: app, ["path": url.path, "app_id": arguments["app_id"] ?? app], name: name)
    // A file in another format, such as CSV or plain text, opens as a new document with no file of its own.
    guard let path = result["path"] as? String else {
      result["path"] = ""
      result["path_unknown"] = true
      result["verified"] = false
      return result
    }
    if path.isEmpty { result["imported"] = true }
    result["verified"] = path.isEmpty ? (result["id"] as? String)?.isEmpty == false : URL(fileURLWithPath: path).standardizedFileURL.path == url.path
    return result
  }
  let exportPDF = Operation(
    name: "export_pdf", summary: "Export a document as a PDF to a new file", effect: .changes,
    arguments: [documentArgument, Argument(name: "path", kind: .string, required: true, description: "Where to write the PDF, ending in .pdf; an existing file is not replaced")]
  ) { arguments in
    let url = try userPath(arguments, mustExist: false)
    guard url.pathExtension.lowercased() == "pdf" else { throw HelperError(code: "invalid_arguments", message: "path must end in .pdf.") }
    guard try !entryExists(url.path) else {
      throw HelperError(code: "not_allowed", message: "\(url.path) exists already; give a new path.")
    }
    // The app writes a hidden file next to the destination, which then takes the name only if nothing has it by
    // then, so a file that appeared meanwhile is never replaced.
    // A short name of its own, so a long destination name still fits the file system's limit.
    let staging = url.deletingLastPathComponent().appendingPathComponent(".export-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: staging) }
    let document = try checkedDocumentArguments(arguments, app: app, name: name)
    do {
      _ = try run("const document = checkedDocument(); changeBegins({ document: args.document_id, path: args.path }); App.export(document, { to: Path(args.path), as: 'PDF' }); return {};",
                  app: app, document.merging(["path": staging.path]) { $1 }, name: name, timeout: 120)
    } catch {
      // The app may still finish an export the script gave up on, so the hidden file is removed again later.
      for minutes in [2.0, 10.0] {
        DispatchQueue.global().asyncAfter(deadline: .now() + minutes * 60) { try? FileManager.default.removeItem(at: staging) }
      }
      throw error
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? Int) ?? 0
    guard size > 0 else { throw HelperError(code: "action_failed", message: "\(name) wrote no PDF.") }
    guard renamex_np(staging.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
      if errno == EEXIST { throw HelperError(code: "not_allowed", message: "\(url.path) appeared while exporting, so it was left as it is; give a new path.") }
      throw HelperError(code: "action_failed", message: "The PDF could not be moved to \(url.path): \(String(cString: strerror(errno))).")
    }
    return ["path": url.path, "bytes": size, "verified": true]
  }
  let close = Operation(
    name: "close", summary: "Close a document, saving it first or discarding unsaved changes", effect: .changes,
    arguments: [documentArgument, Argument(name: "save", kind: .boolean, required: true, description: "true saves to its file first; false discards unsaved changes")]
  ) { arguments in
    try run(#"""
      const document = checkedDocument();
      // Saving a document that has no file would open a save dialog.
      if (args.save && args.document_path === '') fail('not_allowed', 'This document has no file yet, so it cannot be saved here. Export it, or close it without saving.');
      const closed = describe(document);
      changeBegins({ document: closed.id, name: closed.name });
      document.close({ saving: args.save ? 'yes' : 'no' });
      let open = true;
      try { App.documents.byId(closed.id).name(); } catch (error) { open = false; }
      closed.verified = !open;
      return closed;
      """#, app: app, try checkedDocumentArguments(arguments, app: app, name: name), name: name)
  }
  return [list, open, exportPDF, close]
}

// MARK: Pages

// Pages Creator Studio, the current version; the earlier Pages has its own id and the same scripting.
private let pagesId = "com.apple.Pages"
private let earlierPagesId = "com.apple.iWork.Pages"

private let readText = Operation(name: "read_text", summary: "Read a document's body text", effect: .reads, arguments: [documentArgument]) { arguments in
  try run(#"""
    const document = checkedDocument();
    const text = document.bodyText() || '';
    const result = describe(document);
    result.text = text.slice(0, 100000);
    if (text.length > 100000) result.text_truncated = true;
    return result;
    """#, app: pagesId, try checkedDocumentArguments(arguments, app: pagesId, name: "Pages"), name: "Pages")
}

let pagesKnowledge = AppKnowledge(
  bundleId: pagesId, otherBundleIds: [earlierPagesId], name: "Pages", scripted: true, summary: "Open, read, export as PDF and close documents",
  access: "Open, read, export and close your Pages documents",
  pitfalls: [
    "Pages starts if it is not running, to answer an operation.",
    "close with save: false discards unsaved changes.",
  ],
  operations: documentOperations(app: pagesId, name: "Pages") + [readText])

// MARK: Numbers

// Numbers Creator Studio, the current version; the earlier Numbers has its own id and the same scripting.
private let numbersId = "com.apple.Numbers"
private let earlierNumbersId = "com.apple.iWork.Numbers"

private let tableArguments = [
  documentArgument,
  Argument(name: "sheet", kind: .string, required: false, description: "Sheet name; default the first"),
  Argument(name: "table", kind: .string, required: false, description: "Table name; default the first in the sheet"),
]

private let findTable = #"""
  function tableIn(document) {
    const sheet = args.sheet ? document.sheets.byName(args.sheet) : document.sheets[0];
    try { sheet.name(); } catch (error) { fail('not_found', 'There is no sheet ' + (args.sheet || '') + '.'); }
    const table = args.table ? sheet.tables.byName(args.table) : sheet.tables[0];
    try { table.name(); } catch (error) { fail('not_found', 'There is no table ' + (args.table || '') + ' in ' + sheet.name() + '.'); }
    return { sheet: sheet, table: table };
  }
  """#

private let readTable = Operation(
  name: "read_table", summary: "Read a table's cells as shown, row by row, with the document's sheets and tables", effect: .reads,
  arguments: tableArguments + [
    Argument(name: "rows", kind: .integer, required: false, description: "Most rows to read; default 50", minimum: 1, maximum: 500),
    Argument(name: "first_row", kind: .integer, required: false, description: "Row to start at, counting from 1; default 1", minimum: 1),
  ]
) { arguments in
  var given = arguments
  given["rows"] = arguments["rows"] as? Int ?? 50
  given["first_row"] = arguments["first_row"] as? Int ?? 1
  return try run(findTable + #"""
    const document = checkedDocument();
    const { sheet, table } = tableIn(document);
    const rowCount = table.rowCount();
    const first = args.first_row - 1;
    const rows = table.rows().slice(first, first + args.rows).map((row) => row.cells.formattedValue().map((value) => value === null ? '' : value));
    return { document: describe(document), sheets: document.sheets().map((item) => ({ name: item.name(), tables: item.tables.name() })),
      sheet: sheet.name(), table: table.name(), row_count: rowCount, column_count: table.columnCount(), first_row: args.first_row, rows: rows,
      has_more: rowCount > first + rows.length };
    """#, app: numbersId, try checkedDocumentArguments(given, app: numbersId, name: "Numbers"), name: "Numbers")
}

private let setCell = Operation(
  name: "set_cell", summary: "Set one cell's value, as if typed: numbers and dates are recognized", effect: .changes,
  arguments: tableArguments + [
    Argument(name: "cell", kind: .string, required: true, description: "Cell address such as B2"),
    Argument(name: "value", kind: .string, required: true, description: "The value; empty clears the cell"),
  ]
) { arguments in
  let cell = try string(arguments, "cell").uppercased()
  guard cell.range(of: #"^[A-Z]{1,3}[1-9][0-9]{0,5}$"#, options: .regularExpression) != nil else {
    throw HelperError(code: "invalid_arguments", message: "cell must be an address such as B2.")
  }
  return try run(findTable + #"""
    const document = checkedDocument();
    const { sheet, table } = tableIn(document);
    const cell = table.cells.byName(args.cell);
    try { cell.name(); } catch (error) { fail('not_found', 'The table has no cell ' + args.cell + '.'); }
    changeBegins({ document: args.document_id, sheet: sheet.name(), table: table.name(), cell: args.cell });
    cell.value = args.value;
    const shown = cell.formattedValue();
    const stored = cell.value();
    const result = { document: describe(document), sheet: sheet.name(), table: table.name(), cell: args.cell, shown: shown === null ? '' : shown };
    result.verified = args.value === '' ? stored === null : (String(stored) === args.value || result.shown === args.value || (stored !== null && Number(args.value) === stored));
    return result;
    """#, app: numbersId, try checkedDocumentArguments(arguments.merging(["cell": cell]) { $1 }, app: numbersId, name: "Numbers"), name: "Numbers")
}

private let maxCells = 500

// The cells set_cells writes: addresses in capitals, each value as the text typed into it.
func cellValues(_ values: String) throws -> [String: String] {
  guard let data = values.data(using: .utf8),
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !object.isEmpty
  else { throw HelperError(code: "invalid_arguments", message: "values must be a JSON object of cell address to value.") }
  guard object.count <= maxCells else { throw HelperError(code: "invalid_arguments", message: "values may hold at most \(maxCells) cells.") }
  var cells: [String: String] = [:]
  for (address, value) in object {
    let cell = address.uppercased()
    guard cells[cell] == nil else { throw HelperError(code: "invalid_arguments", message: "\(cell) is given more than once.") }
    guard cell.range(of: #"^[A-Z]{1,3}[1-9][0-9]{0,5}$"#, options: .regularExpression) != nil else {
      throw HelperError(code: "invalid_arguments", message: "\(address) is not a cell address such as B2.")
    }
    // JSON true and false arrive as numbers too, and would be written as 1 and 0.
    let number = (value as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.stringValue }
    guard let text = value as? String ?? number else {
      throw HelperError(code: "invalid_arguments", message: "The value for \(address) must be text or a number.")
    }
    cells[cell] = text
  }
  return cells
}

// Several cells in one script, checked before any is written, so a bad address changes nothing.
private let setCells = Operation(
  name: "set_cells", summary: "Set several cells at once, as if typed, and report each one", effect: .changes,
  arguments: tableArguments + [
    Argument(name: "values", kind: .string, required: true, description: "A JSON object of cell address to value, such as {\"B2\": \"10\", \"C2\": \"done\"}; at most 500 cells, empty clears"),
  ]
) { arguments in
  var given = arguments
  given["values"] = try cellValues(try string(arguments, "values"))
  return try run(findTable + #"""
    const document = checkedDocument();
    const { sheet, table } = tableIn(document);
    const addresses = Object.keys(args.values).sort();
    const targets = addresses.map((address) => {
      const cell = table.cells.byName(address);
      try { cell.name(); } catch (error) { fail('not_found', 'The table has no cell ' + address + '. Nothing was changed.'); }
      return cell;
    });
    // Once a cell is written, a failure leaves the earlier ones changed, so each write first says which cells are
    // set and which one is being written.
    const results = [];
    const where = { document: args.document_id, sheet: sheet.name(), table: table.name() };
    for (let index = 0; index < addresses.length; index++) {
      const address = addresses[index];
      const value = args.values[address];
      changeBegins(Object.assign({ writing: address, set: results.map((item) => item.cell) }, where));
      targets[index].value = value;
      const shown = targets[index].formattedValue();
      const stored = targets[index].value();
      const verified = value === '' ? stored === null : (String(stored) === value || shown === value || (stored !== null && Number(value) === stored));
      results.push({ cell: address, shown: shown === null ? '' : shown, verified: verified });
    }
    return { document: describe(document), sheet: sheet.name(), table: table.name(), cells: results, verified: results.every((item) => item.verified) };
    """#, app: numbersId, try checkedDocumentArguments(given, app: numbersId, name: "Numbers"), name: "Numbers", timeout: 120)
}

let numbersKnowledge = AppKnowledge(
  bundleId: numbersId, otherBundleIds: [earlierNumbersId], name: "Numbers", scripted: true, summary: "Open, read tables, set cells, export as PDF and close documents",
  access: "Open, read, change, export and close your Numbers documents",
  pitfalls: [
    "Numbers starts if it is not running, to answer an operation.",
    "A new or imported document is named from its content and saved to iCloud Drive once it changes, so its name changes; refer to it by id.",
    "set_cell does not save a document that has a file; close with save: true does.",
    "close with save: false discards unsaved changes.",
  ],
  operations: documentOperations(app: numbersId, name: "Numbers") + [readTable, setCell, setCells])
