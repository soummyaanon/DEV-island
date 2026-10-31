import AppKit
import IslandCore
import SwiftUI

/// While a drag carries the island: a click-through layer over the whole
/// display. The island lifts off its edge and follows the pointer freely;
/// the three places it can land glow, the nearest brightest, with an outline
/// of exactly where it will settle. Letting go flies it into that outline.
/// Nothing jumps between edges mid-drag, and the island's own window only
/// moves once, on release.
final class DragOverlayPanel: NSPanel {
  init(model: IslandModel) {
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    isFloatingPanel = true
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    let host = NSHostingView(rootView: DragOverlay(model: model))
    host.sizingOptions = []
    contentView = host
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }

  func show(on screen: NSScreen) {
    setFrame(screen.frame, display: true)
    orderFrontRegardless()
  }
}

/// A drag in progress, in the overlay's coordinates (the display's top-left origin, y down).
struct Carry: Equatable {
  /// The pointer.
  var point: CGPoint
  /// The edge it lands on if let go now, and where along it.
  var target: IslandPlacement
  var anchor: CGFloat
  /// Exactly where it will settle.
  var slot: CGRect
  /// Each edge's landing zone, for the glows.
  var zones: [IslandPlacement: CGRect]
  /// Let go: flying into the slot.
  var landing = false
}

struct DragOverlay: View {
  let model: IslandModel

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: .topLeading) {
      if let carry = model.carry {
        ForEach(IslandPlacement.allCases, id: \.self) { placement in
          if let zone = carry.zones[placement] {
            ZoneGlow(placement: placement, zone: zone, hot: placement == carry.target && !carry.landing)
          }
        }
        Ghost(carry: carry)
          .opacity(carry.landing ? 0 : 1)
          .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: carry.slot)
        Carried(model: model, carry: carry)
          .animation(
            reduceMotion ? nil : carry.landing
              ? .spring(response: 0.34, dampingFraction: 0.74)
              // A touch of lag gives it weight without ever feeling behind.
              : .interactiveSpring(response: 0.12, dampingFraction: 0.9),
            value: carry
          )
          .transition(.opacity.animation(.easeOut(duration: 0.15)))
      }
    }
    .animation(.easeOut(duration: 0.18), value: model.carry == nil)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .allowsHitTesting(false)
  }
}

/// A landing zone, just a hint: Apple Intelligence's pastels breathing
/// faintly round the notch, or in a thin wash along a side. The one it's
/// headed for is a touch brighter.
private struct ZoneGlow: View {
  let placement: IslandPlacement
  let zone: CGRect
  let hot: Bool

  private var pastels: LinearGradient {
    LinearGradient(colors: IntelligenceSheen.colors, startPoint: .top, endPoint: .bottom)
  }

  var body: some View {
    Group {
      switch placement {
      case .top:
        IslandEdge(corner: IslandOutline.collapsedCorner)
          .stroke(
            AngularGradient(colors: IntelligenceSheen.colors + [IntelligenceSheen.colors[0]], center: .center),
            lineWidth: 3
          )
          .blur(radius: 3)
          .frame(width: zone.width, height: zone.height)
      case .left, .right:
        pastels
          .frame(width: zone.width, height: zone.height)
          // Fades in from the edge, and out towards the menu bar and the Dock.
          .mask(LinearGradient(
            colors: [.black, .clear],
            startPoint: placement == .left ? .leading : .trailing,
            endPoint: placement == .left ? .trailing : .leading
          ))
          .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .black, location: 0.2),
            .init(color: .black, location: 0.8), .init(color: .clear, location: 1),
          ], startPoint: .top, endPoint: .bottom))
      }
    }
    .opacity(hot ? 0.38 : 0.14)
    .position(x: zone.midX, y: zone.midY)
    .animation(.easeOut(duration: 0.2), value: hot)
    .transition(.opacity)
  }
}

/// Exactly where it will settle: the island's own outline, dashed.
private struct Ghost: View {
  let carry: Carry

  var body: some View {
    let shape = IslandShape(
      corner: carry.target.isSide ? EdgeMetrics.depth / 2 : IslandOutline.collapsedCorner,
      placement: carry.target,
      ear: carry.target.isSide ? EdgeMetrics.ear : IslandOutline.earRadius
    )
    shape.fill(.white.opacity(0.06))
      .overlay(shape.stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
      .frame(width: carry.slot.width, height: carry.slot.height)
      .position(x: carry.slot.midX, y: carry.slot.midY)
  }
}

/// The island in hand: a black pill the shape of where it's headed, lifted
/// with a lit rim and a shadow; on landing it becomes exactly the slot.
private struct Carried: View {
  let model: IslandModel
  let carry: Carry

  private var size: CGSize {
    carry.landing ? carry.slot.size : CGSize(width: carry.slot.width * 1.15, height: carry.slot.height * 1.15)
  }

  private var idle: Bool { model.active.isEmpty && model.needsYou.isEmpty }

  var body: some View {
    let pill = RoundedRectangle(cornerRadius: min(size.width, size.height) / 2, style: .continuous)
    let along: AnyLayout = carry.target.isSide ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 6))
    ZStack {
      pill.fill(.black)
      // A hairline of Apple Intelligence's pastels: picked up, not lit up.
      pill.stroke(
        AngularGradient(colors: IntelligenceSheen.colors + [IntelligenceSheen.colors[0]], center: .center),
        lineWidth: 1
      )
      .opacity(carry.landing ? 0 : 0.8)
      if idle {
        BotAvatar(
          look: BotLook.crew[0].look, state: .idle, size: EdgeMetrics.mascot, seed: 0.12, paused: false,
          style: BotPose.Style(jumpEvery: 0), interactive: false
        )
      } else {
        // The orbs it shows at rest, so the island in hand is the one you picked up.
        let orbs = EdgeMetrics.orbs(model.sessions.sessions)
        along {
          ForEach(orbs, id: \.agent) { orb in
            ThinkingOrb(
              state: orb.state,
              tint: orb.waiting ? Palette.waiting : Color(hex: BotLook.agent(orb.agent).color),
              size: carry.target.isSide ? EdgeMetrics.orbSize(orbs.count) : 16,
              bold: true,
              paused: model.wingStill
            )
          }
        }
      }
    }
    .frame(width: size.width, height: size.height)
    .shadow(color: .black.opacity(carry.landing ? 0 : 0.4), radius: 8, y: 3)
    .position(carry.landing ? CGPoint(x: carry.slot.midX, y: carry.slot.midY) : carry.point)
  }
}
