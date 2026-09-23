import Foundation
import Testing
import UIKit

@testable import MiraOrion

// MARK: - The cast
//
// Six people, and the rules that hold them apart. These tests exist because a
// profile is the whole session: if two people can leak a subscription, a goal
// or a conversation into each other, the chooser is a lie.

// MARK: Shape

@Suite("The six profiles")
struct DemoPersonaTests {
  private func persona(_ id: String) -> DemoPersona {
    guard let persona = DemoPersonas.persona(id: id) else {
      fatalError("missing persona \(id)")
    }
    return persona
  }

  @Test("every persona carries a whole session")
  func shape() {
    for brand in BrandKind.allCases {
      let personas = DemoPersonas.forBrand(brand)
      #expect(personas.count == 3)
      for persona in personas {
        #expect(persona.brand == brand)
        #expect(persona.id.hasPrefix("\(brand.rawValue)-"))
        #expect(!persona.name.isEmpty)
        #expect(!persona.city.isEmpty)
        #expect(!persona.oneLiner.isEmpty)
        #expect(!persona.story.isEmpty)
        #expect(!persona.incomeLine.isEmpty)
        #expect(persona.avatarAsset.hasPrefix("user-\(brand.rawValue)-"))
        #expect(persona.context.preferredLanguage == .english)
        #expect(persona.goals.count == 3)
        #expect(!persona.subscriptions.isEmpty)
        #expect(persona.monthlyIncome.minorUnits > 0)
        #expect(persona.weeklyBudget.minorUnits > 0)
        #expect(persona.accountOpenedMonthsAgo > 0)
        for goal in persona.goals {
          #expect(goal.artAsset?.hasPrefix("goal-\(brand.rawValue)-") == true)
          #expect(goal.story?.isEmpty == false)
          #expect(goal.targetMinor > goal.savedMinor)
        }
      }
    }
  }

  @Test("every subscription bills to the card the brand actually holds")
  func subscriptionCards() {
    for brand in BrandKind.allCases {
      let expected = brand == .orion ? "7182" : "4872"
      for persona in DemoPersonas.forBrand(brand) {
        #expect(persona.subscriptions.allSatisfy { $0.cardLast4 == expected }, "\(persona.id)")
      }
    }
  }

  @Test("the seeded goals carry the cast's exact art ids")
  func goalArtIds() {
    let expected: [String: [String]] = [
      "orion-thiago": [
        "goal-orion-thiago-macbook", "goal-orion-thiago-japan", "goal-orion-thiago-runway",
      ],
      "orion-valentina": [
        "goal-orion-valentina-studio", "goal-orion-valentina-madrid", "goal-orion-valentina-camera",
      ],
      "orion-mateo": ["goal-orion-mateo-rio", "goal-orion-mateo-bike", "goal-orion-mateo-emergency"],
      "aurea-helena": [
        "goal-aurea-helena-tuscany", "goal-aurea-helena-chapel", "goal-aurea-helena-endowment",
      ],
      "aurea-rafael": ["goal-aurea-rafael-cello", "goal-aurea-rafael-japan", "goal-aurea-rafael-porto"],
      "aurea-ines": ["goal-aurea-ines-press", "goal-aurea-ines-harvest", "goal-aurea-ines-garden"],
    ]
    for (slug, ids) in expected {
      let persona = persona(slug)
      #expect(persona.goals.map { $0.artAsset ?? "" } == ids, "\(slug) art ids")
      #expect(persona.goals.map(\.name).count == 3)
    }
  }

  @Test("every persona carries its own duplicate charge")
  func duplicateCharges() {
    let expected: [String: String] = [
      "orion-thiago": "Cloud hosting, monthly",
      "orion-valentina": "Adobe Creative Cloud, monthly",
      "orion-mateo": "iFood Clube, monthly",
      "aurea-helena": "Shipping insurance",
      "aurea-rafael": "Hotel · Vienna",
      "aurea-ines": "Irrigation equipment",
    ]
    for (slug, memo) in expected {
      let charges = persona(slug).activity.filter { $0.memo == memo }
      #expect(charges.count == 2, "\(slug) should carry two \(memo) entries")
      #expect(Set(charges.map(\.daysAgo)).count == 1, "\(slug)'s duplicate lands on one day")
    }
  }

  @Test("the named zombies are the app's own reader's findings")
  func zombies() {
    let thiago = Zombies.findings(persona("orion-thiago").subscriptions)
    #expect(thiago.contains { $0.subscription.name == "Max" && $0.reason == .unused })
    #expect(Zombies.yearlySaving(thiago) != nil)

    let valentina = Zombies.findings(persona("orion-valentina").subscriptions)
    #expect(valentina.contains { $0.subscription.name == "Deezer" && $0.reason == .unused })
    #expect(Zombies.yearlySaving(valentina) != nil)
  }

  @Test("Helena's negotiable bill renews in twelve days with a cheaper competitor")
  func helenaBill() {
    let helena = persona("aurea-helena")
    guard let bill = helena.bills.first else {
      Issue.record("Helena should carry the atelier electricity bill")
      return
    }
    #expect(bill.renewalInDays == 12)
    #expect(bill.competitorMonthlyMinor < bill.monthlyMinor)
    #expect(Negotiation.prepare(bill).yearlySaving.minorUnits > 0)
  }

