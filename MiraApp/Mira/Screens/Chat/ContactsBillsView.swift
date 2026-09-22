import SwiftUI

// MARK: - Contacts and bills
//
// Two lists the user owns, persisted locally and editable by hand. They are not
// a provider directory and nothing in them is verified: a contact is a note-to-
// self with a name on it, and a bill is a claim the user typed, not a debit
// mandate. Both are handed to Mira as context, which is the point of having them.

struct ContactsBillsView: View {
  enum Mode: String {
    case contacts
    case bills

    var title: String { self == .contacts ? "Contacts" : "Bills" }
    var glyph: String { self == .contacts ? "person.crop.circle" : "doc.text" }
  }

  let mode: Mode

  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand
  @Environment(\.dismiss) private var dismiss
  @State private var adding = false

  private var store: LocalDirectoryStore { session.localDirectory }

  var body: some View {
    ZStack {
      brand.canvas.ignoresSafeArea()

      VStack(spacing: 0) {
        SheetHeader(title: mode.title, subtitle: subtitle, onClose: { dismiss() })

        ScrollView {
          VStack(alignment: .leading, spacing: Space.md) {
            switch mode {
            case .contacts: contacts
            case .bills: bills
            }

            Button(mode == .contacts ? "Add a contact" : "Add a bill") { adding = true }
              .buttonStyle(BrandButtonStyle(kind: .secondary))

            Note(footnote, tone: .neutral)
          }
          .padding(.horizontal, Space.gutter)
          .readableWidth(620)
          .padding(.vertical, Space.lg)
        }
        .scrollIndicators(.hidden)
      }
    }
    .navigationBarHidden(true)
    .sheet(isPresented: $adding) { addSheet }
  }

  private var subtitle: String {
    switch mode {
    case .contacts:
      return "People you send to. Mira knows them by name, and can address a transfer to one."
    case .bills:
      return "What you expect to pay, and when. Mira counts these against the plan; it does not pay them."
    }
  }

  private var footnote: String {
    switch mode {
    case .contacts:
      return "Mira knows them by name and can address a transfer to one."
    case .bills:
      return "Mira counts these against your plan and brings each one to you when it is due."
    }
  }

  // MARK: Contacts

  @ViewBuilder
  private var contacts: some View {
    if store.contacts.isEmpty {
      emptyState("No contacts yet.")
    } else {
      VStack(spacing: Space.xs) {
        ForEach(store.contacts) { contact in
          Panel(padding: Space.sm) {
            HStack(spacing: Space.sm) {
              Text(initial(contact.name))
                .font(MiraFont.label(16))
                .foregroundStyle(brand.accentDeep)
                .frame(width: 38, height: 38)
                .background(brand.accentTint, in: Circle())

              VStack(alignment: .leading, spacing: 1) {
                Text(contact.name)
                  .font(MiraFont.label(16))
                  .foregroundStyle(brand.text)
                if !contact.handle.isEmpty {
                  Text(contact.handle)
                    .font(MiraFont.mono(12))
                    .foregroundStyle(brand.textTertiary)
                }
                if !contact.note.isEmpty {
                  Text(contact.note)
                    .font(MiraFont.caption(12))
                    .foregroundStyle(brand.textSecondary)
                }
              }

              Spacer(minLength: Space.xs)

              deleteButton(label: "Remove \(contact.name)") {
                store.removeContact(contact.id)
              }
            }
          }
        }
      }
    }
  }

  // MARK: Bills

