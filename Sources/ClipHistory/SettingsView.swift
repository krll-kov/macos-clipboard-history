import AppKit
import SwiftUI

struct SettingsView: View {
  @ObservedObject var settings = Settings.shared
  @ObservedObject var store = ClipboardStore.shared
  var onHotKeyChange: () -> Void
  var onShowTier: (SizeTier) -> Void

  @State private var recording = false

  /// Width of the control column, so every row shares one right edge; set by
  /// the widest row, a menu and two buttons
  private let controlWidth: CGFloat = 268

  /// Wide enough that no label in the left column wraps
  static let windowSize = CGSize(width: 580, height: 640)

  var body: some View {
    Form {
      Section("Capture") {
        row("Store") {
          Choice(selection: $settings.captureImages,
                 options: [(false, "Text only"), (true, "Text and images")])
        }
        caption("A screenshot takes more disk space than a month of copied text")
      }

      Section("Panel") {
        row("Close after picking") {
          Toggle("", isOn: $settings.closeAfterPick).labelsHidden()
        }
        caption("Off keeps the panel open so you can copy several entries in a row")
      }

      Section("Quick list") {
        row("Show entries from") {
          Picker("", selection: $settings.memoryDays) {
            ForEach(DayOption.all) { Text($0.title).tag($0.days) }
          }
          .labelsHidden()
          .fixedSize()
        }
        caption("Older entries stay on disk and are found by search, not deleted")
      }

      Section("Keep by size") {
        ForEach(SizeTier.allCases, id: \.self) { tier in
          row(tier.title,
              subtitle: "\(store.count(in: tier)) items · \(byteText(store.bytes(in: tier)))") {
            HStack(spacing: 8) {
              Picker("", selection: retention(tier)) {
                ForEach(DayOption.all) { Text($0.title).tag($0.days) }
              }
              .labelsHidden()
              .fixedSize()
              .frame(width: 124, alignment: .trailing)
              Button("Show") { onShowTier(tier) }
                .frame(width: 62)
                .disabled(store.count(in: tier) == 0)
              Button("Clear") {
                withAnimation(.easeOut(duration: 0.18)) { store.removeAll(in: tier) }
              }
              .frame(width: 62)
              .disabled(store.count(in: tier) == 0)
            }
          }
        }
      }

      Section("Hard limits") {
        row("Maximum items") {
          number($settings.maxItems, range: 100...5_000_000, step: 100)
        }
        row("Maximum total size") {
          HStack(spacing: 8) {
            DecimalField(value: totalSizeInUnit)
            Picker("", selection: $settings.totalSizeUnitIsGB) {
              Text("MB").tag(false)
              Text("GB").tag(true)
            }
            .labelsHidden()
            .fixedSize()
          }
        }
        row("Skip items larger than, MB") {
          number($settings.maxItemMB, range: 1...4000, step: 10)
        }
      }

      Section("Shortcut") {
        row("Open history") {
          Button(recording
                 ? "Press keys…"
                 : KeyName.describe(keyCode: settings.hotKeyCode,
                                    modifiers: settings.hotKeyModifiers)) {
            recording.toggle()
          }
          .buttonStyle(.bordered)
        }
        if recording {
          KeyRecorder { code, modifiers in
            settings.hotKeyCode = code
            settings.hotKeyModifiers = modifiers
            recording = false
            onHotKeyChange()
          }
          .frame(height: 0)
        }
      }

      Section("Appearance") {
        row("Theme") {
          Choice(selection: $settings.appearance,
                 options: Appearance.allCases.map { ($0, $0.title) })
        }
      }

      Section("Startup") {
        row("Launch at login") {
          Toggle("", isOn: $settings.launchAtLogin).labelsHidden()
        }
      }

      Section("Storage") {
        row("Everything",
            subtitle: "\(store.count) items · \(byteText(store.totalBytes))") {
          Button("Clear all", role: .destructive) {
            withAnimation(.easeOut(duration: 0.18)) { store.removeAll() }
          }
          .frame(width: 90)
        }
      }
    }
    .formStyle(.grouped)
    // The overlay scroller floats over the right edge and takes no width, so
    // the form gives back half of it on the left to look centred
    .padding(.leading, -ScrollerMetrics.overlay / 2)
    .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    .overlayScrollers()
    .animation(.easeOut(duration: 0.16), value: recording)
    .animation(.easeOut(duration: 0.16), value: store.generation)
    .animation(.easeOut(duration: 0.18), value: settings.captureImages)
    .animation(.easeOut(duration: 0.18), value: settings.appearance)
    .animation(.easeOut(duration: 0.18), value: settings.memoryDays)
    .animation(.easeOut(duration: 0.18), value: settings.totalSizeUnitIsGB)
  }

  private func row<Control: View>(_ title: String, subtitle: String? = nil,
                                  @ViewBuilder control: () -> Control) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        if let subtitle {
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 12)
      control().frame(width: controlWidth, alignment: .trailing)
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
  }

  private func number(_ value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
    HStack(spacing: 8) {
      DigitField(value: value, range: range)
      Stepper("", value: value, in: range, step: step).labelsHidden()
    }
  }

  private var totalSizeInUnit: Binding<Double> {
    Binding(
      get: {
        settings.totalSizeUnitIsGB
          ? Double(settings.maxTotalMB) / 1024
          : Double(settings.maxTotalMB)
      },
      set: { value in
        let mb = settings.totalSizeUnitIsGB ? value * 1024 : value
        settings.maxTotalMB = max(50, min(102400, Int(mb.rounded())))
      })
  }

  private func retention(_ tier: SizeTier) -> Binding<Int> {
    Binding(
      get: { settings.retention(for: tier) },
      set: { settings.retentionDays[tier] = $0 })
  }

  private func byteText(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
  }
}

