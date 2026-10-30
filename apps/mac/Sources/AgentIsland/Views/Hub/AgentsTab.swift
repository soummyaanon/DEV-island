import IslandCore
import SwiftUI

/// Claude Code and Codex at a glance: today on the left, the week on the right.
struct AgentsTab: View {
  let model: IslandModel
  let now: Date

  var body: some View {
    let stats = model.agentStats.stats
    let today = stats.today(now: now)
    let quotas = QuotaSummary.from(model.sessions.usage, now: now)
    HStack(alignment: .top, spacing: 14) {
      // Left: today.
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 0) {
          Text(TokenText.short(today.total))
            .islandFont(28, weight: .semibold)
            .monospacedDigit()
            .foregroundStyle(Palette.text)
            .contentTransition(.numericText())
          Text("tokens today").islandFont(9.5).foregroundStyle(Palette.textDim)
        }
        ForEach([AgentKind.claudeCode, .codex], id: \.self) { agent in
          let tokens = agent == .claudeCode ? today.claude : today.codex
          let sessions = stats.sessionsToday[agent]?.count ?? 0
          let live = model.sessions.sessions.filter { $0.agent == agent && $0.isActive }.count
          HStack(spacing: 6) {
            AgentMarkView(agent: agent, size: 12, color: AgentsTab.color(agent))
            Text(TokenText.short(tokens)).islandFont(11, weight: .semibold).monospacedDigit().foregroundStyle(Palette.text)
            Spacer(minLength: 4)
            if live > 0 {
              Circle().fill(Palette.working).frame(width: 5, height: 5).help("\(live) running")
            }
            Image(systemName: "rectangle.stack").font(.system(size: 8)).foregroundStyle(Palette.textDim)
            Text("\(sessions)").islandFont(10).monospacedDigit().foregroundStyle(Palette.textDim)
          }
          .help("\(agent.displayName): \(tokens.formatted()) tokens, \(sessions) sessions today")
        }
        if !quotas.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(quotas, id: \.agent) { quota in
              HStack(spacing: 6) {
                AgentMarkView(agent: quota.agent, size: 10, color: Palette.textDim)
                ForEach(quota.windows, id: \.label) { window in
                  HStack(spacing: 3) {
                    LimitRing(used: window.used)
                    Text("\(window.used)%").islandFont(9.5, weight: .semibold).monospacedDigit().foregroundStyle(Palette.text)
                  }
                  .help(window.detail)
                }
              }
            }
          }
        }
      }
      .frame(width: 170, alignment: .leading)
      // Right: the week.
      VStack(alignment: .leading, spacing: 8) {
        TokenLines(series: stats.series(days: AgentStatsService.days, now: now))
          .frame(height: 84)
        VStack(spacing: 4) {
          let top = stats.topProjects(3)
          let most = max(1, top.first?.tokens ?? 1)
          ForEach(top, id: \.name) { project in
            HStack(spacing: 6) {
              Text(project.name).islandFont(10).foregroundStyle(Palette.text).lineLimit(1).frame(width: 84, alignment: .leading)
              GeometryReader { proxy in
                // A track behind each bar, so short ones still read against the black.
                ZStack(alignment: .leading) {
                  Capsule().fill(.white.opacity(0.1))
                  Capsule().fill(.white.opacity(0.78)).frame(width: max(4, proxy.size.width * CGFloat(project.tokens) / CGFloat(most)))
                }
              }
              .frame(height: 5)
              Text(TokenText.short(project.tokens)).islandFont(9.5, weight: .medium).monospacedDigit().foregroundStyle(Palette.text.opacity(0.75)).frame(width: 38, alignment: .trailing)
            }
          }
        }
      }
      .frame(maxWidth: .infinity)
    }
    .overlay(alignment: .topTrailing) {
      if model.agentStats.loading && model.agentStats.updated == nil { ProgressView().controlSize(.mini) }
    }
    .onAppear { model.agentStats.refreshIfStale() }
  }

  static func color(_ agent: AgentKind) -> Color {
    Color(hex: BotLook.agent(agent).color)
  }
}

/// The week as two smooth lines, Claude and Codex. Hover to read a day.
private struct TokenLines: View {
  let series: [(key: String, day: AgentStats.Day)]
  private let hover = State(initialValue: Int?.none)

