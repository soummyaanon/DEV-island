import AppKit
import Foundation
import IslandCore
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Files parked on the notch. A dropped file stays where it is (the shelf
/// keeps its path); a dragged image or text snippet with no file behind it is
/// written to the island's own folder, and deleted when it leaves the shelf.
/// Everything stays on this Mac; AirDrop sends only when you press it.
@Observable
final class FileShelf {
  private(set) var items: [ShelfItem] = []
  /// A file drag is near the notch: the island opens as a drop zone.
  var dragActive = false
  /// Which split of the drop zone the drag is over ("files", "airdrop", "agent").
  var targeted: String?
  /// Items picked in the Files tab; actions apply to these, else to all.
  var selection: Set<UUID> = []

  /// The picked items, or everything when nothing is picked.
  var chosen: [ShelfItem] { selection.isEmpty ? items : items.filter { selection.contains($0.id) } }

  func toggleSelection(_ id: UUID) {
    if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
  }
  private(set) var thumbnails: [UUID: NSImage] = [:]

  init() {
    load()
  }

  // MARK: Adding

  /// Takes whatever was dropped: files by reference, images and text as new files.
  func add(_ providers: [NSItemProvider]) {
    Task { add(urls: await collect(providers)) }
  }

  /// Resolves dropped things to files: a file stays where it is; an image or
  /// text without one is written to the shelf's folder (and parked there).
  func collect(_ providers: [NSItemProvider]) async -> [URL] {
    var urls: [URL] = []
    for provider in providers {
      if let url = await resolve(provider) { urls.append(url) }
    }
    return urls
  }

  private func resolve(_ provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
      resolve(provider) { url in done.resume(returning: url) }
    }
  }

  private func resolve(_ provider: NSItemProvider, _ done: @escaping @Sendable (URL?) -> Void) {
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        done(url?.isFileURL == true ? url : nil)
      }
    } else if let type = [UTType.png, .jpeg, .tiff, .heic, .image].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
      provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { [weak self] data, _ in
        guard let data else { return done(nil) }
        let ext = type == .image || type == .tiff ? "png" : (type.preferredFilenameExtension ?? "png")
        let payload = type == .tiff || type == .image ? (NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data) : data
        Task { @MainActor in done(self?.write(payload, named: "Image.\(ext)")) }
      }
    } else if provider.canLoadObject(ofClass: String.self) {
      _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
        guard let text, !text.isEmpty else { return done(nil) }
        Task { @MainActor in done(self?.write(Data(text.utf8), named: Self.snippetName(text))) }
      }
    } else if let type = provider.registeredTypeIdentifiers.first {
      // A file promise (Mail, Photos): the provider hands over a temporary copy.
      provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, _ in
        guard let url, let data = try? Data(contentsOf: url) else { return done(nil) }
        let name = url.lastPathComponent
        Task { @MainActor in done(self?.write(data, named: name)) }
      }
    } else {
      done(nil)
    }
  }

  /// Files picked with the open panel, from the notch's + key.
  func choose() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = true
    panel.prompt = "Add to Files"
    NSApp.activate()
    panel.begin { [weak self] response in
      guard response == .OK else { return }
      let urls = panel.urls
      Task { @MainActor in self?.add(urls: urls) }
    }
  }

  /// AirDrop for files that needn't be on the shelf (a drop on the AirDrop split).
  func airDrop(urls: [URL]) {
    guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
      NSSound.beep()
      return
    }
    NSApp.activate()
    service.perform(withItems: urls)
  }

  func copyPaths(_ items: [ShelfItem]) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
  }

  func add(urls: [URL]) {
    var next = items
    for url in urls where FileManager.default.fileExists(atPath: url.path) {
      next = shelfAdding(next, path: url.standardizedFileURL.path)
    }
    guard next != items else { return }
    items = next
    save()
    thumbnail(items)
  }

  @discardableResult
  private func write(_ data: Data, named wanted: String) -> URL? {
    let folder = ShelfItem.folder
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    let url = folder.appending(path: ShelfItem.freeName(wanted, existing: existing))
    do { try data.write(to: url, options: .atomic) } catch { return nil }
    items = shelfAdding(items, path: url.path, owned: true)
    save()
    thumbnail(items)
    return url
  }

  private static func snippetName(_ text: String) -> String {
    let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(4).joined(separator: " ")
    return (words.isEmpty ? "Snippet" : String(words.prefix(40))) + ".txt"
  }

  // MARK: Removing

  func remove(_ id: UUID) {
    guard let item = items.first(where: { $0.id == id }) else { return }
    if item.owned { try? FileManager.default.removeItem(at: item.url) }
    items.removeAll { $0.id == id }
    thumbnails[id] = nil
    selection.remove(id)
    save()
  }

  func clear() {
    for item in items { remove(item.id) }
  }

  // MARK: Acting

  /// AirDrop: the system's own picker, for one item or all of them.
  func airDrop(_ ids: [UUID]? = nil) {
    let urls = items.filter { ids?.contains($0.id) ?? true }.map(\.url)
    guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
      NSSound.beep()
      return
    }
    NSApp.activate()
    service.perform(withItems: urls)
  }

  func reveal(_ id: UUID) {
    guard let item = items.first(where: { $0.id == id }) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([item.url])
  }

  func open(_ id: UUID) {
    guard let item = items.first(where: { $0.id == id }) else { return }
    NSWorkspace.shared.open(item.url)
  }

  func icon(_ item: ShelfItem) -> NSImage {
    thumbnails[item.id] ?? NSWorkspace.shared.icon(forFile: item.path)
  }

  // MARK: Storage

  private func load() {
    guard let data = try? Data(contentsOf: ShelfItem.indexURL) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let stored = (try? decoder.decode([ShelfItem].self, from: data)) ?? []
    // A file moved or deleted since is dropped quietly.
    items = stored.filter { FileManager.default.fileExists(atPath: $0.path) }
    thumbnail(items)
  }

  private func save() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(items) else { return }
    try? FileManager.default.createDirectory(at: ShelfItem.indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: ShelfItem.indexURL, options: .atomic)
  }

  /// Quick Look thumbnails, for images, PDFs and documents.
  private func thumbnail(_ items: [ShelfItem]) {
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    for item in items where thumbnails[item.id] == nil {
      let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 64, height: 64), scale: scale, representationTypes: .thumbnail)
      let id = item.id
      QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
        guard let image = thumbnail?.nsImage else { return }
        Task { @MainActor in self?.thumbnails[id] = image }
      }
    }
  }
}
