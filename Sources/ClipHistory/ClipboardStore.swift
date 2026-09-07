import AppKit
import CryptoKit

struct ClipItem: Identifiable, Codable, Equatable {
  enum Kind: String, Codable { case text, image }

  let id: UUID
  let kind: Kind
  let date: Date
  let bytes: Int
  let digest: String
  /// Shortened for the list; the whole body is a file beside the database
  let preview: String
  let file: String?
  let thumb: String?
  /// App that was frontmost when this was copied, or "Screenshot"
  let source: String?

  var tier: SizeTier { .of(bytes: bytes) }

  static func == (a: ClipItem, b: ClipItem) -> Bool { a.id == b.id }
}

/// The history, held in SQLite
///
/// Every list and every count is a query, so nothing is kept in memory and a
/// million entries cost the same to open as ten. Bodies stay as files beside
/// the database
@MainActor
final class ClipboardStore: ObservableObject {
  static let shared = ClipboardStore()
  nonisolated static let previewLimit = 400
  /// Rows per query, built into ClipItems on every keystroke
  nonisolated static let pageLimit = 300

  /// Bumped on every change; the list redraws from it
  @Published private(set) var generation = 0

  /// Set while a bulk delete runs
  @Published private(set) var bulk: Bulk?

  struct Bulk: Equatable {
    let title: String
    var done: Int
    let total: Int
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
  }

  private let root: URL
  private let bodies: URL
  private let database: Database
  private var pruneTimer: Timer?
  private var deletedSinceVacuum = 0
  /// Unlinking 90 000 bodies takes longer than deleting their rows
  private let unlink = DispatchQueue(label: "dev.swiftsoft.cliphistory.unlink", qos: .utility)
  /// Last answer given to the list, so redrawing does not repeat the query
  private var lastQuery: (key: String, generation: Int, rows: [ClipItem])?

  private init() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    root = base.appendingPathComponent("dev.swiftsoft.cliphistory", isDirectory: true)
    bodies = root.appendingPathComponent("bodies", isDirectory: true)
    try? FileManager.default.createDirectory(at: bodies, withIntermediateDirectories: true)

    let file = root.appendingPathComponent("history.db")
    do {
      database = try Database(path: file.path)
    } catch {
      // No database means no history, and a menu bar app has nowhere to show
      // the failure
      NSLog("clipboard history: \(error)")
      fatalError("cannot open \(file.path): \(error)")
    }
    prepare()
    dropOrphans()
    applyLimits()

    pruneTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyLimits() }
    }
    NotificationCenter.default.addObserver(
      forName: .clipLimitsChanged, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyLimits() }
    }
  }

  // MARK: - Shape of the database

  private func prepare() {
    // Must be set before the first table exists, or it has no effect
    database.run("PRAGMA auto_vacuum=INCREMENTAL")
    database.run("PRAGMA journal_mode=WAL")
    database.run("PRAGMA synchronous=NORMAL")
    database.run("PRAGMA temp_store=MEMORY")
    database.run("""
      CREATE TABLE IF NOT EXISTS items (
        id TEXT PRIMARY KEY, kind TEXT NOT NULL, date REAL NOT NULL,
        bytes INTEGER NOT NULL, digest TEXT NOT NULL UNIQUE, preview TEXT NOT NULL,
        file TEXT, thumb TEXT, source TEXT, band INTEGER NOT NULL)
      """)
    database.run("CREATE INDEX IF NOT EXISTS items_date ON items(date DESC)")
    database.run("CREATE INDEX IF NOT EXISTS items_band ON items(band, date DESC)")
    // Partial index for the deep read in deepen(): without it that query
    // scanned a million rows and cost 256 ms whenever it matched nothing
    database.run("""
      CREATE INDEX IF NOT EXISTS items_long ON items(date DESC)
      WHERE kind = 'text' AND length(preview) >= \(Self.previewLimit)
      """)
    // Three tables, not three columns of one: a match has to say which of the
    // three it came from, and columns share one hit list, so a meta query walks
    // every hit of the same word in every preview: 96 ms at a million rows to
    // return nothing, against 0.1 ms split apart
    //
    // trigram matches a substring anywhere in a word, unlike unicode61, which
    // finds nothing for "ermina". content='' stores no copy of the text
    for table in Self.indexes {
      database.run("""
        CREATE VIRTUAL TABLE IF NOT EXISTS \(table) USING fts5(
          text, tokenize='trigram', content='', contentless_delete=1)
        """)
    }
    database.run("""
      CREATE TABLE IF NOT EXISTS totals (
        band INTEGER PRIMARY KEY, count INTEGER NOT NULL, bytes INTEGER NOT NULL)
      """)
    for tier in SizeTier.allCases {
      database.perform("INSERT OR IGNORE INTO totals VALUES (?, 0, 0)", [.int(tier.band)])
    }
    // Running totals: count(*) and sum(bytes) over a million rows cost 24 ms,
    // reading these four rows costs 0.02
    database.run("""
      CREATE TRIGGER IF NOT EXISTS items_added AFTER INSERT ON items BEGIN
        UPDATE totals SET count = count + 1, bytes = bytes + new.bytes WHERE band = new.band;
      END
      """)
    database.run("""
      CREATE TRIGGER IF NOT EXISTS items_gone AFTER DELETE ON items BEGIN
        DELETE FROM search_text WHERE rowid = old.rowid;
        DELETE FROM search_source WHERE rowid = old.rowid;
        DELETE FROM search_meta WHERE rowid = old.rowid;
        UPDATE totals SET count = count - 1, bytes = bytes - old.bytes WHERE band = old.band;
      END
      """)
  }

  /// Search indexes in ranking order
  private static let indexes = ["search_text", "search_source", "search_meta"]

  // MARK: - What the list asks for

  var count: Int {
    database.first("SELECT sum(count) FROM totals") { $0.int(0) } ?? 0
  }

  var totalBytes: Int {
    database.first("SELECT sum(bytes) FROM totals") { $0.int(0) } ?? 0
  }

  func count(in tier: SizeTier) -> Int {
    database.first("SELECT count FROM totals WHERE band = ?", [.int(tier.band)]) { $0.int(0) } ?? 0
  }

  func bytes(in tier: SizeTier) -> Int {
    database.first("SELECT bytes FROM totals WHERE band = ?", [.int(tier.band)]) { $0.int(0) } ?? 0
  }

  /// Cached by query and generation: SwiftUI calls this several times per redraw
  func rows(matching query: String, tier: SizeTier?) -> [ClipItem] {
    let key = "\(tier?.rawValue ?? "-")\u{1}\(query)"
    if let last = lastQuery, last.generation == generation, last.key == key { return last.rows }
    let rows = fetch(query: query, tier: tier)
    lastQuery = (key, generation, rows)
    return rows
  }

  private func fetch(query: String, tier: SizeTier?) -> [ClipItem] {
    let needle = Self.loose(query)
    guard !needle.isEmpty else { return recent(tier: tier) }
    // fts5 trigram needs three characters; below that, scan the newest 500
    guard needle.count >= 3 else {
      // Compared as typed: normalising 500 previews cost 35 ms per keystroke
      let typed = query.trimmingCharacters(in: .whitespaces)
      return recent(tier: tier, limit: 500)
        .filter {
          $0.preview.localizedCaseInsensitiveContains(typed)
            || ($0.source ?? "").localizedCaseInsensitiveContains(typed)
        }
        .prefix(Self.pageLimit)
        .map { $0 }
    }

    // Text first, then source, then size and date; newest first inside each
    var found: [ClipItem] = []
    var seen = Set<UUID>()
    for index in Self.indexes {
      // A full page leaves no room for the lower ranks
      guard found.count < Self.pageLimit else { break }
      for item in match(in: index, needle: needle, tier: tier) where !seen.contains(item.id) {
        seen.insert(item.id)
        found.append(item)
      }
    }
    return deepen(found, needle: needle, tier: tier, seen: seen)
  }

  private func match(in index: String, needle: String, tier: SizeTier?) -> [ClipItem] {
    let phrase = "\"\(needle.replacingOccurrences(of: "\"", with: "\"\""))\""
    var values: [Database.Value] = [.text(phrase)]
    var band = ""
    if let tier {
      band = "AND items.band = ?"
      values.append(.int(tier.band))
    }
    values.append(.int(Self.pageLimit))
    var rows: [ClipItem] = []
    database.each("""
      SELECT \(Self.columns) FROM \(index) JOIN items ON items.rowid = \(index).rowid
      WHERE \(index) MATCH ? \(band) ORDER BY \(index).rowid DESC LIMIT ?
      """, values) { rows.append(Self.item(from: $0)) }
    return rows
  }

  /// Reads into the bodies of long entries when the index found under 20 rows
  ///
  /// 15 entries at 16 KB each. Reading them whole froze the window: stored
  /// bodies reach hundreds of megabytes and this runs on every keystroke
  private func deepen(_ found: [ClipItem], needle: String, tier: SizeTier?,
                      seen: Set<UUID>) -> [ClipItem] {
    guard found.count < 20 else { return found }
    var extra: [ClipItem] = []
    var values: [Database.Value] = []
    var band = ""
    if let tier {
      band = "AND band = ?"
      values.append(.int(tier.band))
    }
    // Written into the statement rather than bound, so it matches the partial
    // index above
    database.each("""
      SELECT \(Self.columns) FROM items
      WHERE kind = 'text' AND length(preview) >= \(Self.previewLimit) \(band)
      ORDER BY date DESC LIMIT 15
      """, values) { extra.append(Self.item(from: $0)) }
    let deep = extra.filter { !seen.contains($0.id) && Self.loose(head(of: $0)).contains(needle) }
    return found + deep
  }

  /// First 16 KB of a stored body
  private func head(of item: ClipItem, bytes: Int = 16 << 10) -> String {
    guard item.kind == .text, let url = fileURL(for: item),
          let handle = try? FileHandle(forReadingFrom: url)
    else { return item.preview }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: bytes) else { return item.preview }
    return String(data: data, encoding: .utf8) ?? item.preview
  }

  /// Plain list, newest first, within the retention set for the quick list
  func recent(tier: SizeTier? = nil, limit: Int = ClipboardStore.pageLimit) -> [ClipItem] {
    var conditions: [String] = []
    var values: [Database.Value] = []
    let days = Settings.shared.memoryDays
    if days > 0 {
      conditions.append("date >= ?")
      values.append(.double(Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970))
    }
    if let tier {
      conditions.append("band = ?")
      values.append(.int(tier.band))
    }
    values.append(.int(limit))
    let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
    var rows: [ClipItem] = []
    database.each("SELECT \(Self.columns) FROM items \(filter) ORDER BY date DESC LIMIT ?",
                  values) { rows.append(Self.item(from: $0)) }
    return rows
  }

  // MARK: - Bodies

  func fileURL(for item: ClipItem) -> URL? {
    item.file.map { bodies.appendingPathComponent($0) }
  }

  func thumbURL(for item: ClipItem) -> URL? {
    item.thumb.map { bodies.appendingPathComponent($0) }
  }

  func fullText(of item: ClipItem) -> String {
    guard item.kind == .text, let url = fileURL(for: item),
          let text = try? String(contentsOf: url, encoding: .utf8)
    else { return item.preview }
    return text
  }

  func copyToPasteboard(_ item: ClipItem) {
    let pb = NSPasteboard.general
    pb.clearContents()
    switch item.kind {
    case .text:
      pb.setString(fullText(of: item), forType: .string)
    case .image:
      if let url = fileURL(for: item), let image = NSImage(contentsOf: url) {
        pb.writeObjects([image])
      }
    }
  }

  // MARK: - Storing

  func add(text: String, source: String?) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let data = Data(text.utf8)
    guard data.count <= Settings.shared.maxItemBytes else { return }
    let digest = Self.digest(data)
    if bump(digest) { return }
    let name = UUID().uuidString + ".txt"
    guard (try? data.write(to: bodies.appendingPathComponent(name))) != nil else { return }
    // The body is stored as copied; the preview is flattened, or indented code
    // spends its line on the indent
    let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    insert(ClipItem(id: UUID(), kind: .text, date: Date(), bytes: data.count,
                    digest: digest, preview: String(flat.prefix(Self.previewLimit)),
                    file: name, thumb: nil, source: source))
  }

  func add(png: Data, thumb: Data?, label: String, source: String?) {
    guard png.count <= Settings.shared.maxItemBytes else { return }
    let digest = Self.digest(png)
    if bump(digest) { return }
    let name = UUID().uuidString + ".png"
    guard (try? png.write(to: bodies.appendingPathComponent(name))) != nil else { return }
    var thumbName: String?
    if let thumb {
      let t = UUID().uuidString + "." + Thumbnail.format.ext
      if (try? thumb.write(to: bodies.appendingPathComponent(t))) != nil { thumbName = t }
    }
    insert(ClipItem(id: UUID(), kind: .image, date: Date(), bytes: png.count,
                    digest: digest, preview: label, file: name, thumb: thumbName,
                    source: source))
  }

  /// Re-copying an entry moves it back to the top instead of storing it twice
  ///
  /// Delete and insert rather than UPDATE date: search orders by rowid, so
  /// recency has to be in rowid order too
  private func bump(_ digest: String) -> Bool {
    guard let old = database.first(
      "SELECT \(Self.columns) FROM items WHERE digest = ?", [.text(digest)],
      { Self.item(from: $0) }) else { return false }
    database.transaction {
      database.perform("DELETE FROM items WHERE id = ?", [.text(old.id.uuidString)])
      write(ClipItem(id: old.id, kind: old.kind, date: Date(), bytes: old.bytes,
                     digest: old.digest, preview: old.preview, file: old.file,
                     thumb: old.thumb, source: old.source))
    }
    generation += 1
    return true
  }

  private func insert(_ item: ClipItem) {
    database.transaction { write(item) }
    generation += 1
    applyLimits()
  }

  /// Writes the row and its three index entries; rowid links them
  private func write(_ item: ClipItem) {
    database.perform("""
      INSERT OR REPLACE INTO items (id, kind, date, bytes, digest, preview, file, thumb, source, band)
      VALUES (?,?,?,?,?,?,?,?,?,?)
      """, [
        .text(item.id.uuidString), .text(item.kind.rawValue),
        .double(item.date.timeIntervalSince1970), .int(item.bytes), .text(item.digest),
        .text(item.preview), item.file.map { .text($0) } ?? .null,
        item.thumb.map { .text($0) } ?? .null, item.source.map { .text($0) } ?? .null,
        .int(item.tier.band),
      ])
    guard let rowid = database.first("SELECT rowid FROM items WHERE id = ?",
                                     [.text(item.id.uuidString)], { $0.int(0) }) else { return }
    let keys = [
      Self.loose(item.preview),
      Self.loose(item.source ?? ""),
      Self.loose(Self.sizeKeys(item.bytes) + " " + Self.dateKeys(item.date)),
    ]
    for (index, key) in zip(Self.indexes, keys) {
      database.perform("INSERT INTO \(index)(rowid, text) VALUES (?,?)", [.int(rowid), .text(key)])
    }
  }

  // MARK: - Removing

  func remove(_ item: ClipItem) {
    dropRows("DELETE FROM items WHERE id = ? RETURNING file, thumb, id", [.text(item.id.uuidString)])
    generation += 1
  }

  func removeAll() async {
    await bulkDelete("Clearing history", total: count,
                     "DELETE FROM items WHERE rowid IN (SELECT rowid FROM items LIMIT ?)")
  }

  func removeAll(in tier: SizeTier) async {
    await bulkDelete("Clearing \(tier.title)", total: count(in: tier),
                     """
                     DELETE FROM items WHERE rowid IN
                       (SELECT rowid FROM items WHERE band = ? LIMIT ?)
                     """, [.int(tier.band)])
  }

  /// Deletes in batches, yielding between them
  ///
  /// One statement over 90 000 entries holds the main thread for minutes
  private func bulkDelete(_ title: String, total: Int, _ sql: String,
                          _ values: [Database.Value] = []) async {
    guard total > 0 else { return }
    bulk = Bulk(title: title, done: 0, total: total)
    defer { bulk = nil }

    let statement = sql + " RETURNING file, thumb, id"
    var done = 0
    while true {
      let gone = dropRows(statement, values + [.int(Self.deleteBatch)])
      guard gone > 0 else { break }
      done += gone
      bulk?.done = min(done, total)
      generation += 1
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    await reclaim()
  }

  private static let deleteBatch = 2000

  /// Applies retention, maxItems and maxTotalBytes
  ///
  /// Called on every copy, every 600 s, on .clipLimitsChanged, when the settings
  /// close and when the panel opens: a limit lowered in the settings and a day
  /// passing have nothing else to hang off
  func applyLimits() {
    let settings = Settings.shared
    let now = Date().timeIntervalSince1970
    var dropped = 0
    for tier in SizeTier.allCases {
      let days = settings.retention(for: tier)
      guard days > 0 else { continue }
      dropped += dropRows(
        "DELETE FROM items WHERE band = ? AND date < ? RETURNING file, thumb, id",
        [.int(tier.band), .double(now - Double(days) * 86400)])
    }

    let extra = count - settings.maxItems
    if extra > 0 {
      dropped += dropRows("""
        DELETE FROM items WHERE rowid IN
          (SELECT rowid FROM items ORDER BY date ASC LIMIT ?)
        RETURNING file, thumb, id
        """, [.int(extra)])
    }

    if totalBytes > settings.maxTotalBytes {
      // Running sum over date DESC: everything past the point where the newest
      // entries have used up the allowance
      dropped += dropRows("""
        DELETE FROM items WHERE rowid IN (
          SELECT rowid FROM (
            SELECT rowid, sum(bytes) OVER (ORDER BY date DESC) AS running FROM items
          ) WHERE running > ?
        ) RETURNING file, thumb, id
        """, [.int(settings.maxTotalBytes)])
    }

    if dropped > 0 {
      deletedSinceVacuum += dropped
      if deletedSinceVacuum > 5000 {
        Task { await reclaim() }
      }
      generation += 1
    }
  }

  /// Drops entries whose stored body is gone
  ///
  /// Rows and files fall out of step if the process dies between the two writes.
  /// Bounded to the newest 1000, since this runs at every launch
  private func dropOrphans() {
    var doomed: [String] = []
    database.each("SELECT id, file FROM items ORDER BY date DESC LIMIT 1000") { row in
      let name = row.optionalText(1)
      guard let name, !FileManager.default.fileExists(
        atPath: bodies.appendingPathComponent(name).path) else { return }
      doomed.append(row.text(0))
    }
    guard !doomed.isEmpty else { return }
    database.transaction {
      for id in doomed { database.perform("DELETE FROM items WHERE id = ?", [.text(id)]) }
    }
    generation += 1
  }

  /// Deletes rows with the bodies they name and returns how many went
  ///
  /// The names come back from the delete itself, so nothing has to be read
  /// first
  @discardableResult
  private func dropRows(_ sql: String, _ values: [Database.Value] = []) -> Int {
    var files: [String] = []
    var gone = 0
    database.each(sql, values) { row in
      gone += 1
      if let file = row.optionalText(0) { files.append(file) }
      if let thumb = row.optionalText(1) { files.append(thumb) }
      if let id = UUID(uuidString: row.text(2)) { ThumbnailCache.shared.drop(id) }
    }
    let folder = bodies
    unlink.async {
      for name in files {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
      }
    }
    return gone
  }

  /// Returns freed pages to the file system, 2000 at a time
  ///
  /// 683 MB back to 40 MB after a million rows; in one call that is seconds of
  /// held main thread
  private func reclaim() async {
    deletedSinceVacuum = 0
    bulk = Bulk(title: "Reclaiming space", done: 0, total: freePages)
    defer { bulk = nil }
    let start = freePages
    while true {
      let before = freePages
      guard before > 0 else { break }
      database.run("PRAGMA incremental_vacuum(2000)")
      let after = freePages
      guard after < before else { break }
      bulk?.done = start - after
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
  }

  private var freePages: Int {
    database.first("PRAGMA freelist_count") { $0.int(0) } ?? 0
  }

  /// Allocated size of the whole store folder
  func diskBytes() -> Int {
    let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
    guard let files = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: Array(keys)) else { return totalBytes }
    var total = 0
    for case let url as URL in files {
      let values = try? url.resourceValues(forKeys: keys)
      total += values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
    }
    return total
  }

  /// Folds the write-ahead log into the database file, for shutdown
  func flush() {
    database.run("PRAGMA wal_checkpoint(TRUNCATE)")
  }

  // MARK: - Reading rows

  private static let columns = "items.id, items.kind, items.date, items.bytes, items.digest, "
    + "items.preview, items.file, items.thumb, items.source"

  private static func item(from row: Database.Row) -> ClipItem {
    ClipItem(id: UUID(uuidString: row.text(0)) ?? UUID(),
             kind: ClipItem.Kind(rawValue: row.text(1)) ?? .text,
             date: Date(timeIntervalSince1970: row.double(2)),
             bytes: row.int(3), digest: row.text(4), preview: row.text(5),
             file: row.optionalText(6), thumb: row.optionalText(7), source: row.optionalText(8))
  }

  // MARK: - Search keys

  /// Normalised form written to the indexes and applied to the query
  ///
  /// Each run of non-alphanumerics collapses to one dash, so 16-09-2023,
  /// 16/09/2023 and 16 09 2023 all match. × becomes x, since an image label
  /// reads "Image 82×1648" and nobody types ×
  nonisolated static func loose(_ text: String) -> String {
    var out = ""
    var pending = false
    for character in text.lowercased() {
      if character == "×" {
        out.append("x")
        pending = false
      } else if character.isLetter || character.isNumber {
        out.append(character)
        pending = false
      } else if !pending {
        out.append("-")
        pending = true
      }
    }
    return out
  }

  /// "5,4 MB" as the row shows it, "5,4MB" without the space, and "5400000"
  private static func sizeKeys(_ bytes: Int) -> String {
    let shown = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    return "\(shown) \(shown.filter { !$0.isWhitespace }) \(bytes)"
  }

  private static func dateKeys(_ date: Date) -> String {
    Self.dateKeyFormatters.map { $0.string(from: date) }.joined(separator: " ")
  }

  /// Day first, year first, month and day alone, the time, the month by name;
  /// separators do not matter, loose() flattens both sides
  private static let dateKeyFormatters: [DateFormatter] = [
    "dd-MM-yyyy", "d-M-yyyy", "yyyy-MM-dd", "ddMMyyyy",
    "dd-MM", "d-M", "ddMM", "MM-yyyy",
    "HH-mm", "H-mm", "HHmm",
    "MMMM", "MMM",
  ].map {
    let formatter = DateFormatter()
    formatter.dateFormat = $0
    return formatter
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
