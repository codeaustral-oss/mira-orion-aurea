import SwiftUI

/// Mira Aurea — "Looking After You."
///
/// A warm plate: cream ground, burgundy accent, display type set in a serif. The
/// assistant is engraved: a drawn orbit and a steady bead.
@main
struct MiraAureaApp: App {
  init() {
    CurrentBrand.theme = .aurea
    // Must happen before the app finishes launching, and before any wake.
    MiraBackgroundRefresh.register()
  }

  @State private var session = MiraSession(brand: .aurea, includeExampleConversation: true)
  @State private var motion = MotionSource()

  var body: some Scene {
    WindowGroup {
      MiraRoot()
        .environment(session)
        .environment(motion)
        .brand(.aurea)
        .preferredColorScheme(.light)
    }
  }
}
