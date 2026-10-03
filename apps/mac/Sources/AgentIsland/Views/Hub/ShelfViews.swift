import AppKit
import IslandCore
import SwiftUI
import UniformTypeIdentifiers

/// What the shelf accepts: files, and images or text to keep as files.
let shelfDropTypes: [UTType] = [.fileURL, .image, .plainText, .utf8PlainText, .data]

/// The whole island while files are dragged at the notch, split side by
/// side: keep them in Files, AirDrop them now, or hand their paths to the
/// agent you're working with.
struct ShelfDropZone: View {
  let model: IslandModel

  var body: some View {
    let shelf = model.shelf
    let agent = model.promptTarget
    HStack(spacing: 8) {
      DropSplit(id: "files", title: "Files", targeted: shelf.targeted == "files", model: model) {
        Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 20, weight: .medium))
      } drop: { urls in
        shelf.add(urls: urls)
      }
      DropSplit(id: "airdrop", title: "AirDrop", targeted: shelf.targeted == "airdrop", model: model) {
        Glyph(Glyph.airdrop, size: 20, weight: .medium)
      } drop: { urls in
        shelf.airDrop(urls: urls)
      }
      if let agent {
        DropSplit(id: "agent", title: agent.agent.shortName, targeted: shelf.targeted == "agent", model: model) {
          AgentMarkView(agent: agent.agent, size: 20, color: .white)
        } drop: { urls in
          _ = model.actions.insertPaths(urls.map(\.path), into: agent)
        }
      }
    }
    .frame(width: agent == nil ? 300 : 420, height: 96)
    .padding(.init(top: 8, leading: 10, bottom: 12, trailing: 10))
  }
}

/// One split of the drop zone: a glyph and a word, lit while the drag is over it.
private struct DropSplit<Glyph: View>: View {
  let id: String
  let title: String
  let targeted: Bool
  let model: IslandModel
  @ViewBuilder let glyph: Glyph
  let drop: ([URL]) -> Void

  var body: some View {
    let shelf = model.shelf
    ZStack {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Palette.accent.opacity(targeted ? 0.22 : 0.06))
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(Palette.accent.opacity(targeted ? 0.95 : 0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
      VStack(spacing: 6) {
        glyph.foregroundStyle(targeted ? .white : Palette.accent)
        Text(title).islandFont(11, weight: .semibold).foregroundStyle(targeted ? .white : Palette.text)
      }
      .scaleEffect(targeted ? 1.08 : 1)
    }
    .animation(.easeOut(duration: 0.14), value: targeted)
    .contentShape(Rectangle())
    .onDrop(
      of: shelfDropTypes,
      isTargeted: Binding(get: { targeted }, set: { on in
        if on { shelf.targeted = id } else if shelf.targeted == id { shelf.targeted = nil }
      })
    ) { providers in
      Task {
        let urls = await shelf.collect(providers)
        drop(urls)
      }
      shelf.dragActive = false
      shelf.targeted = nil
      return true
    }
  }
}

/// The Shelf tab: everything parked, with its actions.
struct ShelfTab: View {
  let model: IslandModel

  var body: some View {
    let shelf = model.shelf
    let agent = model.promptTarget
    SplitPane(leftWidth: 84) {
      // Left: round keys; with files picked they act on those, else on all.
      VStack(spacing: 8) {
        CircleKey(symbol: "plus", caption: "Add", size: 40, label: "Add files") { shelf.choose() }
        if !shelf.items.isEmpty {
          Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
              CircleKey(symbol: Glyph.airdrop, size: 28, label: "AirDrop") { shelf.airDrop(shelf.chosen.map(\.id)) }
              CircleKey(symbol: "doc.on.doc", size: 28, label: "Copy paths") { shelf.copyPaths(shelf.chosen) }
            }
            GridRow {
              if let agent {
                CircleKey(symbol: "terminal", size: 28, label: "Paths to \(agent.agent.shortName)") {
                  _ = model.actions.insertPaths(shelf.chosen.map(\.path), into: agent)
                }
              } else {
                DragAllHandle(urls: shelf.chosen.map(\.url)).frame(width: 28, height: 28).background(Circle().fill(.white.opacity(0.08))).help("Drag out")
              }
              CircleKey(symbol: "trash", size: 28, label: shelf.selection.isEmpty ? "Clear all" : "Remove picked") {
                if shelf.selection.isEmpty { shelf.clear() } else { for item in shelf.chosen { shelf.remove(item.id) } }
              }
            }
          }
          if !shelf.selection.isEmpty {
            Button { shelf.selection.removeAll() } label: {
              Text("\(shelf.selection.count) picked").islandFont(9, weight: .semibold).foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            .help("Unpick")
          }
        }
      }
      .frame(maxWidth: .infinity)
    } right: {
      if shelf.items.isEmpty {
        VStack(spacing: 6) {
          Image(systemName: "tray.and.arrow.down").font(.system(size: 22, weight: .light)).foregroundStyle(Palette.textDim)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
      } else {
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], spacing: 6) {
            ForEach(shelf.items) { item in
              ShelfTile(model: model, item: item)
            }
          }
        }
        .frame(maxHeight: 200)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .onDrop(of: shelfDropTypes, isTargeted: nil) { providers in
      shelf.add(providers)
      return true
    }
  }
}