  @ViewBuilder
  private var bills: some View {
    if store.bills.isEmpty {
      emptyState("No bills yet.")
    } else {
      VStack(spacing: Space.xs) {
        ForEach(store.bills) { bill in
          Panel(padding: Space.sm) {
            HStack(spacing: Space.sm) {
              Image(systemName: "doc.text")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(brand.accentDeep)
                .frame(width: 38, height: 38)
                .background(brand.accentTint, in: Circle())

              VStack(alignment: .leading, spacing: 1) {
                Text(bill.name)
                  .font(MiraFont.label(16))
                  .foregroundStyle(brand.text)
                Text("Due day \(bill.dueDay)")
                  .font(MiraFont.caption(12))
                  .foregroundStyle(brand.textTertiary)
              }

              Spacer(minLength: Space.xs)

              Text(bill.amount.display)
                .font(MiraFont.figure(16, weight: .semibold))
                .foregroundStyle(brand.text)

              deleteButton(label: "Remove \(bill.name)") {
                store.removeBill(bill.id)
              }
            }
          }
        }

        if store.billsByCurrency.count > 1 {
          Text(
            "Bills are held per currency and never summed across exchange rates the app does not own."
          )
          .font(MiraFont.caption(12))
          .foregroundStyle(brand.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  // MARK: Pieces

  private func emptyState(_ text: String) -> some View {
    Panel {
      Text(text)
        .font(MiraFont.body(15))
        .foregroundStyle(brand.textSecondary)
    }
  }

  private func deleteButton(label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: "trash")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(MiraColor.failed)
        .frame(width: 44, height: 44)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  private func initial(_ name: String) -> String {
    String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
  }

  @ViewBuilder
  private var addSheet: some View {
    switch mode {
    case .contacts: AddContactSheet()
    case .bills: AddBillSheet()
    }
  }
}

// MARK: - Add contact

private struct AddContactSheet: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var handle = ""
  @State private var note = ""

  private var canAdd: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Space.md) {
          field("Name", text: $name, prompt: "Ana Ribeiro")
          field("Handle or reference", text: $handle, prompt: "sim-ana-001")
          field("Note", text: $note, prompt: "Landlord, pays on the 5th")

          Button("Add contact") {
            session.localDirectory.addContact(name: name, handle: handle, note: note)
            dismiss()
          }
          .buttonStyle(BrandButtonStyle(kind: .gold))
          .disabled(!canAdd)

          Note(
            "Mira can address a transfer to anyone you save here.",
            tone: .neutral
          )
        }
        .padding(Space.gutter)
      }
      .background(brand.canvas.ignoresSafeArea())
      .navigationTitle("New contact")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }

  private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
    VStack(alignment: .leading, spacing: Space.xxs) {
      Text(label)
        .font(MiraFont.label(14))
        .foregroundStyle(brand.textSecondary)
      TextField(prompt, text: text)
        .font(MiraFont.body(16))
        .foregroundStyle(brand.text)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 12)
        .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.medium))
        .overlay {
          RoundedRectangle(cornerRadius: Radius.medium)
            .strokeBorder(brand.hairline, lineWidth: 1)
        }
    }
  }
}

// MARK: - Add bill

private struct AddBillSheet: View {
  @Environment(MiraSession.self) private var session
  @Environment(\.brand) private var brand
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var amountText = ""
  @State private var currency: Asset = .usd
  @State private var dueDay = 5

  private let currencies: [Asset] = [.usd, .eur, .brl]

  private var amount: Decimal? {
    Decimal(string: amountText.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX"))
  }

  private var canAdd: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (amount ?? 0) > 0
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Space.md) {
          VStack(alignment: .leading, spacing: Space.xxs) {
            fieldLabel("Name")
            TextField("Cloud hosting", text: $name)
              .textFieldStyle(.plain)
              .font(MiraFont.body(16))
              .padding(.horizontal, Space.sm)
              .padding(.vertical, 12)
              .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.medium))
              .overlay {
                RoundedRectangle(cornerRadius: Radius.medium)
                  .strokeBorder(brand.hairline, lineWidth: 1)
              }
          }

          VStack(alignment: .leading, spacing: Space.xxs) {
            fieldLabel("Amount")
            HStack(spacing: Space.xs) {
              Text(currency.code)
                .font(MiraFont.mono(15))
                .foregroundStyle(brand.textSecondary)
              TextField("0.00", text: $amountText)
                .keyboardType(.decimalPad)
                .font(MiraFont.figure(18))
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 12)
                .background(brand.surface, in: RoundedRectangle(cornerRadius: Radius.medium))
                .overlay {
                  RoundedRectangle(cornerRadius: Radius.medium)
                    .strokeBorder(brand.hairline, lineWidth: 1)
                }
            }
          }

          VStack(alignment: .leading, spacing: Space.xxs) {
            fieldLabel("Currency")
            Picker("Currency", selection: $currency) {
              ForEach(currencies, id: \.code) { asset in
                Text(asset.code).tag(asset)
              }
            }
            .pickerStyle(.segmented)
          }

          VStack(alignment: .leading, spacing: Space.xxs) {
            fieldLabel("Due day of the month")
            Stepper("Day \(dueDay)", value: $dueDay, in: 1...28)
              .font(MiraFont.body(16))
          }

          Button("Add bill") {
            guard let amount else { return }
            session.localDirectory.addBill(
              name: name, amount: Money(majorUnits: amount, currency: currency), dueDay: dueDay)
            dismiss()
          }
          .buttonStyle(BrandButtonStyle(kind: .gold))
          .disabled(!canAdd)

          Note(
            "A bill is a recurring cost Mira should remember. You approve every payment.",
            tone: .neutral
          )
        }
        .padding(Space.gutter)
      }
      .background(brand.canvas.ignoresSafeArea())
      .navigationTitle("New bill")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }

  private func fieldLabel(_ text: String) -> some View {
    Text(text)
      .font(MiraFont.label(14))
      .foregroundStyle(brand.textSecondary)
  }
}
