import SwiftUI

struct ComposePollEditorView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    @Binding var draft: ComposePollDraft

    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label("Poll", systemImage: "chart.bar.xaxis")
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 12)

                Button("Remove", role: .destructive, action: onRemove)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
            }

            VStack(spacing: 10) {
                ForEach(Array(draft.options.enumerated()), id: \.element.id) { index, option in
                    optionRow(index: index, option: option)
                }

                Button {
                    draft.options.append(ComposePollOption())
                } label: {
                    Label("Add Option", systemImage: "plus.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
                .buttonStyle(.plain)
            }

            Divider()

            Toggle("Allow multiple choices", isOn: $draft.allowsMultipleChoice)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Ends")
                        .font(.subheadline)

                    Spacer(minLength: 0)

                    if let endsAt = draft.endsAt {
                        Text(endsAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.footnote)
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text("No end date")
                            .font(.footnote)
                            .foregroundStyle(appSettings.themePalette.secondaryForeground)
                    }
                }

                if draft.endsAt != nil {
                    DatePicker(
                        "Poll end date",
                        selection: endDateBinding,
                        in: minimumEndDate...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                }

                Button {
                    if draft.endsAt == nil {
                        draft.endsAt = ComposePollDraft.defaultEndDate()
                    } else {
                        draft.endsAt = nil
                    }
                } label: {
                    Label(
                        draft.endsAt == nil ? "Add End Date" : "Clear End Date",
                        systemImage: draft.endsAt == nil ? "calendar.badge.plus" : "xmark.circle"
                    )
                    .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.endsAt == nil ? Color.accentColor : appSettings.themePalette.secondaryForeground)
            }

            Text(
                draft.hasMinimumOptions
                    ? "\(draft.validOptionCount) options ready."
                    : "Add at least two option labels before posting."
            )
            .font(.footnote.weight(draft.hasMinimumOptions ? .regular : .semibold))
            .foregroundStyle(draft.hasMinimumOptions ? appSettings.themePalette.secondaryForeground : Color.orange)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(appSettings.themePalette.sheetInsetBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(appSettings.themePalette.separator, lineWidth: 0.8)
        )
    }

    private var minimumEndDate: Date {
        ComposePollDraft.roundToMinute(Date().addingTimeInterval(60))
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { draft.endsAt ?? ComposePollDraft.defaultEndDate() },
            set: { newValue in
                draft.endsAt = ComposePollDraft.roundToMinute(newValue)
            }
        )
    }

    private func optionRow(index: Int, option: ComposePollOption) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(index + 1)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(appSettings.themePalette.tertiaryFill)
                )

            TextField(
                "Option \(index + 1)",
                text: optionTextBinding(optionID: option.id),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...2)

            if draft.options.count > 2 {
                Button {
                    draft.options.removeAll { $0.id == option.id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(appSettings.themePalette.secondaryForeground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove option \(index + 1)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(appSettings.themePalette.tertiaryFill)
        )
    }

    private func optionTextBinding(optionID: String) -> Binding<String> {
        Binding(
            get: {
                draft.options.first(where: { $0.id == optionID })?.text ?? ""
            },
            set: { newValue in
                guard let index = draft.options.firstIndex(where: { $0.id == optionID }) else { return }
                draft.options[index].text = newValue
            }
        )
    }
}
