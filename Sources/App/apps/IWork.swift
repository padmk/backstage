// Pages and Numbers through their scripting dictionaries. Both share how documents are found, opened, exported
// and closed; each adds what its documents hold.

import Foundation

private let prelude = #"""
  const App = Application(args.app_id);
  const fail = (code, text) => { throw new Error(code + ': ' + text); };
  // By name or id. The script then holds the document by its id, because Numbers renames a new document from its
  // content as soon as it changes.
  function documentNamed(query) {
    const byId = App.documents.byId(query);
    try { byId.name(); return byId; } catch (error) {}
    const matches = App.documents.whose({ name: query });
    const count = matches.length;
    if (count === 0) fail('not_found', 'No open document is named ' + query + '. Use list_documents.');
    if (count > 1) fail('ambiguous', 'Several open documents are named ' + query + '. Give its id.');
    return App.documents.byId(matches[0].id());
  }
  function describe(document) {
    let path = '';
    try { path = document.file().toString(); } catch (error) {}
    return { id: document.id(), name: document.name(), path: path, modified: document.modified() };
  }
  """#

// The app is the one runOperation chose, passed as app_id; the definition's own id is the fallback.
private func run(_ body: String, app: String, _ arguments: JSON, name: String, timeout: TimeInterval = 60) throws -> JSON {
  try dictionary(runScript(prelude + body, arguments: arguments.merging(["app_id": app]) { current, _ in current }, target: name, timeout: timeout), from: name)
}

private let documentArgument = Argument(name: "document", kind: .string, required: true, description: "Document id or name from list_documents")
private let pathArgument = Argument(name: "path", kind: .string, required: true, description: "Absolute path, or one starting with ~")

// The operations every iWork app has.
private func documentOperations(app: String, name: String) -> [Operation] {
  let list = Operation(name: "list_documents", summary: "List open documents with their files", effect: .reads, arguments: []) { arguments in
    try run("return { documents: App.documents().map(describe) };", app: app, arguments, name: name)
  }
  let open = Operation(name: "open", summary: "Open a file as a document, behind the app you are in", effect: .changes, arguments: [pathArgument]) { arguments in
    let url = try userPath(arguments)
    var result = try run("return describe(App.open(Path(args.path)));", app: app, ["path": url.path, "app_id": arguments["app_id"] ?? app], name: name)
    // A file in another format, such as CSV or plain text, opens as a new document with no file of its own.
    let path = result["path"] as? String ?? ""
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
    guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else {
      throw HelperError(code: "not_allowed", message: "\(url.path) exists already; give a new path.")
    }
    _ = try run("App.export(documentNamed(args.document), { to: Path(args.path), as: 'PDF' }); return {};",
                app: app, ["document": try string(arguments, "document"), "path": url.path, "app_id": arguments["app_id"] ?? app], name: name, timeout: 120)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    return ["path": url.path, "bytes": size, "verified": size > 0]
  }
  let close = Operation(
    name: "close", summary: "Close a document, saving it first or discarding unsaved changes", effect: .changes,
    arguments: [documentArgument, Argument(name: "save", kind: .boolean, required: true, description: "true saves to its file first; false discards unsaved changes")]
  ) { arguments in
    try run(#"""
      const document = documentNamed(args.document);
      // Saving a document that has no file would open a save dialog.
      if (args.save && describe(document).path === '') fail('not_allowed', 'This document has no file yet, so it cannot be saved here. Export it, or close it without saving.');
      const closed = describe(document);
      document.close({ saving: args.save ? 'yes' : 'no' });
      let open = true;
      try { App.documents.byId(closed.id).name(); } catch (error) { open = false; }
      closed.verified = !open;
      return closed;
      """#, app: app, arguments, name: name)
  }
  return [list, open, exportPDF, close]
}

// MARK: Pages

// Pages Creator Studio, the current version; the earlier Pages has its own id and the same scripting.
private let pagesId = "com.apple.Pages"
private let earlierPagesId = "com.apple.iWork.Pages"

private let readText = Operation(name: "read_text", summary: "Read a document's body text", effect: .reads, arguments: [documentArgument]) { arguments in
  try run(#"""
    const document = documentNamed(args.document);
    const text = document.bodyText() || '';
    const result = describe(document);
    result.text = text.slice(0, 100000);
    if (text.length > 100000) result.text_truncated = true;
    return result;
    """#, app: pagesId, arguments, name: "Pages")
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
  arguments: tableArguments + [Argument(name: "rows", kind: .integer, required: false, description: "Most rows to read; default 50", minimum: 1, maximum: 500)]
) { arguments in
  var given = arguments
  given["rows"] = arguments["rows"] as? Int ?? 50
  return try run(findTable + #"""
    const document = documentNamed(args.document);
    const { sheet, table } = tableIn(document);
    const rowCount = table.rowCount();
    const rows = table.rows().slice(0, args.rows).map((row) => row.cells.formattedValue().map((value) => value === null ? '' : value));
    return { document: describe(document), sheets: document.sheets().map((item) => ({ name: item.name(), tables: item.tables.name() })),
      sheet: sheet.name(), table: table.name(), row_count: rowCount, column_count: table.columnCount(), rows: rows, rows_truncated: rowCount > rows.length };
    """#, app: numbersId, given, name: "Numbers")
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
    const document = documentNamed(args.document);
    const { sheet, table } = tableIn(document);
    const cell = table.cells.byName(args.cell);
    try { cell.name(); } catch (error) { fail('not_found', 'The table has no cell ' + args.cell + '.'); }
    cell.value = args.value;
    const shown = cell.formattedValue();
    const stored = cell.value();
    const result = { document: describe(document), sheet: sheet.name(), table: table.name(), cell: args.cell, shown: shown === null ? '' : shown };
    result.verified = args.value === '' ? stored === null : (String(stored) === args.value || result.shown === args.value || (stored !== null && Number(args.value) === stored));
    return result;
    """#, app: numbersId, arguments.merging(["cell": cell]) { $1 }, name: "Numbers")
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
  operations: documentOperations(app: numbersId, name: "Numbers") + [readTable, setCell])
