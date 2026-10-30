import AppKit
import IslandCore
import SwiftUI

/// Under the sessions, one quiet line per session with something to say: how
/// full its context is and what it has cost, what it has changed in its repo,
/// how its last test or build went, and the servers it started. Then any
/// other dev servers running. Click a project to jump to it, a server to open it.
struct DevStrip: View {
  let model: IslandModel

  var body: some View {
    let sessions = model.sessions.sessions.filter { hasNews($0) }
    let others = model.dev.servers.filter { $0.sessionKey == nil }
    if !sessions.isEmpty || !others.isEmpty {
      VStack(alignment: .leading, spacing: 5) {
        ForEach(sessions, id: \.key) { session in
          SessionDevLine(session: session, model: model)
        }
        if !others.isEmpty {
          HStack(spacing: 6) {
            Text("Servers").foregroundStyle(Palette.textDim)
            ForEach(others) { ServerChip(server: $0, model: model) }
          }
        }
      }
      .islandFont(10.5, weight: .medium)
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.init(top: 2, leading: 12, bottom: 6, trailing: 12))
      .modifier(Entrance(kind: .rowIn, delay: 0.08))
    }
  }

  private func hasNews(_ session: SessionSnapshot) -> Bool {
    session.meta["context_pct"] != nil || session.meta["cost_usd"] != nil || session.meta["check"] != nil
      || model.dev.changes[session.cwd].map { !$0.isEmpty } == true
      || model.dev.servers.contains { $0.sessionKey == session.key }
  }
}

private struct SessionDevLine: View {
  let session: SessionSnapshot
  let model: IslandModel

  var body: some View {
    HStack(spacing: 8) {
      Button { JumpBack.jump(to: session) } label: {
        Text(session.projectName).foregroundStyle(Palette.text.opacity(0.85))
      }
      .buttonStyle(.plain)
      .help("Jump to \(session.projectName)")
      if let used = session.meta["context_pct"]?.number {
        let tint = used >= 92 ? Palette.failed : used >= SessionStats.compactSoon ? Palette.waiting : Palette.textDim
        Text("ctx \(Int(used.rounded()))%")
          .foregroundStyle(tint)
          .help(used >= SessionStats.compactSoon ? "Context is \(Int(used))% full: worth a /compact soon" : "Context window \(Int(used))% used")
      }
      if let cost = session.meta["cost_usd"]?.number {
        Text(cost < 0.01 ? "<$0.01" : String(format: "$%.2f", cost))
          .foregroundStyle(Palette.textDim)
          .help("Estimated cost of this session so far")
      }
      if let diff = model.dev.changes[session.cwd], !diff.isEmpty {
        HStack(spacing: 3) {
          Text("+\(diff.added)").foregroundStyle(Palette.done.opacity(0.9))
          Text("−\(diff.removed)").foregroundStyle(Palette.failed.opacity(0.9))
        }
        .help("\(diff.files) file\(diff.files == 1 ? "" : "s") changed, not yet committed")
      }
      if let check = session.meta["check"]?.string.flatMap(DevCheck.init(rawValue:)) {
        let ok = session.meta["check_ok"] == .bool(true)
        Button { JumpBack.jump(to: session) } label: {
          HStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            Text(check.label)
          }
          .foregroundStyle(ok ? Palette.done : Palette.failed)
        }
        .buttonStyle(.plain)
        .help("\(ok ? "Passed" : "Failed"): \(session.meta["check_command"]?.string ?? check.label)")
      }
      ForEach(model.dev.servers.filter { $0.sessionKey == session.key }) { ServerChip(server: $0, model: model) }
    }
    .monospacedDigit()
  }
}

/// `:3000` opens it in the browser; hover for a stop button, which asks once.
private struct ServerChip: View {
  let server: DevServer
  let model: IslandModel

  /// Not `@State`: the macro needs Xcode's plugins (see `Entrance`).
  private let confirmingState = State(initialValue: false)
  private var confirming: Bool { confirmingState.wrappedValue }

  var body: some View {
    Hovering { hovered in
      HStack(spacing: 4) {
        Button {
          if let url = server.url { NSWorkspace.shared.open(url) }
        } label: {
          HStack(spacing: 3) {
            Circle().fill(Palette.done).frame(width: 5, height: 5)
            Text(verbatim: ":\(server.port)")
          }
          .foregroundStyle(Palette.text.opacity(hovered ? 1 : 0.8))
        }
        .buttonStyle(.plain)
        .help("Open \(server.address) — \(server.command)\(server.project.map { " in \($0)" } ?? "")")
        if hovered || confirming {
          Button {
            if confirming { model.dev.stop(server) } else { confirmingState.wrappedValue = true }
          } label: {
            Text(confirming ? "Stop?" : "×").foregroundStyle(confirming ? Palette.failed : Palette.textDim)
          }
          .buttonStyle(.plain)
          .help("Stop \(server.command) on \(server.address)")
        }
      }
      .padding(.init(top: 2, leading: 6, bottom: 2, trailing: 6))
      .background(Capsule().fill(.white.opacity(hovered ? 0.1 : 0.06)))
      .onChange(of: hovered) { _, now in if !now { confirmingState.wrappedValue = false } }
    }
  }
}
