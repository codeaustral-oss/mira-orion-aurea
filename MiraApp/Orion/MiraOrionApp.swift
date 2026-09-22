import SwiftUI

/// Mira Orion — "Go Beyond."
///
/// Black, white and a touch of silver. The assistant is dimensional: a rendered
/// body with an orbiting companion that leans with the phone.
@main
struct MiraOrionApp: App {
  init() {
    CurrentBrand.theme = .orion
    // Must happen before the app finishes launching, and before any wake.
    MiraBackgroundRefresh.register()
  }

  @State private var session = MiraSession(brand: .orion, includeExampleConversation: true)
  @State private var motion = MotionSource()

  var body: some Scene {
    WindowGroup {
      MiraRoot()
        .environment(session)
        .environment(motion)
        .brand(.orion)
        .preferredColorScheme(.light)
    }
  }
}
