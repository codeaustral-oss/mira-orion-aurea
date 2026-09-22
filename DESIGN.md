---
name: Mira Orion and Mira Aurea
description: Native chat-centered money prototypes with retained brand art and simulated funds.
colors:
  orion-canvas: "#FAFAFA"
  orion-surface: "#FFFFFF"
  orion-ink: "#0D0D0F"
  orion-hairline: "#E2E4E7"
  orion-text: "#0B0B0D"
  orion-text-secondary: "#54575C"
  orion-text-tertiary: "#6F7379"
  orion-accent: "#9BA1A8"
  orion-accent-deep: "#6B7178"
  orion-accent-tint: "#EFF1F3"
  orion-accent-foreground: "#0B0B0D"
  aurea-canvas: "#FCFCFC"
  aurea-surface: "#FFFFFF"
  aurea-ink: "#1A1114"
  aurea-hairline: "#E8E8E8"
  aurea-text: "#1A1114"
  aurea-text-secondary: "#584A4D"
  aurea-text-tertiary: "#7A6C6F"
  aurea-accent: "#5C1A24"
  aurea-accent-deep: "#5C1A24"
  aurea-accent-tint: "#F2E4E2"
  aurea-accent-foreground: "#FFFFFF"
  settled: "#2F6B4F"
  pending: "#8A5A12"
  failed: "#9E2B2A"
  unknown: "#5E6570"
  info: "#4A6B82"
typography:
  title:
    fontFamily: "SF Pro, system-ui"
    fontSize: "20pt"
    fontWeight: 600
  body:
    fontFamily: "SF Pro, system-ui"
    fontSize: "16pt"
    fontWeight: 400
  label:
    fontFamily: "SF Pro, system-ui"
    fontSize: "14pt"
    fontWeight: 500
  caption:
    fontFamily: "SF Pro, system-ui"
    fontSize: "12pt"
    fontWeight: 400
  mono:
    fontFamily: "system monospace"
    fontSize: "13pt"
    fontWeight: 400
rounded:
  small: "10pt"
  medium: "16pt"
  large: "22pt"
  pill: "999pt"
spacing:
  xxs: "4pt"
  xs: "8pt"
  sm: "12pt"
  md: "18pt"
  lg: "26pt"
  xl: "38pt"
  xxl: "56pt"
  xxxl: "84pt"
  gutter: "24pt"
components:
  button-primary-orion:
    backgroundColor: "{colors.orion-ink}"
    textColor: "{colors.orion-canvas}"
    rounded: "{rounded.pill}"
    padding: "15pt 26pt"
  panel-orion:
    backgroundColor: "{colors.orion-surface}"
    rounded: "{rounded.large}"
    padding: "{spacing.md}"
---

# Design System: Mira

## Overview

**Creative North Star: "Precise, quiet, expensive."**

Two native SwiftUI brands share controls and money behavior. Orion uses near-white, black and silver; Aurea uses neutral almost-white, burgundy and a native serif display voice. Preserve existing components, onboarding and brand art. The owner’s chat-centered direction is code-led from a precise brief; there is no approved composition image.

**Key Characteristics:**
- Quiet canvas and readable native typography.
- Existing controls with restrained, rounded surfaces.
- Distinct brand art supporting named specialists.

Source: `MiraApp/Mira/Design/{Brand,Tokens,Type,Controls}.swift`, `App/MiraRoot.swift`, `Screens/Chat`, and `art/agents/DIRECTION.md`. Sizes above are SwiftUI design points at default Dynamic Type, not CSS points. HTML previews in the sidecar translate one design point to one CSS pixel only for inspection.

## Colors

Orion's silver is a material accent; its deeper accent carries small meaningful marks. Aurea's burgundy supplies the accent against an almost-white neutral canvas. Aurea must not acquire a warm-paper or cream background; warmth belongs to approved artwork. Both use separate primary, secondary and tertiary text colors, white surfaces and hairline separators. Status tones are shared across brands.

**The Readable Signal Rule.** Pair payment status color with a word and symbol; do not use Orion's silver material color for meaningful small text.

## Typography

`MiraFont` scales body, title, label, caption and monospaced roles through matching `UIFontMetrics`. Screen and sheet display headings use the native sans for Orion and native serif for Aurea. Card headings, field labels, buttons and running UI use native sans in both brands. `screenTitle` centralizes display tracking: Aurea opens by size × 0.004; Orion tightens by size × −0.032. Figures remain native sans with tabular digits in both brands; the contrary serif-figure comment in `Type.swift` is stale. Utility titles use a scaled 26pt semibold brand display face. Hero figures default to 68pt; the resting chat balance uses 56pt. Chat responses use scaled 17pt body text.

