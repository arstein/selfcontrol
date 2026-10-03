import SwiftUI

struct OverridesView: View {
    @EnvironmentObject var model: AppModel

    private var perDay: Int { model.isBlockRunning ? model.override.perDay : model.overridePerDayDefault }
    private var minutes: Int { model.isBlockRunning ? model.override.minutes : model.overrideMinutesDefault }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text(NSLocalizedString("An override unblocks everything for a short time. They reset at midnight and need an internet time check to start.", comment: "overrides explainer"))
                .foregroundColor(Theme.sub).lineSpacing(3).padding(.horizontal, 2)
                .fixedSize(horizontal: false, vertical: true)
            Card {
                row(NSLocalizedString("Overrides per day", comment: "")) {
                    if model.isBlockRunning {
                        Text("\(perDay)").fontWeight(.semibold)
                    } else {
                        CompactStepper(value: "\(perDay)", label: NSLocalizedString("overrides per day", comment: ""),
                                       canDecrement: perDay > OverridePolicyLimits.perDayRange.lowerBound,
                                       canIncrement: perDay < OverridePolicyLimits.perDayRange.upperBound,
                                       decrement: { model.setOverridePerDay(perDay - 1) },
                                       increment: { model.setOverridePerDay(perDay + 1) })
                    }
                }
                RowDivider()
                row(NSLocalizedString("Minutes each", comment: "")) {
                    if model.isBlockRunning {
                        Text("\(minutes)").fontWeight(.semibold)
                    } else {
                        CompactStepper(value: "\(minutes)", label: NSLocalizedString("minutes", comment: ""),
                                       canDecrement: minutes > OverridePolicyLimits.minutesRange.lowerBound,
                                       canIncrement: minutes < OverridePolicyLimits.minutesRange.upperBound,
                                       decrement: { model.setOverrideMinutes(OverridePolicyLimits.previousMinutes(minutes)) },
                                       increment: { model.setOverrideMinutes(OverridePolicyLimits.nextMinutes(minutes)) })
                            .disabled(perDay == 0)
                    }
                }
            }
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    if perDay == 0 {
                        Text(NSLocalizedString("Overrides are off", comment: "")).font(.system(size: 15, weight: .medium))
                    } else {
                        Text(NSLocalizedString("Each day you’ll get", comment: "")).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.sub)
                        PillsView(states: OverridePills.states(perDay: perDay, remainingToday: perDay, activeFraction: nil, pendingSpend: false), width: 40)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Group {
                            if perDay == 1 {
                                Text(String(format: NSLocalizedString("1 break of %ld minutes", comment: "override preview, one per day"), minutes))
                            } else {
                                Text(String(format: NSLocalizedString("%ld breaks of %ld minutes", comment: "override preview: <perDay> breaks of <minutes> minutes"), perDay, minutes))
                            }
                        }
                        .font(.system(size: 15, weight: .medium))
                    }
                }
            }
            Text(model.isBlockRunning
                 ? NSLocalizedString("Fixed for this block.", comment: "")
                 : NSLocalizedString("During a block you can lower these, but not raise them. Set 0 to turn overrides off.", comment: ""))
                .font(.system(size: 12)).foregroundColor(Theme.sub).padding(.horizontal, 2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, Theme.inset)
        .padding(.top, 4)
    }

    private func row<V: View>(_ title: String, @ViewBuilder value: () -> V) -> some View {
        HStack { Text(title).fontWeight(.medium); Spacer(); value() }
            .padding(.horizontal, 14).padding(.vertical, 12)
    }
}
