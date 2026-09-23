import Foundation
import Observation
import UIKit

// MARK: - The library
//
// Twelve dreams a brand can draw without asking anyone, plus the seeded goals
// themselves. A new dream that matches one of these is instant and free; only
// a dream nothing matches is worth a live drawing.

/// One catalog dream, with the words that lead to it.
struct GoalArtEntry: Sendable, Equatable {
  let asset: String
  let label: String
  let words: [String]
}

enum GoalArtLibrary {
  /// The library, the seeded goals and the live matcher all read the same
  /// table. Persona goals come first so a word that names a seeded dream
  /// ("endowment") lands on that dream rather than on the closest library one.
  static func entries(for brand: BrandKind) -> [GoalArtEntry] {
    switch brand {
    case .orion:
      return [
        GoalArtEntry(
          asset: "goal-orion-thiago-macbook", label: "MacBook Pro",
          words: ["macbook", "laptop", "new laptop", "mac", "computer"]),
        GoalArtEntry(
          asset: "goal-orion-thiago-japan", label: "Japan in April",
          words: ["japan", "tokyo", "kyoto", "blossom", "japan trip"]),
        GoalArtEntry(
          asset: "goal-orion-thiago-runway", label: "One year of runway",
          words: ["runway", "a year off", "financial independence", "freedom fund", "year of runway"]),
        GoalArtEntry(
          asset: "goal-orion-valentina-studio", label: "Studio deposit",
          words: ["studio", "design studio", "studio deposit", "workspace"]),
        GoalArtEntry(
          asset: "goal-orion-valentina-madrid", label: "Madrid move",
          words: ["madrid", "move abroad", "relocation", "moving to spain"]),
        GoalArtEntry(
          asset: "goal-orion-valentina-camera", label: "Camera kit",
          words: ["camera", "camera kit", "lens", "photography gear"]),
        GoalArtEntry(
          asset: "goal-orion-mateo-rio", label: "Rio weekend",
          words: ["rio", "rio de janeiro", "weekend trip", "beach trip"]),
        GoalArtEntry(
          asset: "goal-orion-mateo-bike", label: "A bike",
          words: ["bike", "bicycle", "cycling", "road bike"]),
        GoalArtEntry(
          asset: "goal-orion-lib-emergency", label: "Emergency fund",
          words: ["emergency", "safety net", "rainy day", "buffer", "cushion"]),
        GoalArtEntry(
          asset: "goal-orion-lib-phone", label: "A new phone",
          words: ["phone", "iphone", "smartphone", "handset", "new phone"]),
        GoalArtEntry(
          asset: "goal-orion-lib-gaming", label: "A games console",
          words: ["gaming", "console", "playstation", "xbox", "switch", "games"]),
        GoalArtEntry(
          asset: "goal-orion-lib-ebike", label: "An e-bike",
          words: ["ebike", "e-bike", "electric bike", "scooter", "moped"]),
        GoalArtEntry(
          asset: "goal-orion-lib-festival", label: "A festival",
          words: ["festival", "concert", "gig", "music festival", "tickets"]),
        GoalArtEntry(
          asset: "goal-orion-lib-wedding", label: "A wedding",
          words: ["wedding", "marriage", "rings", "honeymoon", "bride", "groom"]),
        GoalArtEntry(
          asset: "goal-orion-lib-deposit", label: "A home deposit",
          words: ["deposit", "house deposit", "apartment", "flat", "down payment", "first home"]),
        GoalArtEntry(
          asset: "goal-orion-lib-sabbatical", label: "A sabbatical",
          words: ["sabbatical", "time off", "gap year", "career break", "deck chair"]),
        GoalArtEntry(
          asset: "goal-orion-lib-car", label: "A car",
          words: ["car", "hatchback", "vehicle", "first car", "used car"]),
        GoalArtEntry(
          asset: "goal-orion-lib-dog", label: "A dog",
          words: ["dog", "puppy", "leash", "adopt a dog", "pet"]),
        GoalArtEntry(
          asset: "goal-orion-lib-gym", label: "A home gym",
          words: ["gym", "home gym", "weights", "dumbbells", "bench", "fitness"]),
        GoalArtEntry(
          asset: "goal-orion-lib-course", label: "A course",
          words: ["course", "bootcamp", "degree", "graduation", "certification", "masters"]),
      ]

    case .aurea:
      return [
        GoalArtEntry(
          asset: "goal-aurea-helena-tuscany", label: "A year in Tuscany",
          words: ["tuscany", "year in italy", "florence", "siena", "italian year"]),
        GoalArtEntry(
          asset: "goal-aurea-helena-chapel", label: "The chapel fresco",
          words: ["fresco", "chapel fresco", "restoration", "frescoes"]),
        GoalArtEntry(
          asset: "goal-aurea-helena-endowment", label: "The gallery's endowment",
          words: ["endowment", "gallery endowment", "foundation", "endowment fund"]),
        GoalArtEntry(
          asset: "goal-aurea-rafael-cello", label: "A fine cello",
          words: ["cello", "instrument", "violin", "viola", "strings"]),
        GoalArtEntry(
          asset: "goal-aurea-rafael-japan", label: "A season in Japan",
          words: ["japan", "tokyo", "tokyo season", "osaka", "japan tour"]),
        GoalArtEntry(
          asset: "goal-aurea-rafael-porto", label: "The family house in Porto",
          words: ["porto", "porto alegre", "family house", "house in brazil"]),
        GoalArtEntry(
          asset: "goal-aurea-ines-press", label: "The new press house",
          words: ["press house", "winery", "wine press", "cellar", "vineyard"]),
        GoalArtEntry(
          asset: "goal-aurea-ines-harvest", label: "Harvest reserve",
          words: ["harvest", "harvest reserve", "crop", "vendange"]),
        GoalArtEntry(
          asset: "goal-aurea-ines-garden", label: "Grandmother's garden",
          words: ["garden", "roses", "courtyard", "grandmother's garden"]),
        GoalArtEntry(
          asset: "goal-aurea-lib-wedding", label: "A wedding",
          words: ["wedding", "marriage", "rings", "anniversary", "bride"]),
        GoalArtEntry(
          asset: "goal-aurea-lib-voyage", label: "A voyage",
          words: ["voyage", "cruise", "liner", "sea crossing", "ocean trip"]),
        GoalArtEntry(
          asset: "goal-aurea-lib-grandtour", label: "A grand tour",
          words: ["grand tour", "europe tour", "coach", "classical road", "italy tour"]),
        GoalArtEntry(
          asset: "goal-aurea-lib-library", label: "A private library",
          words: ["library", "private library", "books", "book room", "reading room"]),
        GoalArtEntry(
          asset: "goal-aurea-lib-greenhouse", label: "A glasshouse",
          words: ["greenhouse", "glasshouse", "conservatory", "garden house", "orchard"]),
        GoalArtEntry(
          asset: "goal-aurea-lib-studies", label: "Studies for a grandchild",
          words: ["studies", "tuition", "school fees", "university", "college"]),
        GoalArtEntry(
          asset: "goal-aurea-lib-pilgrimage", label: "A pilgrimage",
          words: ["pilgrimage", "chapel", "santiago", "camino", "holy road"]),
        GoalArtEntry(
          asset: "goal-aurea-lib-lakehouse", label: "A house by the lake",
          words: ["lake house", "villa", "summer house", "house by the lake"]),
        GoalArtEntry(
          asset: "goal-aurea-lib-painting", label: "An easel",
          words: ["painting", "easel", "canvas", "atelier", "art studio"]),
        GoalArtEntry(
          asset: "goal-aurea-lib-opera", label: "An opera season",
          words: ["opera", "opera house", "ballet", "concert season", "season tickets"]),
        GoalArtEntry(
          asset: "goal-aurea-lib-pavilion", label: "A garden pavilion",
          words: ["pavilion", "gazebo", "tea house", "garden room"]),
        GoalArtEntry(
          asset: "goal-aurea-lib-scholarship", label: "A scholarship",
          words: ["scholarship", "fellowship", "grant", "open book", "laurel"]),
      ]
    }
  }

