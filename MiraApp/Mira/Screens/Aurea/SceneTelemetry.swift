import SwiftUI

// MARK: - Telemetry
//
// Ledger references, rail keys and quoted rates, spawning across the water —
// small monospaced notes that appear over the lake, hold for a few seconds while
// their value ticks, and fade as the next one arrives somewhere else.
//
// Not a feed and not a list: the picture is a place, and these are the things
// the product is quietly keeping track of while you look at it. They never sit
// over the type, and they never claim to be an amount the user holds.

struct SceneNote: Identifiable, Hashable {
  let id: String
  /// The values it cycles through, one every few seconds.
  let variants: [String]
  /// An emphasised note carries a solid gold marker.
  var primary: Bool = false
}

/// One note: a marker, a string, and enough plate to hold it over a painting.
struct SceneNoteView: View {
  let note: SceneNote
  let text: String
  var compact: Bool = false

  private var marker: Color { Color(hex: 0xE5C987) }

  var body: some View {
    HStack(spacing: compact ? 4 : 6) {
      Circle()
        .fill(note.primary ? marker : marker.opacity(0.55))
        .frame(width: note.primary ? 4 : 3, height: note.primary ? 4 : 3)

      Text(text)
        .font(.system(size: compact ? 8 : 9, weight: .medium, design: .monospaced))
        .tracking(0.3)
        .foregroundStyle(.white.opacity(note.primary ? 0.92 : 0.74))
        .lineLimit(1)
        .contentTransition(.numericText())
    }
    .padding(.horizontal, compact ? 6 : 8)
    .padding(.vertical, compact ? 3 : 4)
    .background(
      Color(hex: 0x140C10).opacity(0.46),
      in: RoundedRectangle(cornerRadius: 4, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
    }
    .accessibilityHidden(true)
  }
}

/// The notes over the water.
///
/// Three slots, each on its own cycle: a note spawns at an anchor, holds while
/// its value ticks, and fades out as the next slot spawns somewhere else. The
/// anchors are the lake and its shores — never the type zone.
struct LakeNotes: View {
  let step: Int
  let canvas: CGSize
  /// Notes on screen at once.
  private let slots = 3
  /// Seconds between arrivals.
  private let interval: Double = 3.4
  /// Seconds a note stays.
  private let lifetime: Double = 9.0

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Where notes may appear, as fractions of the canvas: across the water, the
  /// far shore and the sky above it, and never in the lower third where the copy
  /// and the buttons live.
  private static let anchors: [UnitPoint] = [
    UnitPoint(x: 0.30, y: 0.225),
    UnitPoint(x: 0.62, y: 0.200),
    UnitPoint(x: 0.72, y: 0.300),
    UnitPoint(x: 0.44, y: 0.320),
    UnitPoint(x: 0.24, y: 0.400),
    UnitPoint(x: 0.64, y: 0.425),
    UnitPoint(x: 0.42, y: 0.500),
    UnitPoint(x: 0.70, y: 0.530),
    UnitPoint(x: 0.50, y: 0.255),
    UnitPoint(x: 0.22, y: 0.520),
  ]

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.4)) { context in
      let t = context.date.timeIntervalSinceReferenceDate

      ZStack {
        ForEach(0..<slots, id: \.self) { slot in
          let index = Int(t / interval) - slot
          if index >= 0, let note = note(at: index) {
            let age = t - Double(index) * interval
            if age < lifetime {
              SceneNoteView(note: note, text: value(of: note, at: t, index: index))
                .position(
                  x: canvas.width * anchor(index: index, slot: slot).x,
                  y: canvas.height * anchor(index: index, slot: slot).y
                )
                .opacity(fade(age: age))
                .scaleEffect(reduceMotion ? 1 : 0.94 + 0.06 * min(1, age / 0.6))
            }
          }
        }
      }
    }
    .allowsHitTesting(false)
  }

  /// A note is fully there for most of its life: it fades in over the first
  /// half-second and out over the last two.
  private func fade(age: Double) -> Double {
    guard !reduceMotion else { return 1 }
    let inFade = min(1, age / 0.5)
    let outFade = min(1, max(0, (lifetime - age) / 2.0))
    return min(inFade, outFade)
  }

  /// Anchors walk a fixed, coprime stride so consecutive notes land far apart
  /// without ever needing a random source.
  private func anchor(index: Int, slot: Int) -> UnitPoint {
    let stride = 7
    let position = (index * stride + slot * 3) % Self.anchors.count
    return Self.anchors[(position + Self.anchors.count) % Self.anchors.count]
  }

  private func note(at index: Int) -> SceneNote? {
    let pool = register
    guard !pool.isEmpty else { return nil }
    let wrapped = ((index % pool.count) + pool.count) % pool.count
    return pool[wrapped]
  }

  /// A note's value moves while it is on screen — rates drift, references
  /// advance — so a note that lingers is never a still image.
  private func value(of note: SceneNote, at t: Double, index: Int) -> String {
    guard note.variants.count > 1 else { return note.variants.first ?? "" }
    let tick = Int((t + Double(index) * 0.7) / 2.8)
    let wrapped = ((tick % note.variants.count) + note.variants.count) % note.variants.count
    return note.variants[wrapped]
  }

  /// The register, by step: what Mira is keeping track of while you look at the
  /// place. Everything here is the app's own synthetic book — never a figure the
  /// user is meant to read as theirs.
  private var register: [SceneNote] {
    switch step {
    case 0:
      return [
        SceneNote(id: "a-hold", variants: ["USDC 1,350.00 · holding", "USDC 1,362.50 · holding"]),
        SceneNote(id: "a-in", variants: ["+ USD 1,203.40 · inbound"], primary: true),
        SceneNote(id: "a-ref", variants: ["settled 12:04 · ref 0x77b1…e204", "settled 12:07 · ref 0x77b1…1f80"]),
        SceneNote(id: "a-key", variants: ["0xSIM4A7F2C91B8E3D6051AC · base"]),
        SceneNote(id: "a-entry", variants: ["entry 0x4f2a…9c81 · balanced", "entry 0x4f2a…b7c3 · balanced"]),
        SceneNote(id: "a-res", variants: ["reserve held · USD 1,000.00"]),
      ]
    case 1:
      return [
        SceneNote(id: "b-usdc", variants: ["USDC 1,350.00 · holding", "USDC 1,375.00 · holding"], primary: true),
        SceneNote(id: "b-rate", variants: ["1 USD = 5.0000 BRL", "1 USD = 4.9987 BRL", "1 USD = 5.0012 BRL"]),
        SceneNote(id: "b-rails", variants: ["3 rails · 4 assets · 1 ledger"]),
        SceneNote(id: "b-pix", variants: ["sim-pix-ana-0192 · BRL 150.00"]),
        SceneNote(id: "b-eur", variants: ["EUR 420.00 · savings", "EUR 428.00 · savings"]),
      ]
    case 2:
      return [
        SceneNote(id: "c-pix", variants: ["sim-pix-ana-0192 · BRL 150.00"], primary: true),
        SceneNote(id: "c-rate", variants: ["1 USD = 5.0000 BRL · fee 0.30", "1 USD = 5.0012 BRL · fee 0.30"]),
        SceneNote(id: "c-flight", variants: ["in flight · 0x0a51…88f3"]),
        SceneNote(id: "c-quote", variants: ["quote held · 120s", "quote held · 96s", "quote held · 71s"]),
        SceneNote(id: "c-key", variants: ["key sim-pix-ana-0192 · verified"]),
      ]
    default:
      return [
        SceneNote(id: "d-journal", variants: ["journal 0417 · balanced", "journal 0418 · balanced"], primary: true),
        SceneNote(id: "d-chain", variants: ["0xSIM9C1E5B7A2D4F80316BE · ethereum"]),
        SceneNote(id: "d-recon", variants: ["reconciled · no second debit"]),
        SceneNote(id: "d-approve", variants: ["you approved · ref 0x77b1…e204"]),
        SceneNote(id: "d-sum", variants: ["committed + unallocated = available"]),
      ]
    }
  }
}

// MARK: - A note in a panel

/// The same idea, at home inside a panel: one quiet reference under a figure.
struct FieldNote: View {
  let text: String
  var primary: Bool = false

  @Environment(\.brand) private var brand

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(brand.accent.opacity(primary ? 1 : 0.45))
        .frame(width: primary ? 4 : 3, height: primary ? 4 : 3)
      Text(text)
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .tracking(0.3)
        .foregroundStyle(brand.textTertiary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .accessibilityHidden(true)
  }
}