/// Field for a whole number
///
/// TextField(value:format:) accepts letters and discards them on commit; here
/// anything that is not a digit never lands
private struct DigitField: View {
  @Binding var value: Int
  let range: ClosedRange<Int>
  @State private var text: String
  @FocusState private var editing: Bool

  init(value: Binding<Int>, range: ClosedRange<Int>) {
    _value = value
    self.range = range
    _text = State(initialValue: String(value.wrappedValue))
  }

  var body: some View {
    TextField("", text: $text)
      .textFieldStyle(.roundedBorder)
      .multilineTextAlignment(.trailing)
      .monospacedDigit()
      .frame(width: 90)
      .focused($editing)
      .onChange(of: text) { _, typed in
        let digits = String(typed.filter(\.isNumber).prefix(9))
        if digits != typed { text = digits }
      }
      // Bounds on commit, not per character: 2 on the way to 2000 is not a
      // request to keep two entries
      .onSubmit { commit() }
      .onChange(of: editing) { _, nowEditing in if !nowEditing { commit() } }
      .onChange(of: value) { _, now in if !editing { text = String(now) } }
  }

  private func commit() {
    value = min(max(Int(text) ?? value, range.lowerBound), range.upperBound)
    text = String(value)
  }
}

/// Field for a size: digits plus one decimal separator, . or ,
private struct DecimalField: View {
  @Binding var value: Double
  @State private var text: String
  @FocusState private var editing: Bool

  init(value: Binding<Double>) {
    _value = value
    _text = State(initialValue: Self.written(value.wrappedValue))
  }

  var body: some View {
    TextField("", text: $text)
      .textFieldStyle(.roundedBorder)
      .multilineTextAlignment(.trailing)
      .monospacedDigit()
      .frame(width: 90)
      .focused($editing)
      .onChange(of: text) { _, typed in
        var seen = false
        let kept = typed.prefix(12).filter { character in
          if character.isNumber { return true }
          guard character == "." || character == ",", !seen else { return false }
          seen = true
          return true
        }
        if kept != typed { text = String(kept) }
      }
      .onSubmit { commit() }
      .onChange(of: editing) { _, nowEditing in if !nowEditing { commit() } }
      .onChange(of: value) { _, now in if !editing { text = Self.written(now) } }
  }

  private func commit() {
    value = Double(text.replacingOccurrences(of: ",", with: ".")) ?? value
    text = Self.written(value)
  }

  /// Whole numbers without a fraction, the rest to one decimal place
  private static func written(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
  }
}

/// Exclusive options as separate pills, sized to their labels
///
/// .pickerStyle(.segmented) gives no say over the gap between its labels
private struct Choice<Value: Hashable>: View {
  @Binding var selection: Value
  let options: [(Value, String)]

  var body: some View {
    HStack(spacing: 6) {
      ForEach(options.indices, id: \.self) { index in
        pill(options[index].0, options[index].1)
      }
    }
  }

  private func pill(_ value: Value, _ title: String) -> some View {
    let picked = value == selection
    // The change comes from an ObservableObject, and .animation(value:) does
    // not fire on a re-render from outside, so the write carries the animation
    return Button {
      withAnimation(.easeOut(duration: 0.2)) { selection = value }
    } label: {
      // Both colours are drawn at once and cross-fade by opacity; one Text
      // switching foregroundStyle blinks instead
      ZStack {
        Text(title).foregroundStyle(Color.primary).opacity(picked ? 0 : 1)
        Text(title).foregroundStyle(Color.white).opacity(picked ? 1 : 0)
      }
      .font(.system(size: 12))
      .padding(.horizontal, 10)
      .padding(.vertical, 3)
      .background {
        ZStack {
          Capsule().fill(Color.primary.opacity(0.07))
          Capsule().strokeBorder(Color.primary.opacity(0.10)).opacity(picked ? 0 : 1)
          Capsule().fill(Color.accentColor).opacity(picked ? 1 : 0)
        }
      }
      .contentShape(Capsule())
    }
    .buttonStyle(PillPress())
  }
}

/// Press dims the pill, never the label: .buttonStyle(.plain) dims the whole
/// label, and text changing colour at the same time reads as a blink
private struct PillPress: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .brightness(configuration.isPressed ? -0.06 : 0)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

/// Captures the next key press with a modifier, for the shortcut recorder
private struct KeyRecorder: NSViewRepresentable {
  var onKey: (Int, Int) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = RecorderView()
    view.onKey = onKey
    DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class RecorderView: NSView {
    var onKey: ((Int, Int) -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
      var carbon = 0
      if event.modifierFlags.contains(.command) { carbon |= 256 }
      if event.modifierFlags.contains(.shift) { carbon |= 512 }
      if event.modifierFlags.contains(.option) { carbon |= 2048 }
      if event.modifierFlags.contains(.control) { carbon |= 4096 }
      guard carbon != 0 else { return }
      onKey?(Int(event.keyCode), carbon)
    }
  }
}
