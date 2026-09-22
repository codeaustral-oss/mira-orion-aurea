import SwiftUI

/// Plan.
///
/// The hero is the only figure that answers a question a person actually asks:
/// how much is left this week. The four allocations, the reserve and the
/// forecast are one tap away, because they are the explanation, not the answer.
struct PlanView: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.dismiss) private var dismiss

  @State private var showDetail = false

  var body: some View {
    ZStack {
      DepthScene.gridField()
      content
    }
    .navigationBarHidden(true)
    .navigationDestination(isPresented: $showDetail) { PlanDetailView() }
  }

  private var content: some View {
    VStack(spacing: 0) {
      SheetHeader(
        title: "Plan", subtitle: "Allocations and the budget",
        onClose: { dismiss() }
      ) {
        RoundIconButton(glyph: "list.bullet", label: "The plan") { showDetail = true }
      }

      Spacer(minLength: Space.lg)

      VStack(alignment: .leading, spacing: Space.sm) {
        Text("Left this week")
          .font(MiraFont.body(16))
          .foregroundStyle(MiraColor.textSecondary)

        HeroNumber(session.currentWeekRemaining.display, size: 72)

        Text(
          "Week \(session.currentWeekIndex) of \(session.plan.durationWeeks) · without touching the reserve."
        )
        .font(MiraFont.body(16))
        .foregroundStyle(MiraColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Space.gutter)
      .readableWidth()
      .animation(.easeOut(duration: 0.35), value: session.currentWeekRemaining.minorUnits)

      Spacer(minLength: Space.lg)

      VStack(alignment: .leading, spacing: Space.md) {
        Button("The plan") { showDetail = true }
          .buttonStyle(MiraButtonStyle(kind: .secondary))

        Button("Ask Mira") {
          session.requestTab(.accounts)
          startConversation()
        }
        .buttonStyle(MiraButtonStyle(kind: .secondary))

      }
      .padding(.horizontal, Space.gutter)
      .readableWidth()
      .padding(.bottom, Space.md)
    }
  }

  private func startConversation() {
    Task { await session.ask("How much can I spend this week without using my reserve?") }
    showDetail = true
  }
}

// MARK: - Detail

/// The explanation: four allocations, editable, and the reserve stated honestly.
struct PlanDetailView: View {
  @Environment(MiraSession.self) private var session

  @State private var editing: AllocationRow.Kind?
  @State private var showConversation = false

  var body: some View {
    ZStack {
      MiraColor.canvas.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: Space.lg) {
          allocations
          reserve
          askMira
        }
        .padding(.horizontal, Space.gutter)
        .readableWidth()
        .padding(.vertical, Space.lg)
      }
    }
    .navigationTitle("The plan")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $editing) { AllocationEditorSheet(kind: $0) }
    .sheet(isPresented: $showConversation) { ConversationSheet() }
  }

  private var allocations: some View {
    let plan = session.plan
    return VStack(alignment: .leading, spacing: Space.sm) {
      VStack(alignment: .leading, spacing: Space.xs) {
        HeroNumber(plan.total.display, size: 40)
        Text("across \(plan.durationWeeks) weeks in \(session.context.presentLocation.name)")
          .font(MiraFont.body(15))
          .foregroundStyle(MiraColor.textSecondary)
      }
      .padding(.bottom, Space.xxs)

      Panel(padding: Space.xs) {
        VStack(spacing: 0) {
          ForEach(plan.rows) { row in
            TapRow {
              guard row.isEditable else { return }
              editing = row.kind
            } content: {
              VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                  .font(MiraFont.body(16))
                  .foregroundStyle(
                    row.kind == .unallocated ? MiraColor.textSecondary : MiraColor.text
                  )
                  .multilineTextAlignment(.leading)
                if let note = row.note {
                  Text(note)
                    .font(MiraFont.caption(12))
                    .foregroundStyle(MiraColor.textTertiary)
                    .multilineTextAlignment(.leading)
                }
              }
              .padding(.horizontal, Space.sm)
              Spacer(minLength: Space.xs)
              Text(row.amount.display)
                .font(MiraFont.figure(16, weight: .semibold))
                .foregroundStyle(
                  row.kind == .unallocated ? MiraColor.textSecondary : MiraColor.text
                )
                .padding(.trailing, Space.sm)
            }
            .disabled(!row.isEditable)

            if row.id != plan.rows.last?.id { Rule() }
          }
        }
      }

      if case .shortfall(let over) = plan.status {
        Note("Over by \(over.display).", tone: .negative)
      }

      if plan.isApproved {
        HStack(spacing: Space.xs) {
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
          Text("Approved")
            .font(MiraFont.label(14))
        }
        .foregroundStyle(MiraColor.settled)
      } else {
        Button("Approve this plan") { session.approvePlan() }
          .buttonStyle(MiraButtonStyle(kind: .primary))
          .disabled(!plan.status.isBalanced)
          .opacity(plan.status.isBalanced ? 1 : 0.4)
      }
    }
  }

  private var reserve: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      FieldLine(label: "Reserve", value: session.plan.reserveMoney.display, strong: true)
    }
  }

  private var askMira: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Button("Ask Mira about this") { showConversation = true }
        .buttonStyle(MiraButtonStyle(kind: .secondary))
    }
  }
}

// MARK: - Allocation editor

/// Edit one line of the plan, without retyping a sentence.
struct AllocationEditorSheet: View {
  let kind: AllocationRow.Kind

  @Environment(MiraSession.self) private var session
  @Environment(\.dismiss) private var dismiss

  @State private var amount: Double = 0

  private var title: String {
    switch kind {
    case .knownBills: return "Known bills"
    case .reserve: return "Reserve"
    case .discretionary: return "Weekly budget"
    case .unallocated: return "Unallocated"
    }
  }

