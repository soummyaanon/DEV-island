import CoreGraphics

/// Which screen edge the island lives on. The bottom belongs to the Dock.
public enum IslandPlacement: String, Sendable, CaseIterable {
  /// Around the hardware notch: the classic island.
  case top
  /// A mini notch on the left edge.
  case left
  /// A mini notch on the right edge.
  case right

  public var isSide: Bool { self != .top }

  public var label: String {
    switch self {
    case .top: "Top"
    case .left: "Left"
    case .right: "Right"
    }
  }
}

/// The side island: the notch's own outline shrunk and turned on its side.
/// At rest it holds one mascot; while agents work, a dot per session.
public enum EdgeMetrics {
  /// Concave ear radius where the side island meets the bezel.
  public static let ear: CGFloat = 6
  /// How far the resting island reaches in from the edge: room for the mascot.
  public static let depth: CGFloat = 22
  /// The resting body's length along the edge, ears excluded.
  public static let length: CGFloat = 42
  /// The resting mascot's size.
  public static let mascot: CGFloat = 17
  /// Most dots the resting island shows.
  public static let maxDots = 3
  /// Where on the edge it sits by default: a third of the way down, clear of
  /// the Dock's middle and the hot corners.
  public static let defaultAnchor: CGFloat = 0.32
  /// The anchor never reaches the corners.
  public static let anchorRange: ClosedRange<CGFloat> = 0.08...0.92
  /// Kept clear between the island and the menu bar or a bottom Dock.
  public static let margin: CGFloat = 6
  /// The side window: wide enough for the widest panel.
  public static let canvasWidth: CGFloat = 760

  /// The resting box (ears included), across × along the edge.
  public static var restingBox: CGSize { CGSize(width: depth, height: length + 2 * ear) }

  /// Where a box of `size` sits in its canvas (top-left origin, y down):
  /// flush with the edge, its top where the resting notch's top is (the notch
  /// is centred on `anchor`, 0 top … 1 bottom), so an open panel grows down
  /// from the notch and a section opening never moves what's under the
  /// pointer. Never under the menu bar (`top`) or a bottom Dock (`bottom`).
  public static func origin(
    box size: CGSize, canvas: CGSize, placement: IslandPlacement, anchor: CGFloat, top: CGFloat, bottom: CGFloat
  ) -> CGPoint {
    let x = placement == .left ? 0 : canvas.width - size.width
    let lowest = top + margin
    let highest = max(lowest, canvas.height - bottom - margin - size.height)
    let y = min(max(anchor * canvas.height - restingBox.height / 2, lowest), highest)
    return CGPoint(x: x.rounded(), y: y.rounded())
  }

  /// The states the resting dots show, most urgent first: waiting on you,
  /// then working, then the rest.
  public static func dots(_ sessions: [SessionSnapshot]) -> [SessionState] {
    func rank(_ session: SessionSnapshot) -> Int {
      if session.state == .waitingForApproval || session.needsAction || session.pendingQuestion != nil { return 0 }
      if session.isActive { return 1 }
      return 2
    }
    let ordered = sessions.enumerated().sorted { a, b in
      let (ra, rb) = (rank(a.element), rank(b.element))
      return ra != rb ? ra < rb : a.offset < b.offset
    }
    return ordered.prefix(maxDots).map { rank($0.element) == 0 ? .waitingForApproval : $0.element.state }
  }
}

/// Dragging the island to another edge: the nearest of top, left and right
/// wins (the bottom is the Dock's), measured as a share of the screen so a
/// wide display doesn't favour the top.
public enum EdgeSnap {
  /// How much nearer another edge must be before the island jumps to it, so
  /// it doesn't flicker on the diagonal.
  public static let hysteresis: CGFloat = 0.04

  /// The edge for a pointer at `point` (AppKit coordinates, y up) on `screen`.
  public static func placement(at point: CGPoint, in screen: CGRect, current: IslandPlacement) -> IslandPlacement {
    guard screen.width > 0, screen.height > 0 else { return current }
    func distance(_ placement: IslandPlacement) -> CGFloat {
      switch placement {
      case .top: (screen.maxY - point.y) / screen.height
      case .left: (point.x - screen.minX) / screen.width
      case .right: (screen.maxX - point.x) / screen.width
      }
    }
    let nearest = IslandPlacement.allCases.min { distance($0) < distance($1) } ?? current
    return distance(nearest) < distance(current) - hysteresis ? nearest : current
  }

  /// Where along a side edge the pointer is: 0 top … 1 bottom, kept off the corners.
  public static func anchor(at point: CGPoint, in screen: CGRect) -> CGFloat {
    guard screen.height > 0 else { return EdgeMetrics.defaultAnchor }
    let fraction = (screen.maxY - point.y) / screen.height
    return min(max(fraction, EdgeMetrics.anchorRange.lowerBound), EdgeMetrics.anchorRange.upperBound)
  }
}

extension IslandOutline {
  /// The outline that fills `box` on `placement`'s edge: drawn as if on top,
  /// so its length runs along the edge and its height reaches in from it.
  public static func fitting(_ box: CGSize, on placement: IslandPlacement, corner: CGFloat, ear: CGFloat) -> IslandOutline {
    placement == .top
      ? IslandOutline(width: box.width - 2 * ear, height: box.height, corner: corner, ear: ear)
      : IslandOutline(width: box.height - 2 * ear, height: box.width, corner: corner, ear: ear)
  }

  /// Turns a top-edge drawing so its bezel runs down `placement`'s edge of `box`.
  public static func turn(to placement: IslandPlacement, box: CGSize) -> CGAffineTransform {
    switch placement {
    case .top: .identity
    // (x, y) → (width − y, x): the bezel (y = 0) lands on the right side.
    case .right: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: box.width, ty: 0)
    // (x, y) → (y, x): the bezel lands on the left side.
    case .left: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
    }
  }

  /// The whole silhouette filling `box` on `placement`'s edge.
  public static func silhouette(_ box: CGSize, on placement: IslandPlacement, corner: CGFloat, ear: CGFloat) -> CGPath {
    var turn = turn(to: placement, box: box)
    let path = fitting(box, on: placement, corner: corner, ear: ear).silhouette()
    return path.copy(using: &turn) ?? path
  }

  /// The open edge (never the bezel) filling `box` on `placement`'s edge.
  public static func edge(_ box: CGSize, on placement: IslandPlacement, corner: CGFloat, ear: CGFloat) -> CGPath {
    var turn = turn(to: placement, box: box)
    let path = fitting(box, on: placement, corner: corner, ear: ear).edge()
    return path.copy(using: &turn) ?? path
  }
}
