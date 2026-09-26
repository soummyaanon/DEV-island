import IslandCore
import SwiftUI

/// The hello. The crew pops up one by one and hops, the title lands with a
/// sunset shimmer, and the line types itself in. Click it, or let it be, and
/// the island folds back to the notch.
struct GreetingCard: View {
  let greeting: Greeting
  /// When it appeared: the typing and pops run off this clock.
  let at: Date
  let paused: Bool
  let dismiss: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Per character, after a short pause so the title lands first.
  private static let typeDelay = 0.45
  private static let perCharacter = 0.028

  var body: some View {
    // The line types in unless paused (then it's all there at once); only
    // Reduce Motion stops the pops, the rise, the shimmer and the caret.
    let still = reduceMotion
    Button(action: dismiss) {
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
        let age = timeline.date.timeIntervalSince(at)
        let pose = still ? 60 : age
        let shown = paused ? greeting.line.count : min(greeting.line.count, max(0, Int((age - Self.typeDelay) / Self.perCharacter)))
        HStack(spacing: 12) {
          GreetingCrew(age: pose, now: timeline.date.timeIntervalSinceReferenceDate, still: paused || reduceMotion)
            .padding(.trailing, -2)
          VStack(alignment: .leading, spacing: 2) {
            let rise = Self.easeOut.y(at: min(1, pose / 0.42))
            Text(greeting.title)
              .islandFont(13.5, weight: .bold)
              .foregroundStyle(.white)
              .overlay {
                if !still {
                  Shimmer(progress: CubicBezier.easeInOutCurve.y(at: min(1, max(0, (age - 0.3) / 1.6))))
                    .mask(Text(greeting.title).islandFont(13.5, weight: .bold))
                }
              }
              .offset(y: 6 * (1 - rise))
              .opacity(rise)
            // The caret blinks on an 0.8 s beat while the line types.
            let caret = !still && shown < greeting.line.count && age.truncatingRemainder(dividingBy: 0.8) < 0.4
            (Text(String(greeting.line.prefix(shown))) + Text(caret ? "▏" : "").foregroundColor(Color(hex: 0xB18CFF)))
              .islandFont(12)
              .foregroundStyle(.white.opacity(0.82))
              .lineSpacing(3)
              .fixedSize(horizontal: false, vertical: true)
              .frame(minHeight: 17, alignment: .topLeading)
            if greeting.ai && shown >= greeting.line.count {
              Text("✦ Apple Intelligence")
                .islandFont(9.5)
                .foregroundStyle(Palette.textDim)
                .modifier(Entrance(kind: .rise(0.3)))
            }
          }
        }
        .frame(maxWidth: 330, alignment: .leading)
        .padding(.init(top: 6, leading: 6, bottom: 6, trailing: 10))
        .contentShape(Rectangle())
      }
    }
    .buttonStyle(.plain)
    .padding(.init(top: 4, leading: 0, bottom: 6, trailing: 0))
    .accessibilityLabel("\(greeting.title). \(greeting.line)")
  }

  static let pop = CubicBezier(0.34, 1.56, 0.64, 1)
  static let easeOut = CubicBezier(0, 0, 0.58, 1)
}

/// The crew on the hello, drawn in one canvas on the card's clock: each pops
/// up in turn (greet-pop: 520 ms, 110 ms apart, overshooting a touch) and
/// hops with a whirl. Not interactive (1.x's `interactive={false}`): a click
/// is the card's.
private struct GreetingCrew: View {
  /// Seconds since the card appeared, for the pops.
  let age: Double
  let now: TimeInterval
  let still: Bool

  private static let size: CGFloat = 30
  /// Overlapping by 9.
  private static let pitch: CGFloat = 21
  private static let width = size + 2 * pitch
  private static let pad: CGFloat = 16
  private static let style = BotPose.Style(whirl: 1, jumpEvery: 2.4)

  var body: some View {
    Color.clear
      .frame(width: Self.width, height: Self.size)
      .overlay {
        Canvas { context, _ in
          let style = still ? Self.style.still : Self.style
          for (index, member) in BotLook.crew.enumerated() {
            let pop = GreetingCard.pop.y(at: min(1, max(0, (age - Double(index) * 0.11) / 0.52)))
            let opacity = min(1, max(0, pop))
            guard opacity > 0 else { continue }
            let box = CGRect(x: Self.pad + Self.pitch * CGFloat(index), y: Self.pad, width: Self.size, height: Self.size)
            // scaleEffect about the middle, then the offset.
            var ctx = context
            ctx.translateBy(x: box.midX, y: box.midY + 14 * (1 - pop))
            let scale = 0.3 + 0.7 * pop
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.midX, y: -box.midY)
            let pose = still ? BotPose.rest(.working) : BotPose.at(now, state: .working, seed: member.seed, style: style)
            if opacity < 1 {
              // Faded as one, as `.opacity` fades the whole view.
              ctx.opacity = opacity
              ctx.drawLayer { layer in BotRenderer.draw(member.look, pose: pose, style: style, in: layer, box: box) }
            } else {
              BotRenderer.draw(member.look, pose: pose, style: style, in: ctx, box: box)
            }
          }
        }
        .frame(width: Self.width + 2 * Self.pad, height: Self.size + 2 * Self.pad)
        .allowsHitTesting(false)
      }
      .accessibilityHidden(true)
  }
}

/// A sunset band sweeping across the title, once.
private struct Shimmer: View {
  let progress: Double

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0.35),
          .init(color: Color(hex: 0xFFB36B), location: 0.45),
          .init(color: Color(hex: 0xFF6FA8), location: 0.52),
          .init(color: Color(hex: 0xB18CFF), location: 0.6),
          .init(color: .clear, location: 0.7),
        ],
        startPoint: .leading, endPoint: .trailing
      )
      .frame(width: width * 3)
      .offset(x: -width * 2 * (1 - progress))
    }
    .allowsHitTesting(false)
  }
}
