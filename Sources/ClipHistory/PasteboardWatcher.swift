import AppKit

@MainActor
final class PasteboardWatcher {
  private let pasteboard = NSPasteboard.general
  private var changeCount: Int
  private var timer: Timer?
  private let queue = DispatchQueue(label: "dev.swiftsoft.cliphistory.capture", qos: .utility)

  init() {
    changeCount = pasteboard.changeCount
  }

  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func poll() {
    guard pasteboard.changeCount != changeCount else { return }
    changeCount = pasteboard.changeCount
    guard pasteboard.string(forType: .init("org.nspasteboard.ConcealedType")) == nil else { return }

    let source = currentSource()
    if let text = pasteboard.string(forType: .string) {
      ClipboardStore.shared.add(text: text, source: source)
      return
    }
    guard Settings.shared.captureImages else { return }
    // One representation: the pasteboard offers the same image in half a dozen
    // encodings
    guard let image = NSImage(pasteboard: pasteboard),
          let tiff = image.tiffRepresentation
    else { return }

    // PNG encoding runs off the main thread: a large paste would stall the UI
    queue.async {
      guard let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:]),
            let cg = rep.cgImage
      else { return }
      let thumb = Thumbnail.make(from: cg)
      let label = "Image \(rep.pixelsWide)×\(rep.pixelsHigh)"
      Task { @MainActor in
        ClipboardStore.shared.add(png: png, thumb: thumb, label: label, source: source)
      }
    }
  }

  /// Where the copy came from
  ///
  /// A screen capture announces itself on the pasteboard, anything else is
  /// credited to the frontmost app. The panel never activates, so it is never
  /// credited itself
  private func currentSource() -> String? {
    if pasteboard.types?.contains(where: { $0.rawValue.contains("screencapture") }) == true {
      return "Screenshot"
    }
    return NSWorkspace.shared.frontmostApplication?.localizedName
  }
}
