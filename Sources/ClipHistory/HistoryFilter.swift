import Foundation

/// Size band the panel is limited to, set when it is opened from settings
@MainActor
final class HistoryFilter: ObservableObject {
  static let shared = HistoryFilter()
  @Published var tier: SizeTier?
}