  private var range: ClosedRange<Double> {
    switch kind {
    case .knownBills, .reserve: return 0...3000
    case .discretionary: return 0...1000
    case .unallocated: return 0...0
    }
  }

  private var preview: AllocationPlan {
    var plan = session.plan
    plan.edit(kind, to: Decimal(amount), at: Date())
    return plan
  }

  var body: some View {
    NavigationStack {
      ZStack {
        MiraColor.canvas.ignoresSafeArea()
        VStack(alignment: .leading, spacing: Space.lg) {
          HeroNumber(Money(majorUnits: Decimal(amount), currency: .usd).display, size: 44)

          Slider(value: $amount, in: range, step: 10)
            .tint(MiraColor.gold)

          Panel {
            VStack(spacing: Space.sm) {
              FieldLine(label: "Earmarked", value: preview.committed.display)
              Rule()
              FieldLine(
                label: "Unallocated",
                value: preview.unallocated.display,
                strong: true,
                valueColor: preview.unallocated.isNegative ? MiraColor.failed : MiraColor.text
              )
            }
          }

          if case .shortfall(let over) = preview.status {
            Note("Over by \(over.display).", tone: .negative)
          }

          Spacer()
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.lg)
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            session.editAllocation(kind, to: Decimal(amount))
            dismiss()
          }
          .tint(MiraColor.gold)
        }
      }
      .onAppear {
        let current: Decimal
        switch kind {
        case .knownBills: current = session.plan.knownBillsMoney.majorUnits
        case .reserve: current = session.plan.reserveMoney.majorUnits
        case .discretionary: current = session.plan.weeklyBudgetMoney.majorUnits
        case .unallocated: current = session.plan.unallocated.majorUnits
        }
        amount = NSDecimalNumber(decimal: current).doubleValue
      }
    }
    .presentationDetents([.medium])
    .presentationBackground(MiraColor.canvas)
  }
}

// MARK: - Conversation

/// Ask Mira, and get an answer made of cards that already exist elsewhere.
struct ConversationSheet: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.dismiss) private var dismiss

  @State private var draft = ""

  var body: some View {
    NavigationStack {
      ZStack {
        MiraColor.canvas.ignoresSafeArea()
        VStack(spacing: 0) {
          ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
              if session.conversation.isEmpty { starters }
              ForEach(session.conversation) { turn in
                turnView(turn)
              }
              if session.isWorking { working }
            }
            .padding(.horizontal, Space.gutter)
            .readableWidth()
            .padding(.vertical, Space.lg)
          }
          composer
        }
      }
      .navigationTitle("Ask Mira")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.tint(MiraColor.gold)
        }
      }
    }
    .presentationBackground(MiraColor.canvas)
  }

  private var starters: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      starter("How much can I spend this week without using my reserve?")
      starter("What is still pending?")
      starter("What would Earn look like?")
    }
  }

  private func starter(_ text: String) -> some View {
    Button {
      Task { await session.ask(text) }
    } label: {
      HStack {
        Text(text)
          .font(MiraFont.body(16))
          .foregroundStyle(MiraColor.text)
          .multilineTextAlignment(.leading)
        Spacer(minLength: Space.xs)
        Image(systemName: "arrow.up.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(MiraColor.textTertiary)
      }
      .padding(Space.md)
      .background(
        MiraColor.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
          .strokeBorder(MiraColor.hairline, lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private func turnView(_ turn: ConversationTurn) -> some View {
    if turn.role == .user {
      HStack {
        Spacer(minLength: Space.xl)
        Text(turn.text)
          .font(MiraFont.body(16))
          .foregroundStyle(MiraColor.canvas)
          .padding(.horizontal, Space.md)
          .padding(.vertical, Space.sm)
          .background(
            MiraColor.ink, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
      }
    } else if let explanation = turn.explanation {
      VStack(alignment: .leading, spacing: Space.sm) {
        Text(explanation.headline)
          .font(MiraFont.title(20))
          .foregroundStyle(MiraColor.text)
          .fixedSize(horizontal: false, vertical: true)
        Text(explanation.body)
          .font(MiraFont.body(16))
          .foregroundStyle(MiraColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)

        if !explanation.citations.isEmpty {
          VStack(alignment: .leading, spacing: 3) {
            ForEach(explanation.citations, id: \.self) { citation in
              Text(citation)
                .font(MiraFont.caption(12))
                .foregroundStyle(MiraColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .padding(.top, Space.xxs)
        }
      }
    }
  }

  private var working: some View {
    HStack(spacing: Space.xs) {
      MiraDot(size: 8, pulsing: true)
      Text("Mira is deciding")
        .font(MiraFont.body(15))
        .foregroundStyle(MiraColor.textSecondary)
    }
  }

  private var composer: some View {
    HStack(spacing: Space.xs) {
      TextField("Ask about your money", text: $draft, axis: .vertical)
        .font(MiraFont.body(16))
        .lineLimit(1...4)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(
          MiraColor.surface, in: RoundedRectangle(cornerRadius: Radius.pill, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: Radius.pill, style: .continuous)
            .strokeBorder(MiraColor.hairline, lineWidth: 1)
        }
        .onSubmit(send)

      Button(action: send) {
        Image(systemName: "arrow.up")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(MiraColor.canvas)
          .frame(width: 44, height: 44)
          .background(MiraColor.ink, in: Circle())
      }
      .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
      .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
    }
    .padding(.horizontal, Space.gutter)
    .readableWidth()
    .padding(.vertical, Space.sm)
    .background(MiraColor.canvas)
    .overlay(alignment: .top) { Rule() }
  }

  private func send() {
    let text = draft
    draft = ""
    Task { await session.ask(text) }
  }
}