private struct ShelfTile: View {
  let model: IslandModel
  let item: ShelfItem

  var body: some View {
    let shelf = model.shelf
    let picked = shelf.selection.contains(item.id)
    Hovering { hovered in
      VStack(spacing: 3) {
        Image(nsImage: shelf.icon(item))
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 40, height: 40)
        Text(item.name).islandFont(9.5).foregroundStyle(hovered ? Palette.text : Palette.textDim).lineLimit(1).truncationMode(.middle)
      }
      .frame(width: 76, height: 66)
      .background(RoundedRectangle(cornerRadius: 9).fill(picked ? Palette.accent.opacity(0.22) : .white.opacity(hovered ? 0.08 : 0.03)))
      .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(picked ? Palette.accent.opacity(0.8) : .clear, lineWidth: 1.2))
      .overlay(alignment: .topTrailing) {
        if hovered {
          HStack(spacing: 0) {
            MiniKey(symbol: Glyph.airdrop, label: "AirDrop") { shelf.airDrop([item.id]) }
            MiniKey(symbol: "xmark", label: "Remove from the shelf") { shelf.remove(item.id) }
          }
          .padding(2)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture(count: 2) { shelf.open(item.id) }
      .onTapGesture { shelf.toggleSelection(item.id) }
      .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
      .contextMenu {
        Button("Open") { shelf.open(item.id) }
        Button("Show in Finder") { shelf.reveal(item.id) }
        Button("AirDrop") { shelf.airDrop([item.id]) }
        Divider()
        Button("Remove from Shelf") { shelf.remove(item.id) }
      }
      .help(item.name)
    }
  }
}

/// A tiny round key over a tile.
struct MiniKey: View {
  let symbol: String
  let label: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Glyph(symbol, size: 8, weight: .bold)
        .foregroundStyle(.white)
        .frame(width: 16, height: 16)
        .background(Circle().fill(.black.opacity(0.75)))
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
  }
}

/// Drags every URL at once, as one stack (SwiftUI's drag carries only one).
struct DragAllHandle: NSViewRepresentable {
  let urls: [URL]

  func makeNSView(context: Context) -> DragAllView {
    let view = DragAllView()
    view.urls = urls
    return view
  }

  func updateNSView(_ view: DragAllView, context: Context) {
    view.urls = urls
  }
}

final class DragAllView: NSView, NSDraggingSource {
  var urls: [URL] = []

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    let image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Drag all")
    let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
    guard let symbol = image?.withSymbolConfiguration(config) else { return }
    let tinted = NSImage(size: symbol.size, flipped: false) { rect in
      symbol.draw(in: rect)
      NSColor.white.withAlphaComponent(0.72).set()
      rect.fill(using: .sourceAtop)
      return true
    }
    let origin = CGPoint(x: (bounds.width - symbol.size.width) / 2, y: (bounds.height - symbol.size.height) / 2)
    tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
  }

  override func mouseDragged(with event: NSEvent) {
    guard !urls.isEmpty else { return }
    let items = urls.enumerated().map { index, url in
      let item = NSDraggingItem(pasteboardWriter: url as NSURL)
      let icon = NSWorkspace.shared.icon(forFile: url.path)
      item.setDraggingFrame(CGRect(x: CGFloat(index) * 4, y: CGFloat(index) * -4, width: 32, height: 32), contents: icon)
      return item
    }
    beginDraggingSession(with: items, event: event, source: self)
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    context == .outsideApplication ? [.copy, .move, .link, .generic] : .copy
  }
}
