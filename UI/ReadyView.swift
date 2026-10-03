import SwiftUI

struct ReadyView: View {
    @EnvironmentObject var model: AppModel

    private let presets: [(minutes: Int, label: String)] = [
        (30, "30m"), (60, "1h"), (120, "2h"), (240, "4h"), (480, "8h"),
        (1440, "1 day"), (2880, "2 days"), (10080, "1 week"),
    ]

    var body: some View {
        VStack(spacing: Theme.gap) {
            durationCard
            Card {
                NavRow(title: NSLocalizedString("Restrictions", comment: "row"),
                       subtitle: RestrictionsSummary.subtitle(entries: model.editableEntries, isAllowlist: model.isAllowlist),
                       action: { model.push(.restrictions) }) {
                    Text("\(model.editableEntries.count)").foregroundColor(Theme.sub)
                }
                .disabled(model.isAddingBlock)
                .opacity(model.isAddingBlock ? 0.5 : 1)
                RowDivider()
                NavRow(title: NSLocalizedString("Overrides", comment: "row"),
                       subtitle: model.overridePerDayDefault == 0 ? NSLocalizedString("Off", comment: "overrides off") : nil,
                       action: { model.push(.overrides) }) {
                    PillsView(states: OverridePills.states(perDay: model.overridePerDayDefault,
                                                           remainingToday: model.overridePerDayDefault,
                                                           activeFraction: nil, pendingSpend: false), width: 16)
                }
                .disabled(model.isAddingBlock)
                .opacity(model.isAddingBlock ? 0.5 : 1)
            }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Button(model.isAddingBlock ? NSLocalizedString("Starting Block…", comment: "start button busy")
                                           : NSLocalizedString("Start Block", comment: "start button")) {
                    model.startBlock()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canStart)
                // deliberately NO .keyboardShortcut(.defaultAction): starting a block is irreversible
                Text(NSLocalizedString("Once a block starts, it can’t be stopped early.", comment: "start caption"))
                    .font(.system(size: 12)).foregroundColor(Theme.sub)
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, Theme.inset)
        .padding(.top, 4)
    }

    private var durationCard: some View {
        let parts = DurationText.parts(minutes: model.blockDurationMinutes)
        let end = model.now.addingTimeInterval(TimeInterval(model.blockDurationMinutes * 60))
        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(NSLocalizedString("Block for", comment: "duration eyebrow")).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.sub)
                    Spacer()
                    Text(String(format: NSLocalizedString("until %@", comment: "until <end time>"), EndTimePhrase.phrase(for: end, now: model.now)))
                        .font(.system(size: 12)).foregroundColor(Theme.sub)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(parts.primary)
                    if let s = parts.secondary { Text(s).foregroundColor(Theme.sub) }
                }
                .font(.system(size: 38, weight: .light).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
                DurationSlider(minutes: Binding(get: { model.blockDurationMinutes }, set: { model.setBlockDuration($0) }),
                               scale: model.durationScale)
                    .disabled(model.isAddingBlock)
                HStack(spacing: 2) {
                    ForEach(presets.filter { $0.minutes <= model.maxBlockLengthMinutes }, id: \.minutes) { preset in
                        Button(preset.label) { model.setBlockDuration(preset.minutes) }
                            .buttonStyle(ChipButtonStyle(selected: preset.minutes == model.blockDurationMinutes))
                    }
                }
                .padding(.horizontal, -6)
                .disabled(model.isAddingBlock)
            }
        }
    }
}
