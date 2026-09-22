import SwiftUI

// MARK: - Depth objects

/// One thing floating in the scene.
///
/// `depth` does all the work: 0 is the far plane, 1 is nearest the camera. Blur,
/// parallax, scale and shadow are all derived from it, so adding an object can
/// never produce a scene that moves inconsistently.
struct DepthObject: Identifiable {
  let id: String
  /// A generated image, or nil for an object drawn in code.
  var imageName: String? = nil
  /// 0 = far, 1 = near.
  var depth: Double
  /// Width as a fraction of the scene width.
  var width: Double
  /// Centre position, in unit coordinates.
  var center: UnitPoint
  var opacity: Double = 1
  /// Distance-of-field blur applied to far objects.
  var blur: CGFloat = 0
  /// Ambient vertical drift, in points at this depth.
  var bob: Double = 0
  /// Slow constant rotation, in degrees.
  var spin: Double = 0

  /// Identity defaults to the image name so a scene built from assets gets
  /// stable identities for free. Without stability, `ForEach` would treat every
  /// re-render as a new set of objects and the depth animation would stop
  /// working.
  init(
    id: String? = nil,
    imageName: String? = nil,
    depth: Double,
    width: Double,
    center: UnitPoint,
    opacity: Double = 1,
    blur: CGFloat = 0,
    bob: Double = 0,
    spin: Double = 0
  ) {
    self.id = id ?? imageName ?? "object"
    self.imageName = imageName
    self.depth = depth
    self.width = width
    self.center = center
    self.opacity = opacity
    self.blur = blur
    self.bob = bob
    self.spin = spin
  }
}

// MARK: - Depth scene

/// A layered three-dimensional space.
///
/// Two things make this read as depth rather than as a slideshow of layers:
///
///  1. **Perspective.** The whole scene rotates in 3D, with the rotation driven
///     by device attitude. Because the rotation is applied to the container and
///     the parallax offset is applied per object, the near objects appear to
///     swing further than the far ones, which is what a real space does.
///  2. **Depth of field.** Far objects are blurred and dimmed, near objects are
///     sharp and carry a shadow. Your eye reads focus as distance.
///
/// Everything here is decorative. The scene never accepts touches, so it can
/// never intercept a control, and it collapses to a still composition under
/// Reduce Motion.
struct DepthScene<Overlay: View>: View {
  var objects: [DepthObject]
  /// A vanishing-point floor, drawn in code so it stays crisp at any size.
  var grid: Bool = false
  var gridDepth: Double = 0.08
  var background: Color = MiraColor.canvas
  /// Maximum container rotation in degrees at full tilt.
  var maxRotation: Double = 7
  /// Maximum parallax travel in points at depth 1.
  var parallax: CGFloat = 34
  /// A gentle pull toward the light, applied to the whole scene.
  var vignette: Bool = false
  @ViewBuilder var overlay: () -> Overlay

  init(
    objects: [DepthObject],
    grid: Bool = false,
    gridDepth: Double = 0.08,
    background: Color = MiraColor.canvas,
    maxRotation: Double = 7,
    parallax: CGFloat = 34,
    vignette: Bool = false,
    @ViewBuilder overlay: @escaping () -> Overlay
  ) {
    self.objects = objects
    self.grid = grid
    self.gridDepth = gridDepth
    self.background = background
    self.maxRotation = maxRotation
    self.parallax = parallax
    self.vignette = vignette
    self.overlay = overlay
  }

  @Environment(MotionSource.self) private var motion
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Finger drag, so the depth is demonstrable on a simulator and on a device
  /// whose motion sensor is unavailable.
  @State private var drag: CGSize = .zero
  @State private var settling = false

  private var motionOn: Bool { !reduceMotion }

