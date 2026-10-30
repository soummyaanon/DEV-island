import IslandCore
import SwiftUI

/// The island on a side edge: a mini notch, the hardware notch's outline
/// shrunk and turned on its side. At rest one mascot keeps it company; while
/// agents work it shows a dot per session.
/// Opening grows the same black body out from the edge into the full panel,
/// so everything the top island offers is here too; only the wings' ambient
/// extras (battery, music, timers) wait inside the panel instead.
struct EdgeIsland: View {
  let model: IslandModel

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  private var placement: IslandPlacement { model.placement }

  private var corner: CGFloat {
    model.isExpanded ? IslandOutline.expandedCorner : EdgeMetrics.depth / 2
  }

  private var shape: IslandShape {
    IslandShape(corner: corner, placement: placement, ear: EdgeMetrics.ear)
  }

  var body: some View {
    EdgeDock(placement: placement, anchor: model.edgeAnchor, top: model.edgeTopInset, bottom: model.edgeBottomInset) {
      island
        // Each edge is a new arrival: it springs out of that edge.
        .id(placement)
        .transition(.arrive(placement))
    }
  }

  /// One container, so the black body is a single shape that grows out of
  /// the notch (a `Group` would give the resting and open contents a shape
  /// each, cross-fading instead of growing). Pinned to the edge and the
  /// notch's top while the contents swap inside it.
  private var island: some View {
    ZStack(alignment: placement == .left ? .topLeading : .topTrailing) {
      if model.isExpanded {
        IslandWidth(fixed: nil, range: model.expandedWidthRange) {
          Panel(model: model)
            .padding(.top, 4)
        }
        .transition(reduceMotion ? .identity : .asymmetric(
          insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.05)),
          removal: .opacity.animation(.easeIn(duration: 0.07))
        ))
      } else {
        EdgeResting(model: model)
          .frame(width: EdgeMetrics.depth, height: EdgeMetrics.length)
          .contentShape(Rectangle())
          .onTapGesture { model.clickEdge() }
          .transition(.opacity.animation(.easeOut(duration: 0.12)))
      }
    }
    .padding(.vertical, EdgeMetrics.ear)
    .background { background }
    .overlay {
      if let pulse = model.sessions.pulse {
        EdgeGlow(
          pulse: pulse, corner: corner, placement: placement, ear: EdgeMetrics.ear, reduced: reduceMotion,
          highContrast: contrast == .increased, paused: model.isPaused
        ) {
          model.sessions.clearPulse(pulse.id)
        }
        .id(pulse.id)
      }
    }
    .clipShape(shape)
    .overlay {
      // Plugged in or out: a current runs round the edge in the Energy Mode's
      // colour (green, amber in Low Power, cyan in High Power; white unplugged).
      if let activity = model.power.activity, activity.isCharger, model.reading != nil, !model.isPaused {
        let tint = Palette.charge(activity)
        IntelligenceSheen(
          corner: corner, placement: placement, ear: EdgeMetrics.ear, paused: model.isPaused,
          colors: [tint, tint.opacity(0.15), .white, tint.opacity(0.15)], period: 1.4
        )
        .transition(.opacity.animation(.easeOut(duration: 0.3)))
        .id(activity.id)
      }
    }
    .overlay {
      if model.settings.edgeGlow && model.ask.isOpen && model.isExpanded && !model.isPaused {
        IslandGlow(corner: corner, placement: placement, ear: EdgeMetrics.ear, bright: model.ask.live != nil, paused: model.isPaused)
      }
    }
    .contentShape(shape)
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(IslandView.canvas)) } action: { frame in
      model.edgeBox = frame
    }
    .contextMenu { IslandMenu(model: model) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Agent Island")
  }

  /// Solid black, or with glass on, glass under a dark scrim while open.
  @ViewBuilder private var background: some View {
    if model.settings.glass && model.isExpanded && !reduceTransparency && contrast != .increased {
      ZStack {
        GlassMaterial()
        Color.black.opacity(0.8)
      }
      .clipShape(shape)
    } else {
      shape.fill(.black)
    }
  }
}

/// At rest, a single mascot. While agents work or wait, one dot per session,
/// most urgent first. A dim red dot while the island can't reach its daemon.
private struct EdgeResting: View {
  let model: IslandModel

  /// Nothing working, nothing waiting.
  private var idle: Bool { model.active.isEmpty && model.needsYou.isEmpty && model.sessions.connected }

  var body: some View {
    let states = EdgeMetrics.dots(model.sessions.sessions.filter { $0.isActive || $0.needsAction || $0.pendingQuestion != nil })
    Group {
      if let activity = model.power.activity, activity.isCharger, let reading = model.reading {
        // The charger moment takes the notch for a few seconds: a bolt and the level.
        VStack(spacing: 2) {
          Image(systemName: activity.kind == .plugged ? "bolt.fill" : "bolt.slash.fill")
            .font(.system(size: 11, weight: .semibold))
          Text(verbatim: "\(reading.percent)")
            .islandFont(8, weight: .bold)
            .monospacedDigit()
        }
        .foregroundStyle(Palette.charge(activity))
        .pop()
        .id(activity.id)
      } else if idle {
        BotAvatar(
          look: BotLook.crew[0].look, state: .idle, size: EdgeMetrics.mascot, seed: 0.12, paused: model.ambientStill,
          style: BotPose.Style(jumpEvery: 0), interactive: false
        )
        .pop()
      } else {
        VStack(spacing: 5) {
          if states.isEmpty {
            dot(Palette.failed.opacity(0.7))
          }
          ForEach(Array(states.enumerated()), id: \.offset) { _, state in
            dot(Palette.state(state))
          }
        }
        .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.2), value: states)
    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: idle)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(WingText.label(model))
    .accessibilityAddTraits(.isButton)
  }

  private func dot(_ color: Color) -> some View {
    Circle().fill(color).frame(width: 5, height: 5)
  }
}

extension AnyTransition {
  /// The island arriving on an edge: it squeezes out of the bezel and
  /// springs to size. Leaving is instant, since the window has already
  /// moved to the new edge.
  static func arrive(_ placement: IslandPlacement) -> AnyTransition {
    .asymmetric(
      insertion: .modifier(active: Arrive(placement: placement, progress: 0), identity: Arrive(placement: placement, progress: 1)),
      removal: .identity
    )
  }
}

/// Scale out of the edge: thin against the bezel at 0, full size at 1.
private struct Arrive: ViewModifier {
  let placement: IslandPlacement
  let progress: CGFloat

  func body(content: Content) -> some View {
    let across = 0.05 + 0.95 * progress
    let along = 0.55 + 0.45 * progress
    switch placement {
    case .top:
      content.scaleEffect(x: along, y: across, anchor: .top).opacity(Double(min(1, progress * 3)))
    case .left:
      content.scaleEffect(x: across, y: along, anchor: .leading).opacity(Double(min(1, progress * 3)))
    case .right:
      content.scaleEffect(x: across, y: along, anchor: .trailing).opacity(Double(min(1, progress * 3)))
    }
  }
}

/// Fills the window and puts the island flush with its edge, centred on the
/// anchor and clear of the menu bar and a bottom Dock.
private struct EdgeDock: Layout {
  var placement: IslandPlacement
  var anchor: CGFloat
  var top: CGFloat
  var bottom: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let island = subviews.first else { return }
    let size = island.sizeThatFits(.unspecified)
    let origin = EdgeMetrics.origin(box: size, canvas: bounds.size, placement: placement, anchor: anchor, top: top, bottom: bottom)
    island.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: ProposedViewSize(size))
  }
}
