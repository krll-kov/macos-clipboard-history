import AppKit
import SwiftUI

/// Sets the scrollers of every SwiftUI scroll view in the window
///
/// SwiftUI exposes no API for this, so the NSScrollViews are found by walking
/// the view tree from the window
struct ScrollerStyle: NSViewRepresentable {
  /// true: legacy scroller, always visible, 15 pt taken out of the clip view
  /// false: overlay scroller, floats above the content, thin, fades out
  var alwaysVisible: Bool

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    let coordinator = context.coordinator
    DispatchQueue.main.async { apply(from: view, coordinator) }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    let coordinator = context.coordinator
    DispatchQueue.main.async { apply(from: nsView, coordinator) }
  }

  /// Holds the frame observation across updateNSView calls
  final class Coordinator {
    weak var document: NSView?
    var token: NSObjectProtocol?
    deinit {
      if let token { NotificationCenter.default.removeObserver(token) }
    }
  }

  private func apply(from view: NSView, _ coordinator: Coordinator) {
    guard let root = view.window?.contentView else { return }
    var found = false
    walk(root) { scroll in
      if alwaysVisible {
        if !(scroll.verticalScroller is SlimScroller) {
          scroll.verticalScroller = SlimScroller()
        }
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.verticalScroller?.scrollerStyle = .legacy
        scroll.verticalScroller?.controlSize = .regular
      } else {
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.scrollerStyle = .overlay
        scroll.verticalScroller?.controlSize = .small
      }
      scroll.tile()
      scroll.reflectScrolledClipView(scroll.contentView)
      if alwaysVisible {
        measure(scroll)
        watch(scroll, coordinator)
      }
      found = true
    }
    if !found {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { apply(from: view, coordinator) }
    }
  }

  /// Records how much wider than the clip view SwiftUI laid the content out
  ///
  /// A list too short to scroll is laid out against the full 620 pt of the
  /// scroll view, a scrolling one against the 605 pt clip view. Nothing forces a
  /// re-measure, so the list takes the difference off its trailing edge and both
  /// cases end on the same pixel
  private func measure(_ scroll: NSScrollView) {
    guard let document = scroll.documentView else { return }
    let over = document.frame.width - scroll.contentView.bounds.width
    guard abs(ListInset.shared.overhang - over) > 0.5 else { return }
    // The measurement can arrive mid-layout, where publishing would recurse
    DispatchQueue.main.async { ListInset.shared.overhang = over }
  }

  /// Re-measures whenever the document view resizes
  ///
  /// The list is laid out again long after the style is set: a filter applied, a
  /// search typed, the last entry deleted. Measuring once left short lists
  /// clipped on the right
  private func watch(_ scroll: NSScrollView, _ coordinator: Coordinator) {
    guard let document = scroll.documentView, coordinator.document !== document else { return }
    if let token = coordinator.token { NotificationCenter.default.removeObserver(token) }
    document.postsFrameChangedNotifications = true
    coordinator.document = document
    coordinator.token = NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification, object: document, queue: .main
    ) { _ in
      MainActor.assumeIsolated { measure(scroll) }
    }
  }

  private func walk(_ view: NSView, _ body: (NSScrollView) -> Void) {
    if let scroll = view as? NSScrollView { body(scroll) }
    for child in view.subviews { walk(child, body) }
  }
}

/// Trailing inset the list applies, in points
@MainActor
final class ListInset: ObservableObject {
  static let shared = ListInset()
  @Published var overhang: CGFloat = 0
}

enum ScrollerMetrics {
  /// Width of an overlay scroller, 15 pt
  ///
  /// It floats above the content instead of taking width from it, so a form
  /// filling the window sits optically off to the right by half of this
  static let overlay = NSScroller.scrollerWidth(for: .small, scrollerStyle: .overlay)
}

/// Legacy scroller 2 pt narrower than standard
///
/// scrollerWidth(for:scrollerStyle:) is a class method, so this takes a subclass
private final class SlimScroller: NSScroller {
  override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                    scrollerStyle: NSScroller.Style) -> CGFloat {
    super.scrollerWidth(for: controlSize, scrollerStyle: scrollerStyle) - 2
  }
}

extension View {
  /// Overlay scrollers: above the content, autohiding
  func overlayScrollers() -> some View {
    background(ScrollerStyle(alwaysVisible: false).frame(width: 0, height: 0))
  }

  /// Legacy scrollers that never autohide, plus the trailing inset measurement
  func visibleScrollers() -> some View {
    background(ScrollerStyle(alwaysVisible: true).frame(width: 0, height: 0))
  }
}
