import CoreMotion
import SwiftUI

// MARK: - Motion source

/// Merges device tilt into a single normalised value the parallax world can use.
///
/// Deliberately forgiving:
///  - On a simulator (or a device without the sensor) tilt stays at zero and
///    the world simply runs on ambient drift and gesture pan.
///  - Values are low-pass filtered, so the scene glides instead of jittering.
///  - Everything stops when the system asks for reduced motion.
@MainActor
@Observable
final class MotionSource {
  /// Normalised tilt, roughly -1...1 on each axis.
  private(set) var tilt: CGSize = .zero
  /// False on simulators and devices without device motion.
  private(set) var isAvailable: Bool = false

  var isEnabled: Bool = true {
    didSet {
      guard oldValue != isEnabled else { return }
      isEnabled ? start() : stop()
    }
  }

  private let manager = CMMotionManager()
  private let queue: OperationQueue = {
    let q = OperationQueue()
    q.name = "mira.motion"
    q.maxConcurrentOperationCount = 1
    q.qualityOfService = .userInteractive
    return q
  }()

  /// Low-pass factor. Higher = smoother and lazier.
  private let smoothing: Double = 0.14
  /// Keep the scene calm: never let a tilt push the art around.
  private let maxTilt: Double = 1.0

  init() {}

  func start() {
    guard isEnabled, manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
    isAvailable = true
    manager.deviceMotionUpdateInterval = 1.0 / 30.0
    manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
      guard let motion else { return }
      // Roll drives horizontal, pitch drives vertical. Both clamped and
      // scaled so holding the phone normally sits near centre.
      let roll = motion.attitude.roll
      let pitch = motion.attitude.pitch
      let x = max(-1, min(1, roll / (.pi / 3)))
      let y = max(-1, min(1, (pitch - (.pi / 2.6)) / (.pi / 4)))
      Task { @MainActor [weak self] in
        guard let self, self.isEnabled else { return }
        self.tilt = CGSize(
          width: self.tilt.width + (x - self.tilt.width) * self.smoothing,
          height: self.tilt.height + (y - self.tilt.height) * self.smoothing
        )
      }
    }
  }

  func stop() {
    if manager.isDeviceMotionActive {
      manager.stopDeviceMotionUpdates()
    }
    tilt = .zero
  }

  /// Recentres the scene, for example when a screen disappears.
  func reset() {
    tilt = .zero
  }

  deinit {
    if manager.isDeviceMotionActive {
      manager.stopDeviceMotionUpdates()
    }
  }
}

// MARK: - Environment
//
// The shared source is injected with `.environment(motionSource)` and read with
// `@Environment(MotionSource.self)`, which is the @Observable-native path.