Respect the owner’s native accessible typography requirement. Preserve Dynamic Type, wrapping and spoken labels. Do not inherit fixed tiny marketing type as a reusable text role. This source extraction is not an accessibility certification.

## Layout

Shared gutters use the named gutter token. Utility sheets use `SheetHeader`: a clear title, optional context, an accessible close control and 24pt top breathing room. They do not stack logo, tagline and three-word brand columns above the title.

Onboarding keeps its narrative, artwork and footer in one viewport. Orion explicitly pins its root column to the measured viewport; full-bleed effects live behind it so they do not push the footer offscreen. Its six robot specialists surround Mira as coordinator, over a restrained engraved constellation. Aurea frames one portrait painting above copy and footer, retaining neutral almost-white UI. The reauthored lake and terrace scenes use simplified luminous cool-blue oil landscapes; their source prompts and provenance are in `art/onboarding/manifest.json`. These onboarding compositions do not change utility-screen rules.

Chat transcript and composer cap their readable width at 640pt. Text can grow vertically. The composer supports one to five lines; action chips scroll horizontally. See `.impeccable/chat-surface.md` for this surface’s behavior rather than applying its composition to every screen.

## Elevation & Depth

The sampled chat controls and panels use tonal surfaces and thin borders, without cast shadows. The resting home retains the existing receding grid scene; conversation removes it. Existing onboarding and dimensional art remain part of their own surfaces. Buttons press to 0.98 scale and 0.92 opacity with a 0.16-second ease-out; chat-state transition uses 0.35 seconds and is disabled with Reduce Motion. Transcript scrolling respects Reduce Motion.

## Shapes

Panels, chat bubbles and composer use continuous rounded rectangles with the large radius. Primary and secondary actions and suggestion chips are capsules; avatar crops and icon controls are circles. Standard borders are one point. Do not introduce nested panels as a default organizing device.

## Components

- **Buttons:** `MiraButtonStyle` is the single implementation; `BrandButtonStyle` is its compatibility alias. Primary, secondary, quiet, commitment and destructive variants share scaled 16pt native labels and 15pt vertical padding. Primary fills use ink, secondary fills use surface with a border. Commitment uses brand accent and explicit accent foreground (dark text on Orion silver, white on Aurea burgundy). Destructive uses the shared failed tone for text and a 10% failed-tone fill.
- **Panel:** White or explicit tint, shared large radius, hairline border, default medium padding.
- **Composer:** Native multiline text field, visible secondary-color prompt, white surface, large radius and hairline. Adjacent circular send control is 44pt and disabled for blank drafts or work in progress.
- **Action chip:** Surface capsule, hairline border, 14pt scaled label, 18pt horizontal padding and at least 44pt height.
- **Navigation:** Menu at top left; utility destinations retain their existing views. Utility close controls have a 44pt target and a spoken “Close” label.
- **Status pill:** Symbol and 13pt scaled label, tone at 10% opacity as capsule fill, combined accessibility label.
- **Agent task card:** Reuses `ChatCard` surface, large radius, medium padding and hairline. A scaled 16pt native title, state word and mark lead the card. Server-reported steps appear while queued/running or awaiting input; completed results can expose summary, sources and files. Needs-input asks for a reply in chat. Cancel and retry reuse shared buttons. Only valid HTTP(S) URLs become links; other addresses remain text. No invented progress or completion state.
- **Specialist avatar:** Circular generated art with a hairline; adjacent name and role identify the speaker. Decorative image is hidden from accessibility. Six specialists per brand accompany Mira as coordinator. Aurea uses luminous adult Renaissance/Baroque oil portraits, broad brushwork and vibrant period clothing; Orion uses soft chunky matte isometric robot creatures with dot eyes. Full direction and provenance remain in `art/agents`.

## Do's and Don'ts

- **Do** retain existing components, onboarding and approved brand art.
- **Do** use native scaling, clear labels and explicit simulated-funds language.
- **Do** keep Aurea backgrounds neutral almost-white with white surfaces.
- **Do** keep specialist art subordinate to conversation and action controls.
- **Don't** restore stacked marketing headers on utility sheets.
- **Don't** make dark dense portraits, Disney-like faces or glossy mechanical robot details the avatar direction.
- **Don't** treat model prose as authorization to move even simulated money.
