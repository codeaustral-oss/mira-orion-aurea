import SwiftUI

// MARK: - Documents in the conversation
//
// A receipt, a swap slip, an itinerary, a reservation. The facts are already
// decided; this only lays them out the way the object itself is laid out:
// monospaced type, dotted rules, a reference, a barcode. No gradients, no
// confetti — a document earns its place by being readable and by being true.

struct ReceiptCardView: View {
  let receipt: ReceiptSpec
  /// Inside a task card the document already has a container: skip the paper
  /// frame and keep only the typography and the rules.
  var compact: Bool = false

  @Environment(\.brand) private var brand

  /// The badge, with the document's symbol when it has one.
  private func badgeView(_ text: String) -> some View {
    HStack(spacing: 5) {
      if let symbol = receipt.symbol {
        Image(systemName: Icons.symbol(for: symbol))
          .font(.system(size: 10, weight: .semibold))
      }
      Text(text)
        .font(.system(size: 9, weight: .semibold))
        .tracking(1.4)
    }
    .foregroundStyle(brand.accentDeep)
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(Capsule().fill(brand.accentDeep.opacity(0.12)))
  }

  /// One row of a list: its mark (a service tile or a symbol), the label, the value.
  @ViewBuilder
  private func lineRow(_ line: ReceiptLine) -> some View {
    if line.value.count > 34 || line.label.count > 25 {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: Space.xs) {
          if let service = line.service {
            ServiceMark(name: service, size: 22)
          } else if let icon = line.icon {
            Image(systemName: Icons.symbol(for: icon))
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(brand.textTertiary)
          }
          Text(line.label)
            .font(MiraFont.label(13))
            .foregroundStyle(brand.text)
        }
        Text(line.value)
          .font(.system(size: 12.5, design: .monospaced))
          .foregroundStyle(brand.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, Space.xs)
    } else {
      HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
        if let service = line.service {
          ServiceMark(name: service, size: 22)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
        } else if let icon = line.icon {
          Image(systemName: Icons.symbol(for: icon))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(brand.textTertiary)
            .frame(width: 18, alignment: .leading)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
        }
        Text(line.label)
          .font(.system(size: 12.5))
          .foregroundStyle(brand.text)
        Spacer(minLength: Space.xs)
        Text(line.value)
          .font(.system(size: 12.5, design: .monospaced))
          .foregroundStyle(brand.textSecondary)
      }
    }
  }

  /// A recurring charge gets two calm lines: identity and amount first, date
  /// below. Keeping the amount out of the date's text prevents either column
  /// from breaking into the other on an iPhone.
  private func subscriptionRow(_ line: ReceiptLine) -> some View {
    HStack(alignment: .top, spacing: Space.sm) {
      if let service = line.service {
        ServiceMark(name: service, size: 26)
          .padding(.top, 1)
          .accessibilityHidden(true)
      }

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
          Text(line.label)
            .font(MiraFont.label(14))
            .foregroundStyle(brand.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

          Text(line.value)
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .foregroundStyle(brand.text)
            .fixedSize(horizontal: true, vertical: false)
        }

        if let detail = line.detail {
          Text(detail)
            .font(MiraFont.caption(12))
            .foregroundStyle(brand.textSecondary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, Space.xs)
    .accessibilityElement(children: .combine)
  }

  private var label: String {
    switch receipt.kind {
    case .purchase: return "RECEIPT"
    case .swap: return "SWAP"
    case .itinerary: return "ITINERARY"
    case .reservation: return "RESERVATION"
    case .tracking: return "TRACKING"
    case .order: return "ORDER"
    case .savings: return "SUBSCRIPTIONS"
    case .offers: return "OFFERS"
    case .capacity: return "TIER"
    case .brief: return "MONEY DESK"
    }
  }

  private var dateText: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMM yyyy · HH:mm"
    return formatter.string(from: receipt.date)
  }

  var body: some View {
    switch receipt.kind {
    case .purchase, .swap:
      receiptBody
    case .itinerary, .reservation:
      planBody
    case .tracking:
      trackingBody
    case .order:
      orderBody
    case .savings:
      listBody
    case .offers:
      listBody
    case .capacity:
      capacityBody
    case .brief:
      listBody
    }
  }

  /// A settled document: money moved, so it reads like a till slip — mono type,
  /// dotted rules, a reference and a barcode as proof.
  private var receiptBody: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      VStack(alignment: .leading, spacing: 3) {
        Text(label)
          .font(.system(size: 10, weight: .semibold, design: .monospaced))
          .tracking(1.8)
          .foregroundStyle(brand.textTertiary)
        Text(receipt.title)
          .font(.system(size: 17, weight: .semibold, design: .monospaced))
          .foregroundStyle(brand.text)
          .fixedSize(horizontal: false, vertical: true)
        if let subtitle = receipt.subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(brand.textSecondary)
        }
      }

      DashedRule()

      VStack(alignment: .leading, spacing: 6) {
        ForEach(receipt.lines, id: \.self) { line in
          HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(line.label.uppercased())
              .font(.system(size: 10, weight: .medium, design: .monospaced))
              .tracking(0.8)
              .foregroundStyle(brand.textTertiary)
            Spacer(minLength: Space.xs)
            Text(line.value)
              .font(.system(size: 13, design: .monospaced))
              .foregroundStyle(brand.text)
              .multilineTextAlignment(.trailing)
          }
        }
      }

      if let total = receipt.total {
        DashedRule()
        HStack(alignment: .firstTextBaseline) {
          Text(total.label.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(brand.text)
          Spacer(minLength: Space.xs)
          Text(total.value)
            .font(.system(size: 16, weight: .semibold, design: .monospaced))
            .foregroundStyle(brand.text)
        }
      }

      DashedRule()

      HStack(alignment: .bottom, spacing: Space.sm) {
        VStack(alignment: .leading, spacing: 2) {
          if let reference = receipt.reference, !reference.isEmpty {
            Text("REF \(reference)")
              .font(.system(size: 11, weight: .medium, design: .monospaced))
              .foregroundStyle(brand.textSecondary)
          }
          Text(dateText)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(brand.textTertiary)
        }
        Spacer(minLength: Space.xs)
        BarcodeStrip(seed: receipt.reference ?? receipt.title)
      }

      if let footnote = receipt.footnote, !footnote.isEmpty {
        Text(footnote)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(brand.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(compact ? 0 : Space.md)
    .frame(maxWidth: compact ? .infinity : 360, alignment: .leading)
    .background {
      if !compact {
        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
          .fill(brand.surface)
      }
    }
    .overlay {
      if !compact {
        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
          .strokeBorder(brand.textTertiary.opacity(0.28), lineWidth: 1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label). \(receipt.title).")
  }

  // MARK: Plans — prepared, not settled
  //
  // Nothing has been paid for or held, so nothing here may look like proof.
  // No barcode, no reference, no total: a ticket-shaped slip that says what it
  // is planning, with the state stated as a badge rather than implied by the
  // styling.

  private var stateBadge: String {
    switch receipt.kind {
    case .itinerary: return "PREPARED · NOT BOOKED"
    case .reservation: return "PREPARED · NOT HELD"
    case .tracking:
      let status = receipt.lines.first { $0.label == "Status" }?.value ?? ""
      return status.uppercased()
    default: return ""
    }
  }

  /// The parcel's route, with the step it has reached filled in.
  private var trackingSteps: some View {
    let status = receipt.lines.first { $0.label == "Status" }?.value ?? ""
    let reached = PlacedOrder.steps.firstIndex(of: status) ?? 0
    return HStack(spacing: 0) {
      ForEach(Array(PlacedOrder.steps.enumerated()), id: \.offset) { index, _ in
        if index > 0 {
          Rectangle()
            .fill(index <= reached ? brand.accentDeep : brand.textTertiary.opacity(0.3))
            .frame(height: 1.5)
        }
        Circle()
          .fill(index <= reached ? brand.accentDeep : brand.textTertiary.opacity(0.25))
          .frame(width: index == reached ? 9 : 7, height: index == reached ? 9 : 7)
      }
    }
    .accessibilityHidden(true)
  }

  /// The list-shaped documents — the recurring charges, the offers, the tier,
  /// the money desk's notes — share one sheet: a badge, a heading, rows, one
  /// emphasised row, and the small print the spec carries.
  private var listBody: some View { documentBody(badge: Self.badgeLabel(for: receipt)) }

  /// The badge a list-shaped document wears. Only the recurring charges are
  /// RECURRING: a one-off split, plan or ask carries its own badge from the
  /// spec (SPLIT, CREDIT, NEGOTIATION, …), and never the subscriptions' word.
  static func badgeLabel(for receipt: ReceiptSpec) -> String {
    switch receipt.kind {
    case .savings: return "RECURRING"
    case .offers: return "OFFERS"
    case .capacity: return "TIER"
    case .brief:
      let badge = receipt.reference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return badge.isEmpty ? "MONEY DESK" : badge
    default: return "MONEY DESK"
    }
  }

  /// The account's tier: what it lifts, what earned it, and the one step that
  /// would move it — as a document, not a sales page.
  private var capacityBody: some View { documentBody(badge: Self.badgeLabel(for: receipt)) }

  private func documentBody(badge: String) -> some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      HStack(alignment: .top) {
        badgeView(badge)
        Spacer(minLength: Space.xs)
        Text(dateText)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(brand.textTertiary)
      }

      Text(receipt.title)
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(brand.text)

      if let subtitle = receipt.subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(MiraFont.body(13))
          .foregroundStyle(brand.textSecondary)
      }

      DashedRule()

      if receipt.kind == .savings {
        VStack(spacing: 0) {
          ForEach(receipt.lines, id: \.self) { line in
            subscriptionRow(line)
            if line != receipt.lines.last {
              Rectangle()
                .fill(brand.hairline)
                .frame(height: 1)
                .accessibilityHidden(true)
            }
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(receipt.lines, id: \.self) { line in
            lineRow(line)
          }
        }
      }

      if let total = receipt.total {
        DashedRule()
        HStack(alignment: .firstTextBaseline) {
          Text(total.label.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1)
            .foregroundStyle(brand.textSecondary)
          Spacer(minLength: Space.xs)
          Text(total.value)
            .font(.system(size: 16, weight: .semibold, design: .monospaced))
            .foregroundStyle(brand.text)
        }
      }

      if let footnote = receipt.footnote, !footnote.isEmpty {
        Text(footnote)
          .font(MiraFont.caption(12))
          .foregroundStyle(brand.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(compact ? 0 : Space.md)
    .frame(maxWidth: compact ? .infinity : 360, alignment: .leading)
    .background {
      if !compact {
        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(brand.surface)
      }
    }
    .overlay {
      if !compact {
        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
          .strokeBorder(brand.accentDeep.opacity(0.28), lineWidth: 1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label). \(receipt.title).")
  }

  /// An order being prepared: the ticker large, the size and venue as fields,
  /// an estimate when arithmetic is possible — and it says it is not executed.
  private var orderBody: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      HStack(alignment: .top) {
        Text("PREPARED · NOT EXECUTED")
          .font(.system(size: 9, weight: .semibold))
          .tracking(1.4)
          .foregroundStyle(brand.accentDeep)
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(Capsule().fill(brand.accentDeep.opacity(0.12)))
        Spacer(minLength: Space.xs)
        Text(dateText)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(brand.textTertiary)
      }

      HStack(alignment: .center, spacing: Space.xs) {
        ChartMark(color: brand.accentDeep, size: 22)
        Text(receipt.title)
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(brand.text)
        Spacer(minLength: 0)
      }

      if let subtitle = receipt.subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(MiraFont.body(13))
          .foregroundStyle(brand.textSecondary)
      }

      DashedRule()

      VStack(alignment: .leading, spacing: 6) {
        ForEach(receipt.lines, id: \.self) { line in
          HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(line.label.uppercased())
              .font(.system(size: 9, weight: .semibold))
              .tracking(1.1)
              .foregroundStyle(brand.textTertiary)
            Spacer(minLength: Space.xs)
            Text(line.value)
              .font(.system(size: 13, design: .monospaced))
              .foregroundStyle(brand.text)
              .multilineTextAlignment(.trailing)
          }
        }
      }

      if let estimate = receipt.total {
        DashedRule()
        HStack(alignment: .firstTextBaseline) {
          Text(estimate.label.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1)
            .foregroundStyle(brand.textSecondary)
          Spacer(minLength: Space.xs)
          Text(estimate.value)
            .font(.system(size: 16, weight: .semibold, design: .monospaced))
            .foregroundStyle(brand.text)
        }
      }

      if let footnote = receipt.footnote, !footnote.isEmpty {
        Text(footnote)
          .font(MiraFont.caption(12))
          .foregroundStyle(brand.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(compact ? 0 : Space.md)
    .frame(maxWidth: compact ? .infinity : 360, alignment: .leading)
    .background {
      if !compact {
        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
          .fill(brand.surface)
      }
    }
    .overlay {
      if !compact {
        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
          .strokeBorder(brand.accentDeep.opacity(0.28), lineWidth: 1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label). \(receipt.title). PREPARED · NOT EXECUTED.")
  }

  private var trackingBody: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      HStack(alignment: .top) {
        Text(stateBadge)
          .font(.system(size: 9, weight: .semibold))
          .tracking(1.4)
          .foregroundStyle(brand.accentDeep)
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(Capsule().fill(brand.accentDeep.opacity(0.12)))
        Spacer(minLength: Space.xs)
        Text(dateText)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(brand.textTertiary)
      }

      Text(receipt.title)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(brand.text)
        .fixedSize(horizontal: false, vertical: true)

      trackingSteps

      VStack(alignment: .leading, spacing: 6) {
        ForEach(receipt.lines.filter { $0.label != "Status" }, id: \.self) { line in
          HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(line.label.uppercased())
              .font(.system(size: 9, weight: .semibold))
              .tracking(1.1)
              .foregroundStyle(brand.textTertiary)
            Spacer(minLength: Space.xs)
            Text(line.value)
              .font(.system(size: 13, design: .monospaced))
              .foregroundStyle(brand.text)
          }
        }
      }

      if let footnote = receipt.footnote, !footnote.isEmpty {
        Text(footnote)
          .font(MiraFont.caption(12))
          .foregroundStyle(brand.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(compact ? 0 : Space.md)
    .frame(maxWidth: compact ? .infinity : 360, alignment: .leading)
    .background {
      if !compact {
        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
          .fill(brand.surface)
      }
    }
    .overlay {
      if !compact {
        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
          .strokeBorder(brand.accentDeep.opacity(0.28), lineWidth: 1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label). \(receipt.title). \(stateBadge).")
  }

  private var planBody: some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      HStack(alignment: .top) {
        Text(stateBadge)
          .font(.system(size: 9, weight: .semibold))
          .tracking(1.4)
          .foregroundStyle(brand.accentDeep)
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(Capsule().fill(brand.accentDeep.opacity(0.12)))
        Spacer(minLength: Space.xs)
        Text(dateText)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(brand.textTertiary)
      }

      if receipt.kind == .itinerary, let route = routeParts {
        HStack(alignment: .center, spacing: Space.sm) {
          Text(route.from)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(brand.text)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
          Image(systemName: "arrow.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(brand.accentDeep)
          Text(route.to)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(brand.text)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
      } else {
        Text(receipt.title)
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(brand.text)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let subtitle = receipt.subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(MiraFont.body(13))
          .foregroundStyle(brand.textSecondary)
      }

      // A tear line, not a ruled total: the stub you would carry, not a receipt.
      TearLine()

      HStack(alignment: .top, spacing: Space.lg) {
        ForEach(receipt.lines, id: \.self) { line in
          VStack(alignment: .leading, spacing: 3) {
            Text(line.label.uppercased())
              .font(.system(size: 9, weight: .semibold))
              .tracking(1.2)
              .foregroundStyle(brand.textTertiary)
            Text(line.value)
              .font(.system(size: 14, weight: .medium))
              .foregroundStyle(brand.text)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
      }

      if let footnote = receipt.footnote, !footnote.isEmpty {
        Text(footnote)
          .font(MiraFont.caption(12))
          .foregroundStyle(brand.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(compact ? 0 : Space.md)
    .frame(maxWidth: compact ? .infinity : 360, alignment: .leading)
    .background {
      if !compact {
        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
          .fill(brand.surface)
      }
    }
    .overlay {
      if !compact {
        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
          .strokeBorder(brand.accentDeep.opacity(0.28), lineWidth: 1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label). \(receipt.title). \(stateBadge).")
  }

  /// "Sao Paulo  →  Lisbon" becomes two ends, when the title has that shape.
  private var routeParts: (from: String, to: String)? {
    let title = receipt.title
    let separator = "  →  "
    guard title.contains(separator) else { return nil }
    let parts = title.components(separatedBy: separator)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return (parts[0], parts[1])
  }
}

/// The dotted edge of a ticket stub.
struct TearLine: View {
  @Environment(\.brand) private var brand

  var body: some View {
    ZStack {
      DashedRule()
        .foregroundStyle(brand.textTertiary.opacity(0.5))
      HStack {
        Circle()
          .fill(brand.surface)
          .frame(width: 10, height: 10)
          .offset(x: -14)
        Spacer(minLength: 0)
        Circle()
          .fill(brand.surface)
          .frame(width: 10, height: 10)
          .offset(x: 14)
      }
    }
    .frame(height: 12)
    .accessibilityHidden(true)
  }
}

/// A dotted rule, the way a till prints one.
struct DashedRule: View {
  @Environment(\.brand) private var brand

  var body: some View {
    Canvas { context, size in
      var path = Path()
      path.move(to: CGPoint(x: 0, y: size.height / 2))
      path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
      context.stroke(
        path,
        with: .color(brand.textTertiary.opacity(0.55)),
        style: StrokeStyle(lineWidth: 1, dash: [3.5, 3.5]))
    }
    .frame(height: 1.5)
  }
}

/// The barcode on a receipt: not a real symbology, and not pretending to be —
/// but deterministic, so the same reference always prints the same bars.
struct BarcodeStrip: View {
  let seed: String

  @Environment(\.brand) private var brand

  var body: some View {
    Canvas { context, size in
      var value = seed.unicodeScalars.reduce(UInt64(5381)) { ($0 &<< 5) &+ $0 &+ UInt64($1.value) }
      var x: CGFloat = 0
      var guardrail = 0
      while x < size.width, guardrail < 240 {
        value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let wide = (value >> 33) % 2 == 0
        let width: CGFloat = wide ? 2.6 : 1.2
        let gap: CGFloat = ((value >> 20) % 3 == 0) ? 2.8 : 1.5
        context.fill(
          Path(CGRect(x: x, y: 0, width: width, height: size.height)),
          with: .color(brand.text.opacity(0.72)))
        x += width + gap
        guardrail += 1
      }
    }
    .frame(width: 92, height: 28)
    .accessibilityHidden(true)
  }
}
