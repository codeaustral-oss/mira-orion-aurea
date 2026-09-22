import SwiftUI

/// Pay.
///
/// One transaction, shown the way a person thinks about it: what leaves, what
/// arrives, and what it costs. The previous build listed seven spec rows and a
/// countdown ring. This states the two figures that matter at reading size and
/// keeps the rest one tap away.
struct MoveView: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dismiss) private var dismiss

  @State private var pasted = ""
  @State private var showDetail = false

  private var payment: Payment? { session.activePayment }

  var body: some View {
    ZStack {
      DepthScene.gridField()
      content
    }
    .navigationBarHidden(true)
    .sheet(isPresented: $showDetail) { PaymentDetailSheet() }
  }

  @ViewBuilder
  private var content: some View {
    if let payment {
      review(payment)
    } else {
      entry
    }
  }

  // MARK: Entry

  private var entry: some View {
    VStack(spacing: 0) {
      SheetHeader(
        title: "Move money", subtitle: "Send, swap, receive",
        onClose: { dismiss() })

      Spacer(minLength: Space.lg)

      VStack(alignment: .leading, spacing: Space.lg) {
        Text("Send a local payment")
          .screenTitle(32)
          .foregroundStyle(MiraColor.text)

        VStack(spacing: Space.xs) {
          Button("Load the sample Pix request") {
            Task { await session.loadSampleRequest() }
          }
          .buttonStyle(MiraButtonStyle(kind: .primary))

          Button("Try an ambiguous recipient") {
            Task { await session.prepareForAmbiguousPayee() }
          }
          .buttonStyle(MiraButtonStyle(kind: .secondary))
        }

        VStack(alignment: .leading, spacing: Space.sm) {
          TextField("Or paste an invoice", text: $pasted, axis: .vertical)
            .font(MiraFont.body(16))
            .lineLimit(2...6)
            .padding(Space.md)
            .background(
              MiraColor.surface,
              in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            )
            .overlay {
              RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(MiraColor.hairline, lineWidth: 1)
            }

          Button("Read it") {
            let text = pasted
            pasted = ""
            Task { await session.prepareFromPastedText(text) }
          }
          .buttonStyle(MiraButtonStyle(kind: .secondary))
          .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .opacity(pasted.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
        }
      }
      .padding(.horizontal, Space.gutter)
      .readableWidth()

      Spacer(minLength: Space.lg)
    }
  }

  // MARK: Review

  private func review(_ payment: Payment) -> some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let now = context.date
      let confirmability = payment.confirmability(at: now, availableFunds: session.clearedUSD)
      let quote = payment.draft.quote

      VStack(spacing: 0) {
        SheetHeader(
          title: "Review payment", subtitle: "What leaves, what arrives, what it costs",
          onClose: { dismiss() }
        ) {
          RoundIconButton(glyph: "ellipsis", label: "Payment detail") { showDetail = true }
        }

        Spacer(minLength: Space.md)

        VStack(alignment: .leading, spacing: Space.lg) {
          recipient(payment)

          // The two figures, as one object. This is the whole transaction.
          Panel {
            VStack(spacing: Space.md) {
              amountRow("You send", quote.totalDebit.display, emphasis: true)
              Rule(accented: true)
              amountRow("They receive", quote.recipientAmount.display, emphasis: false)
              Rule()
              FieldLine(label: "Rate", value: quote.rateLabel)
              if !quote.fee.isZero {
                FieldLine(label: "Fee", value: quote.fee.display)
              }
            }
          }

          if let block = blockReason(payment, confirmability: confirmability, now: now) {
            Note(block, tone: payment.state.isUnknown ? .indeterminate : .negative)
          }
        }
        .padding(.horizontal, Space.gutter)
        .readableWidth()

        Spacer(minLength: Space.lg)

        // The action is anchored to the bottom, where the thumb is. It used to
        // sit directly under the panel, which left it floating mid-screen with
        // the secondary action stranded below it.
        VStack(spacing: Space.xs) {
          actions(payment, confirmability: confirmability)

          if !payment.state.isInFlightOrBeyond {
            Button("Discard") { session.discardActivePayment() }
              .buttonStyle(MiraButtonStyle(kind: .quiet))
          }
        }
        .padding(.horizontal, Space.gutter)
        .readableWidth()
        .padding(.bottom, Space.md)
      }
    }
  }

  private func recipient(_ payment: Payment) -> some View {
    VStack(alignment: .leading, spacing: Space.xxs) {
      Text(payment.draft.payee.resolvedName ?? "Recipient not verified")
        .screenTitle(24)
        .foregroundStyle(payment.draft.payee.isResolvable ? MiraColor.text : MiraColor.failed)
        .fixedSize(horizontal: false, vertical: true)

      if let mismatch = payment.draft.payee.mismatchNote {
        Text(mismatch)
          .font(MiraFont.caption(13))
          .foregroundStyle(MiraColor.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func amountRow(_ label: String, _ value: String, emphasis: Bool) -> some View {
    VStack(alignment: .leading, spacing: Space.xxs) {
      Text(label)
        .font(MiraFont.body(15))
        .foregroundStyle(MiraColor.textSecondary)
      Text(value)
        .font(MiraFont.hero(emphasis ? 34 : 28))
        .tracking(-1.0)
        .foregroundStyle(MiraColor.text)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func blockReason(_ payment: Payment, confirmability: Payment.Confirmability, now: Date)
    -> String?
  {
    if payment.state.isUnknown { return payment.state.explanation }
    if let payeeBlock = payment.draft.payee.blockReason { return payeeBlock }
    if payment.draft.quote.isExpired(at: now) {
      return "This quote expired. Nothing can be sent until a new one is issued."
    }
    return nil
  }

  @ViewBuilder
  private func actions(_ payment: Payment, confirmability: Payment.Confirmability) -> some View {
    switch payment.state {
    case .draft:
      Button("Approve") { session.approveDraft(userGesture: true) }
        .buttonStyle(MiraButtonStyle(kind: .primary))
        .disabled(!payment.draft.payee.isResolvable)
        .opacity(payment.draft.payee.isResolvable ? 1 : 0.4)

    case .awaitingApproval:
      if payment.draft.quote.isExpired(at: Date()) {
        Button("Get a new quote") { Task { await session.refreshQuote() } }
          .buttonStyle(MiraButtonStyle(kind: .primary))
      } else {
        Button("Send \(payment.draft.quote.totalDebit.display)") {
          Task { await session.confirmPayment() }
        }
        .buttonStyle(MiraButtonStyle(kind: .gold))
        .disabled(!confirmability.isReady)
        .opacity(confirmability.isReady ? 1 : 0.4)
      }

    case .statusUnknown:
      Button("Check with the provider") { Task { await session.reconcile() } }
        .buttonStyle(MiraButtonStyle(kind: .primary))

    case .settled, .failed:
      Button("Start another payment") { session.discardActivePayment() }
        .buttonStyle(MiraButtonStyle(kind: .secondary))

    case .submitting, .pending:
      HStack(spacing: Space.xs) {
        MiraDot(size: 8, pulsing: true)
        Text(payment.state.label)
          .font(MiraFont.body(16))
          .foregroundStyle(MiraColor.textSecondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, Space.md)
    }
  }
}

// MARK: - Detail

/// Everything that is true but not needed at a glance: the key, the quote
/// lifetime, the state history, the consent reference, and the failure paths a
/// presenter wants to demonstrate.
struct PaymentDetailSheet: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ZStack {
        MiraColor.canvas.ignoresSafeArea()
        ScrollView {
          VStack(alignment: .leading, spacing: Space.lg) {
            if let payment = session.activePayment {
              Panel {
                VStack(spacing: Space.sm) {
                  FieldLine(label: "Recipient key", value: payment.draft.payee.handle, mono: true)
                  Rule()
                  FieldLine(
                    label: "Quote",
                    value: payment.draft.quote.isExpired(at: Date()) ? "Expired" : "Active")
                  Rule()
                  FieldLine(label: "Draft", value: payment.draft.shortFingerprint, mono: true)
                  if let reference = payment.state.providerReference {
                    Rule()
                    FieldLine(label: "Provider", value: reference, mono: true)
                  }
                  if let approval = payment.approval {
                    Rule()
                    FieldLine(label: "Consent", value: approval.consentId, mono: true)
                  }
                }
              }

              VStack(alignment: .leading, spacing: Space.sm) {
                Text("History")
                  .font(MiraFont.label(15))
                  .foregroundStyle(MiraColor.textSecondary)
                Panel {
                  VStack(spacing: Space.sm) {
                    ForEach(Array(payment.history.enumerated()), id: \.element.id) {
                      index, transition in
                      HStack(alignment: .top, spacing: Space.xs) {
                        Circle()
                          .fill(
                            index == payment.history.count - 1
                              ? transition.to.tone.color : MiraColor.hairline
                          )
                          .frame(width: 7, height: 7)
                          .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                          Text(transition.to.label)
                            .font(MiraFont.body(15))
                            .foregroundStyle(MiraColor.text)
                          if let note = transition.note {
                            Text(note)
                              .font(MiraFont.caption(12))
                              .foregroundStyle(MiraColor.textTertiary)
                              .fixedSize(horizontal: false, vertical: true)
                          }
                        }
                        Spacer(minLength: 0)
                      }
                    }
                  }
                }
              }

              failurePaths
            }
          }
          .padding(.horizontal, Space.gutter)
          .readableWidth()
          .padding(.vertical, Space.lg)
        }
      }
      .navigationTitle("Payment")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.tint(MiraColor.gold)
        }
      }
    }
    .presentationBackground(MiraColor.canvas)
  }

  private var failurePaths: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Text("Failure paths")
        .font(MiraFont.label(15))
        .foregroundStyle(MiraColor.textSecondary)

      Panel {
        VStack(spacing: Space.sm) {
          FieldLine(label: "Provider behaviour", value: session.scenario.displayName)
          Rule()
          Text(session.scenario.explanation)
            .font(MiraFont.caption(12))
            .foregroundStyle(MiraColor.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Menu {
        ForEach(PaymentScenario.allCases) { scenario in
          Button(scenario.displayName) { Task { await session.setScenario(scenario) } }
        }
      } label: {
        HStack {
          Text("Change provider behaviour").font(MiraFont.label(16))
          Spacer()
          Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(MiraColor.text)
        .padding(.vertical, 15)
        .padding(.horizontal, Space.md)
        .background(MiraColor.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(MiraColor.hairline, lineWidth: 1) }
      }

      if let payment = session.activePayment, payment.state.isSettled || payment.state.isUnknown {
        Button("Replay the provider event") { Task { await session.replayProviderEvent() } }
          .buttonStyle(MiraButtonStyle(kind: .secondary))
      }
    }
  }
}
