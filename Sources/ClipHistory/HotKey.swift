import AppKit
import Carbon.HIToolbox

/// Global hot key through Carbon, which needs no accessibility permission
final class HotKey {
  private var ref: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let action: () -> Void
  private static var instances: [UInt32: HotKey] = [:]
  private static var nextID: UInt32 = 1

  private let id: UInt32

  init(action: @escaping () -> Void) {
    self.action = action
    id = Self.nextID
    Self.nextID += 1
    Self.instances[id] = self
  }

  deinit {
    unregister()
    Self.instances[id] = nil
  }

  func register(keyCode: Int, modifiers: Int) {
    unregister()

    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                             eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
      var hotKeyID = EventHotKeyID()
      GetEventParameter(event, EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
      HotKey.instances[hotKeyID.id]?.action()
      return noErr
    }, 1, &spec, nil, &handler)

    let hotKeyID = EventHotKeyID(signature: OSType(0x43_4C_49_50), id: id)
    RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                        GetApplicationEventTarget(), 0, &ref)
  }

  func unregister() {
    if let ref { UnregisterEventHotKey(ref) }
    ref = nil
    if let handler { RemoveEventHandler(handler) }
    handler = nil
  }
}

enum KeyName {
  static func describe(keyCode: Int, modifiers: Int) -> String {
    var parts: [String] = []
    if modifiers & Int(controlKey) != 0 { parts.append("⌃") }
    if modifiers & Int(optionKey) != 0 { parts.append("⌥") }
    if modifiers & Int(shiftKey) != 0 { parts.append("⇧") }
    if modifiers & Int(cmdKey) != 0 { parts.append("⌘") }
    parts.append(character(for: keyCode))
    return parts.joined()
  }

  static func cocoaModifiers(_ carbon: Int) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if carbon & Int(cmdKey) != 0 { flags.insert(.command) }
    if carbon & Int(shiftKey) != 0 { flags.insert(.shift) }
    if carbon & Int(optionKey) != 0 { flags.insert(.option) }
    if carbon & Int(controlKey) != 0 { flags.insert(.control) }
    return flags
  }

  /// Name of the key as shown in the interface
  ///
  /// Taken from the keyboard layout, not from a table of letters: a comma, a
  /// bracket or a digit would otherwise print as its raw key code. The layout
  /// asked is the Latin one, so ⌘Q reads as Q on a Cyrillic keyboard
  static func character(for keyCode: Int) -> String {
    if let name = named[keyCode] { return name }
    return translated(keyCode)?.uppercased() ?? "Key \(keyCode)"
  }

  /// Same key in the form a menu item takes: one character, or empty when the
  /// key has no character a menu can draw
  static func menuKey(for keyCode: Int) -> String {
    if let key = menuKeys[keyCode] { return key }
    guard named[keyCode] == nil else { return "" }
    return translated(keyCode)?.lowercased() ?? ""
  }

  /// Keys with no character of their own
  private static let named: [Int: String] = [
    kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Tab: "⇥",
    kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
    kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
    kVK_F11: "F11", kVK_F12: "F12",
  ]

  private static let menuKeys: [Int: String] = [
    kVK_Space: " ", kVK_Return: "\r", kVK_Tab: "\t", kVK_Escape: "\u{1b}",
    kVK_Delete: "\u{8}", kVK_ForwardDelete: "\u{7f}",
    kVK_LeftArrow: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
    kVK_RightArrow: String(UnicodeScalar(NSRightArrowFunctionKey)!),
    kVK_UpArrow: String(UnicodeScalar(NSUpArrowFunctionKey)!),
    kVK_DownArrow: String(UnicodeScalar(NSDownArrowFunctionKey)!),
  ]

  /// What the key types on the system's Latin fallback layout
  private static func translated(_ keyCode: Int) -> String? {
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    var result: String?
    data.withUnsafeBytes { raw in
      guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
      var dead: UInt32 = 0
      var length = 0
      var characters = [UniChar](repeating: 0, count: 4)
      let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &dead, characters.count, &length, &characters)
      guard status == noErr, length > 0 else { return }
      result = String(utf16CodeUnits: characters, count: length)
    }
    return result
  }
}
