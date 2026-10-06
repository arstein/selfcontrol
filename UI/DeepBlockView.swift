import SwiftUI

/// The Deep Block card: list summary, length, start — or the running deep block.
struct DeepBlockView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: Theme.gap) {
            if model.deepRunning { DeepBlockBanner() }
            Card {
                NavRow(title: NSLocalizedString("Deep list", comment: "row"),
                       subtitle: RestrictionsSummary.subtitle(entries: model.entries(.deep), isAllowlist: model.allowlist(.deep)),
                       action: { model.push(.deepList) }) {
                    Text("\(model.entries(.deep).count)").foregroundColor(Theme.sub)
                }
            }
            if !model.deepRunning { lengthCard }
            Text(NSLocalizedString("A deep block can’t be overridden. Only emergency unlock can end it early.", comment: "deep block caption"))
                .font(.system(size: 12)).foregroundColor(Theme.sub)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !model.deepRunning {
                Button(model.isAddingDeepBlock ? NSLocalizedString("Starting Deep Block…", comment: "")
                                               : NSLocalizedString("Start Deep Block", comment: "start deep block button")) {
                    model.startDeepBlock()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canStartDeep)
                // deliberately NO .keyboardShortcut(.defaultAction): starting a block is irreversible
                .padding(.bottom, 16)
            } else if model.emergencyUnlockAvailable {
                Button(NSLocalizedString("Emergency unlock…", comment: "")) { model.push(.emergencyUnlock) }
                    .buttonStyle(LinkButtonStyle()).padding(.bottom, 12)
            }
        }
        .padding(.horizontal, Theme.inset)
        .padding(.top, 4)
    }

    private var lengthCard: some View {
        let parts = DurationText.parts(minutes: model.deepDurationMinutes)
        let end = model.now.addingTimeInterval(TimeInterval(model.deepDurationMinutes * 60))
        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(NSLocalizedString("Length", comment: "deep block eyebrow")).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.sub)
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
                DurationSlider(minutes: Binding(get: { model.deepDurationMinutes }, set: { model.setDeepDuration($0) }),
                               scale: DeepBlockLimits.scale)
                    .disabled(model.isAddingDeepBlock)
                DurationTicks(maxMinutes: DeepBlockLimits.maxMinutes, scale: DeepBlockLimits.scale,
                              selectedMinutes: model.deepDurationMinutes) { model.setDeepDuration($0) }
                    .disabled(model.isAddingDeepBlock)
                    .padding(.top, -4)
            }
        }
    }
}

/// Compact running-deep-block card used on the Ready, Blocking and Deep Block screens.
struct DeepBlockBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("Deep block", comment: "banner title")).fontWeight(.medium)
                    Text(subtitle).font(.system(size: 12)).foregroundColor(Theme.sub)
                }
                Spacer()
                if let secs = model.deepRemainingSeconds {
                    let p = CountdownText.parts(seconds: secs)
                    Text(String(format: NSLocalizedString("%@ left", comment: ""), [p.days, p.clock].compactMap { $0 }.joined(separator: " ")))
                        .foregroundColor(Theme.sub).monospacedDigit()
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1))
    }

    private var subtitle: String {
        guard let end = model.deepEndDate else {
            return NSLocalizedString("Verifying end time…", comment: "Waiting for network time before ending a block")
        }
        return String(format: NSLocalizedString("ends %@", comment: "ends <end time>"), EndTimePhrase.phrase(for: end, now: model.now))
    }
}
