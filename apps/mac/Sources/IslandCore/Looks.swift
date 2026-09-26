import CoreGraphics

/// A robot's body, from the `bot-avatars` library 1.x drew with: its outline
/// (in a 100-unit box), thin parts like antennae, its colour, and where the
/// face sits. The shapes are the library's own path data.
public struct BotLook: Equatable, Sendable {
  public enum Kind: String, Sendable, CaseIterable {
    case mech, droid, hexagon, clover, star, alien
  }

  public var kind: Kind
  public var outline: String
  /// Drawn behind the body.
  public var parts: String?
  /// 0xRRGGBB.
  public var color: UInt32
  public var faceX: CGFloat
  public var faceY: CGFloat
  public var faceScale: CGFloat

  public init(_ kind: Kind, color: UInt32? = nil) {
    self = Self.stock[kind]!
    if let color { self.color = color }
  }

  private init(kind: Kind, outline: String, parts: String? = nil, color: UInt32, faceX: CGFloat, faceY: CGFloat, faceScale: CGFloat) {
    self.kind = kind
    self.outline = outline
    self.parts = parts
    self.color = color
    self.faceX = faceX
    self.faceY = faceY
    self.faceScale = faceScale
  }

  /// Every session is its agent's robot: Claude the orange mech, Codex the
  /// green droid, Cursor the blue hexagon.
  public static func agent(_ kind: AgentKind) -> BotLook {
    switch kind {
    case .claudeCode: BotLook(.mech, color: 0xFF8C42)
    case .codex: BotLook(.droid, color: 0x2FCB7A)
    case .cursor: BotLook(.hexagon, color: 0x35B8FF)
    }
  }

  /// The island's own crew (idle wing, assistant): deliberately not the agents' shapes.
  public static let crew: [(look: BotLook, seed: Double)] = [
    (BotLook(.clover), 0.12),
    (BotLook(.star), 0.47),
    (BotLook(.alien), 0.81),
  ]

  /// The face's ink: dark on a light body, light on a dark one.
  public var ink: UInt32 {
    let (r, g, b) = (Double(color >> 16 & 0xFF), Double(color >> 8 & 0xFF), Double(color & 0xFF))
    let luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
    return luminance > 0.35 ? 0x1E1A33 : 0xF7F5F2
  }

  static let stock: [Kind: BotLook] = [
    .mech: BotLook(
      kind: .mech,
      outline: "M10 48C10 38.06 18.06 30 28 30H72C81.94 30 90 38.06 90 48V70C90 79.94 81.94 88 72 88H28C18.06 88 10 79.94 10 70ZM3 54C3 51.79 4.79 50 7 50H11V72H7C4.79 72 3 70.21 3 68ZM89 50H93C95.21 50 97 51.79 97 54V68C97 70.21 95.21 72 93 72H89Z",
      parts: "M19.5 32L24.5 32L17 13L12 13ZM75.5 32L80.5 32L88 13L83 13ZM10 11.5A4.5 4.5 0 1 1 19 11.5A4.5 4.5 0 1 1 10 11.5ZM81 11.5A4.5 4.5 0 1 1 90 11.5A4.5 4.5 0 1 1 81 11.5Z",
      color: 0x95A6C4, faceX: 50, faceY: 59, faceScale: 1
    ),
    .droid: BotLook(
      kind: .droid,
      outline: "M16 50C16 38.95 24.95 30 36 30H64C75.05 30 84 38.95 84 50V70C84 81.05 75.05 90 64 90H36C24.95 90 16 81.05 16 70ZM4 62A7 7 0 1 1 18 62A7 7 0 1 1 4 62ZM82 62A7 7 0 1 1 96 62A7 7 0 1 1 82 62Z",
      parts: "M47.5 14H52.5V32H47.5ZM43 11A7 7 0 1 1 57 11A7 7 0 1 1 43 11Z",
      color: 0xD5DBEA, faceX: 50, faceY: 60, faceScale: 0.95
    ),
    .hexagon: BotLook(
      kind: .hexagon,
      outline: "M91.4 45.5A9 9 0 0 1 91.4 54.5L74.6 83.61A9 9 0 0 1 66.8 88.11L33.2 88.11A9 9 0 0 1 25.4 83.61L8.6 54.5A9 9 0 0 1 8.6 45.5L25.4 16.39A9 9 0 0 1 33.2 11.89L66.8 11.89A9 9 0 0 1 74.6 16.39L91.4 45.5Z",
      color: 0xFF2A2A, faceX: 50, faceY: 50, faceScale: 0.95
    ),
    .clover: BotLook(
      kind: .clover,
      outline: "M26.53 22.38A25 25 0 0 1 73.47 22.38A7 7 0 0 0 77.62 26.53A25 25 0 0 1 77.62 73.47A7 7 0 0 0 73.47 77.62A25 25 0 0 1 26.53 77.62A7 7 0 0 0 22.38 73.47A25 25 0 0 1 22.38 26.53A7 7 0 0 0 26.53 22.38Z",
      color: 0x35B8FF, faceX: 50, faceY: 50, faceScale: 1
    ),
    .star: BotLook(
      kind: .star,
      outline: "M45.77 9.7A5 5 0 0 1 54.23 9.7L65.02 26.81A4 4 0 0 0 67.42 28.55L87.02 33.53A5 5 0 0 1 89.63 41.57L76.7 57.12A4 4 0 0 0 75.78 59.94L77.11 80.12A5 5 0 0 1 70.26 85.09L51.48 77.59A4 4 0 0 0 48.52 77.59L29.74 85.09A5 5 0 0 1 22.89 80.12L24.22 59.94A4 4 0 0 0 23.3 57.12L10.37 41.57A5 5 0 0 1 12.98 33.53L32.58 28.55A4 4 0 0 0 34.98 26.81L45.77 9.7Z",
      color: 0xFFD32B, faceX: 50, faceY: 52, faceScale: 0.82
    ),
    .alien: BotLook(
      kind: .alien,
      outline: "M50 10C70 10 83 27 83 46C83 65 64 92 50 92C36 92 17 65 17 46C17 27 30 10 50 10Z",
      color: 0x9BE85A, faceX: 50, faceY: 45, faceScale: 1.05
    ),
  ]
}

/// The agents' real marks, for the footer's usage rings.
public enum AgentMark {
  /// Path data and its view box side.
  public static func path(_ agent: AgentKind) -> (data: [String], box: CGFloat, turns: [CGFloat]) {
    switch agent {
    case .claudeCode:
      ([claudeSpark], 24, [0])
    case .codex:
      // One petal, repeated every 60° around the centre.
      ([openAIPetal], 2406, [0, 60, 120, 180, 240, 300])
    case .cursor:
      ([cursorCube], 24, [0])
    }
  }

  static let claudeSpark =
    "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"

  static let openAIPetal =
    "M1107.3 299.1c-197.999 0-373.9 127.3-435.2 315.3L650 743.5v427.9c0 21.4 11 40.4 29.4 51.4l344.5 198.515V833.3h.1v-27.9L1372.7 604c33.715-19.52 70.44-32.857 108.47-39.828L1447.6 450.3C1361 353.5 1237.1 298.5 1107.3 299.1zm0 117.5-.6.6c79.699 0 156.3 27.5 217.6 78.4-2.5 1.2-7.4 4.3-11 6.1L952.8 709.3c-18.4 10.4-29.4 30-29.4 51.4V1248l-155.1-89.4V755.8c-.1-187.099 151.601-338.9 339-339.2z"

  static let cursorCube =
    "M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23"
}