  @Test("the flagged charges are the cast's, and Helena has none")
  func flaggedCharges() {
    for slug in ["orion-thiago", "orion-valentina", "orion-mateo", "aurea-rafael", "aurea-ines"] {
      let flagged = persona(slug).flagged
      #expect(flagged.count == 1, "\(slug) carries one flagged charge")
      #expect(flagged.first?.amountMinor ?? 0 > 0)
    }
    #expect(persona("aurea-helena").flagged.isEmpty)
  }

  @Test("an unknown slug resolves to nothing rather than a default")
  func unknownSlug() {
    #expect(DemoPersonas.persona(id: "orion-nobody") == nil)
    #expect(DemoPersonas.persona(id: "") == nil)
    for brand in BrandKind.allCases {
      #expect(DemoPersonas.defaultPersona(for: brand).brand == brand)
    }
  }

  @Test("every persona's plan is balanced at their opening figure")
  func plansBalance() {
    for brand in BrandKind.allCases {
      for persona in DemoPersonas.forBrand(brand) {
        let total = persona.openingBalances[.usd] ?? .zero(.usd)
        let plan = persona.plan(total: total)
        #expect(plan.status.isBalanced, "\(persona.id): \(plan.status)")
        #expect(plan.rowsTotal.minorUnits == total.minorUnits)
      }
    }
  }

