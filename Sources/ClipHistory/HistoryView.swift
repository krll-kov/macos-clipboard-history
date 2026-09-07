import AppKit
import Combine
import SwiftUI

/// Button press: dims to 0.55 and scales to 0.94 over 0.12 s
struct SoftButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.55 : 1)
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

struct HistoryView: View {
  @ObservedObject var store = ClipboardStore.shared
  @ObservedObject var filter = HistoryFilter.shared
  @ObservedObject var inset = ListInset.shared
  @State private var query = ""
  @State private var selection: UUID?
  @State private var hovered: UUID?
  @State private var settingsHovered = false
  @State private var centerHovered = false
  @State private var pressed: UUID?
  /// The selection ring is drawn only after an arrow key, so a freshly opened
  /// panel has nothing highlighted
  @State private var keyboardActive = false
  /// task_info, refreshed on the 5 s ticker rather than per redraw
  @State private var ram = 0
  @FocusState private var searchFocused: Bool

  private let usageTicker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

  var onPick: (ClipItem) -> Void
  var onClose: () -> Void
  var onSettings: () -> Void
  var onCenter: () -> Void

  private var results: [ClipItem] {
    store.rows(matching: query, tier: filter.tier)
  }

  var body: some View {
    VStack(spacing: 0) {
      searchBar
      Divider()
      Group {
        if results.isEmpty { empty } else { list }
      }
      .transition(.opacity)
      .animation(.easeOut(duration: 0.14), value: results.isEmpty)
      Divider()
      footer
    }
    .frame(width: 620, height: 460)
    // The blur is PanelBackdrop behind this view; this tint keeps a light panel
    // over a dark desktop from reading as grey
    .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.12))
    )
    .onAppear {
      searchFocused = true
      selection = results.first?.id
      keyboardActive = false
      ram = ProcessMemory.footprint
    }
    .onReceive(usageTicker) { _ in ram = ProcessMemory.footprint }
  }

  private var searchBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Search history", text: $query)
        .textFieldStyle(.plain)
        .font(.system(size: 15))
        .focused($searchFocused)
        .onSubmit { if let item = current { onPick(item) } }
        .onChange(of: query) { _, _ in selection = results.first?.id }
        .onKeyPress(.downArrow) { keyboardActive = true; move(1); return .handled }
        .onKeyPress(.upArrow) { keyboardActive = true; move(-1); return .handled }
      // Always in the row: appearing on the first letter took its width out of
      // the field and shifted the text already typed
      Button {
        query = ""
      } label: {
        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .opacity(query.isEmpty ? 0 : 1)
      .allowsHitTesting(!query.isEmpty)
      .animation(.easeOut(duration: 0.12), value: query.isEmpty)
      Divider().frame(height: 18).padding(.horizontal, 2)
      barButton("scope", hovered: $centerHovered, help: "Center window", action: onCenter)
      barButton("gearshape.fill", hovered: $settingsHovered, help: "Settings",
                action: onSettings)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
  }

  /// Both hover states are drawn at once and cross-fade by opacity
  ///
  /// foregroundStyle swapped on one Image gives SwiftUI nothing to interpolate
  /// when the change arrives with the view rebuilt, and the button snaps
  private func barButton(_ symbol: String, hovered: Binding<Bool>, help: String,
                         action: @escaping () -> Void) -> some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    return Button(action: action) {
      ZStack {
        shape.fill(Color.primary.opacity(0.07))
        shape.fill(Color.primary.opacity(0.07)).opacity(hovered.wrappedValue ? 1 : 0)
        shape.strokeBorder(Color.primary.opacity(0.10))
        ZStack {
          Image(systemName: symbol).foregroundStyle(Color.secondary)
          Image(systemName: symbol).foregroundStyle(Color.primary)
            .opacity(hovered.wrappedValue ? 1 : 0)
        }
        .font(.system(size: 14, weight: .medium))
      }
      .frame(width: 30, height: 30)
      .animation(.easeOut(duration: 0.14), value: hovered.wrappedValue)
    }
    .buttonStyle(SoftButtonStyle())
    .onHover { hovered.wrappedValue = $0 }
    .help(help)
  }

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 6) {
          ForEach(results) { item in
            row(item)
              .id(item.id)
              .contentShape(Rectangle())
              .opacity(pressed == item.id ? 0.55 : 1)
              .scaleEffect(pressed == item.id ? 0.985 : 1)
              .animation(.easeOut(duration: 0.12), value: pressed)
              .onTapGesture {
                selection = item.id
                onPick(item)
              }
              .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                  .onChanged { _ in if pressed != item.id { pressed = item.id } }
                  .onEnded { _ in pressed = nil }
              )
              .onHover { inside in
                if inside {
                  hovered = item.id
                  keyboardActive = false
                } else if hovered == item.id {
                  hovered = nil
                }
              }
              .contextMenu {
                Button("Copy") { onPick(item) }
                Button("Delete") { store.remove(item) }
              }
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // 15 pt the scroller took but SwiftUI did not account for, so a card
        // ends on the same edge whether the list scrolls or not
        .padding(.trailing, inset.overhang)
      }
      .visibleScrollers()
      // Animated only for the arrow keys: when the selection moved because a
      // new search replaced the list, there is nothing to slide from
      .onChange(of: selection) { _, id in
        guard let id else { return }
        if keyboardActive {
          withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
        } else {
          proxy.scrollTo(id, anchor: .top)
        }
      }
    }
  }

  private func row(_ item: ClipItem) -> some View {
    HStack(spacing: 10) {
      icon(item)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.kind == .text ? oneLine(item.preview) : item.preview)
          .lineLimit(1)
          .font(.system(size: 13))
        Text(subtitle(item))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Button {
        store.remove(item)
      } label: {
        Image(systemName: "trash")
          .font(.system(size: 12))
          .frame(width: 26, height: 26)
          .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
      }
      .buttonStyle(SoftButtonStyle())
      .help("Delete")
      .opacity(hovered == item.id ? 1 : 0)
      .animation(.easeOut(duration: 0.14), value: hovered)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 8)
    .background(background(item), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .animation(.easeOut(duration: 0.12), value: selection)
    .animation(.easeOut(duration: 0.12), value: keyboardActive)
    .animation(.easeOut(duration: 0.10), value: hovered)
  }

  private func background(_ item: ClipItem) -> Color {
    if keyboardActive, selection == item.id { return Color.accentColor.opacity(0.20) }
    if hovered == item.id { return Color.primary.opacity(0.07) }
    return .clear
  }

  @ViewBuilder
  private func icon(_ item: ClipItem) -> some View {
    if item.kind == .image,
       let url = store.thumbURL(for: item) ?? store.fileURL(for: item),
       let image = ThumbnailCache.shared.image(for: item.id, url: url) {
      Image(nsImage: image)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        // A hairline, or a screenshot of a white window has no edge
        .overlay(
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
        )
    } else {
      Image(systemName: item.kind == .text ? "text.alignleft" : "photo")
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .frame(width: 34, height: 34)
        .background(Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
        )
    }
  }

  private var empty: some View {
    VStack(spacing: 6) {
      Spacer()
      Image(systemName: "clipboard").font(.system(size: 28)).foregroundStyle(.tertiary)
      Text(store.count == 0 ? "Nothing copied yet" : "No matches")
        .foregroundStyle(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Text(scopeText)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .help("Space the history takes on disk, and the memory the app is using")
      if let tier = filter.tier {
        Button {
          withAnimation(.easeOut(duration: 0.14)) { filter.tier = nil }
        } label: {
          HStack(spacing: 4) {
            Text(tier.title)
            Image(systemName: "xmark.circle.fill")
          }
          .font(.system(size: 11))
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(Color.primary.opacity(0.10), in: Capsule())
        }
        .buttonStyle(SoftButtonStyle())
        .help("Clear filter")
      }
      Spacer()
      Text("↵ paste · esc close")
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  private var scopeText: String {
    let scope: String
    if query.isEmpty {
      let shown = results.count
      let all = store.count
      scope = shown == all ? "\(all) items" : "\(shown) recent of \(all)"
    } else {
      scope = "\(results.count) matches in \(store.count) items"
    }
    // The same figure the settings show for Everything, from the totals table
    return "\(scope) · \(byteText(store.totalBytes)) on disk · \(byteText(ram)) RAM"
  }

  private var current: ClipItem? {
    results.first { $0.id == selection } ?? results.first
  }

  private func move(_ step: Int) {
    guard !results.isEmpty else { return }
    let index = results.firstIndex { $0.id == selection } ?? -1
    selection = results[min(max(index + step, 0), results.count - 1)].id
  }

  /// Collapses whitespace for the one line the row has
  private func oneLine(_ s: String) -> String {
    s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// Date and size, plus the source for pictures, where the label alone says
  /// nothing about where it came from
  private func subtitle(_ item: ClipItem) -> String {
    var parts = [Self.stamp.string(from: item.date), byteText(item.bytes)]
    if item.kind == .image, let source = item.source { parts.append(source) }
    return parts.joined(separator: " · ")
  }

  private func byteText(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
  }

  private static let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .short
    return f
  }()
}
