import SwiftUI
import UIKit

// MARK: - Art

/// Cached access to the generated dimensional objects.
///
/// A missing asset degrades to nothing rather than to a placeholder shape: these
/// are decorative depth elements, and a scene with one fewer object is still a
/// correct scene. Nothing here is load-bearing.
enum MiraArt {
  private static var cache: [String: UIImage] = [:]
  private static let lock = NSLock()

  static func image(named name: String) -> UIImage? {
    lock.lock()
    if let cached = cache[name] {
      lock.unlock()
      return cached
    }
    lock.unlock()

    let image = UIImage(named: name)
    if let image {
      lock.lock()
      cache[name] = image
      lock.unlock()
    }
    return image
  }

  static func exists(_ name: String) -> Bool { image(named: name) != nil }
}

/// Every object the app composes into a scene.
///
/// Names resolve against the active brand: Orion is black, white and silver, so
/// it draws the chrome set, while Aurea draws the warm gold one. Call sites ask
/// for "the sphere" and never for a metal.
enum Obj {
  /// Polished sphere. The brand dot, made physical.
  static var sphere: String { resolve("obj-sphere") }
  /// Fine ring, tilted.
  static var ring: String { resolve("obj-ring") }
  /// Payment card.
  static var card: String { resolve("obj-card") }
  /// Smoked-glass slab that sits behind a figure.
  static var slab: String { resolve("obj-slab") }
  /// Soft porcelain forms for light depth.
  static var forms: String { resolve("obj-forms") }
  /// Receding grid plane.
  static var grid: String { resolve("obj-grid") }

  /// Objects that exist in both a warm and a neutral metal.
  private static let metals: Set<String> = ["obj-sphere", "obj-ring", "obj-card"]

  private static func resolve(_ base: String) -> String {
    guard CurrentBrand.theme.kind == .orion, metals.contains(base) else { return base }
    return "\(base)-silver"
  }
}

// MARK: - Scenes

extension DepthScene where Overlay == EmptyView {
  /// Onboarding: one gold sphere, close, with soft porcelain forms behind it.
  /// The sphere is the only sharp thing in the frame, which is what makes it
  /// the subject.
  static func onboarding(step: Int) -> DepthScene<EmptyView> {
    // Each step moves the camera slightly: the sphere drifts, the porcelain
    // forms shift the other way. Small numbers, real depth.
    let sphereDepth = 0.92
    let drift: [UnitPoint] = [
      UnitPoint(x: 0.68, y: 0.30),
      UnitPoint(x: 0.74, y: 0.38),
      UnitPoint(x: 0.62, y: 0.26),
      UnitPoint(x: 0.70, y: 0.44),
    ]
    let center = drift[min(step, drift.count - 1)]

    return DepthScene(
      objects: [
        DepthObject(
          imageName: Obj.forms, depth: 0.18, width: 1.05, center: UnitPoint(x: 0.42, y: 0.62),
          opacity: 0.9, blur: 2.5),
        DepthObject(
          imageName: Obj.ring, depth: 0.55, width: 0.30, center: UnitPoint(x: 0.22, y: 0.24),
          opacity: 0.95, spin: -12),
        DepthObject(imageName: Obj.sphere, depth: sphereDepth, width: 0.46, center: center),
      ],
      grid: true,
      gridDepth: 0.06,
      maxRotation: 8,
      parallax: 40,
      overlay: { EmptyView() }
    )
  }

  /// A quiet depth field for the main screens.
  ///
  /// The receding floor is Orion's motif: a cool, near-white ground with a faint
  /// grid. Aurea stays flat — a neutral almost-white canvas where the burgundy
  /// and the portraits carry the character — so the grid is drawn only for
  /// Orion.
  static func gridField() -> DepthScene<EmptyView> {
    DepthScene(
      objects: [],
      grid: CurrentBrand.theme.kind == .orion,
      gridDepth: 0.05,
      maxRotation: 4,
      parallax: 18,
      overlay: { EmptyView() }
    )
  }
}
