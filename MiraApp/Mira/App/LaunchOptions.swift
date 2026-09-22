import Foundation

// MARK: - Launch options
//
// Debug-only switches for previewing the onboarding without touching saved
// state. They are read from the process arguments, so a preview build can be
// launched straight onto any step of either scene:
//
//   -mira-preview-onboarding
//   -mira-onboarding-step 2
//   -mira-onboarding-scene plate
//
// The profile switches are the same idea for the chooser: `-profile <slug>`
// picks a person silently, so a script never has to answer a question, and
// `-profileChooser` forces the question even when a profile was named.
//
// Previewing never clears `mira.onboarded`; finishing a preview simply returns
// to the app that was already there.

struct LaunchOptions: Sendable {
  var previewOnboarding: Bool = false
  /// Zero-based step index, matching the `step` state in the onboarding views.
  var onboardingStep: Int?
  var onboardingScene: OnboardingScene?
  /// A persona slug to open as, e.g. `orion-thiago`.
  var profileSlug: String?
  /// Show the chooser even when a profile was named.
  var profileChooser: Bool = false

  /// The chooser is the question the app asks on every cold launch — unless a
  /// launch argument already named the person.
  var skipsProfileChooser: Bool { !profileChooser && profileSlug != nil }

  static let current = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)

  init() {}

  init(arguments: [String]) {
    var preview = false
    var step: Int?
    var scene: OnboardingScene?
    var profile: String?
    var chooser = false
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      let value = index + 1 < arguments.count ? arguments[index + 1] : nil
      switch argument {
      case "-mira-preview-onboarding", "--preview-onboarding":
        preview = true
      case "-mira-onboarding-step", "--onboarding-step":
        if let value, let parsed = Int(value) { step = max(0, parsed) }
      case "-mira-onboarding-scene", "--onboarding-scene":
        if let value { scene = OnboardingScene(rawValue: value.lowercased()) }
      case "-profile", "--profile":
        if let value, !value.hasPrefix("-") { profile = value }
      case "-profileChooser", "--profile-chooser", "-profile-chooser":
        chooser = true
      default:
        break
      }
      index += 1
    }
    self.previewOnboarding = preview
    self.onboardingStep = step
    self.onboardingScene = scene
    self.profileSlug = profile
    self.profileChooser = chooser
  }
}
