import AppKit
import SwiftUI

/// Borderless floating panel holding the history list, 620x460
@MainActor
final class HistoryPanel {
  private static let frameName = "historyPanel"
  private var panel: NSPanel?
  private var tier: SizeTier? {
    didSet { HistoryFilter.shared.tier = tier }
  }
  var onSettings: (() -> Void)?

  var isVisible: Bool { panel?.isVisible ?? false }

  func toggle() {
    if isVisible { hide() } else { show() }
  }

  func show(filter: SizeTier? = nil) {
    tier = filter
    // The list should already obey the limits, whether or not anything was
    // copied since they last changed
    ClipboardStore.shared.applyLimits()
    let panel = self.panel ?? makePanel()
    self.panel = panel
    if !panel.setFrameUsingName(Self.frameName) { center(panel) }

    panel.alphaValue = 0
    panel.contentView?.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
    // No NSApp.activate: it would pull every other window of the app forward
    panel.makeKeyAndOrderFront(nil)

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
      panel.contentView?.layer?.transform = CATransform3DIdentity
    }
    focusSearch(in: panel)
  }

  /// Makes the search field first responder on open
  ///
  /// With .focused() alone the panel stayed first responder until the first key
  /// arrived, and installing the field editor at that moment shifted the text
  private func focusSearch(in panel: NSPanel) {
    DispatchQueue.main.async {
      guard let content = panel.contentView,
            let field = Self.searchField(in: content) else { return }
      panel.makeFirstResponder(field)
    }
  }

  private static func searchField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    for child in view.subviews {
      if let found = searchField(in: child) { return found }
    }
    return nil
  }

  func hide() {
    guard let panel, panel.isVisible else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    } completionHandler: {
      panel.orderOut(nil)
    }
  }

  private func makePanel() -> NSPanel {
    let panel = KeyPanel(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isMovable = true
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.setFrameAutosaveName(Self.frameName)
    panel.onEscape = { [weak self] in self?.hide() }

    let view = HistoryView(
      onPick: { [weak self] item in
        ClipboardStore.shared.copyToPasteboard(item)
        if Settings.shared.closeAfterPick { self?.hide() }
      },
      onClose: { [weak self] in self?.hide() },
      onSettings: { [weak self] in
        self?.hide()
        self?.onSettings?()
      },
      onCenter: { [weak self] in self?.recenter() })

    let backdrop = PanelBackdrop()
    backdrop.frame = NSRect(x: 0, y: 0, width: 620, height: 460)
    let hosting = NSHostingView(rootView: view)
    hosting.frame = backdrop.bounds
    hosting.autoresizingMask = [.width, .height]
    backdrop.addSubview(hosting)
    panel.contentView = backdrop
    return panel
  }

  /// Moves the panel back to the centre and saves that frame
  func recenter() {
    guard let panel else { return }
    center(panel)
    panel.saveFrame(usingName: Self.frameName)
    if !panel.isVisible { show() }
  }

  private func center(_ panel: NSPanel) {
    guard let screen = NSScreen.main else { return }
    let frame = screen.visibleFrame
    let size = panel.frame.size
    panel.setFrameOrigin(NSPoint(
      x: frame.midX - size.width / 2,
      y: frame.midY - size.height / 2 + frame.height * 0.06))
  }
}

private final class KeyPanel: NSPanel {
  var onEscape: (() -> Void)?

  /// Heights of the search bar and the status strip, both of which drag the
  /// panel
  private let topBar: CGFloat = 46
  private let bottomBar: CGFloat = 30

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  /// Drags the panel from either bar without stealing clicks
  ///
  /// A press that turns into a drag moves the panel, one that stays put reaches
  /// the control under it
  override func sendEvent(_ event: NSEvent) {
    // A text field runs its own tracking loop, so a drag over it never reaches
    // here; the following events are peeked at without dequeuing them
    if event.type == .leftMouseDown {
      let y = event.locationInWindow.y
      if y > frame.height - topBar || y < bottomBar {
        let start = event.locationInWindow
        // Under 4 pt of movement is still a click, or the buttons in the bar
        // would stop responding to a shaky hand
        while let next = nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                   until: .distantFuture,
                                   inMode: .eventTracking,
                                   dequeue: false) {
          if next.type == .leftMouseUp { break }
          let moved = hypot(next.locationInWindow.x - start.x,
                            next.locationInWindow.y - start.y)
          if moved > 4 {
            performDrag(with: event)
            return
          }
          _ = nextEvent(matching: [.leftMouseDragged], until: .distantFuture,
                        inMode: .eventTracking, dequeue: true)
        }
      }
    }
    super.sendEvent(event)
  }

  override func cancelOperation(_ sender: Any?) { onEscape?() }

  override func resignKey() {
    super.resignKey()
    onEscape?()
  }
}
