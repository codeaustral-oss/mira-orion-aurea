import SwiftUI

// MARK: - Card details
//
// The one screen that shows the whole card. The number and the CVV are hidden
// until you ask for them, and hidden again on their own: an assistant that will
// happily print a card number on request also has to be the one that puts it
// away afterwards.
//
// Nothing here is sent anywhere. The details live on this device, and the copy
// says so once, plainly, rather than in a footnote.

struct CardDetailsView: View {
  let card: CardMock

  @Environment(\.brand) private var brand
  @Environment(\.dismiss) private var dismiss

  @State private var revealed = false
  @State private var hidesAt: Date?

  /// How long the details stay on screen once they are shown.
  private let window: TimeInterval = 30

  var body: some View {
    ZStack {
      brand.canvas.ignoresSafeArea()

      VStack(spacing: 0) {
        SheetHeader(
          title: "Card details",
          subtitle: card.summary,
          onClose: { dismiss() }
        )

        ScrollView {
          VStack(alignment: .leading, spacing: Space.lg) {
            Button {
              withAnimation(.easeOut(duration: 0.25)) { revealed.toggle() }
              if revealed { hidesAt = Date().addingTimeInterval(window); scheduleHide() }
            } label: {
              MiraCardFace(card: card, style: faceStyle, revealed: revealed)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealed ? "Hide the number on the card" : "Show the number on the card")

            if card.frozen {
              Note("This card is frozen. Charges are declined until you unfreeze it.", tone: .indeterminate)
            }

            Panel {
              VStack(spacing: Space.sm) {
                revealedField(label: "Card number", value: card.pan, masked: card.masked)
                Rule()
                FieldLine(label: "Expires", value: card.expiry, mono: true)
                Rule()
                revealedField(label: "CVV", value: card.cvv, masked: card.maskedCVV)
                Rule()
                FieldLine(label: "Cardholder", value: card.holder)
                Rule()
                FieldLine(label: "Type", value: card.summary)
              }
            }

            controls

            Text(
              revealed
                ? "Shown on this screen only. Mira puts it away again in thirty seconds, and never sends it anywhere."
                : "Mira keeps the number hidden until you ask for it."
            )
            .font(MiraFont.caption(13))
            .foregroundStyle(brand.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.horizontal, Space.gutter)
          .readableWidth(600)
          .padding(.vertical, Space.lg)
        }
        .scrollIndicators(.hidden)
      }
    }
    .navigationBarHidden(true)
    .onDisappear { revealed = false }
  }

  // MARK: Controls

  @ViewBuilder
  private var controls: some View {
    if revealed {
      VStack(spacing: Space.xs) {
        Button("Hide details") {
          withAnimation(.easeOut(duration: 0.25)) { revealed = false }
        }
        .buttonStyle(BrandButtonStyle(kind: .secondary))

        if let hidesAt {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(hidesAt.timeIntervalSince(context.date).rounded()))
            Text("Hides itself in \(left)s")
              .font(MiraFont.caption(12))
              .foregroundStyle(brand.textTertiary)
              .frame(maxWidth: .infinity)
          }
        }
      }
    } else {
      Button("Show details") {
        withAnimation(.easeOut(duration: 0.25)) { revealed = true }
        hidesAt = Date().addingTimeInterval(window)
        scheduleHide()
      }
      .buttonStyle(BrandButtonStyle(kind: .primary))
    }
  }

  private var faceStyle: MiraCardFace.Style {
    switch brand.kind {
    case .orion: return .orion
    case .aurea: return .aurea(imageName: "aurea-card")
    }
  }

  // MARK: Fields

  /// A field that can be revealed and re-hidden, with the transition kept quiet.
  private func revealedField(label: String, value: String, masked: String) -> some View {
    FieldLine(label: label, value: revealed ? value : masked, mono: true)
      .contentTransition(.opacity)
      .accessibilityLabel("\(label): \(revealed ? value : "hidden")")
  }

  /// Hides the details on their own, so a card number is never left on a screen
  /// someone walked away from.
  private func scheduleHide() {
    Task {
      try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
      await MainActor.run {
        guard let hidesAt, Date() >= hidesAt else { return }
        withAnimation(.easeOut(duration: 0.25)) { revealed = false }
      }
    }
  }
}

// MARK: - Entry points

/// The button that opens the details, shared by the menu and the chat card.
struct CardDetailsButton: View {
  var card: CardMock
  var kind: BrandButtonStyle.Kind = .secondary
  var onOpen: (() -> Void)?

  @State private var showing = false

  var body: some View {
    Button("Card details") {
      if let onOpen { onOpen() } else { showing = true }
    }
    .buttonStyle(BrandButtonStyle(kind: kind))
    .sheet(isPresented: $showing) {
      CardDetailsView(card: card)
    }
    .accessibilityHint("Shows the full number and CVV on request")
  }
}
