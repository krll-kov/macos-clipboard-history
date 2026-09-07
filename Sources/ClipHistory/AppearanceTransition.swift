import AppKit

/// Cross-fades every window when the theme changes
///
/// Setting NSApp.appearance repaints all windows in one frame, which reads as a
/// flash. A bitmap of the old state does not work as the top half of the fade:
/// cacheDisplay misses NSVisualEffectView vibrancy, draws text fields as bare
/// boxes and cannot reach the title bar. CATransition on the window frame layer
/// is composited in the render server, where the window is already whole
@MainActor
enum AppearanceTransition {
  private static let duration: TimeInterval = 0.18

  static func apply(_ appearance: Appearance) {
    let frames = NSApp.windows.compactMap { window -> NSView? in
      guard window.isVisible, window.alphaValue > 0.99 else { return nil }
      return window.contentView?.superview ?? window.contentView
    }
    for frame in frames {
      frame.wantsLayer = true
      let fade = CATransition()
      fade.type = .fade
      fade.duration = duration
      fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      frame.layer?.add(fade, forKey: "themeFade")
    }

    NSApp.appearance = appearance.nsAppearance

    // A transition covers only changes made in the transaction it was added in,
    // and SwiftUI would repaint a run loop turn later
    for frame in frames {
      frame.layoutSubtreeIfNeeded()
      frame.displayIfNeeded()
    }
  }
}
