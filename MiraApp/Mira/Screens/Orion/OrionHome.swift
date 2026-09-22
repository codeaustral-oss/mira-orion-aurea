import SwiftUI

/// Orion's home.
///
/// Not a tab bar over four screens. One star chart, four stations marked on it,
/// and a camera that travels between them. Choosing a station moves the chart,
/// and so does an action: pressing Send takes you to the belt, because that is
/// where things cross. The navigation is the constellation.
///
/// Black line work on paper. The earlier dark version was a night sky; this is a
/// chart, which is what the constellation actually is.
struct OrionHome: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand

  @State private var station: OrionStation = .accounts
  @State private var travelling = false
  @State private var showProfile = false

  var body: some View {
    ZStack {
      brand.canvas.ignoresSafeArea()

      // The chart sits behind everything and fades out below the top third, so
      // it never draws a line through the station's content.
      OrionField(focus: station)
        // The Mira station puts its own moving mark in the middle of the frame,
        // and the two collided. The chart steps aside for it.
        .opacity(station == .mira ? 0 : 0.85)
        .animation(.easeOut(duration: 0.4), value: station)
        .mask(
          LinearGradient(
            stops: [
              .init(color: .black, location: 0.00),
              .init(color: .black.opacity(0.55), location: 0.30),
              .init(color: .clear, location: 0.58),
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        )

      VStack(spacing: 0) {
        header

        Spacer(minLength: Space.md)

        stationContent
          .opacity(travelling ? 0 : 1)
          .animation(.easeOut(duration: 0.26), value: travelling)

        Spacer(minLength: Space.sm)

        OrionStationBar(station: $station, travel: travel)
      }
    }
    .sheet(isPresented: $showProfile) { YouView() }
    .onChange(of: session.requestedTab) { _, requested in
      guard let requested, let target = OrionStation(rawValue: requested.rawValue) else { return }
      travel(to: target)
      session.requestedTab = nil
    }
  }

  /// Move the camera. Everything that navigates in Orion goes through here, so a
  /// tap on the station bar and a tap on Send feel identical.
  private func travel(to target: OrionStation) {
    guard target != station else { return }
    travelling = true
    withAnimation(.spring(response: 1.0, dampingFraction: 0.88)) {
      station = target
    }
    Task {
      try? await Task.sleep(nanoseconds: 300_000_000)
      travelling = false
    }
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 3) {
        MiraWordmark(size: 20, color: brand.text, dotColor: brand.accent)
        Text("GO BEYOND.")
          .font(.system(size: 8, weight: .medium))
          .tracking(3.0)
          .foregroundStyle(brand.textTertiary)
      }
      Spacer()
      // The one moving thing in the chrome: a ring turning around the profile
      // mark, so the app is alive even at rest.
      Button { showProfile = true } label: {
        ZStack {
          OrbitRing(size: 44, color: brand.text, lineWidth: 0.8, period: 13, highlight: 0.2)
          Circle()
            .fill(brand.surface)
            .frame(width: 32, height: 32)
            .overlay { Circle().strokeBorder(brand.hairline, lineWidth: 1) }
          Image(systemName: "person")
            .font(.system(size: 13))
            .foregroundStyle(brand.text)
        }
        .frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("You")
    }
    .padding(.horizontal, Space.gutter)
    .padding(.top, Space.xs)
  }

  @ViewBuilder
  private var stationContent: some View {
    switch station {
    case .accounts: OrionAccounts()
    case .move: OrionMove()
    case .mira: OrionMira()
    case .you: OrionYou()
    }
  }
}

// MARK: - Station bar

/// The four stations, drawn as a small map of the figure itself: the two
/// supergiants either side, the belt across the middle, the sword below. The
/// focused stop is a filled dot; the rest are hollow.
struct OrionStationBar: View {
  @Binding var station: OrionStation
  let travel: (OrionStation) -> Void

  @Environment(\.brand) private var brand

  var body: some View {
    VStack(spacing: 0) {
      Rectangle()
        .fill(brand.hairline)
        .frame(height: 1)

      HStack(spacing: 0) {
        ForEach(OrionStation.allCases) { item in
          Button {
            travel(item)
          } label: {
            VStack(spacing: 6) {
              ZStack {
                if item == station {
                  Circle()
                    .fill(brand.text)
                    .frame(width: 9, height: 9)
                } else {
                  Circle()
                    .strokeBorder(brand.text.opacity(0.35), lineWidth: 1)
                    .frame(width: 9, height: 9)
                }
              }
              Text(item.title)
                .font(.system(size: 11, weight: item == station ? .semibold : .regular))
                .foregroundStyle(item == station ? brand.text : brand.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
    .background(brand.canvas)
  }
}

// MARK: - Paper components

/// A panel on paper: white, one hairline, no shadow.
struct PaperPanel<Content: View>: View {
  var padding: CGFloat = Space.md
  @ViewBuilder var content: () -> Content

  @Environment(\.brand) private var brand

  var body: some View {
    content()
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
          .strokeBorder(brand.hairline, lineWidth: 1)
      }
  }
}

/// Orion's figure, set for paper.
struct PaperNumber: View {
  let value: String
  var size: CGFloat = 60
  var color: Color? = nil

  @Environment(\.brand) private var brand

  var body: some View {
    Text(value)
      .font(.system(size: size, weight: .semibold).monospacedDigit())
      .tracking(-size * 0.032)
      .foregroundStyle(color ?? brand.text)
      .lineLimit(1)
      .minimumScaleFactor(0.45)
      .contentTransition(.numericText())
  }
}

/// Orion's buttons: black pill, or an outlined pill.
struct PaperButtonStyle: ButtonStyle {
  enum Kind { case filled, outlined, quiet }
  var kind: Kind = .filled
  var fullWidth: Bool = true

  @Environment(\.brand) private var brand

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 15, weight: .medium))
      .foregroundStyle(kind == .filled ? brand.canvas : brand.text)
      .padding(.vertical, 14)
      .padding(.horizontal, Space.lg)
      .frame(maxWidth: fullWidth ? .infinity : nil)
      .background(kind == .filled ? brand.text : Color.clear)
      .overlay {
        if kind == .outlined {
          Capsule().strokeBorder(brand.hairline, lineWidth: 1)
        }
      }
      .clipShape(Capsule())
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
  }
}

/// A small tracked label, used sparingly.
struct PaperLabel: View {
  let text: String
  @Environment(\.brand) private var brand

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text.uppercased())
      .font(.system(size: 8.5, weight: .medium))
      .tracking(2.2)
      .foregroundStyle(brand.textTertiary)
  }
}
