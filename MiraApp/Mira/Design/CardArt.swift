import SwiftUI

// MARK: - Card data

/// A payment card, as data.
///
/// The PAN is stored grouped as a human reads it. The face of the card shows
/// only the last four; the rest is shown in one place, on request, and hidden
/// again when you are done with it.
struct CardMock: Identifiable, Hashable, Sendable {
  enum Network: String, Hashable, Sendable {
    case visa
    case mastercard

    var displayName: String {
      switch self {
      case .visa: return "Visa"
      case .mastercard: return "Mastercard"
      }
    }
  }

  enum Kind: String, Hashable, Sendable {
    case debit
    case credit

    var displayName: String {
      switch self {
      case .debit: return "Debit"
      case .credit: return "Credit"
      }
    }
  }

  let id: String
  let nickname: String
  let holder: String
  let pan: String
  let expiry: String
  let cvv: String
  let network: Network
  let kind: Kind
  let frozen: Bool

  /// Last four only, which is all the card face ever shows.
  var last4: String { String(pan.suffix(4)) }

  var masked: String { "•••• •••• •••• \(last4)" }

  /// The CVV, held back to three dots until the details are asked for.
  var maskedCVV: String { String(repeating: "•", count: max(cvv.count, 3)) }

  var isVirtual: Bool { nickname.localizedCaseInsensitiveContains("virtual") }

  /// One line for the details screen: what this card is.
  var summary: String { "\(kind.displayName) · \(network.displayName)" }

  static let orion = CardMock(
    id: "card-orion-01",
    nickname: "Mira",
    holder: "GERARDO SALAZAR",
    pan: "4539 8821 0094 7182",
    expiry: "09/29",
    cvv: "417",
    network: .visa,
    kind: .debit,
    frozen: false
  )

  static let aurea = CardMock(
    id: "card-aurea-01",
    nickname: "Mira",
    holder: "GERARDO SALAZAR",
    pan: "5199 2244 8810 4872",
    expiry: "04/30",
    cvv: "832",
    network: .mastercard,
    kind: .credit,
    frozen: false
  )

  static let aureaVirtual = CardMock(
    id: "card-aurea-02",
    nickname: "Mira Virtual",
    holder: "GERARDO SALAZAR",
    pan: "5199 7703 5561 2094",
    expiry: "04/30",
    cvv: "294",
    network: .mastercard,
    kind: .credit,
    frozen: false
  )
}

// MARK: - Network marks

/// The card network mark.
///
/// Drawn, not an asset: these are placeholder representations for a prototype
/// and deliberately not the official artwork. In a shipping product they would
/// come from the network's own brand library, supplied under licence.
struct NetworkMark: View {
  let network: CardMock.Network
  var light: Bool = true

  private var ink: Color { light ? .white : Color(hex: 0x1A1114) }

  var body: some View {
    switch network {
    case .visa:
      VisaMark(light: light)

    case .mastercard:
      MastercardMark(light: light)
        .accessibilityLabel("Mastercard")
    }
  }
}

/// The two interlocking discs.
///
/// Drawn as three opaque regions rather than two blended circles. A blend mode
/// picks up whatever is behind it — artwork, a painted sky, a photograph — and
/// the mark disappears into the picture. Explicit regions cannot.
struct MastercardMark: View {
  var size: CGFloat = 19
  var light: Bool = true

  private let red = Color(hex: 0xD9222B)
  private let yellow = Color(hex: 0xF4A11C)
  private let amber = Color(hex: 0xE4631B)

  private var overlap: CGFloat { size * 0.62 }

  var body: some View {
    let shift = overlap / 2
    ZStack {
      Circle().fill(red).frame(width: size, height: size).offset(x: -shift)
      Circle().fill(yellow).frame(width: size, height: size).offset(x: shift)
      // The lens where the two discs meet: the yellow disc, cut to the red one.
      Circle()
        .fill(amber)
        .frame(width: size, height: size)
        .offset(x: shift)
        .mask(Circle().frame(width: size, height: size).offset(x: -shift))
    }
    .frame(width: size + overlap, height: size)
  }
}

// MARK: - Pix mark

/// The Pix mark, drawn as a placeholder.
///
/// Pix's actual logo is a specific four-part form; this is a faithful sketch of
/// its silhouette rather than the licensed artwork, which is the honest thing to
/// put in a prototype.
struct PixMark: View {
  var size: CGFloat = 22
  var color: Color = Color(hex: 0x32BCAD)

  var body: some View {
    ZStack {
      // Two interlocking rounded chevrons, rotated into the Pix diamond.
      ForEach([0.0, 90.0], id: \.self) { angle in
        RoundedRectangle(cornerRadius: size * 0.14, style: .continuous)
          .strokeBorder(color, lineWidth: size * 0.13)
          .frame(width: size * 0.60, height: size * 0.60)
          .rotationEffect(.degrees(45))
          .rotationEffect(.degrees(angle))
      }
      RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
        .fill(color)
        .frame(width: size * 0.20, height: size * 0.20)
        .rotationEffect(.degrees(45))
    }
    .frame(width: size, height: size)
    .accessibilityLabel("Pix")
  }
}

// MARK: - Card face

/// A card, rendered as a card.
///
/// Orion's is black metal with a chrome edge and no image. Aurea's is printed:
/// the plate runs full bleed, and everything that has to be read sits on a scrim
/// rather than on the picture. That is the whole difference between a card that
/// looks printed and one where white text was dropped on a painting and hoped
/// for the best.
struct MiraCardFace: View {
  let card: CardMock
  var style: Style = .orion
  /// Shows the whole number on the face instead of the last four. Off by
  /// default: a card number is shown when it is asked for, on one screen.
  var revealed: Bool = false