  /// The closest catalog dream for a name, or nil when nothing is close. Nil is
  /// a real answer: it is what makes a live drawing worth asking for.
  static func match(_ name: String, brand: BrandKind) -> String? {
    let haystack = normalise(name)
    guard !haystack.isEmpty else { return nil }

    var best: (asset: String, score: Int)?
    for entry in entries(for: brand) {
      var score = 0
      let label = normalise(entry.label)
      if !label.isEmpty, haystack.contains(label) || label.contains(haystack) { score += 3 }
      for word in entry.words {
        let needle = normalise(word)
        guard !needle.isEmpty else { continue }
        // A phrase match is more specific than a single word: "an electric
        // bike" is the e-bike, not the bicycle.
        if haystack.contains(needle) || needle.contains(haystack) {
          score += needle.contains(" ") ? 4 : 2
        }
      }
      if score > 0, score > (best?.score ?? 0) {
        best = (entry.asset, score)
      }
    }
    return best?.asset
  }

  /// Lowercased, punctuation flattened to spaces, so "a month in Tokyo" and
  /// "month-in-tokyo" read the same.
  private static func normalise(_ text: String) -> String {
    text.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// MARK: - What a drawing resolved to

enum GoalArtOutcome: Equatable, Sendable {
  /// A catalog asset the app already holds.
  case asset(String)
  /// A PNG received from the proxy and cached on this device.
  case cached(URL)
  /// Nothing was drawn. The card stays quiet rather than showing a placeholder.
  case none
}

/// The live half of the service, injectable so the create flow can be driven
/// without a network in tests.
protocol GoalArtGenerating: Sendable {
  /// Ask for a drawing. Nil on any failure — the person never sees an error.
  func generate(words: String, name: String, brand: BrandKind, goalId: UUID) async -> GoalArtOutcome?
}

// MARK: - The proxy client

/// Talks to the goal-art endpoint: create, poll, fetch the PNG.
///
/// Reuses the app's proxy base URL and proxy session, so a simulator reaches
/// the Mac's loopback and a device build reaches the address `point-app.sh`
/// wrote into its Info.plist — with the key when that bundle carries one. Every
/// failure path is silent: art is a nicety, not a task.
struct GoalArtProxyClient: GoalArtGenerating {
  let baseURL: URL
  let timeout: TimeInterval
  /// How long to wait between polls, and the most polls before giving up.
  let pollInterval: Duration
  let maxPolls: Int
  let session: URLSession

  init(
    baseURL: URL = JevProxyClient.defaultBaseURL,
    timeout: TimeInterval = 8,
    // A drawing takes as long as it takes; the app waits in the background,
    // never in front of the person, and the card simply keeps its shape.
    pollInterval: Duration = .milliseconds(1_500),
    maxPolls: Int = 160,
    // Proxy traffic: the session attaches the key when the installed bundle
    // carries one (a simulator build without it simply sends nothing).
    session: URLSession = .miraProxy
  ) {
    self.baseURL = baseURL
    self.timeout = timeout
    self.pollInterval = pollInterval
    self.maxPolls = maxPolls
    self.session = session
  }

  func generate(words: String, name: String, brand: BrandKind, goalId: UUID) async -> GoalArtOutcome? {
    guard let job = await create(words: words, name: name, brand: brand) else { return nil }

    var current = job
    var polls = 0
    while current.status == "generating", polls < maxPolls {
      try? await Task.sleep(for: pollInterval)
      guard !Task.isCancelled else { return nil }
      guard let next = await fetch(id: current.id) else { return nil }
      current = next
      polls += 1
    }
    guard current.status == "ready" else { return nil }

    let imageURL = current.url.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
      ?? baseURL.appendingPathComponent("v1/goal-art/\(current.id)/image")
    guard let data = await imageData(from: imageURL), !data.isEmpty,
      let cached = GoalArtCache.store(data, for: goalId)
    else { return nil }
    return .cached(cached)
  }

  private func create(words: String, name: String, brand: BrandKind) async -> Job? {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/goal-art"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = timeout
    request.httpBody = try? JSONEncoder().encode(
      CreateBody(brand: brand.rawValue, words: words, name: name))
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      let job = try? JSONDecoder().decode(Job.self, from: data)
    else { return nil }
    return job
  }

  private func fetch(id: String) async -> Job? {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/goal-art/\(id)"))
    request.timeoutInterval = timeout
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      let job = try? JSONDecoder().decode(Job.self, from: data)
    else { return nil }
    return job
  }

  private func imageData(from url: URL) async -> Data? {
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
    else { return nil }
    return data
  }

  private struct CreateBody: Encodable {
    let brand: String
    let words: String
    let name: String
  }

  private struct Job: Decodable {
    let id: String
    let status: String
    let url: String?
  }
}

// MARK: - The cache

/// The drawings this device has received, one PNG per goal. Application
/// Support, beside the directory, so a created dream survives relaunch.
enum GoalArtCache {
  /// Redirectable so tests never write into the app's own store.
  nonisolated(unsafe) static var rootOverride: URL?

  static func directory() -> URL {
    if let rootOverride { return rootOverride }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("Mira", isDirectory: true)
      .appendingPathComponent("goal-art", isDirectory: true)
  }

  static func fileURL(for goalId: UUID) -> URL? {
    let url = directory().appendingPathComponent("\(goalId.uuidString).png")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// Writes the PNG atomically and answers with where it landed.
  @discardableResult
  static func store(_ data: Data, for goalId: UUID) -> URL? {
    let directory = directory()
    let url = directory.appendingPathComponent("\(goalId.uuidString).png")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }
}

// MARK: - The service

/// The carousel's art: catalog first, cached drawing second, nothing last.
///
/// The service owns the create flow's drawing state, because that state belongs
/// to a goal rather than to a card: a card can scroll out of the carousel while
/// its drawing is still coming back.
@MainActor
@Observable
final class GoalArtService {
  enum Phase: Equatable, Sendable {
    case idle
    case drawing
    case ready
  }

  let brand: BrandKind
  private(set) var phase: [UUID: Phase] = [:]
  private(set) var images: [UUID: UIImage] = [:]
  @ObservationIgnored private let generator: any GoalArtGenerating
  @ObservationIgnored private var drawingTasks: [UUID: Task<Void, Never>] = [:]
  /// Images read back from disk. Kept out of the observed state because the
  /// resolver runs during a view's body, and a body must not publish.
  @ObservationIgnored private var diskCache: [UUID: UIImage] = [:]

  init(brand: BrandKind = CurrentBrand.theme.kind, generator: any GoalArtGenerating = GoalArtProxyClient()) {
    self.brand = brand
    self.generator = generator
  }

  /// The image a card shows: the catalog asset when it exists, the cached
  /// drawing when one landed, and nothing at all otherwise. A missing image is
  /// a quieter card, never a placeholder.
  func image(for goal: Goal) -> UIImage? {
    if let asset = goal.artAsset, let image = MiraArt.image(named: asset) {
      return image
    }
    if let image = images[goal.id] { return image }
    if let image = diskCache[goal.id] { return image }
    guard let url = GoalArtCache.fileURL(for: goal.id),
      let image = UIImage(contentsOfFile: url.path)
    else { return nil }
    diskCache[goal.id] = image
    return image
  }

  func isDrawing(_ goal: Goal) -> Bool { phase[goal.id] == .drawing }

  /// A new dream. The catalog is checked first — a match is instant — and only
  /// an unmatched dream is drawn. The goal is persisted before anything
  /// network-shaped happens, so it survives a relaunch mid-drawing. An empty
  /// name is not a dream and is never written.
  @discardableResult
  func create(name: String, target: Money?, currency: Asset, in store: LocalDirectoryStore) -> Goal? {
    let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    let targetMinor = target?.minorUnits ?? 0
    let currencyCode = (target?.currency ?? currency).code
    if let existing = store.goals.first(where: {
      $0.name.compare(cleaned, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        && $0.targetMinor == targetMinor
        && $0.currencyCode == currencyCode
    }) {
      return existing
    }
    let goal = Goal(
      name: cleaned,
      targetMinor: targetMinor,
      savedMinor: 0,
      currencyCode: currencyCode,
      protected: true,
      artAsset: GoalArtLibrary.match(cleaned, brand: brand),
      story: nil,
      createdAt: Date())
    store.saveGoal(goal)

    guard goal.artAsset == nil else {
      phase[goal.id] = .ready
      return goal
    }
    phase[goal.id] = .drawing
    drawingTasks[goal.id] = Task { [weak self] in
      await self?.draw(goal, in: store)
    }
    return goal
  }

  /// Waits for a drawing that is in flight. Exists so a test can hold the same
  /// edge the screen holds: drawing, then ready.
  func waitForDrawing(_ goalId: UUID) async {
    await drawingTasks[goalId]?.value
  }

  private func draw(_ goal: Goal, in store: LocalDirectoryStore) async {
    defer {
      phase[goal.id] = .ready
      drawingTasks[goal.id] = nil
    }
    guard
      let outcome = await generator.generate(
        words: goal.name, name: goal.name, brand: brand, goalId: goal.id)
    else { return }

    switch outcome {
    case .asset(let asset):
      var updated = goal
      updated.artAsset = asset
      store.saveGoal(updated)
    case .cached(let url):
      if let image = UIImage(contentsOfFile: url.path) { images[goal.id] = image }
    case .none:
      break
    }
  }
}