  var body: some View {
    let most = Double(max(1, series.map { max($0.day.claude, $0.day.codex) }.max() ?? 1))
    let picked = hover.wrappedValue
    VStack(spacing: 3) {
      GeometryReader { proxy in
        let size = proxy.size
        let step = series.count > 1 ? size.width / CGFloat(series.count - 1) : 0
        let point = { (index: Int, value: Int) in
          CGPoint(x: CGFloat(index) * step, y: size.height - 4 - (size.height - 10) * CGFloat(Double(value) / most))
        }
        let claude = series.enumerated().map { point($0.offset, $0.element.day.claude) }
        let codex = series.enumerated().map { point($0.offset, $0.element.day.codex) }
        ZStack(alignment: .topLeading) {
          // Quiet guides at the top, middle and baseline, so a height reads as an amount.
          ForEach([0.0, 0.5, 1.0], id: \.self) { level in
            Rectangle().fill(.white.opacity(level == 1 ? 0.18 : 0.08)).frame(width: size.width, height: 1)
              .offset(y: (size.height - 4) - (size.height - 10) * level)
          }
          // A wash under each line: Claude's stronger, Codex's lighter.
          Self.curve(codex, closingAt: size.height)
            .fill(LinearGradient(colors: [AgentsTab.color(.codex).opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
          Self.curve(claude, closingAt: size.height)
            .fill(LinearGradient(colors: [AgentsTab.color(.claudeCode).opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
          Self.curve(codex).stroke(AgentsTab.color(.codex), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
          Self.curve(claude).stroke(AgentsTab.color(.claudeCode), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
          // A small dot on each day, so single days stand out from the curve.
          ForEach(Array(claude.enumerated()), id: \.offset) { _, point in
            Circle().fill(AgentsTab.color(.claudeCode)).frame(width: 3.5, height: 3.5).offset(x: point.x - 1.75, y: point.y - 1.75)
          }
          if let picked, picked < series.count {
            Rectangle().fill(.white.opacity(0.35)).frame(width: 1, height: size.height).offset(x: claude[picked].x)
            dot(claude[picked], AgentsTab.color(.claudeCode))
            if series[picked].day.codex > 0 { dot(codex[picked], AgentsTab.color(.codex)) }
            let entry = series[picked]
            Text("\(TokenText.short(entry.day.total))")
              .islandFont(10, weight: .bold).monospacedDigit()
              .foregroundStyle(.white)
              .padding(.init(top: 2, leading: 6, bottom: 2, trailing: 6))
              .background(Capsule().fill(.black.opacity(0.8)))
              .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
              .fixedSize()
              .offset(x: min(max(0, claude[picked].x - 22), size.width - 50), y: -2)
          } else if let last = claude.last {
            dot(last, AgentsTab.color(.claudeCode))
          }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
          switch phase {
          case let .active(location):
            let index = step > 0 ? Int((location.x / step).rounded()) : 0
            hover.wrappedValue = min(max(0, index), series.count - 1)
          case .ended:
            hover.wrappedValue = nil
          }
        }
      }
      HStack(spacing: 0) {
        ForEach(Array(series.enumerated()), id: \.offset) { index, entry in
          Text(Self.initial(entry.key))
            .islandFont(8.5, weight: index == (picked ?? series.count - 1) ? .bold : .regular)
            .foregroundStyle(index == (picked ?? series.count - 1) ? Palette.text : Palette.text.opacity(0.62))
            .frame(maxWidth: .infinity)
        }
      }
      .padding(.horizontal, -6)
    }
    .animation(.easeOut(duration: 0.12), value: picked)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Tokens this week: " + series.map { "\(Self.initial($0.key)) \(TokenText.short($0.day.total))" }.joined(separator: ", "))
  }

  private func dot(_ point: CGPoint, _ color: Color) -> some View {
    Circle().fill(color).frame(width: 7, height: 7).overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
      .offset(x: point.x - 3.5, y: point.y - 3.5)
  }

  /// A smooth line through the points (horizontal tangents, so it never overshoots
  /// below zero), optionally closed down to the baseline for a fill.
  static func curve(_ points: [CGPoint], closingAt baseline: CGFloat? = nil) -> Path {
    Path { path in
      guard let first = points.first else { return }
      path.move(to: first)
      for (previous, point) in zip(points, points.dropFirst()) {
        let mid = (point.x - previous.x) / 2
        path.addCurve(to: point, control1: CGPoint(x: previous.x + mid, y: previous.y), control2: CGPoint(x: point.x - mid, y: point.y))
      }
      if let baseline, let last = points.last {
        path.addLine(to: CGPoint(x: last.x, y: baseline))
        path.addLine(to: CGPoint(x: first.x, y: baseline))
        path.closeSubpath()
      }
    }
  }

  private static let parser: DateFormatter = {
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    return parser
  }()

  static func initial(_ key: String) -> String {
    guard let date = parser.date(from: key) else { return "" }
    return String(date.formatted(.dateTime.weekday(.narrow)))
  }
}

/// A usage limit as a small ring that warms as it fills.
private struct LimitRing: View {
  let used: Int

  var body: some View {
    let tone = used >= 90 ? Palette.failed : used >= 70 ? Palette.waiting : Palette.done
    ZStack {
      Circle().stroke(tone.opacity(0.2), lineWidth: 1.8)
      Circle().trim(from: 0, to: CGFloat(used) / 100).stroke(tone, style: StrokeStyle(lineWidth: 1.8, lineCap: .round)).rotationEffect(.degrees(-90))
    }
    .frame(width: 11, height: 11)
  }
}