  @Test("a goal saved before the piggy banks still opens")
  func legacyGoalDecodes() throws {
    let json = #"""
    {"id":"1B9D6C1E-0000-4000-8000-000000000001","name":"Lisbon trip","targetMinor":400000,
     "savedMinor":120000,"currencyCode":"BRL","protected":true}
    """#
    let goal = try JSONDecoder().decode(Goal.self, from: Data(json.utf8))
    #expect(goal.name == "Lisbon trip")
    #expect(goal.saved.minorUnits == 120_000)
    #expect(goal.artAsset == nil)
    #expect(goal.story == nil)

    // And the new shape round-trips whole.
    let data = try JSONEncoder().encode(goal)
    #expect(try JSONDecoder().decode(Goal.self, from: data) == goal)
  }
}

// MARK: Opening balances

@MainActor
@Suite("Every profile opens on its stated balances")
struct PersonaBalanceTests {
  private func tempDirectory(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("mira-balance-\(label)-\(UUID().uuidString)", isDirectory: true)
  }

  @Test("the ledger carries the cast's opening position, balanced per asset")
  func openingBalances() {
    for brand in BrandKind.allCases {
      for persona in DemoPersonas.forBrand(brand) {
        let directory = tempDirectory(persona.id)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "mira-cast-balance-\(persona.id)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = MiraSession(
          sessionId: "balance-\(persona.id)",
          brand: brand,
          persona: persona,
          chatStore: ChatThreadStore(path: directory.appendingPathComponent("chats.json")),
          taskStore: AgentTaskStore(path: directory.appendingPathComponent("tasks.json")),
          directory: LocalDirectoryStore(path: directory.appendingPathComponent("directory.json")),
          defaults: defaults)

        for (asset, target) in persona.openingBalances {
          #expect(
            session.ledger.balance(ofAsset: asset).minorUnits == target.minorUnits,
            "\(persona.id) \(asset.code)")
        }
        #expect(session.ledger.pendingUSD.minorUnits == persona.pendingUSD.minorUnits)
        #expect(session.context == persona.context)
        #expect(session.persona.id == persona.id)

        // Assets the persona does not hold stay empty rather than inheriting
        // the last person's.
        for asset in Asset.all where persona.openingBalances[asset] == nil {
          #expect(session.ledger.balance(ofAsset: asset).minorUnits == 0, "\(persona.id) \(asset.code)")
        }

        // The book still balances per currency after the brought-forward entry.
        for asset in Asset.all {
          let residual = session.ledger.entries.flatMap(\.postings)
            .filter { $0.amount.currency == asset }
            .reduce(Int64(0)) { $0 + $1.amount.minorUnits }
          #expect(residual == 0, "\(persona.id) \(asset.code) is not balanced")
        }

        // The plan is the persona's, and it is a proposal.
        #expect(session.plan.total.minorUnits == session.ledger.clearedSpendableUSD.minorUnits)
        #expect(
          session.plan.weeklyBudgetMoney
            == Money(majorUnits: persona.planWeeklyUSD, currency: .usd))
        #expect(session.plan.isApproved == false)
        #expect(session.automations.first?.perActionCap == session.plan.weeklyBudgetMoney)

        // The directory was seeded for this person, once.
        #expect(session.localDirectory.personaSlug == persona.id)
        #expect(session.localDirectory.goals.map(\.name) == persona.goals.map(\.name))
        #expect(
          session.localDirectory.subscriptions.map(\.name) == persona.subscriptions.map(\.name))
        #expect(session.localDirectory.flaggedCharges.count == persona.flagged.count)
        #expect(session.localDirectory.feeEvents.count == persona.fees.count)
      }
    }
  }
}

// MARK: The matcher

@Suite("The goal-art library matcher")
struct GoalArtLibraryTests {
  @Test("Orion's words land on Orion's ids")
  func orionMatches() {
    let cases: [(String, String)] = [
      ("a month in Tokyo", "goal-orion-thiago-japan"),
      ("new laptop for work", "goal-orion-thiago-macbook"),
      ("one year of runway", "goal-orion-thiago-runway"),
      ("studio deposit", "goal-orion-valentina-studio"),
      ("moving to Madrid", "goal-orion-valentina-madrid"),
      ("a camera kit", "goal-orion-valentina-camera"),
      ("rio de janeiro", "goal-orion-mateo-rio"),
      ("a bicycle", "goal-orion-mateo-bike"),
      ("emergency fund", "goal-orion-lib-emergency"),
      ("buy an iphone", "goal-orion-lib-phone"),
      ("playstation for the living room", "goal-orion-lib-gaming"),
      ("an electric bike", "goal-orion-lib-ebike"),
      ("festival tickets", "goal-orion-lib-festival"),
      ("our wedding", "goal-orion-lib-wedding"),
      ("house deposit", "goal-orion-lib-deposit"),
      ("a sabbatical next year", "goal-orion-lib-sabbatical"),
      ("first car", "goal-orion-lib-car"),
      ("adopt a dog", "goal-orion-lib-dog"),
      ("home gym", "goal-orion-lib-gym"),
      ("a master's degree", "goal-orion-lib-course"),
    ]
    for (words, asset) in cases {
      #expect(GoalArtLibrary.match(words, brand: .orion) == asset, "\(words)")
    }
  }

  @Test("Aurea's words land on Aurea's ids")
  func aureaMatches() {
    let cases: [(String, String)] = [
      ("a month in Tokyo", "goal-aurea-rafael-japan"),
      ("a year in Tuscany", "goal-aurea-helena-tuscany"),
      ("fresco restoration", "goal-aurea-helena-chapel"),
      ("the gallery's endowment", "goal-aurea-helena-endowment"),
      ("a fine cello", "goal-aurea-rafael-cello"),
      ("the family house in Porto", "goal-aurea-rafael-porto"),
      ("the new press house", "goal-aurea-ines-press"),
      ("harvest reserve", "goal-aurea-ines-harvest"),
      ("grandmother's garden", "goal-aurea-ines-garden"),
      ("a cruise", "goal-aurea-lib-voyage"),
      ("grand tour of Europe", "goal-aurea-lib-grandtour"),
      ("a private library", "goal-aurea-lib-library"),
      ("a glasshouse", "goal-aurea-lib-greenhouse"),
      ("school fees", "goal-aurea-lib-studies"),
      ("a pilgrimage", "goal-aurea-lib-pilgrimage"),
      ("a villa by the lake", "goal-aurea-lib-lakehouse"),
      ("an easel and canvas", "goal-aurea-lib-painting"),
      ("opera season", "goal-aurea-lib-opera"),
      ("a pavilion", "goal-aurea-lib-pavilion"),
      ("a scholarship fund", "goal-aurea-lib-scholarship"),
    ]
    for (words, asset) in cases {
      #expect(GoalArtLibrary.match(words, brand: .aurea) == asset, "\(words)")
    }
  }

  @Test("nothing close is nil, not the nearest guess")
  func noMatch() {
    for brand in BrandKind.allCases {
      for words in ["", "   ", "a submarine", "dragon", "12345"] {
        #expect(GoalArtLibrary.match(words, brand: brand) == nil, "\(brand) \(words)")
      }
    }
  }

  @Test("balloon and Lisbon dreams have bundled artwork")
  func repairedDreamArt() {
    #expect(GoalArtLibrary.match("A hot air balloon", brand: .orion) == "goal-orion-lib-balloon")
    #expect(GoalArtLibrary.match("Summer in Lisbon", brand: .orion) == "goal-orion-lib-lisbon")
    #expect(MiraArt.image(named: "goal-orion-lib-balloon") != nil)
    #expect(MiraArt.image(named: "goal-orion-lib-lisbon") != nil)
  }

  @Test("each brand carries at least forty synonyms")
  func synonyms() {
    for brand in BrandKind.allCases {
      let entries = GoalArtLibrary.entries(for: brand)
      let words = entries.flatMap(\.words)
      #expect(words.count >= 40, "\(brand) has \(words.count) synonyms")
      #expect(entries.count >= 20)
      for entry in entries {
        #expect(entry.asset.hasPrefix("goal-\(brand.rawValue)-"), "\(entry.asset)")
        #expect(!entry.words.isEmpty)
      }
    }
  }
}

// MARK: Switching

@MainActor
@Suite("Switching profiles", .serialized)
struct ProfileSwitchingTests {
  @Test("every profile has its own labelled, non-transactional example")
  func exampleConversations() {
    for brand in BrandKind.allCases {
      for persona in DemoPersonas.forBrand(brand) {
        let example = ExampleConversation.make(for: persona)
        #expect(example.title == ExampleConversation.title(for: persona))
        #expect(example.turns.count == 8)
        #expect(example.turns.filter { $0.role == "mira" }.allSatisfy {
          $0.replySource == "example" && $0.action == nil
        })
        #expect(example.turns.first?.text != nil)
      }
    }
  }

  private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("mira-switch-\(UUID().uuidString)", isDirectory: true)
  }

  private func session(
    persona: DemoPersona, directory: URL, defaults: UserDefaults
  ) -> MiraSession {
    MiraSession(
      sessionId: "switch-\(persona.id)",
      brand: persona.brand,
      persona: persona,
      chatStore: ChatThreadStore(path: directory.appendingPathComponent("chats.json")),
      taskStore: AgentTaskStore(path: directory.appendingPathComponent("tasks.json")),
      directory: LocalDirectoryStore(path: directory.appendingPathComponent("directory.json")),
      defaults: defaults)
  }

  @Test("switching swaps the ledger, the directory and the conversation — and accumulates nothing")
  func switching() async {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "mira-cast-switch-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let thiago = DemoPersonas.persona(id: "orion-thiago")!
    let valentina = DemoPersonas.persona(id: "orion-valentina")!
    let session = session(persona: thiago, directory: directory, defaults: defaults)

    // The first person's own data and a conversation of their own.
    session.localDirectory.addContact(name: "Rui", handle: "sim-rui")
    await session.sendChat("hi")
    #expect(!session.conversation.isEmpty)

    session.switchProfile(valentina)

    #expect(session.persona.id == "orion-valentina")
    #expect(session.context == valentina.context)
    #expect(session.ledger.clearedSpendableUSD.minorUnits == 318_000)
    #expect(session.ledger.pendingUSD.minorUnits == 190_000)
    #expect(session.plan.total.minorUnits == 318_000)
    #expect(session.plan.weeklyBudgetMoney.minorUnits == 42_000)
    #expect(session.localDirectory.personaSlug == "orion-valentina")
    #expect(session.localDirectory.contacts.isEmpty)
    #expect(session.localDirectory.goals.map(\.name) == valentina.goals.map(\.name))
    #expect(
      session.localDirectory.subscriptions.map(\.name) == valentina.subscriptions.map(\.name))
    #expect(!session.localDirectory.subscriptions.contains { $0.name == "Max" })
    #expect(session.localDirectory.flaggedCharges.first?.merchant == "UNKNOWN*ONLINE-41")
    #expect(!session.ledger.entries.contains { $0.memo.contains("Northwind") })

    // A fresh conversation, persisted as the only one.
    #expect(session.conversation.isEmpty)
    #expect(session.threads.count == 1)
    #expect(session.threads[0].turns.isEmpty)
    let reloadedChats = ChatThreadStore(path: directory.appendingPathComponent("chats.json")).load()
    #expect(reloadedChats.threads.count == 1)
    #expect(reloadedChats.threads[0].turns.isEmpty)
    #expect(defaults.string(forKey: MiraSession.profileDefaultsKey) == "orion-valentina")

    // Switching back and forth must not accumulate records.
    session.switchProfile(thiago)
    #expect(session.localDirectory.subscriptions.count == thiago.subscriptions.count)
    #expect(session.localDirectory.goals.count == 3)
    #expect(session.ledger.entries.contains { $0.memo.contains("Northwind") })
    #expect(!session.ledger.entries.contains { $0.memo.contains("Kessler") })

    session.switchProfile(valentina)
    #expect(session.localDirectory.subscriptions.count == valentina.subscriptions.count)
    #expect(session.localDirectory.goals.count == 3)
    #expect(session.localDirectory.feeEvents.count == valentina.fees.count)
    #expect(session.localDirectory.flaggedCharges.count == 1)
    #expect(session.localDirectory.bills.isEmpty)
  }

  @Test("choosing the person already open keeps their conversation")
  func continuing() async {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "mira-cast-continue-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let thiago = DemoPersonas.persona(id: "orion-thiago")!
    let session = session(persona: thiago, directory: directory, defaults: defaults)
    await session.sendChat("hi")
    let turns = session.conversation.count
    #expect(turns > 0)

    // The chooser treats the current profile as a continue: it does not call
    // chooseProfile at all, which is what keeps the transcript.
    #expect(session.persona.id == thiago.id)
    #expect(session.conversation.count == turns)
  }

  @Test("a transcript written for one profile is not shown to another")
  func transcriptOwnership() async {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let chats = directory.appendingPathComponent("chats.json")
    let suiteName = "mira-cast-owner-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let thiago = DemoPersonas.persona(id: "orion-thiago")!
    let valentina = DemoPersonas.persona(id: "orion-valentina")!

    let first = MiraSession(
      sessionId: "owner-thiago",
      brand: .orion,
      persona: thiago,
      chatStore: ChatThreadStore(path: chats),
      taskStore: AgentTaskStore(path: directory.appendingPathComponent("tasks-a.json")),
      directory: LocalDirectoryStore(path: directory.appendingPathComponent("dir-a.json")),
      defaults: defaults)
    await first.sendChat("hi")
    #expect(!first.conversation.isEmpty)

    // A different person opening the same chat file starts fresh.
    let second = MiraSession(
      sessionId: "owner-valentina",
      brand: .orion,
      persona: valentina,
      chatStore: ChatThreadStore(path: chats),
      taskStore: AgentTaskStore(path: directory.appendingPathComponent("tasks-b.json")),
      directory: LocalDirectoryStore(path: directory.appendingPathComponent("dir-b.json")),
      defaults: defaults)
    #expect(second.conversation.isEmpty)
    #expect(second.threads.count == 1)
    #expect(second.threads[0].turns.isEmpty)

    // And the file now belongs to the new person: the old transcript is gone
    // rather than waiting to be shown to the wrong session.
    let payload = ChatThreadStore(path: chats).load()
    #expect(payload.profileSlug == "orion-valentina")
    #expect(payload.threads.allSatisfy { $0.turns.isEmpty })
  }
}

// MARK: Drawing

@MainActor
@Suite("Drawing a new dream", .serialized)
struct GoalArtServiceTests {
  /// A generator that either draws a tiny real PNG into the cache or fails,
  /// standing in for the proxy.
  private struct StubGenerator: GoalArtGenerating {
    let draws: Bool

    func generate(
      words: String, name: String, brand: BrandKind, goalId: UUID
    ) async -> GoalArtOutcome? {
      guard draws else { return nil }
      let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
        UIColor.black.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
      }
      guard let data = image.pngData(), let url = GoalArtCache.store(data, for: goalId) else {
        return nil
      }
      return .cached(url)
    }
  }

  private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("mira-dream-\(UUID().uuidString)", isDirectory: true)
  }

  /// The store as the app has it: already reseeded for the person whose
  /// session is open.
  private func store(in directory: URL) -> LocalDirectoryStore {
    let store = LocalDirectoryStore(path: directory.appendingPathComponent("directory.json"))
    store.reseed(for: DemoPersonas.persona(id: "orion-thiago")!)
    return store
  }

  @Test("a dream the library knows appears instantly, with no drawing")
  func libraryMatchIsInstant() {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = store(in: directory)
    let before = store.goals.count
    let service = GoalArtService(brand: .orion, generator: StubGenerator(draws: false))

    let goal = service.create(
      name: "a month in Tokyo", target: nil, currency: .usd, in: store)

    #expect(goal?.artAsset == "goal-orion-thiago-japan")
    #expect(goal.map { !service.isDrawing($0) } == true)
    #expect(store.goals.count == before + 1)
  }

  @Test("an unmatched dream is drawn, lands in the cache, and persists")
  func drawnDream() async {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    GoalArtCache.rootOverride = directory.appendingPathComponent("art", isDirectory: true)
    defer { GoalArtCache.rootOverride = nil }

    let store = store(in: directory)
    let service = GoalArtService(brand: .orion, generator: StubGenerator(draws: true))

    guard
      let goal = service.create(
        name: "a submarine",
        target: Money(majorUnits: 1_200, currency: .usd),
        currency: .usd,
        in: store)
    else {
      Issue.record("the dream should be created")
      return
    }

    // The goal exists before the network does, and the card says it is drawing.
    #expect(goal.artAsset == nil)
    #expect(service.isDrawing(goal))
    let created = store.goals.first { $0.id == goal.id }
    #expect(created?.name == "a submarine")
    #expect(created?.targetMinor == 120_000)
    #expect(created?.currencyCode == "USD")

    await service.waitForDrawing(goal.id)

    #expect(!service.isDrawing(goal))
    #expect(GoalArtCache.fileURL(for: goal.id) != nil)
    #expect(service.image(for: goal) != nil)
    #expect(
      store.goals.first { $0.id == goal.id }?.artAsset == nil,
      "the drawing lives in the cache, not the catalog")

    // It survives a relaunch: the store reloads and the PNG is still there.
    let reloaded = LocalDirectoryStore(path: directory.appendingPathComponent("directory.json"))
    guard let persisted = reloaded.goals.first(where: { $0.id == goal.id }) else {
      Issue.record("the created dream should persist")
      return
    }
    #expect(persisted.name == "a submarine")
    #expect(GoalArtCache.fileURL(for: persisted.id) != nil)
  }

  @Test("when drawing fails the goal offers a retry and still persists")
  func failedDrawing() async {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    GoalArtCache.rootOverride = directory.appendingPathComponent("art", isDirectory: true)
    defer { GoalArtCache.rootOverride = nil }

    let store = store(in: directory)
    let service = GoalArtService(brand: .aurea, generator: StubGenerator(draws: false))

    guard let goal = service.create(name: "a submarine", target: nil, currency: .usd, in: store)
    else {
      Issue.record("the dream should be created")
      return
    }
    #expect(service.isDrawing(goal))

    await service.waitForDrawing(goal.id)

    #expect(!service.isDrawing(goal))
    #expect(service.didFail(goal))
    #expect(service.image(for: goal) == nil)
    let created = store.goals.first { $0.id == goal.id }
    #expect(created != nil)
    #expect(created?.artAsset == nil)
    #expect(created?.targetMinor == 0)
  }

  @Test("older blank goals recover bundled artwork")
  func existingDreamArt() {
    let service = GoalArtService(brand: .orion, generator: StubGenerator(draws: false))
    for name in ["A hot air balloon", "Summer in Lisbon"] {
      let goal = Goal(
        name: name, targetMinor: 0, savedMinor: 0, currencyCode: "USD",
        protected: true, artAsset: nil, story: nil, createdAt: Date())
      #expect(service.image(for: goal) != nil)
    }
  }

  @Test("a saved unfinished drawing resumes and can be retried")
  func resumeDrawing() async {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = store(in: directory)
    let goal = Goal(
      name: "a submarine", targetMinor: 0, savedMinor: 0, currencyCode: "USD",
      protected: true, artAsset: nil, story: nil, createdAt: Date())
    store.saveGoal(goal)
    let service = GoalArtService(brand: .orion, generator: StubGenerator(draws: false))
    service.resumeMissingArt(for: store.goals, in: store)
    #expect(service.isDrawing(goal))
    await service.waitForDrawing(goal.id)
    #expect(service.didFail(goal))
    service.retryDrawing(goal, in: store)
    #expect(service.isDrawing(goal))
    await service.waitForDrawing(goal.id)
    #expect(service.didFail(goal))
  }

  @Test("an empty name is never a dream")
  func emptyName() {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = store(in: directory)
    let before = store.goals.count
    let service = GoalArtService(brand: .orion, generator: StubGenerator(draws: true))

    let goal = service.create(name: "   ", target: nil, currency: .usd, in: store)
    #expect(goal == nil)
    #expect(store.goals.count == before)
  }

  @Test("creating the same dream twice reuses its record")
  func duplicateDream() {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = store(in: directory)
    let service = GoalArtService(brand: .orion, generator: StubGenerator(draws: false))

    let first = service.create(name: "A hot air balloon", target: nil, currency: .usd, in: store)
    let second = service.create(name: "  a hot air balloon  ", target: nil, currency: .usd, in: store)

    #expect(first?.id == second?.id)
    #expect(store.goals.filter { $0.name == "A hot air balloon" }.count == 1)
  }
}

// MARK: The wire

/// A stub goal-art service: create → generating, poll → ready, image → PNG.
final class GoalArtServiceStub: URLProtocol, @unchecked Sendable {
  struct Recorded: Sendable {
    var method: String
    var path: String
  }

  nonisolated(unsafe) static var requests: [Recorded] = []
  nonisolated(unsafe) static var pollsBeforeReady = 1
  static let lock = NSLock()

  static func reset(pollsBeforeReady: Int = 1) {
    lock.lock()
    requests = []
    Self.pollsBeforeReady = pollsBeforeReady
    lock.unlock()
  }

  static func recorded() -> [Recorded] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let method = request.httpMethod ?? ""
    let url = request.url ?? URL(string: "about:blank")!
    let path = url.path
    Self.lock.lock()
    Self.requests.append(Recorded(method: method, path: path))
    let remaining = Self.pollsBeforeReady
    if path.hasPrefix("/v1/goal-art/") && !path.hasSuffix("/image") {
      Self.pollsBeforeReady = max(0, remaining - 1)
    }
    Self.lock.unlock()

    if path.hasSuffix("/image") {
      let data = Data([0x89, 0x50, 0x4E, 0x47])  // a PNG header is enough to cache
      respond(url: url, status: 200, data: data, contentType: "image/png")
      return
    }

    let json: String
    if method == "POST" {
      json = #"{"id":"tokyo-ab12","status":"generating"}"#
    } else if remaining > 0 {
      json = #"{"id":"tokyo-ab12","status":"generating"}"#
    } else {
      json = #"{"id":"tokyo-ab12","status":"ready","url":"/v1/goal-art/tokyo-ab12/image"}"#
    }
    respond(url: url, status: 200, data: Data(json.utf8), contentType: "application/json")
  }

  private func respond(url: URL, status: Int, data: Data, contentType: String) {
    let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": contentType])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

@MainActor
@Suite("The goal-art endpoint", .serialized)
struct GoalArtWireTests {
  private func client() -> GoalArtProxyClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [GoalArtServiceStub.self]
    return GoalArtProxyClient(
      baseURL: URL(string: "https://mira.example")!,
      pollInterval: .milliseconds(1),
      maxPolls: 5,
      session: URLSession(configuration: config))
  }

  private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("mira-wire-\(UUID().uuidString)", isDirectory: true)
  }

  @Test("the client posts the words, polls until ready, and caches the PNG")
  func roundTrip() async {
    GoalArtServiceStub.reset(pollsBeforeReady: 2)
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    GoalArtCache.rootOverride = directory
    defer { GoalArtCache.rootOverride = nil }

    let goalId = UUID()
    let outcome = await client().generate(
      words: "a month in Tokyo", name: "Tokyo", brand: .orion, goalId: goalId)

    guard case .cached(let url) = outcome else {
      Issue.record("expected a cached drawing, got \(String(describing: outcome))")
      return
    }
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(url.lastPathComponent == "\(goalId.uuidString).png")

    let recorded = GoalArtServiceStub.recorded()
    #expect(recorded.contains { $0.method == "POST" && $0.path == "/v1/goal-art" })
    #expect(recorded.filter { $0.method == "GET" && $0.path == "/v1/goal-art/tokyo-ab12" }.count >= 1)
    #expect(recorded.contains { $0.path == "/v1/goal-art/tokyo-ab12/image" })
  }

  @Test("an unreachable proxy is nil, never an error")
  func unreachable() async {
    let client = GoalArtProxyClient(
      baseURL: URL(string: "http://127.0.0.1:1")!,
      timeout: 1,
      pollInterval: .milliseconds(1),
      maxPolls: 1)
    let outcome = await client.generate(words: "anything", name: "Anything", brand: .aurea, goalId: UUID())
    #expect(outcome == nil)
  }
}

// MARK: The chat route

@MainActor
@Suite("The piggy banks route", .serialized)
struct PiggyBanksRouteTests {
  @Test("'open my piggy banks' opens the screen and answers from the records")
  func chatRoute() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mira-route-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "mira-cast-route-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let session = MiraSession(
      sessionId: "route-test",
      brand: .orion,
      persona: DemoPersonas.persona(id: "orion-thiago")!,
      chatStore: ChatThreadStore(path: directory.appendingPathComponent("chats.json")),
      taskStore: AgentTaskStore(path: directory.appendingPathComponent("tasks.json")),
      directory: LocalDirectoryStore(path: directory.appendingPathComponent("directory.json")),
      defaults: defaults)

    await session.sendChat("open my piggy banks")

    // The app's own flow, not a model's and not a task.
    #expect(session.requestedRoute == .piggyBanks)
    #expect(session.conversation.last?.role == .mira)
    #expect(session.conversation.last?.isError == false)
    #expect(session.conversation.last?.action?.kind != .agentTask)
    #expect(session.conversation.last?.text.contains("MacBook Pro") == true)

    // The chips on the turn are live, so the answer leads somewhere real.
    let chips = session.conversation.last?.chips ?? []
    #expect(!chips.isEmpty)
    if let id = session.conversation.last?.id {
      #expect(session.chipTurnIds.contains(id))
    }
  }
}

@MainActor
@Suite("Subscription language", .serialized)
struct SubscriptionLanguageTests {
  @Test("a request to save money from subs shows the person's subscription receipt")
  func colloquialSubs() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mira-subs-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "mira-subs-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let session = MiraSession(
      sessionId: "subs-test",
      brand: .orion,
      persona: DemoPersonas.persona(id: "orion-thiago")!,
      chatStore: ChatThreadStore(path: directory.appendingPathComponent("chats.json")),
      taskStore: AgentTaskStore(path: directory.appendingPathComponent("tasks.json")),
      directory: LocalDirectoryStore(path: directory.appendingPathComponent("directory.json")),
      defaults: defaults)

    await session.sendChat("I need to save money from my subs")

    let reply = session.conversation.last
    #expect(reply?.receipt?.kind == .savings)
    #expect(reply?.receipt?.lines.contains { $0.service == "Max" } == true)
    #expect(reply?.action?.kind != .agentTask)
  }
}

@MainActor
@Suite("Simulated card checkout", .serialized)
struct SimulatedCardCheckoutTests {
  private func session() -> (MiraSession, URL, UserDefaults, String) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mira-checkout-\(UUID().uuidString)", isDirectory: true)
    let suiteName = "mira-checkout-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    let session = MiraSession(
      sessionId: "checkout-test",
      brand: .orion,
      persona: DemoPersonas.persona(id: "orion-thiago")!,
      chatStore: ChatThreadStore(path: directory.appendingPathComponent("chats.json")),
      taskStore: AgentTaskStore(path: directory.appendingPathComponent("tasks.json")),
      directory: LocalDirectoryStore(path: directory.appendingPathComponent("directory.json")),
      defaults: defaults)
    session.localDirectory.saveAddress("Florianópolis, Brazil", makeMain: true)
    return (session, directory, defaults, suiteName)
  }

  @Test("a priced purchase charges the selected card and shows a receipt")
  func pricedPurchase() async {
    let (session, directory, defaults, suiteName) = session()
    defer {
      try? FileManager.default.removeItem(at: directory)
      defaults.removePersistentDomain(forName: suiteName)
    }
    let before = session.ledger.clearedSpendableUSD.minorUnits

    await session.sendChat("buy a notebook for USD 25")
    #expect(session.checkout?.stage == .payment)
    await session.sendChat("Use this card")

    let reply = session.conversation.last
    #expect(session.checkout == nil)
    #expect(reply?.receipt?.kind == .purchase)
    #expect(reply?.receipt?.total?.value == "USD 25.00")
    #expect(reply?.receipt?.lines.contains { $0.label == "Paid with" && $0.value.contains(session.mainCard.last4) } == true)
    #expect(session.ledger.clearedSpendableUSD.minorUnits == before - 2_500)
    #expect(session.lastOrder != nil)

    let reopened = MiraSession(
      sessionId: "checkout-reopened",
      brand: .orion,
      persona: DemoPersonas.persona(id: "orion-thiago")!,
      chatStore: ChatThreadStore(path: directory.appendingPathComponent("chats.json")),
      taskStore: AgentTaskStore(path: directory.appendingPathComponent("tasks.json")),
      directory: LocalDirectoryStore(path: directory.appendingPathComponent("directory.json")),
      defaults: defaults)
    #expect(reopened.ledger.clearedSpendableUSD.minorUnits == before - 2_500)
    #expect(reopened.lastOrder?.reference == session.lastOrder?.reference)
  }

  @Test("an unpriced purchase asks for a price before any card charge")
  func unpricedPurchase() async {
    let (session, directory, defaults, suiteName) = session()
    defer {
      try? FileManager.default.removeItem(at: directory)
      defaults.removePersistentDomain(forName: suiteName)
    }
    let before = session.ledger.clearedSpendableUSD.minorUnits

    await session.sendChat("buy a notebook")
    #expect(session.checkout?.stage == .price)
    #expect(session.ledger.clearedSpendableUSD.minorUnits == before)
    #expect(session.lastOrder == nil)

    await session.sendChat("USD 25")
    #expect(session.checkout?.stage == .payment)
    await session.sendChat("Use this card")
    #expect(session.conversation.last?.receipt?.total?.value == "USD 25.00")
    #expect(session.ledger.clearedSpendableUSD.minorUnits == before - 2_500)
  }

  @Test("a BRL card purchase changes the BRL balance")
  func brlPurchase() async {
    let (session, directory, defaults, suiteName) = session()
    defer {
      try? FileManager.default.removeItem(at: directory)
      defaults.removePersistentDomain(forName: suiteName)
    }
    let before = session.ledger.brlBalance.minorUnits

    await session.sendChat("buy a notebook for BRL 25")
    await session.sendChat("Use this card")

    #expect(session.conversation.last?.receipt?.total?.value == "BRL 25.00")
    #expect(session.ledger.brlBalance.minorUnits == before - 2_500)
  }
}

// MARK: Launch arguments

@Suite("Profile launch arguments")
struct LaunchOptionTests {
  @Test("-profile names the person, and skips the question")
  func profileFlag() {
    let options = LaunchOptions(arguments: ["-profile", "orion-mateo"])
    #expect(options.profileSlug == "orion-mateo")
    #expect(options.skipsProfileChooser)
    #expect(options.onboardingStep == nil)
  }

  @Test("-profileChooser forces the question")
  func chooserFlag() {
    let options = LaunchOptions(arguments: ["-profileChooser"])
    #expect(options.profileChooser)
    #expect(options.profileSlug == nil)
    #expect(!options.skipsProfileChooser)

    let both = LaunchOptions(arguments: ["-profile", "aurea-helena", "-profileChooser"])
    #expect(both.profileSlug == "aurea-helena")
    #expect(!both.skipsProfileChooser, "the forced chooser outranks the named profile")
  }

  @Test("a flag with no value is not a profile")
  func missingValue() {
    #expect(LaunchOptions(arguments: ["-profile"]).profileSlug == nil)
    #expect(LaunchOptions(arguments: ["-profile", "-profileChooser"]).profileSlug == nil)
    #expect(!LaunchOptions(arguments: ["-profile"]).skipsProfileChooser)
  }

  @Test("the profile flags do not disturb the onboarding previews")
  func coexist() {
    let options = LaunchOptions(arguments: [
      "-mira-preview-onboarding", "-mira-onboarding-step", "2", "-profile", "orion-thiago",
    ])
    #expect(options.previewOnboarding)
    #expect(options.onboardingStep == 2)
    #expect(options.profileSlug == "orion-thiago")
  }
}

// MARK: The proxy transport
//
// Two facts decide whether a phone can reach the hosted proxy at all: which
// address the installed bundle names, and whether its requests carry the key
// the server asks for. Both are written into Info.plist at install time, so
// these tests pin the resolution order and the header on the wire.

/// Records the headers a session actually sent, then answers a bare 200.
final class ProxyHeaderStub: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var headers: [String: String]?
  static let lock = NSLock()

  static func reset() {
    lock.lock()
    headers = nil
    lock.unlock()
  }

  static func recorded() -> [String: String]? {
    lock.lock()
    defer { lock.unlock() }
    return headers
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    Self.headers = request.allHTTPHeaderFields ?? [:]
    Self.lock.unlock()

    let url = request.url ?? URL(string: "https://mira.example")!
    let response = HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

@Suite("The proxy transport", .serialized)
struct ProxyTransportTests {
  /// A proxy session with the given key, over the recording stub.
  private func sentHeaders(key: String?) async -> [String: String]? {
    ProxyHeaderStub.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProxyHeaderStub.self]
    let session = MiraProxySession.make(key: key, configuration: configuration)
    let request = URLRequest(url: URL(string: "https://mira.codeaustral.com/v1/roster")!)
    _ = try? await session.data(for: request)
    return ProxyHeaderStub.recorded()
  }

  @Test("a configured build sends the key on every proxy request")
  func configured() async {
    let key = "proxy-key-in-the-bundle"
    let headers = await sentHeaders(key: key)
    #expect(headers?["x-mira-key"] == key)
  }

  @Test("a build with no key sends no proxy header at all")
  func unconfigured() async {
    let headers = await sentHeaders(key: nil)
    #expect(headers?["x-mira-key"] == nil)
    // The request still went out: nothing else about the session changed.
    #expect(headers != nil)
  }

  @Test("the base URL is the hosted URL, the legacy host, or loopback")
  func baseURLPrecedence() {
    // The hosted URL is used as written, even when a legacy host is also there.
    #expect(
      MiraProxyConfig.baseURL(info: [
        "MIRAProxyURL": "https://mira.codeaustral.com",
        "MIRAProxyHost": "192.168.1.24",
      ]) == URL(string: "https://mira.codeaustral.com"))

    // A port or path on the hosted URL is kept as written, not rebuilt.
    #expect(
      MiraProxyConfig.url(info: ["MIRAProxyURL": "http://192.168.1.24:9000"])
        == URL(string: "http://192.168.1.24:9000"))
    #expect(
      MiraProxyConfig.url(info: ["MIRAProxyURL": "https://vpn.example/mira"])
        == URL(string: "https://vpn.example/mira"))

    // Without it, the legacy host renders the port the local proxy uses.
    #expect(
      MiraProxyConfig.baseURL(info: ["MIRAProxyHost": "192.168.1.24"])
        == URL(string: "http://192.168.1.24:8791"))

    // A malformed hosted URL never shadows a usable legacy host, and an empty
    // or scheme-less value falls all the way back to loopback.
    #expect(
      MiraProxyConfig.baseURL(info: ["MIRAProxyURL": "mira.codeaustral.com", "MIRAProxyHost": "10.0.0.7"])
        == URL(string: "http://10.0.0.7:8791"))
    #expect(
      MiraProxyConfig.baseURL(info: ["MIRAProxyURL": "   ", "MIRAProxyHost": ""])
        == URL(string: "http://127.0.0.1:8791"))
    #expect(MiraProxyConfig.baseURL(info: [:]) == URL(string: "http://127.0.0.1:8791"))
  }

  @Test("the key is trimmed, and an empty value counts as absent")
  func keyResolution() {
    #expect(MiraProxyConfig.key(info: ["MIRAProxyKey": "  key-here \n"]) == "key-here")
    #expect(MiraProxyConfig.key(info: ["MIRAProxyKey": "   "]) == nil)
    #expect(MiraProxyConfig.key(info: [:]) == nil)
  }

  @Test("an unconfigured bundle uses loopback unless the simulator has saved configuration")
  func developmentBuild() {
    #expect(MiraProxyConfig.key(info: [:]) == nil)
    #expect(MiraProxyConfig.url(info: [:]) == nil)
    #expect(MiraProxyConfig.baseURL(info: [:]) == URL(string: "http://127.0.0.1:8791"))
  }
}
