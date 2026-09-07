import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?
  private var settingsWindow: NSWindow?
  private var openItem: NSMenuItem?
  private let watcher = PasteboardWatcher()
  private let panel = HistoryPanel()
  private var hotKey: HotKey?
  private var termSignal: DispatchSourceSignal?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    NSApp.appearance = Settings.shared.appearance.nsAppearance
    buildMainMenu()
    buildStatusItem()
    panel.onSettings = { [weak self] in
      MainActor.assumeIsolated { self?.openSettings() }
    }
    watcher.start()
    hotKey = HotKey { [weak self] in
      MainActor.assumeIsolated { self?.panel.toggle() }
    }
    applyHotKey()
    catchTermination()
    // SwiftUI builds the settings form lazily and the first pass is slow, so
    // it happens in the background rather than under the user's click
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      self?.warmSettings()
    }
  }

  /// Checkpoints the database on SIGTERM
  ///
  /// applicationWillTerminate does not run for a signal, and Run.command stops
  /// the app with pkill
  private func catchTermination() {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler {
      MainActor.assumeIsolated {
        ClipboardStore.shared.flush()
        NSApp.terminate(nil)
      }
    }
    source.resume()
    termSignal = source
  }

  private func warmSettings() {
    guard settingsWindow == nil else { return }
    makeSettingsWindow().alphaValue = 0
  }

  func applyHotKey() {
    hotKey?.register(keyCode: Settings.shared.hotKeyCode,
                     modifiers: Settings.shared.hotKeyModifiers)
    updateTip()
  }

  /// Shows the hot key next to the menu item
  ///
  /// Display only: the panel is opened by the Carbon hot key, since a status
  /// item menu matches its key equivalents only while it is open
  private func updateTip() {
    let key = KeyName.menuKey(for: Settings.shared.hotKeyCode)
    openItem?.keyEquivalent = key
    openItem?.keyEquivalentModifierMask = key.isEmpty
      ? []
      : KeyName.cocoaModifiers(Settings.shared.hotKeyModifiers)
  }

  /// An accessory app has no menu bar, and without an Edit menu the panel's
  /// text field gets no ⌘A, ⌘C, ⌘V or ⌘Z
  private func buildMainMenu() {
    let main = NSMenu()

    // Empty app menu: no ⌘Q, since quitting a menu bar utility should be a
    // deliberate click
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    main.addItem(appItem)

    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)

    let windowItem = NSMenuItem()
    let window = NSMenu(title: "Window")
    window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
                   keyEquivalent: "w")
    // No ⌘Q item, hidden or otherwise: NSApp.mainMenu is offered the shortcut
    // before the key window, so even a hidden item shadows SettingsWindow
    windowItem.submenu = window
    main.addItem(windowItem)

    NSApp.mainMenu = main
  }

  private func buildStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                 accessibilityDescription: "Clipboard History")
    item.button?.image?.isTemplate = true

    let menu = NSMenu()
    let open = NSMenuItem(title: "Open History", action: #selector(openHistory), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    openItem = open

    let recenter = NSMenuItem(title: "Center Window", action: #selector(centerPanel),
                              keyEquivalent: "")
    recenter.target = self
    menu.addItem(recenter)

    menu.addItem(.separator())
    let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings),
                              keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
    quit.target = self
    menu.addItem(quit)
    item.menu = menu
    statusItem = item
  }

  @objc private func openHistory() { panel.show() }

  @objc private func centerPanel() { panel.recenter() }

  @objc func openSettings() {
    let window = settingsWindow ?? makeSettingsWindow()
    if window.isVisible {
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
    } else {
      present(window)
    }
  }

  @discardableResult
  private func makeSettingsWindow() -> NSWindow {
    let view = SettingsView(
      onHotKeyChange: { [weak self] in
        MainActor.assumeIsolated { self?.applyHotKey() }
      },
      onShowTier: { [weak self] tier in
        MainActor.assumeIsolated {
          self?.settingsWindow?.orderOut(nil)
          self?.panel.show(filter: tier)
        }
      })
    let window = SettingsWindow(
      contentRect: NSRect(origin: .zero, size: SettingsView.windowSize),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.title = "Clipboard History Settings"
    // Plain container around the hosting view: NSHostingView owns its layer
    // tree and drops foreign sublayers, including the theme cross-fade
    let container = NSView(frame: NSRect(origin: .zero, size: SettingsView.windowSize))
    container.wantsLayer = true
    let hosting = NSHostingView(rootView: view)
    hosting.frame = container.bounds
    hosting.autoresizingMask = [.width, .height]
    container.addSubview(hosting)
    window.contentView = container
    window.isReleasedWhenClosed = false
    if let visible = NSScreen.main?.visibleFrame, window.frame.height > visible.height {
      window.setContentSize(NSSize(width: window.frame.width, height: visible.height - 40))
    }
    window.center()
    settingsWindow = window
    return window
  }

  /// Fades a window in
  ///
  /// makeKeyAndOrderFront resets alphaValue, so the fade starts one run loop
  /// turn later
  private func present(_ window: NSWindow) {
    window.alphaValue = 0
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.alphaValue = 0
    DispatchQueue.main.async {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        window.animator().alphaValue = 1
      }
    }
  }

  @objc private func quit() { NSApp.terminate(nil) }

  /// Checkpoints the database on a normal quit
  func applicationWillTerminate(_ notification: Notification) {
    ClipboardStore.shared.flush()
  }
}

/// Settings window: Esc and ⌘Q close it instead of quitting the app
private final class SettingsWindow: NSWindow {
  /// Drops the focus ring when a click lands outside a text field
  ///
  /// Nothing else in the form takes first responder, so the ring stayed lit for
  /// the rest of the session. Dropping it also commits the value being typed
  override func sendEvent(_ event: NSEvent) {
    // Only while a field is being edited: KeyRecorder also holds first
    // responder and must keep it
    if event.type == .leftMouseDown, isEditing, let content = contentView {
      let point = content.convert(event.locationInWindow, from: nil)
      if !isTextInput(content.hitTest(point)) { makeFirstResponder(nil) }
    }
    super.sendEvent(event)
  }

  /// Editing runs through the window's field editor, the only NSTextView here
  private var isEditing: Bool { firstResponder is NSTextView }

  /// The field editor is a subview of the field, so walking up catches both
  private func isTextInput(_ view: NSView?) -> Bool {
    var current = view
    while let view = current {
      if view is NSTextField || view is NSTextView { return true }
      current = view.superview
    }
    return false
  }

  /// A window that is not key should not look like it is being typed into
  override func resignKey() {
    super.resignKey()
    if isEditing { makeFirstResponder(nil) }
  }

  /// Esc closes the window instead of beeping
  override func cancelOperation(_ sender: Any?) { close() }

  /// A limit lowered here applies to what is already stored, not only to what
  /// is copied next
  override func close() {
    super.close()
    ClipboardStore.shared.applyLimits()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if SettingsWindow.isQuit(event) {
      close()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  /// ⌘Q on any keyboard layout
  ///
  /// Matched by key code, not by character: on a Cyrillic layout ⌘Q arrives as
  /// "й" and comparing characters never matched. Only the four real modifiers
  /// are compared, since deviceIndependentFlagsMask also carries Caps Lock
  static func isQuit(_ event: NSEvent) -> Bool {
    event.type == .keyDown && Int(event.keyCode) == kVK_ANSI_Q
      && event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
  }
}
