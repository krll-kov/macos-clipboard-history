import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Size bands, each with its own retention: a line of text is cheap to keep for
/// a year, a 100 MB screenshot is not
enum SizeTier: String, CaseIterable, Codable {
  case small, medium, large, huge

  static func of(bytes: Int) -> SizeTier {
    switch bytes {
    case ..<(1 << 20): .small
    case ..<(10 << 20): .medium
    case ..<(100 << 20): .large
    default: .huge
    }
  }

  var title: String {
    switch self {
    case .small: "Up to 1 MB"
    case .medium: "1 to 10 MB"
    case .large: "10 to 100 MB"
    case .huge: "Over 100 MB"
    }
  }

  var defaultDays: Int {
    switch self {
    case .small: 365
    case .medium: 30
    case .large: 14
    case .huge: 3
    }
  }

  /// Band as stored in items.band and totals.band
  var band: Int {
    switch self {
    case .small: 0
    case .medium: 1
    case .large: 2
    case .huge: 3
    }
  }

  fileprivate var key: String { "retentionDays.\(rawValue)" }
}

/// Choices offered by every retention control
struct DayOption: Identifiable, Hashable {
  let days: Int
  let title: String
  var id: Int { days }

  static let all: [DayOption] = [
    .init(days: 1, title: "1 day"),
    .init(days: 3, title: "3 days"),
    .init(days: 7, title: "1 week"),
    .init(days: 14, title: "2 weeks"),
    .init(days: 30, title: "1 month"),
    .init(days: 90, title: "3 months"),
    .init(days: 180, title: "6 months"),
    .init(days: 365, title: "1 year"),
    .init(days: 0, title: "Forever"),
  ]

  static func title(for days: Int) -> String {
    all.first { $0.days == days }?.title ?? "\(days) days"
  }
}

enum Appearance: String, CaseIterable, Identifiable {
  case system, light, dark
  var id: String { rawValue }
  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
  var nsAppearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}

extension Notification.Name {
  /// A retention changed; ClipboardStore has to measure the history against it
  /// again
  static let clipLimitsChanged = Notification.Name("dev.swiftsoft.cliphistory.limitsChanged")
}

final class Settings: ObservableObject {
  static let shared = Settings()

  private enum Key {
    static let maxItems = "maxItems"
    static let maxTotalMB = "maxTotalMB"
    static let maxItemMB = "maxItemMB"
    static let captureImages = "captureImages"
    static let hotKeyCode = "hotKeyCode"
    static let hotKeyModifiers = "hotKeyModifiers"
    static let memoryDays = "memoryDays"
    static let closeAfterPick = "closeAfterPick"
    static let appearance = "appearance"
    static let totalSizeUnitIsGB = "totalSizeUnitIsGB"
  }

  private let defaults = UserDefaults.standard

  @Published var maxItems: Int { didSet { defaults.set(maxItems, forKey: Key.maxItems) } }
  @Published var maxTotalMB: Int { didSet { defaults.set(maxTotalMB, forKey: Key.maxTotalMB) } }
  @Published var maxItemMB: Int { didSet { defaults.set(maxItemMB, forKey: Key.maxItemMB) } }
  @Published var captureImages: Bool { didSet { defaults.set(captureImages, forKey: Key.captureImages) } }
  @Published var hotKeyCode: Int { didSet { defaults.set(hotKeyCode, forKey: Key.hotKeyCode) } }
  @Published var hotKeyModifiers: Int { didSet { defaults.set(hotKeyModifiers, forKey: Key.hotKeyModifiers) } }

  /// How far back the quick list reaches; older entries are found by search
  @Published var memoryDays: Int { didSet { defaults.set(memoryDays, forKey: Key.memoryDays) } }

  /// Whether picking an entry closes the panel
  @Published var closeAfterPick: Bool {
    didSet { defaults.set(closeAfterPick, forKey: Key.closeAfterPick) }
  }

  @Published var totalSizeUnitIsGB: Bool {
    didSet { defaults.set(totalSizeUnitIsGB, forKey: Key.totalSizeUnitIsGB) }
  }

  @Published var appearance: Appearance {
    didSet {
      defaults.set(appearance.rawValue, forKey: Key.appearance)
      MainActor.assumeIsolated { AppearanceTransition.apply(appearance) }
    }
  }

  @Published var retentionDays: [SizeTier: Int] {
    didSet {
      for (tier, days) in retentionDays { defaults.set(days, forKey: tier.key) }
      NotificationCenter.default.post(name: .clipLimitsChanged, object: nil)
    }
  }

  @Published var launchAtLogin: Bool {
    didSet {
      guard launchAtLogin != Self.loginItemEnabled else { return }
      do {
        if launchAtLogin {
          try SMAppService.mainApp.register()
        } else {
          try SMAppService.mainApp.unregister()
        }
      } catch {
        NSLog("login item: \(error.localizedDescription)")
      }
    }
  }

  var maxTotalBytes: Int { maxTotalMB * 1024 * 1024 }
  var maxItemBytes: Int { maxItemMB * 1024 * 1024 }

  func retention(for tier: SizeTier) -> Int { retentionDays[tier] ?? tier.defaultDays }

  private static var loginItemEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  private init() {
    var registration: [String: Any] = [
      Key.maxItems: 2000,
      Key.maxTotalMB: 500,
      Key.maxItemMB: 200,
      Key.captureImages: true,
      Key.hotKeyCode: kVK_ANSI_V,
      Key.hotKeyModifiers: Int(cmdKey | shiftKey),
      Key.memoryDays: 1,
      Key.closeAfterPick: true,
      Key.appearance: Appearance.system.rawValue,
      Key.totalSizeUnitIsGB: false,
    ]
    for tier in SizeTier.allCases { registration[tier.key] = tier.defaultDays }
    defaults.register(defaults: registration)

    maxItems = defaults.integer(forKey: Key.maxItems)
    maxTotalMB = defaults.integer(forKey: Key.maxTotalMB)
    maxItemMB = defaults.integer(forKey: Key.maxItemMB)
    captureImages = defaults.bool(forKey: Key.captureImages)
    hotKeyCode = defaults.integer(forKey: Key.hotKeyCode)
    hotKeyModifiers = defaults.integer(forKey: Key.hotKeyModifiers)
    memoryDays = defaults.integer(forKey: Key.memoryDays)
    closeAfterPick = defaults.bool(forKey: Key.closeAfterPick)
    totalSizeUnitIsGB = defaults.bool(forKey: Key.totalSizeUnitIsGB)
    appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
    var map: [SizeTier: Int] = [:]
    for tier in SizeTier.allCases { map[tier] = defaults.integer(forKey: tier.key) }
    retentionDays = map
    launchAtLogin = Self.loginItemEnabled
  }
}
