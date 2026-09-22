import SwiftUI

// MARK: - Transfer draft

/// A stablecoin send, in the shape the confirm sheet needs.
///
/// Deliberately a plain value rather than the full `ChainTransfer` state
/// machine: the sheet is a confirmation, and the posting is done by
/// `MiraSession` so the ledger stays the single writer.
struct TransferDraft: Identifiable, Hashable {
  let id = UUID()
  var asset: Asset
  var to: ChainAddress
  var amount: Money
  var fee: Money

  var total: Money { amount + fee }
  var destination: String { to.label ?? to.short }
}

// MARK: - Confirm

/// Confirm a stablecoin send.
///
/// The same shape as the Pix review: what leaves, what arrives, what it costs,
/// and one button. The network is stated because sending on the wrong chain is
/// the mistake that actually loses money.
struct TransferConfirmSheet: View {
  let draft: TransferDraft

  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand
  @Environment(\.dismiss) private var dismiss

  @State private var error: String?

  var body: some View {
    NavigationStack {
      ZStack {
        brand.canvas.ignoresSafeArea()
        VStack(alignment: .leading, spacing: Space.lg) {
          VStack(alignment: .leading, spacing: Space.xxs) {
            Text("You send")
              .font(.system(size: 14))
              .foregroundStyle(brand.textSecondary)
            PaperNumber(value: draft.amount.display, size: 40)
          }

          PaperPanel {
            VStack(spacing: Space.sm) {
              row("To", draft.destination)
              Rectangle().fill(brand.hairline).frame(height: 1)
              row("Network", draft.to.network.displayName)
              Rectangle().fill(brand.hairline).frame(height: 1)
              row("Address", draft.to.short, mono: true)
              Rectangle().fill(brand.hairline).frame(height: 1)
              row("Network fee", draft.fee.display)
              Rectangle().fill(brand.hairline).frame(height: 1)
              row("Total", draft.total.display, strong: true)
            }
          }

          Text("Arrives in \(draft.to.network.typicalSettlement).")
            .font(.system(size: 13))
            .foregroundStyle(brand.textSecondary)

          if let error {
            Text(error).font(.system(size: 13)).foregroundStyle(MiraColor.failed)
          }

          Spacer()

          Button("Send \(draft.total.display)") { send() }
            .buttonStyle(PaperButtonStyle(kind: .filled))
        }
        .padding(.horizontal, Space.gutter)
        .readableWidth(560)
        .padding(.vertical, Space.lg)
      }
      .navigationTitle("Confirm transfer")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationBackground(brand.canvas)
  }

  private func row(_ label: String, _ value: String, mono: Bool = false, strong: Bool = false) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label).font(.system(size: 14)).foregroundStyle(brand.textSecondary)
      Spacer(minLength: Space.xs)
      Text(value)
        .font(mono
          ? .system(size: 13, design: .monospaced)
          : .system(size: strong ? 16 : 14, weight: strong ? .semibold : .regular).monospacedDigit())
        .foregroundStyle(brand.text)
        .multilineTextAlignment(.trailing)
    }
  }

  private func send() {
    error = nil
    if session.sendExternalTransfer(asset: draft.asset, amount: draft.amount, to: draft.destination) {
      dismiss()
    } else {
      error = session.lastError ?? "That transfer could not be sent."
    }
  }
}
