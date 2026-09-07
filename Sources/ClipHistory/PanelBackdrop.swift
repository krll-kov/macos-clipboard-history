import AppKit

/// Blurred backdrop of the history panel
///
/// An AppKit view rather than a SwiftUI background: vibrancy is drawn by the
/// window server and does not survive inside the SwiftUI layer tree
final class PanelBackdrop: NSVisualEffectView {
  static let cornerRadius: CGFloat = 10

  convenience init() {
    self.init(frame: .zero)
    // .hudWindow is a dark HUD material and turns grey in the light appearance
    material = .menu
    blendingMode = .behindWindow
    state = .active
    // The panel never takes activation, so without this it draws as inactive
    isEmphasized = true
    wantsLayer = true
    layer?.cornerRadius = Self.cornerRadius
    layer?.masksToBounds = true
  }
}
