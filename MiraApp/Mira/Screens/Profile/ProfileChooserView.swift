import SwiftUI

// MARK: - The chooser
//
// The question the app asks on every cold launch: whose session is this? It is
// deliberately not a settings screen — no menu.
// Three cards, and the one you had last time is already lit.

struct ProfileChooserView: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @AppStorage(MiraSession.profileDefaultsKey) private var storedSlug = ""

  /// Called once a profile has been continued or chosen.
  let onDone: () -> Void

  private var personas: [DemoPersona] { DemoPersonas.forBrand(session.brandKind) }

  var body: some View {
    ZStack {
      brand.canvas.ignoresSafeArea()

      ScrollView {
        VStack(alignment: .leading, spacing: Space.lg) {
          VStack(alignment: .leading, spacing: Space.xs) {
            if session.wantsProfileChooser {
              Button {
                session.profileChooserClosed()
                onDone()
              } label: {
                Label("Back to chat", systemImage: "arrow.left")
                  .font(MiraFont.label(15))
                  .frame(minHeight: 44)
              }
              .foregroundStyle(brand.text)
              .padding(.bottom, Space.sm)
              .accessibilityIdentifier("profile.backToChat")
            }
            Text("Choose a profile")
              .screenTitle(30)
              .foregroundStyle(brand.text)
              .accessibilityAddTraits(.isHeader)
            Text("Three lives, already in progress.")
              .font(MiraFont.body(17))
              .foregroundStyle(brand.textSecondary)
          }
          .padding(.bottom, Space.xxs)

          ForEach(personas) { persona in
            card(persona)
          }
        }
        .padding(.horizontal, Space.gutter)
        .readableWidth(560)
        .padding(.top, Space.xxl)
        .padding(.bottom, Space.xl)
      }
      .scrollIndicators(.hidden)
    }
  }

  // MARK: One life

  private func card(_ persona: DemoPersona) -> some View {
    // The lit card is the person the session is actually in — the last choice,
    // whatever door it came through (the chooser, `-profile`, or the menu).
    let isLast = persona.id == session.persona.id

    return Button {
      choose(persona)
    } label: {
      HStack(alignment: .top, spacing: Space.md) {
        avatar(persona)

        VStack(alignment: .leading, spacing: 5) {
          Text(persona.name)
            .font(MiraFont.display(22))
            .foregroundStyle(brand.text)

          Text("\(persona.city) · \(persona.incomeLine)")
            .font(MiraFont.body(16))
            .foregroundStyle(brand.textSecondary)

          Text(persona.oneLiner)
            .font(MiraFont.body(16))
            .foregroundStyle(brand.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)

          if isLast {
            Text("Continue as \(persona.name)")
              .font(MiraFont.label(15))
              .foregroundStyle(brand.accentDeep)
              .padding(.top, Space.xs)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(Space.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(isLast ? brand.accentTint : brand.surface)
      .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
          .strokeBorder(isLast ? brand.accentDeep : brand.hairline, lineWidth: isLast ? 1.5 : 1)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(persona.name), \(persona.city), \(persona.incomeLine). \(persona.oneLiner)")
    .accessibilityHint(isLast ? "Continues as \(persona.name)" : "Uses \(persona.name)'s session")
  }

  /// The catalog art may not be built yet. A missing avatar is an empty
  /// hairline ring — quiet, and never invented initials.
  private func avatar(_ persona: DemoPersona) -> some View {
    UserAvatar(persona: persona, size: 104)
  }

  /// Continuing as the person already open keeps their conversation; choosing
  /// someone else rebuilds the whole session around them. Either way the choice
  /// is remembered, so the next cold launch can offer one tap.
  private func choose(_ persona: DemoPersona) {
    storedSlug = persona.id
    if persona.id != session.persona.id {
      session.chooseProfile(persona)
    }
    session.profileChooserClosed()
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
      onDone()
    }
  }
}

// MARK: - The avatar

/// The person's avatar, wherever it appears — the chooser, the menu and the
/// control centre. The catalog may not be built yet, so a missing image is an
/// empty hairline ring rather than invented initials.
struct UserAvatar: View {
  let persona: DemoPersona
  var size: CGFloat = 104

  @Environment(\.brand) private var brand

  var body: some View {
    Group {
      if let image = MiraArt.image(named: persona.avatarAsset) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Color.clear
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay { Circle().strokeBorder(brand.hairline, lineWidth: 1) }
    .accessibilityHidden(true)
  }
}
