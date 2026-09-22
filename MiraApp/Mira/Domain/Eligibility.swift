import Foundation

// MARK: - Geography and language

struct Country: Hashable, Sendable, Codable, Identifiable {
  let code: String
  let name: String
  let flag: String

  var id: String { code }

  init(code: String, name: String, flag: String) {
    self.code = code
    self.name = name
    self.flag = flag
  }

  static let brazil = Country(code: "BR", name: "Brazil", flag: "🇧🇷")
  static let mexico = Country(code: "MX", name: "Mexico", flag: "🇲🇽")
  static let argentina = Country(code: "AR", name: "Argentina", flag: "🇦🇷")
  static let colombia = Country(code: "CO", name: "Colombia", flag: "🇨🇴")
  static let chile = Country(code: "CL", name: "Chile", flag: "🇨🇱")
  static let uruguay = Country(code: "UY", name: "Uruguay", flag: "🇺🇾")
  static let portugal = Country(code: "PT", name: "Portugal", flag: "🇵🇹")
  static let spain = Country(code: "ES", name: "Spain", flag: "🇪🇸")
  static let unitedStates = Country(code: "US", name: "United States", flag: "🇺🇸")

  static let all: [Country] = [
    .brazil, .mexico, .argentina, .colombia, .chile, .uruguay, .portugal, .spain, .unitedStates,
  ]
}

enum Language: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
  case english = "en"
  case spanish = "es"
  case portuguese = "pt-BR"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .english: return "English"
    case .spanish: return "Español"
    case .portuguese: return "Português (BR)"
    }
  }
}

// MARK: - User context

/// Five facts that are easy to conflate and must not be.
///
/// Someone travelling to Brazil is not thereby a Brazilian resident, is not
/// thereby eligible for a Brazilian account, and does not thereby change the
/// currency their income arrives in.
struct UserContext: Hashable, Sendable, Codable {
  /// Where the user is legally resident. Drives eligibility.
  var legalResidence: Country
  /// The country that issued the identity document on file.
  var documentCountry: Country
  /// Where the user physically is right now. Drives suggestions, not rights.
  var presentLocation: Country
  var preferredLanguage: Language
  /// The country the user wants to pay into.
  var paymentDestination: Country

  init(
    legalResidence: Country,
    documentCountry: Country,
    presentLocation: Country,
    preferredLanguage: Language,
    paymentDestination: Country
  ) {
    self.legalResidence = legalResidence
    self.documentCountry = documentCountry
    self.presentLocation = presentLocation
    self.preferredLanguage = preferredLanguage
    self.paymentDestination = paymentDestination
  }

  /// True when the user is somewhere other than where they are resident.
  var isTravelling: Bool { presentLocation != legalResidence }
}

// MARK: - Eligibility

enum EligibilityOutcome: Equatable, Sendable {
  /// The corridor may be exercised.
  case available(reason: String)
  /// More information is genuinely required before a decision.
  case needsInformation(questions: [String])
  /// The corridor may not be exercised, with a stated reason.
  case unavailable(reason: String)

  var isAvailable: Bool {
    if case .available = self { return true }
    return false
  }

  var symbol: String {
    switch self {
    case .available: return "checkmark.circle"
    case .needsInformation: return "questionmark.circle"
    case .unavailable: return "nosign"
    }
  }
}

/// A product/corridor rule set.
///
/// Product rules are simulated here. In production this is owned by the team's
/// approved eligibility service; Jev never decides eligibility.
struct CorridorRule: Hashable, Sendable, Codable {
  let id: String
  let productName: String
  let settlementCountry: Country
  let settlementCurrency: Asset
  /// Residencies that may open the product.
  let eligibleResidencies: Set<String>
  /// Document issuers accepted for identity verification.
  let acceptedDocuments: Set<String>
  let requiresLocalTaxIdentifier: Bool
  let note: String
}

struct EligibilityEngine: Sendable {
  let rules: [CorridorRule]

  init(rules: [CorridorRule]) {
    self.rules = rules
  }

  /// Evaluates a context against a specific product.
  ///
  /// Deliberately does NOT consult `presentLocation` when granting access:
  /// being in Brazil for four weeks does not make someone eligible for a
  /// Brazilian account.
  func evaluate(context: UserContext, productId: String) -> EligibilityOutcome {
    guard let rule = rules.first(where: { $0.id == productId }) else {
      return .unavailable(reason: "That product is not open here yet.")
    }

    guard rule.eligibleResidencies.contains(context.legalResidence.code) else {
      return .unavailable(
        reason:
          "\(rule.productName) is not open to residents of \(context.legalResidence.name) yet."
      )
    }

    guard rule.acceptedDocuments.contains(context.documentCountry.code) else {
      return .unavailable(
        reason:
          "The document on file was issued in \(context.documentCountry.name), which Mira cannot accept for \(rule.productName) yet."
      )
    }

    // Only ask for a tax identifier once the user is actually eligible. Asking
    // earlier would mean collecting personal data we have no reason to hold.
    if rule.requiresLocalTaxIdentifier {
      return .needsInformation(questions: [
        "What is your local tax identifier for \(rule.settlementCountry.name)?"
      ])
    }

    let travelNote =
      context.isTravelling
      ? " You're currently in \(context.presentLocation.name), which changes what Mira suggests — not what you're eligible for."
      : ""

    return .available(reason: "Based on residence in \(context.legalResidence.name).\(travelNote)")
  }

  /// The prototype's simulated product rules.
  static let prototype = EligibilityEngine(rules: [
    CorridorRule(
      id: "usd-account",
      productName: "USD account",
      settlementCountry: .unitedStates,
      settlementCurrency: .usd,
      eligibleResidencies: ["BR", "MX", "AR", "CO", "CL", "UY", "PT", "ES"],
      acceptedDocuments: ["BR", "MX", "AR", "CO", "CL", "UY", "PT", "ES"],
      requiresLocalTaxIdentifier: false,
      note: "Your receiving details are ready to share."
    ),
    CorridorRule(
      id: "brl-wallet",
      productName: "BRL wallet",
      settlementCountry: .brazil,
      settlementCurrency: .brl,
      eligibleResidencies: ["BR"],
      acceptedDocuments: ["BR"],
      requiresLocalTaxIdentifier: true,
      note:
        "A BRL wallet is for residents. Travelling to Brazil does not qualify you."
    ),
  ])
}
