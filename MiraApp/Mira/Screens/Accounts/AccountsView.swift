import SwiftUI

/// Today.
///
/// One number, and one line that qualifies it. Everything else in this app is
/// reachable from here in a single tap, and deliberately absent from here.
struct AccountsView: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dismiss) private var dismiss

  @State private var showReceive = false

  var body: some View {
    ZStack {
      DepthScene.gridField()

      VStack(spacing: 0) {
        SheetHeader(
          title: "Accounts", subtitle: "Where the money is",
          onClose: { dismiss() })

        Spacer(minLength: Space.lg)

        figure

        Spacer(minLength: Space.lg)

        VStack(spacing: Space.md) {
          actions
        }
        .padding(.horizontal, Space.gutter)
        .readableWidth()
        .padding(.bottom, Space.md)
      }
    }
    .navigationBarHidden(true)
    .sheet(isPresented: $showReceive) { ReceiveSheet() }
  }

  // MARK: The number

  private var figure: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Text("Available")
        .font(MiraFont.body(16))
        .foregroundStyle(MiraColor.textSecondary)

      HeroNumber(session.clearedUSD.display, size: 72)

      // Exactly one qualifier. The weekly figure lives on Plan; the reserve
      // lives on Plan; pending appears here only when it exists, because a
      // pending deposit is the one thing that changes what "available" means.
      Text(qualifier)
        .font(MiraFont.body(16))
        .foregroundStyle(MiraColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      if let alert = session.activePayment, alert.state.isUnknown {
        Note(
          "A payment is unresolved. Mira will not retry it until the provider answers.",
          tone: .indeterminate
        )
        .padding(.top, Space.xs)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Space.gutter)
    .readableWidth()
    .animation(.easeOut(duration: 0.35), value: session.clearedUSD.minorUnits)
  }

  private var qualifier: String {
    if session.pendingUSD.minorUnits > 0 {
      return "\(session.pendingUSD.display) is still pending and is not counted here."
    }
    return "\(session.currentWeekRemaining.display) left to spend this week."
  }

  // MARK: Actions

  private var actions: some View {
    HStack(spacing: Space.xs) {
      Button("Pay") { session.requestTab(.move) }
        .buttonStyle(MiraButtonStyle(kind: .primary))
      Button("Receive") { showReceive = true }
        .buttonStyle(MiraButtonStyle(kind: .secondary))
    }
  }
}

// MARK: - Receive

/// Receiving details, as one sheet rather than a tab.
///
/// Three synthetic fields, the available balance, and the one sentence that
/// matters: these cannot accept a real transfer.
struct ReceiveSheet: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ZStack {
        MiraColor.canvas.ignoresSafeArea()
        ScrollView {
          VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
              HeroNumber(session.clearedUSD.display, size: 40)
              Text("available to receive into")
                .font(MiraFont.body(15))
                .foregroundStyle(MiraColor.textSecondary)
            }

            Panel {
              VStack(spacing: Space.sm) {
                FieldLine(label: "Account holder", value: "Gerardo Salazar")
                Rule()
                FieldLine(label: "Routing", value: "0840 0001 9", mono: true)
                Rule()
                FieldLine(label: "Account", value: "0004 4291", mono: true)
              }
            }
          }
          .padding(.horizontal, Space.gutter)
          .readableWidth()
          .padding(.vertical, Space.lg)
        }
      }
      .navigationTitle("Receive")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.tint(MiraColor.gold)
        }
      }
    }
    .presentationBackground(MiraColor.canvas)
  }
}
