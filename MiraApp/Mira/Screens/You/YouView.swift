import SwiftUI

/// Control centre.
///
/// Everything about how the app is configured, in one place, behind one tap.
/// It also carries the reserves and the Earn position, because those are
/// settings and disclosures rather than destinations.
struct YouView: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.dismiss) private var dismiss

  @AppStorage("mira.onboarded") private var hasOnboarded = true

  var body: some View {
    ZStack {
      MiraColor.canvas.ignoresSafeArea()

      VStack(spacing: 0) {
        SheetHeader(
          title: "Controls", subtitle: "Permissions, automations, preferences",
          onClose: { dismiss() })

        ScrollView {
          VStack(alignment: .leading, spacing: Space.lg) {
            profileHeader
            card
            reserves
            permissions
            data
            history
            demo
          }
          .padding(.horizontal, Space.gutter)
          .readableWidth()
          .padding(.vertical, Space.lg)
        }
        .scrollIndicators(.hidden)
      }
    }
  }

  // MARK: Profile

  /// Whose session this is. The chooser asks; this answers, quietly, at the
  /// top of the control centre.
  private var profileHeader: some View {
    HStack(spacing: Space.md) {
      UserAvatar(persona: session.persona, size: 64)
      VStack(alignment: .leading, spacing: 3) {
        Text(session.persona.name)
          .font(MiraFont.display(22))
          .foregroundStyle(MiraColor.text)
        Text("\(session.persona.city) · \(session.persona.incomeLine)")
          .font(MiraFont.body(15))
          .foregroundStyle(MiraColor.textSecondary)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(session.persona.name), \(session.persona.city)")
  }

  // MARK: Card

  private var card: some View {
    VStack(alignment: .leading, spacing: Space.md) {
      // The card is the one place a rendered object earns the space: it is the
      // product, not decoration.
      if let image = MiraArt.image(named: Obj.card) {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: 320)
          .shadow(color: MiraColor.ink.opacity(0.18), radius: 24, y: 14)
          .frame(maxWidth: .infinity)
      }

      Panel {
        VStack(spacing: Space.sm) {
          Toggle(
            isOn: Binding(
              get: { session.cardFrozen },
              set: { session.setCardFrozen($0) }
            )
          ) {
            Text("Freeze card")
              .font(MiraFont.body(16))
              .foregroundStyle(MiraColor.text)
          }
          .tint(MiraColor.gold)

          Rule()

        }
      }
    }
  }

  // MARK: Reserves

  private var reserves: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      sectionTitle("Reserve")

      Panel {
        VStack(alignment: .leading, spacing: Space.sm) {
          HeroNumber(session.plan.reserveMoney.display, size: 34)
          Text("set aside from your available balance")
            .font(MiraFont.body(15))
            .foregroundStyle(MiraColor.textSecondary)
          Rule()
        }
      }

      Panel {
        VStack(alignment: .leading, spacing: Space.sm) {
          Text("Earn")
            .font(MiraFont.label(16))
            .foregroundStyle(MiraColor.text)
          Text("Not offered in this build.")
            .font(MiraFont.body(15))
            .foregroundStyle(MiraColor.textSecondary)
        }
      }
    }
  }

  // MARK: Permissions

  private var permissions: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      sectionTitle("What Mira may do")

      Panel {
        VStack(spacing: Space.sm) {
          Toggle(
            isOn: Binding(
              get: { session.controls.personalizedSuggestions },
              set: { session.setPersonalizedSuggestions($0) }
            )
          ) {
            Text("Suggestions")
              .font(MiraFont.body(16))
              .foregroundStyle(MiraColor.text)
          }
          .tint(MiraColor.gold)

          Rule()

          Toggle(
            isOn: Binding(
              get: { session.controls.assistantEnabled },
              set: { session.setAssistantEnabled($0) }
            )
          ) {
            Text("Ask Mira")
              .font(MiraFont.body(16))
              .foregroundStyle(MiraColor.text)
          }
          .tint(MiraColor.gold)

          Rule()

          Toggle(
            isOn: Binding(
              get: { session.renewalReminders },
              set: { session.setRenewalReminders($0) }
            )
          ) {
            Text("Reminders")
              .font(MiraFont.body(16))
              .foregroundStyle(MiraColor.text)
          }
          .tint(MiraColor.gold)

          Rule()

          Text(
            "Mira can read your balances and suggest actions. Every payment is yours to approve, and no sentence can move money on its own."
          )
          .font(MiraFont.body(14))
          .foregroundStyle(MiraColor.textTertiary)
          .fixedSize(horizontal: false, vertical: true)

          Rule()

          Text(
            "While Mira is closed it may send a nudge on the day a subscription charges, a reminder three days before a price-claim window closes, and a quiet line when a watch could not be checked. Nothing else. If notifications are off for Mira in iOS Settings, nothing arrives."
          )
          .font(MiraFont.body(14))
          .foregroundStyle(MiraColor.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  // MARK: Data

  private var data: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      sectionTitle("Data")
      Panel {
        VStack(alignment: .leading, spacing: Space.sm) {
          Button("Clear the conversation") { session.clearConversation() }
            .buttonStyle(MiraButtonStyle(kind: .secondary))
        }
      }
    }
  }

  // MARK: History

  private var history: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      sectionTitle("Recent")
      if session.actionHistory.isEmpty {
        Text("Nothing yet.")
          .font(MiraFont.body(15))
          .foregroundStyle(MiraColor.textTertiary)
      } else {
        Panel {
          VStack(alignment: .leading, spacing: Space.sm) {
            ForEach(session.actionHistory.prefix(6)) { record in
              VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                  .font(MiraFont.body(15))
                  .foregroundStyle(MiraColor.text)
                Text(record.detail)
                  .font(MiraFont.caption(12))
                  .foregroundStyle(MiraColor.textTertiary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }
      }
    }
  }

  // MARK: Demo

  private var demo: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      sectionTitle("Mira controls")

      Panel {
        VStack(alignment: .leading, spacing: Space.sm) {
          Button("Receive a deposit") { session.simulatePendingDeposit() }
            .buttonStyle(MiraButtonStyle(kind: .secondary))
          Button("Clear the deposit") { session.clearPendingDeposit() }
            .buttonStyle(MiraButtonStyle(kind: .secondary))
          Button("Let the quote expire") { session.expireActiveQuote() }
            .buttonStyle(MiraButtonStyle(kind: .secondary))

          Rule()

          FieldLine(label: "Provider", value: session.scenario.displayName)
          FieldLine(label: "Session", value: session.sessionId, mono: true)

          Button("Replay onboarding") {
            hasOnboarded = false
            dismiss()
          }
          .buttonStyle(MiraButtonStyle(kind: .quiet))
          .frame(maxWidth: .infinity)
        }
      }

    }
  }

  private func sectionTitle(_ text: String) -> some View {
    Text(text)
      .font(MiraFont.label(15))
      .foregroundStyle(MiraColor.textSecondary)
  }
}
