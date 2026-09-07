import AppKit
import ImageIO
import UniformTypeIdentifiers

enum Thumbnail {
  static let side = 200

  /// AVIF where the system encodes it, JPEG otherwise
  ///
  /// At 200 pt AVIF is ~1.5 KB against ~3.5 KB for JPEG, at 4 ms to encode
  /// against 0.1 ms. Encoding runs off the main thread, decoding is equal
  static let format: (id: String, ext: String) = {
    let available = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
    let avif = "public.avif"
    return available.contains(avif) ? (avif, "avif") : (UTType.jpeg.identifier, "jpg")
  }()

  static func make(from image: CGImage) -> Data? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    let scale = min(Double(side) / Double(width), Double(side) / Double(height), 1)
    let w = max(1, Int(Double(width) * scale))
    let h = max(1, Int(Double(height) * scale))

    guard let ctx = CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
    else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let scaled = ctx.makeImage() else { return nil }

    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
      out, format.id as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, scaled,
                               [kCGImageDestinationLossyCompressionQuality: 0.4] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
  }
}

/// Decoded thumbnails, 300 most recently decoded
///
/// Eviction is by insertion order: a cache hit does not move an entry
@MainActor
final class ThumbnailCache {
  static let shared = ThumbnailCache()
  private var cache: [UUID: NSImage] = [:]
  private var order: [UUID] = []
  private let limit = 300

  func image(for id: UUID, url: URL) -> NSImage? {
    if let hit = cache[id] { return hit }
    guard let image = NSImage(contentsOf: url) else { return nil }
    cache[id] = image
    order.append(id)
    if order.count > limit {
      let evicted = order.removeFirst()
      cache[evicted] = nil
    }
    return image
  }

  func drop(_ id: UUID) {
    cache[id] = nil
    order.removeAll { $0 == id }
  }
}
