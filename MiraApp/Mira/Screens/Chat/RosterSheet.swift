import SwiftUI

// MARK: - Roster
//
// Six specialists per brand. The roster is a real choice, not decoration: pinning
// one sends the next turns straight to that specialist instead of through Mira's
// routing. The name, role and personality are the app's own copy; the server
// holds the instructions that actually reach the model, and the two are kept in
// step by the shared id.

struct RosterSheet: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ZStack {
      brand.canvas.ignoresSafeArea()

      VStack(spacing: 0) {
        SheetHeader(
          title: "Specialists",
          subtitle: "Mira routes to whoever fits, or choose one and stay with them.",
          onClose: { dismiss() })

        ScrollView {
          VStack(alignment: .leading, spacing: Space.sm) {
            coordinatorRow

            ForEach(session.roster) { agent in
              agentRow(agent)
            }
          }
          .padding(.horizontal, Space.gutter)
          .padding(.bottom, Space.lg)
        }
        .scrollIndicators(.hidden)
      }
    }
  }

  private var coordinatorRow: some View {
    TapRow {
      session.releaseSpecialist()
      dismiss()
    } content: {
      HStack(spacing: Space.sm) {
        Image(systemName: "circle.dotted")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(brand.accentDeep)
          .frame(width: 38, height: 38)
          .background(brand.accentTint, in: Circle())
        VStack(alignment: .leading, spacing: 1) {
          Text("Mira")
            .font(MiraFont.label(16))
            .foregroundStyle(brand.text)
          Text("Coordinates the whole roster")
            .font(MiraFont.caption(12))
            .foregroundStyle(brand.textTertiary)
        }
        if session.activeAgentId == nil { currentTag }
      }
    }
  }

  private func agentRow(_ agent: AgentSpecialist) -> some View {
    TapRow {
      session.openSpecialist(agent)
      dismiss()
    } content: {
      HStack(alignment: .top, spacing: Space.sm) {
        AgentAvatar(agent: agent, size: 40)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: Space.xs) {
            Text(agent.name)
              .font(MiraFont.label(16))
              .foregroundStyle(brand.text)
            if session.activeAgentId == agent.id { currentTag }
          }
          Text(agent.role)
            .font(MiraFont.caption(12))
            .foregroundStyle(brand.textTertiary)
          Text(agent.personality)
            .font(MiraFont.body(13))
            .foregroundStyle(brand.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.vertical, Space.xxs)
    }
  }

  private var currentTag: some View {
    Text("CURRENT")
      .font(.system(size: 9, weight: .semibold))
      .tracking(1.2)
      .foregroundStyle(brand.accentDeep)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(brand.accentTint, in: Capsule())
  }
}
