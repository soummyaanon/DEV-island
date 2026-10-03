import AppKit
import Foundation
import IslandCore
import Observation

/// Recent copies, text and images, kept in memory only (never written to
/// disk) and gone when the app quits. Password managers' items, anything an
/// app marks concealed, and text that looks like a secret are never kept.
@Observable
final class ClipboardHistory {
  nonisolated struct Clip: Equatable, Sendable, Identifiable {
    let id: UUID
    var text: String?
    var image: Data?
    var imageType: String?
    /// Files copied in Finder, by path.
    var files: [String]?
    let date: Date
    var source: String?

    /// The same content, whatever its id or time: copying it again moves it up.
    static func == (a: Clip, b: Clip) -> Bool {
      a.text == b.text && a.files == b.files && a.image?.count == b.image?.count && a.image == b.image
    }

    enum Kind: String, CaseIterable, Sendable { case text, link, image, file }

    var kind: Kind {
      if image != nil { return .image }
      if files != nil { return .file }
      if let text, Self.isLink(text) { return .link }
      return .text
    }

    static func isLink(_ text: String) -> Bool {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
      return ["http", "https", "mailto", "ftp"].contains(scheme) && (url.host() != nil || scheme == "mailto")
    }
  }

  /// Which kinds the list shows; nil is everything.
  var filter: Clip.Kind?

  var shown: [Clip] { filter.map { kind in clips.filter { $0.kind == kind } } ?? clips }

  private(set) var log = ClipboardLog<Clip>(limit: 30)
  private(set) var thumbnails: [UUID: NSImage] = [:]
  /// Items skipped as private since launch, so the list can say so.
  private(set) var skipped = 0
  var paused = false

  var clips: [Clip] { log.items }

  @ObservationIgnored private var poll: Task<Void, Never>?
  @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount

  static let maxImageBytes = 12 * 1024 * 1024

  func start() {
    guard poll == nil else { return }
    lastChange = NSPasteboard.general.changeCount
    // The pasteboard has no change notification; a counter read is nearly free.
    poll = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(750))
        self?.check()
      }
    }
  }

  func stop() {
    poll?.cancel()
    poll = nil
    log.clear()
    thumbnails.removeAll()
  }

  private func check() {
    let pasteboard = NSPasteboard.general
    guard pasteboard.changeCount != lastChange else { return }
    lastChange = pasteboard.changeCount
    guard !paused else { return }
    let types = pasteboard.types?.map(\.rawValue) ?? []
    let front = NSWorkspace.shared.frontmostApplication
    if ClipboardPrivacy.skips(types: types, sourceBundle: front?.bundleIdentifier) {
      skipped += 1
      return
    }
    let source = front?.localizedName
    // Files copied in Finder: kept as their paths, to copy again or drag out.
    if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
      let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
      if !urls.isEmpty {
        log.add(Clip(id: UUID(), files: urls.map(\.path), date: .now, source: source))
        pruneThumbnails()
      }
      return
    }
    if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard !ClipboardPrivacy.looksSensitive(text) else {
        skipped += 1
        return
      }
      log.add(Clip(id: UUID(), text: String(text.prefix(20_000)), date: .now, source: source))
      return
    }
    for type in [NSPasteboard.PasteboardType.png, .tiff] {
      guard let data = pasteboard.data(forType: type), data.count <= Self.maxImageBytes else { continue }
      let clip = Clip(id: UUID(), image: data, imageType: type.rawValue, date: .now, source: source)
      log.add(clip)
      if let kept = log.items.first, thumbnails[kept.id] == nil, let image = NSImage(data: data) { thumbnails[kept.id] = image }
      pruneThumbnails()
      return
    }
  }

  /// Puts a clip back on the clipboard; it moves to the top.
  func copy(_ clip: Clip) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if let files = clip.files {
      pasteboard.writeObjects(files.map { URL(filePath: $0) as NSURL })
    } else if let text = clip.text {
      pasteboard.setString(text, forType: .string)
    } else if let image = clip.image, let type = clip.imageType {
      pasteboard.setData(image, forType: NSPasteboard.PasteboardType(type))
    }
    log.add(Clip(id: clip.id, text: clip.text, image: clip.image, imageType: clip.imageType, files: clip.files, date: .now, source: clip.source))
    lastChange = pasteboard.changeCount
  }

  func remove(_ id: UUID) {
    log.remove { $0.id == id }
    thumbnails[id] = nil
  }

  func clear() {
    log.clear()
    thumbnails.removeAll()
  }

  private func pruneThumbnails() {
    let alive = Set(log.items.map(\.id))
    thumbnails = thumbnails.filter { alive.contains($0.key) }
  }
}
