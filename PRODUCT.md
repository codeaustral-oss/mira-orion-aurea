# Product

## Register

product

## Users

Independent professionals and remote workers paid in USD who live, or spend
extended time, in Latin America. The first corridor is USD income into local BRL
spending via Pix.

Their context when opening the app: they are not sitting down to do finance. They
are standing in a shop, or on a call between two time zones, and they want one
answer. "Can I afford this." "How much is left this week." "Who actually receives
this money if I send it."

The job to be done: turn an international income into a plan they can trust, and a
local payment into a number they can verify, without learning a financial product
to do it.

## Product Purpose

Mira is an AI-native money account for people whose income and life are in
different countries. It bridges the gap between receiving money globally and
spending it locally.

Success looks like a user who can state, from memory and without opening the app,
their weekly spending figure, who is about to receive their next payment, and what
it will cost. Comprehension is the metric. A balance dashboard with a chatbot
bolted on is the failure mode.

The prototype is simulated end to end. The arithmetic, permissions, consent and
failure handling are real; the money is not.

## Brand Personality

Precise, quiet, expensive.

The voice of a private bank that respects your time. It states the number, states
the cost, and stops. It never sells, never encourages, never uses an exclamation
mark. When it does not know something it says so in the same even tone it uses for
everything else.

Emotional goal: the calm of knowing exactly where you stand. Not excitement, not
delight, not gamified progress. Confidence that the figure on screen is the truth
and that nothing is hidden behind it.

## Anti-references

- **The previous build's own direction.** Dense museum-dark screens with six
  stacked panels, a footnote under every card, and paragraphs of legal hedging
  competing with the numbers. Beautiful art, unusable restraint. It failed on
  information density first and palette second.
- **Crypto and neon fintech.** Dark gradients, glow, glassmorphism, animated
  balances. None of it.
- **The gamified neobank.** Confetti on payment, streaks, badges, "you're on a
  roll". Money is not a game and the user is not a player.
- **Dashboard maximalism.** Six metrics above the fold, sparklines without a
  decision attached, a card per concept.
- **Art competing with the task.** Retain existing onboarding and approved brand
  art. The owner's later request explicitly allows specialist avatars: luminous
  Renaissance/Baroque oil portraits for Aurea and soft matte isometric creatures
  for Orion. Keep them subordinate to conversation and controls.
- **A giant AI orb dominating home.** The owner's specialist-avatar request
  supersedes the earlier no-face rule. Six specialists per brand accompany Mira
  as coordinator; their portraits identify speakers rather than dominate home.
- **Aphoristic marketing cadence.** "Serious claim. Short rebuttal." repeated down
  a page.

## Design Principles

1. **One primary answer at a time.** The resting home centers the available
   balance; it disappears once conversation begins. Focused financial screens
   emphasize their primary figure. A chat transcript can contain multiple turns,
   amounts and action cards, with a clear hierarchy within each turn rather than
   an artificial one-number limit across the conversation.

2. **The number is the design.** Scale, weight and spacing exist to make the figure
   unambiguous and stable. Decoration that does not help you read the number is
   removed, including decoration that is beautiful.

3. **Depth, not ornament.** Three-dimensional layering carries the premium feel and
   gives motion somewhere to live. Depth is structural (planes, perspective,
   parallax under tilt), never a texture applied on top.

4. **Legal honesty at the same volume as everything else.** The simulated-money
   disclosure, the reserve-not-insured note, the unknown-payment state: these are
   not footnotes in small grey type. They are stated once, plainly, at reading size,
   and then the interface gets out of the way.

5. **The assistant never raises its voice.** It routes, it explains a card that
   already exists, and it always offers the manual path. It never authorizes, never
   computes an amount. The owner's later direction permits named specialist
   avatars alongside Mira as coordinator; this supersedes the earlier blanket
   prohibition on assistant avatars.

6. **Reachable without the assistant.** Every action is a control first. If the
   model is unavailable, no screen becomes unreachable and no path is lost.

## Accessibility & Inclusion

- WCAG 2.2 AA as the floor. Body text at least 4.5:1; the huge figures must clear
  3:1 as large text and are designed to clear 4.5:1 anyway.
- Status is never carried by colour alone. Every payment state has a word and a
  glyph in addition to a tone.
- Reduce Motion is a first-class path: the 3D parallax collapses to static depth
  with a crossfade, never to a jarring cut.
- The parallax is decorative and non-interactive, so it can never intercept a
  control or a screen reader focus.
- Dynamic Type up to at least XXL without truncating a figure.
- English, Spanish and Brazilian Portuguese are the target languages. Amount
  formats must not be assumed: `1.234,56` and `1,234.56` both parse.
