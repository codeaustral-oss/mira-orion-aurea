import SwiftUI
import UIKit

// MARK: - Which scene

/// Two onboarding scenes, one product.
///
/// Both are a single painted place — the lake settlement and the garden terrace
/// above the bay — shown full-bleed, with the camera standing somewhere in the
/// picture and moving a little at each step. The painting is the screen; the
/// words sit on it.
///
/// They are kept so the choice can be made by looking at them rather than by
/// arguing about them, and the choice is remembered.
enum OnboardingScene: String, CaseIterable, Identifiable {
  case lake
  case terrace

  var id: String { rawValue }

  var title: String {
    switch self {
    case .lake: return "Lake"
    case .terrace: return "Terrace"
    }
  }

  var blurb: String {
    switch self {
    case .lake:
      return "A lakeside settlement: the villa in its cypresses, the town across the water, one sail."
    case .terrace:
      return "A garden terrace above the bay: balustrade, jasmine and the villa on its headland."
    }
  }

  /// The portrait painting this scene is composed from.
  var assetName: String {
    switch self {
    case .lake: return "aurea-onboarding-lake"
    case .terrace: return "aurea-onboarding-terrace"
    }
  }

  /// Existing art used until a scene's artwork is installed in the catalog.
  /// Never a crash and never a blank frame.
  var fallbackAssetNames: [String] {
    switch self {
    case .lake: return ["px-lake", "aurea-landscape"]
    case .terrace: return ["aurea-landscape", "px-lake"]
    }
  }

  var image: UIImage? {
    for name in [assetName] + fallbackAssetNames {
      if let image = MiraArt.image(named: name) { return image }
    }
    return nil
  }

  /// The one the app opens on until the choice is made.
  static let fallback: OnboardingScene = .lake
}

// MARK: - The backdrop

/// The painting, full-bleed, with a camera standing inside it.
///
/// The picture is scaled to cover the whole screen and cropped, so there is no
/// frame, no letterbox and no second sky: every pixel the user sees is the
/// painting. Advancing a step does not slide a new page in — it moves this
/// camera, a few percent, the way standing somewhere and turning your head
/// moves what you see.
struct AureaBackdrop: View {
  let scene: OnboardingScene
  let step: Int
  let reduceMotion: Bool

  @Environment(MotionSource.self) private var motion

  var body: some View {
    // Measured here, and reported as the safe area — not as the screen. A view
    // that reports the whole screen would make the shell taller than the screen
    // and push the buttons below the home indicator; one that draws across the
    // whole screen and reports the safe area keeps the painting full-bleed and
    // the type where it belongs.
    GeometryReader { proxy in
      let insets = proxy.safeAreaInsets
      let screen = CGSize(
        width: proxy.size.width + insets.leading + insets.trailing,
        height: proxy.size.height + insets.top + insets.bottom
      )

      ZStack {
        if let image = scene.image {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: screen.width, height: screen.height)
            .scaleEffect(camera.scale)
            .offset(x: camera.x + tilt.width, y: camera.y + tilt.height)
            .offset(x: -insets.leading, y: -insets.top)
        } else {
          // A calm surface rather than a hole, if the catalog is ever missing
          // the artwork.
          LinearGradient(
            colors: [Color(hex: 0x24404F), Color(hex: 0x16262F)],
            startPoint: .top,
            endPoint: .bottom
          )
          .frame(width: screen.width, height: screen.height)
          .offset(x: -insets.leading, y: -insets.top)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .modifier(SceneBreath(amount: reduceMotion ? 0 : 0.010))
      .animation(.easeInOut(duration: 0.9), value: step)
      .allowsHitTesting(false)
    }
  }

  /// Where the camera stands at each step: a small push in, and a slow travel
  /// across the painting from the villa to the water and back out to the whole
  /// place. Offsets are fractions of the screen, so they stay modest.
  private var camera: (scale: CGFloat, x: CGFloat, y: CGFloat) {
    switch (scene, step) {
    case (.lake, 0): return (1.10, -0.055 * 440, 0.010 * 880)
    case (.lake, 1): return (1.16, 0.055 * 440, -0.015 * 880)
    case (.lake, 2): return (1.24, 0.005 * 440, 0.055 * 880)
    case (.lake, _): return (1.03, 0, 0)

    case (.terrace, 0): return (1.12, -0.045 * 440, 0.045 * 880)
    case (.terrace, 1): return (1.18, 0.050 * 440, -0.010 * 880)
    case (.terrace, 2): return (1.22, -0.020 * 440, -0.045 * 880)
    default: return (1.03, 0, 0)
    }
  }

  /// A gentle tilt parallax, so the place leans when the phone does. Collapses
  /// to nothing under Reduce Motion or on a device without the sensor.
  private var tilt: CGSize {
    guard !reduceMotion, motion.isAvailable, motion.isEnabled else { return .zero }
    return CGSize(width: motion.tilt.width * 14, height: motion.tilt.height * 10)
  }
}
