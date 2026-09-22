import SwiftUI

// MARK: - A staged scene

/// A composition of pictures, at stated sizes, you can push around with a hand.
///
/// Deliberately plain: a ZStack of planes whose width is a fraction of the
/// canvas, each positioned by its centre. Nothing measures anything at render
/// time, and nothing depends on a container's geometry, because a composition
/// that depends on a measurement silently changes when its container does.
///
/// The camera is applied by the caller, so each scene can stand wherever it
/// likes in its own picture.
struct SceneStage: View {
  let planes: [StagePlane]
  let canvas: CGSize
  let reduceMotion: Bool
  var interactive: Bool = true

  @State private var drag: CGSize = .zero
  @State private var carried: CGSize = .zero

  var body: some View {
    let w = canvas.width
    let h = canvas.height

    ZStack {
      ForEach(planes) { plane in
        if let image = MiraArt.image(named: plane.image) {
          let width = w * plane.width
          Image(uiImage: image)
            .resizable()
            .frame(width: width, height: width * image.size.height / max(image.size.width, 1))
            .scaleEffect(x: plane.flip ? -1 : 1, y: 1)
            .rotationEffect(.degrees(plane.rotation))
            .blur(radius: plane.blur)
            .opacity(plane.opacity)
            .modifier(
              DriftModifier(
                amount: reduceMotion ? 0 : plane.drift,
                period: plane.period,
                depth: 0.5
              )
            )
            .modifier(
              SwayModifier(
                amount: reduceMotion ? 0 : plane.sway,
                period: plane.period * 1.7
              )
            )
            .position(x: w * plane.at.x, y: h * plane.at.y)
        }
      }
    }
    .frame(width: w, height: h)
    .offset(x: drag.width + carried.width, y: drag.height + carried.height)
    .contentShape(Rectangle())
    .gesture(interactive ? hand : nil)
  }

  /// Elastic, like a held picture: it follows the hand but stiffens, and always
  /// wants to return.
  private var hand: some Gesture {
    DragGesture(minimumDistance: 6)
      .onChanged { value in
        guard !reduceMotion else { return }
        let raw = value.translation
        drag = CGSize(
          width: raw.width / (1 + abs(raw.width) / 520),
          height: raw.height / (1 + abs(raw.height) / 760)
        )
      }
      .onEnded { _ in
        let momentum = CGSize(width: drag.width * 0.3, height: drag.height * 0.3)
        withAnimation(.spring(response: 1.05, dampingFraction: 0.82)) {
          carried = CGSize(
            width: max(-22, min(22, carried.width + momentum.width)),
            height: max(-12, min(12, carried.height + momentum.height))
          )
          drag = .zero
        }
      }
  }
}

// MARK: - A plane

/// One picture in a staged composition.
///
/// `width` is a fraction of the canvas width, and the height follows from the
/// image's own aspect.
struct StagePlane: Identifiable {
  let id: String
  let image: String
  let width: CGFloat
  let at: UnitPoint
  var opacity: Double = 1
  var blur: CGFloat = 0
  var flip: Bool = false
  /// A fixed tilt for the plane, in degrees.
  var rotation: Double = 0
  /// Perpetual slow drift, in points, so the scene is never completely still.
  var drift: Double = 0
  var period: Double = 22
  /// A perpetual slow turn, in degrees of total sweep. The plane breathes
  /// rather than spins: a degree or two over a minute.
  var sway: Double = 0
}

// MARK: - Breath

/// A very slow swell on the whole plate. Barely perceptible, and the reason a
/// still screen never looks like a screenshot.
struct SceneBreath: ViewModifier {
  let amount: Double

  func body(content: Content) -> some View {
    if amount == 0 {
      content
    } else {
      TimelineView(.periodic(from: .now, by: 1.0 / 8.0)) { context in
        let t = context.date.timeIntervalSinceReferenceDate
        let phase = (t.truncatingRemainder(dividingBy: 44) / 44) * 2 * .pi
        content.scaleEffect(1 + sin(phase) * amount, anchor: .center)
      }
    }
  }
}

/// A very slow turn, so an engraved plate reads as something being measured
/// rather than as a printed page.
struct SwayModifier: ViewModifier {
  let amount: Double
  let period: Double

  func body(content: Content) -> some View {
    if amount == 0 {
      content
    } else {
      TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { context in
        let t = context.date.timeIntervalSinceReferenceDate
        let phase = (t.truncatingRemainder(dividingBy: period) / period) * 2 * .pi
        content.rotationEffect(.degrees(sin(phase) * amount))
      }
    }
  }
}

/// A slow perpetual sway on one axis, so nothing on screen is ever frozen.
struct DriftModifier: ViewModifier {
  let amount: Double
  let period: Double
  let depth: Double

  func body(content: Content) -> some View {
    if amount == 0 {
      content
    } else {
      TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { context in
        let t = context.date.timeIntervalSinceReferenceDate
        let phase = (t.truncatingRemainder(dividingBy: period) / period) * 2 * .pi
        content.offset(y: sin(phase) * amount * (0.4 + depth * 0.6))
      }
    }
  }
}
