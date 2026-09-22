import SwiftUI

/// Mira.
///
/// The assistant is a place in the app, not a floating button, and it looks like
/// the product it lives in: a rendered body with an orbiting companion in Orion,
/// an engraved plate in Aurea.
///
/// What it can do is deliberately narrow. It reads a digest of real state and
/// answers with figures taken from it. It may flag something that looks wrong
/// and propose exactly one action, which arrives as a card the user approves.
/// There is no path from a sentence to a ledger posting.
struct MiraAgentView: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand

  @State private var draft = ""

  var body: some View {
    ZStack {
      brand.canvas.ignoresSafeArea()

      VStack(spacing: 0) {
        header

        ScrollView {
          VStack(alignment: .leading, spacing: Space.lg) {
            if session.conversation.isEmpty {
              starters
            }
            ForEach(session.conversation) { turn in
              turnView(turn)
            }
            if let reply = session.lastAgentReply { replyDetail(reply) }
            if let error = session.lastAgentError { failure(error) }
            if session.isWorking { working }
          }
          .padding(.horizontal, Space.gutter)
          .readableWidth(600)
          .padding(.vertical, Space.lg)
        }
        .scrollIndicators(.hidden)

        composer
      }
    }
    .navigationBarHidden(true)
  }

  // MARK: Header

  private var header: some View {
    VStack(spacing: Space.sm) {
      MiraAvatar(size: session.isWorking ? 132 : 112)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: session.isWorking)

      VStack(spacing: 2) {
        Text(brand.kind == .orion ? "Mira" : "Mira")
          .screenTitle(22)
          .foregroundStyle(brand.text)
        Text(session.isWorking ? "Reading your account" : "Ask me about your money")
          .font(.system(size: 14))
          .foregroundStyle(brand.textSecondary)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, Space.sm)
    .padding(.bottom, Space.md)
  }

  // MARK: Starters

  private var starters: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      starter("Did anything unusual happen this week?")
      starter("How much can I spend without touching the reserve?")
      starter("How much do I hold in stablecoins?")
      starter("What did I spend on subscriptions?")
    }
  }

  private func starter(_ text: String) -> some View {
    Button {
      Task { await session.askAgent(text) }
    } label: {
      HStack {
        Text(text)
          .font(.system(size: 16))
          .foregroundStyle(brand.text)
          .multilineTextAlignment(.leading)
        Spacer(minLength: Space.xs)
        Image(systemName: "arrow.up.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(brand.textTertiary)
      }
      .padding(Space.md)
      .background(
        brand.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
          .strokeBorder(brand.hairline, lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
  }

  // MARK: Turns

  @ViewBuilder
  private func turnView(_ turn: ConversationTurn) -> some View {
    if turn.role == .user {
      HStack {
        Spacer(minLength: Space.xl)
        Text(turn.text)
          .font(.system(size: 16))
          .foregroundStyle(brand.canvas)
          .padding(.horizontal, Space.md)
          .padding(.vertical, Space.sm)
          .background(
            brand.ink, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
      }
    } else {
      Text(turn.text)
        .font(MiraFont.body(17))
        .foregroundStyle(brand.text)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// Citations and flags. This is where the grounding is visible: every claim
  /// the model made is shown next to the figure it came from.
  @ViewBuilder
  private func replyDetail(_ reply: AgentReply) -> some View {
    if !reply.citations.isEmpty || !reply.flags.isEmpty || reply.proposal != nil {
      VStack(alignment: .leading, spacing: Space.sm) {
        ForEach(reply.flags) { flag in
          HStack(alignment: .top, spacing: Space.xs) {
            Circle()
              .fill(flag.severity == .warn ? brand.accent : brand.accentDeep)
              .frame(width: 6, height: 6)
              .padding(.top, 6)
            Text(flag.text)
              .font(.system(size: 15))
              .foregroundStyle(brand.text)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
          }
        }

        if !reply.citations.isEmpty {
          VStack(alignment: .leading, spacing: 3) {
            ForEach(reply.citations, id: \.self) { citation in
              Text(citation)
                .font(.system(size: 13))
                .foregroundStyle(brand.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .padding(.leading, 14)
        }

        if let proposal = reply.proposal {
          proposalCard(proposal)
        }
      }
      .padding(Space.md)
      .background(
        brand.surface, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
          .strokeBorder(brand.hairline, lineWidth: 1)
      }
    }
  }

  private func proposalCard(_ proposal: AgentReply.Proposal) -> some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Rule()
      Text(proposal.title)
        .font(MiraFont.title(17))
        .foregroundStyle(brand.text)
        .fixedSize(horizontal: false, vertical: true)
      Text(proposal.detail)
        .font(.system(size: 14))
        .foregroundStyle(brand.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: Space.xs) {
        Button("Review in Move") { session.requestTab(.move) }
          .buttonStyle(BrandButtonStyle(kind: .primary))
        Button("Not now") { session.dismissProposal() }
          .buttonStyle(BrandButtonStyle(kind: .quiet))
      }
    }
  }

  private func failure(_ message: String) -> some View {
    HStack(alignment: .top, spacing: Space.xs) {
      Circle().fill(brand.ink).frame(width: 6, height: 6).padding(.top, 6)
      Text(message)
        .font(.system(size: 15))
        .foregroundStyle(brand.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }

  private var working: some View {
    HStack(spacing: Space.xs) {
      MiraDot(size: 8, pulsing: true)
      Text("Thinking")
        .font(.system(size: 15))
        .foregroundStyle(brand.textSecondary)
    }
  }

  // MARK: Composer

  private var composer: some View {
    HStack(spacing: Space.xs) {
      TextField("Ask Mira", text: $draft, axis: .vertical)
        .font(.system(size: 16))
        .lineLimit(1...4)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(
          brand.surface, in: RoundedRectangle(cornerRadius: Radius.pill, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: Radius.pill, style: .continuous)
            .strokeBorder(brand.hairline, lineWidth: 1)
        }
        .onSubmit(send)

      Button(action: send) {
        Image(systemName: "arrow.up")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(brand.canvas)
          .frame(width: 44, height: 44)
          .background(brand.ink, in: Circle())
      }
      .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || session.isWorking)
      .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
    }
    .padding(.horizontal, Space.gutter)
    .readableWidth(600)
    .padding(.vertical, Space.sm)
    .background(brand.canvas)
    .overlay(alignment: .top) { Rule() }
  }

  private func send() {
    let text = draft
    draft = ""
    Task { await session.askAgent(text) }
  }
}
