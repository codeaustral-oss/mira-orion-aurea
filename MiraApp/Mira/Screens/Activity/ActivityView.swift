import SwiftUI

/// Activity.
///
/// A list of what happened and what state it is in. No hero figure here: the
/// screen's job is the record, and the record is a list.
struct ActivityView: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.dismiss) private var dismiss

  @State private var selected: ActivityItem?

  var body: some View {
    ZStack {
      MiraColor.canvas.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: Space.md) {
          let items = session.activity
          if items.isEmpty {
            Text("Nothing has moved yet.")
              .font(MiraFont.body(16))
              .foregroundStyle(MiraColor.textSecondary)
              .padding(.top, Space.xl)
          } else {
            Panel(padding: Space.xs) {
              VStack(spacing: 0) {
                ForEach(items) { item in
                  TapRow {
                    selected = item
                  } content: {
                    row(item)
                  }
                  if item.id != items.last?.id { Rule() }
                }
              }
            }
          }

        }
        .padding(.horizontal, Space.gutter)
        .readableWidth()
        .padding(.bottom, Space.xl)
      }
    }
    .safeAreaInset(edge: .top) {
      SheetHeader(
        title: "Activity", subtitle: "Your transactions",
        onClose: { dismiss() })
        .readableWidth()
        .background(MiraColor.canvas)
    }
    .navigationBarHidden(true)
    .sheet(item: $selected) { ReceiptView(item: $0) }
  }

  private func row(_ item: ActivityItem) -> some View {
    HStack(alignment: .center, spacing: Space.sm) {
      VStack(alignment: .leading, spacing: 3) {
        Text(item.title)
          .font(MiraFont.body(16))
          .foregroundStyle(MiraColor.text)
          .multilineTextAlignment(.leading)
        HStack(spacing: Space.xs) {
          Text(item.at.formatted(.dateTime.day().month(.abbreviated)))
            .font(MiraFont.caption(12))
            .foregroundStyle(MiraColor.textTertiary)
          if let state = item.state {
            Text(state.label)
              .font(MiraFont.caption(12))
              .foregroundStyle(state.tone.color)
          }
        }
      }
      .padding(.horizontal, Space.sm)

      Spacer(minLength: Space.xs)

      if let movement = item.usdMovement {
        Text(movement.signedDisplay)
          .font(MiraFont.figure(16, weight: .semibold))
          .foregroundStyle(movement.isNegative ? MiraColor.text : MiraColor.settled)
          .padding(.trailing, Space.sm)
      }
    }
  }
}

// MARK: - Receipt

/// What was requested, what was approved, what was submitted, what came back.
struct ReceiptView: View {
  let item: ActivityItem

  @Environment(MiraSession.self) private var session
  @Environment(\.dismiss) private var dismiss

  private var payment: Payment? {
    item.payment
      ?? session.payments.first { $0.draft.fingerprint == item.entry?.references.draftFingerprint }
  }

  var body: some View {
    NavigationStack {
      ZStack {
        MiraColor.canvas.ignoresSafeArea()
        ScrollView {
          VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
              if let movement = item.usdMovement {
                HeroNumber(movement.signedDisplay, size: 44)
              }
              Text(item.title)
                .font(MiraFont.body(16))
                .foregroundStyle(MiraColor.textSecondary)
            }

            if let payment {
              Panel {
                VStack(spacing: Space.sm) {
                  FieldLine(label: "To", value: payment.draft.payee.resolvedName ?? "Unverified")
                  Rule()
                  FieldLine(
                    label: "They received", value: payment.draft.quote.recipientAmount.display)
                  Rule()
                  FieldLine(label: "Rate", value: payment.draft.quote.rateLabel)
                  Rule()
                  FieldLine(
                    label: "Total debit", value: payment.draft.quote.totalDebit.display,
                    strong: true)
                }
              }

              Panel {
                VStack(spacing: Space.sm) {
                  FieldLine(
                    label: "Draft approved", value: payment.draft.shortFingerprint, mono: true)
                  if let consent = payment.approval?.consentId {
                    Rule()
                    FieldLine(label: "Consent", value: consent, mono: true)
                  }
                  if let reference = payment.state.providerReference {
                    Rule()
                    FieldLine(label: "Provider reference", value: reference, mono: true)
                  }
                }
              }

              Text(payment.state.explanation)
                .font(MiraFont.body(15))
                .foregroundStyle(MiraColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .padding(.horizontal, Space.gutter)
          .readableWidth()
          .padding(.vertical, Space.lg)
        }
      }
      .navigationTitle("Receipt")
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