  /// Normalised -1...1 on each axis, from tilt when available and from drag
  /// otherwise. Both feed the same maths so the scene behaves identically.
  private var field: CGSize {
    guard motionOn else { return .zero }
    let tilt = motion.isAvailable && motion.isEnabled ? motion.tilt : .zero
    let dragInfluence = CGSize(
      width: max(-1, min(1, drag.width / 140)),
      height: max(-1, min(1, drag.height / 140))
    )
    return CGSize(
      width: max(-1, min(1, tilt.width + dragInfluence.width)),
      height: max(-1, min(1, tilt.height + dragInfluence.height))
    )
  }

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      ZStack {
        background

        if grid {
          // The floor fades in rather than starting at a hard edge. A visible
          // horizon line across the middle of the screen reads as a seam.
          PerspectiveGrid()
            .stroke(MiraColor.text.opacity(0.055), lineWidth: 1)
            .frame(height: size.height * 0.46)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .mask {
              LinearGradient(
                stops: [
                  .init(color: .clear, location: 0.0),
                  .init(color: .black.opacity(0.35), location: 0.28),
                  .init(color: .black, location: 0.62),
                ],
                startPoint: .top,
                endPoint: .bottom
              )
            }
            .offset(y: offset(for: gridDepth, in: size).height)
            .rotation3DEffect(
              .degrees(-field.height * maxRotation * 0.4 * gridDepth),
              axis: (x: 1, y: 0, z: 0),
              perspective: 0.5
            )
        }

        ForEach(objects) { object in
          layer(object, in: size)
        }

        if vignette {
          RadialGradient(
            colors: [.clear, MiraColor.ink.opacity(0.05)],
            center: .center,
            startRadius: size.width * 0.25,
            endRadius: size.width * 0.95
          )
          .allowsHitTesting(false)
        }

        overlay()
      }
      .frame(width: size.width, height: size.height)
      // The scene rotates as one space; the per-object offsets above create the
      // differential movement that makes the depth legible.
      .rotation3DEffect(
        .degrees(field.width * maxRotation),
        axis: (x: 0, y: 1, z: 0),
        perspective: 0.55
      )
      .rotation3DEffect(
        .degrees(-field.height * maxRotation * 0.7),
        axis: (x: 1, y: 0, z: 0),
        perspective: 0.55
      )
      .animation(settling ? .spring(response: 0.9, dampingFraction: 0.85) : nil, value: field)
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .gesture(dragGesture)
  }

  // MARK: Layers

  private func layer(_ object: DepthObject, in size: CGSize) -> some View {
    let offset = offset(for: object.depth, in: size)
    let scale = 1 + (field.width * object.depth * 0.035)
    let width = size.width * object.width

    return Group {
      if let name = object.imageName, let image = MiraArt.image(named: name) {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: width)
      } else {
        Color.clear.frame(width: width, height: width)
      }
    }
    .blur(radius: object.blur + CGFloat(abs(field.width)) * object.depth * 0.6)
    .scaleEffect(scale)
    .rotationEffect(.degrees(object.spin + field.width * object.depth * 1.4))
    .opacity(object.opacity)
    .shadow(
      color: MiraColor.ink.opacity(object.depth * 0.10),
      radius: 6 + object.depth * 26,
      x: -field.width * object.depth * 10,
      y: 8 + object.depth * 22
    )
    .position(
      x: size.width * object.center.x + offset.width,
      y: size.height * object.center.y + offset.height
    )
  }

  /// Parallax travel for a given depth. Near objects move further and opposite
  /// to the camera, which is the cue that sells the space.
  private func offset(for depth: Double, in size: CGSize) -> CGSize {
    CGSize(
      width: -field.width * parallax * depth,
      height: -field.height * parallax * depth * 0.6
    )
  }

  // MARK: Gesture

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 8)
      .onChanged { value in
        guard motionOn else { return }
        settling = false
        drag = value.translation
      }
      .onEnded { _ in
        settling = true
        drag = .zero
      }
  }
}

// MARK: - Perspective grid

/// A floor receding to a vanishing point.
///
/// Drawn rather than generated: lines stay exactly one pixel at every size, and
/// it costs nothing to ship.
struct PerspectiveGrid: Shape {
  var columns: Int = 15
  var rows: Int = 11
  /// Vanishing point height as a fraction of the shape's height.
  var horizon: CGFloat = 0.30

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let vanish = CGPoint(x: rect.midX, y: rect.minY + rect.height * horizon)

    // Vertical lines fanning out from the vanishing point.
    for column in 0...columns {
      let t = CGFloat(column) / CGFloat(columns)
      let bottomX = rect.minX + rect.width * (t * 2.4 - 0.7)
      path.move(to: vanish)
      path.addLine(to: CGPoint(x: bottomX, y: rect.maxY))
    }

    // Horizontal lines spaced so they compress toward the horizon, which is
    // what makes the plane read as receding rather than as a flat grid.
    for row in 0...rows {
      let t = CGFloat(row) / CGFloat(rows)
      let eased = pow(t, 2.1)
      let y = vanish.y + (rect.maxY - vanish.y) * eased
      path.move(to: CGPoint(x: rect.minX, y: y))
      path.addLine(to: CGPoint(x: rect.maxX, y: y))
    }

    return path
  }
}
