import Foundation
import SQLite3

/// Minimal wrapper over libsqlite3
///
/// Statements are cached by their SQL text and finalised in deinit. The same
/// dozen run on every copy, and preparing one costs more than stepping it
final class Database {
  enum Failure: Error {
    case open(String)
    case statement(String)
  }

  enum Value {
    case text(String)
    case int(Int)
    case double(Double)
    case null
  }

  private var handle: OpaquePointer?
  private var prepared: [String: OpaquePointer] = [:]

  init(path: String) throws {
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
      throw Failure.open(String(cString: sqlite3_errmsg(handle)))
    }
    self.handle = handle
    sqlite3_busy_timeout(handle, 3000)
  }

  deinit {
    for statement in prepared.values { sqlite3_finalize(statement) }
    sqlite3_close_v2(handle)
  }

  /// sqlite3_exec, for DDL and PRAGMA: no parameters, no rows
  @discardableResult
  func run(_ sql: String) -> Bool {
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(handle, sql, nil, nil, &message)
    if let message {
      NSLog("sqlite: \(String(cString: message)) in \(sql)")
      sqlite3_free(message)
    }
    return result == SQLITE_OK
  }

  func transaction(_ body: () -> Void) {
    run("BEGIN IMMEDIATE")
    body()
    run("COMMIT")
  }

  /// Steps a statement, passing each row to the body
  func each(_ sql: String, _ values: [Value] = [], _ body: (Row) -> Void) {
    guard let statement = statement(for: sql) else { return }
    defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
    bind(values, to: statement)
    let row = Row(statement: statement)
    while sqlite3_step(statement) == SQLITE_ROW { body(row) }
  }

  /// Value read from the first row, nil if there were none
  @discardableResult
  func first<T>(_ sql: String, _ values: [Value] = [], _ body: (Row) -> T) -> T? {
    var result: T?
    each(sql, values) { row in if result == nil { result = body(row) } }
    return result
  }

  /// Steps a statement for its effect, discarding rows
  func perform(_ sql: String, _ values: [Value] = []) {
    each(sql, values) { _ in }
  }

  var changes: Int { Int(sqlite3_changes(handle)) }

  private func statement(for sql: String) -> OpaquePointer? {
    if let cached = prepared[sql] { return cached }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      NSLog("sqlite: \(String(cString: sqlite3_errmsg(handle))) in \(sql)")
      return nil
    }
    prepared[sql] = statement
    return statement
  }

  private func bind(_ values: [Value], to statement: OpaquePointer) {
    // SQLITE_TRANSIENT: SQLite copies the text, so the Swift string can go
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
      case .int(let number): sqlite3_bind_int64(statement, index, Int64(number))
      case .double(let number): sqlite3_bind_double(statement, index, number)
      case .null: sqlite3_bind_null(statement, index)
      }
    }
  }

  /// Column access, valid only inside the each() body: the statement is reset
  /// afterwards
  struct Row {
    let statement: OpaquePointer

    func text(_ column: Int32) -> String {
      guard let value = sqlite3_column_text(statement, column) else { return "" }
      return String(cString: value)
    }

    func optionalText(_ column: Int32) -> String? {
      sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(column)
    }

    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
  }
}