  enum Style {
    case orion
    /// The printed plate, full bleed, with the type and the network mark on a
    /// scrim so neither has to compete with the painting.
    case aurea(imageName: String)
  }

  @Environment(\.brand) private var brand

  private let aspect: CGFloat = 1.586

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      ZStack {
        switch style {
        case .orion:
          orionGround(size)
        case .aurea(let imageName):
          aureaGround(imageName, size: size)
        }
        content(size)
      }
      .frame(width: size.width, height: size.height)
      .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .strokeBorder(borderColor, lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.34), radius: 26, y: 16)
    }
    .aspectRatio(aspect, contentMode: .fit)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      revealed
        ? "\(card.nickname), \(card.network.rawValue), number shown"
        : "\(card.nickname), \(card.network.rawValue), ending \(card.last4)")
  }

  private var borderColor: Color {
    switch style {
    case .orion: return Color.white.opacity(0.14)
    case .aurea: return Color.black.opacity(0.10)
    }
  }

  // MARK: Grounds

  private func orionGround(_ size: CGSize) -> some View {
    ZStack {
      LinearGradient(
        stops: [
          .init(color: Color(hex: 0x1C1E22), location: 0),
          .init(color: Color(hex: 0x101114), location: 0.55),
          .init(color: Color(hex: 0x0A0B0D), location: 1),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      // A single soft chrome sweep, the way brushed metal catches a window.
      LinearGradient(
        colors: [.clear, Color.white.opacity(0.10), .clear],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .rotationEffect(.degrees(-18))
      .scaleEffect(1.6)
      .blendMode(.plusLighter)
    }
  }

  /// The plate, and the scrim that makes it a card.
  ///
  /// The scrim is not decoration: a painting is a high-contrast, high-detail
  /// ground, and type over it without one is type you cannot read. It runs in
  /// from the left where the name goes, and up from the bottom where the number
  /// and the network mark go, and it stays clear of the middle so the picture is
  /// still the picture.
  private func aureaGround(_ imageName: String, size: CGSize) -> some View {
    ZStack {
      // The field the card is printed on, in case the plate is ever missing.
      LinearGradient(
        colors: [Color(hex: 0x6A1F2B), Color(hex: 0x3E1017)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      if let image = MiraArt.image(named: imageName) {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
      }

      // Ink from the left, where the name and the opening figures sit.
      LinearGradient(
        stops: [
          .init(color: Color(hex: 0x260A10).opacity(0.90), location: 0.00),
          .init(color: Color(hex: 0x260A10).opacity(0.62), location: 0.26),
          .init(color: Color(hex: 0x260A10).opacity(0.18), location: 0.52),
          .init(color: Color(hex: 0x260A10).opacity(0.00), location: 0.78),
        ],
        startPoint: .leading,
        endPoint: .trailing
      )

      // Ink from the bottom, where the number and the mark sit.
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0.44),
          .init(color: Color(hex: 0x260A10).opacity(0.52), location: 0.74),
          .init(color: Color(hex: 0x260A10).opacity(0.86), location: 1.00),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
  }

  // MARK: Content

  private func content(_ size: CGSize) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 3) {
        Text(card.nickname.uppercased())
          .font(.system(size: 8.5, weight: .medium))
          .tracking(1.8)
          .foregroundStyle(.white.opacity(0.86))
        // Only when the nickname does not already say it.
        if card.isVirtual && !card.nickname.localizedCaseInsensitiveContains("virtual") {
          Text("VIRTUAL")
            .font(.system(size: 7, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(.white.opacity(0.58))
        }
      }
      .shadow(color: .black.opacity(0.35), radius: 6, y: 1)

      Spacer(minLength: 0)

      VStack(alignment: .leading, spacing: size.height * 0.035) {
        HStack(spacing: 6) {
          Text(revealed ? card.pan : card.masked)
            .font(.system(size: 15, weight: .medium).monospacedDigit())
            .tracking(1.1)
            .foregroundStyle(.white.opacity(0.96))
            .contentTransition(.numericText())
          Image(systemName: revealed ? "eye" : "eye.slash")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
        }
        .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
        .animation(.easeOut(duration: 0.22), value: revealed)

        HStack(alignment: .bottom, spacing: size.width * 0.06) {
          VStack(alignment: .leading, spacing: 2) {
            Text("CARDHOLDER")
              .font(.system(size: 6.5, weight: .medium))
              .tracking(1.2)
              .foregroundStyle(.white.opacity(0.55))
            Text(card.holder)
              .font(.system(size: 10, weight: .medium))
              .tracking(0.6)
              .foregroundStyle(.white.opacity(0.92))
          }
          VStack(alignment: .leading, spacing: 2) {
            Text("EXPIRES")
              .font(.system(size: 6.5, weight: .medium))
              .tracking(1.2)
              .foregroundStyle(.white.opacity(0.55))
            Text(card.expiry)
              .font(.system(size: 10, weight: .medium).monospacedDigit())
              .foregroundStyle(.white.opacity(0.92))
          }

          Spacer(minLength: 0)

          // The mark lives where a real card puts it: bottom right, on the
          // scrim, clear of the picture's subject.
          NetworkMark(network: card.network, light: true)
            .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
      }
      .padding(.bottom, size.height * 0.085)
    }
    .padding(.horizontal, size.width * 0.062)
    .padding(.top, size.height * 0.085)
    .frame(width: size.width, height: size.height)
    .overlay(alignment: .center) {
      if card.frozen {
        // Freezing is a state, so it covers the card rather than replacing it.
        ZStack {
          Rectangle().fill(Color.black.opacity(0.42))
          Image(systemName: "snowflake")
            .font(.system(size: 22, weight: .light))
            .foregroundStyle(.white.opacity(0.92))
        }
      }
    }
  }
}
