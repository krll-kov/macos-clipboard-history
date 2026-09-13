import AppKit

/// Icon of the app an entry was copied from, matched on the app name, which is
/// all that is stored: a running app first, then the application folders
///
/// Cached, misses included: the list asks for every visible row on every redraw
@MainActor
enum SourceIcon {
  private static var cache: [String: NSImage?] = [:]

  static func image(for source: String?) -> NSImage? {
    guard let source, !source.isEmpty else { return nil }
    if let known = cache[source] { return known }
    let icon = find(source)
    cache[source] = icon
    return icon
  }

  private static func find(_ name: String) -> NSImage? {
    let running = NSWorkspace.shared.runningApplications
    if let icon = running.first(where: { $0.localizedName == name })?.icon { return icon }
    for folder in folders {
      let path = folder + "/" + name + ".app"
      guard FileManager.default.fileExists(atPath: path) else { continue }
      return NSWorkspace.shared.icon(forFile: path)
    }
    return nil
  }

  private static let folders = [
    "/Applications",
    "/Applications/Utilities",
    "/System/Applications",
    "/System/Applications/Utilities",
    NSHomeDirectory() + "/Applications",
  ]
}
