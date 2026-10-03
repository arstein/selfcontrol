import SwiftUI

struct BlockingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: Theme.gap) {
            if model.overrideRunning { overrideTimeCard } else { timeCard }
            if model.override.perDay > 0 && model.isModernBlock { overridesCard }
            if model.overrideRunning { underlyingBlockRow }
            Card {
                NavRow(title: NSLocalizedString("Restrictions", comment: "row"),
                       subtitle: restrictionsSubtitle,
                       action: { model.push(.restrictions) }) {
                    Text("\(model.shownEntries.count)").foregroundColor(Theme.sub)
                }
            }
            if model.isStuck {
                Button(NSLocalizedString("Stuck? Stop block manually", comment: "manual kill button")) { model.stopBlockManually() }
                    .buttonStyle(SecondaryButtonStyle(height: 36, fullWidth: true))
                    .foregroundColor(Theme.danger)
            }
            Spacer(minLength: 0)
            if model.isModernBlock {
                Button(NSLocalizedString("Emergency unlock…", comment: "")) { model.push(.emergencyUnlock) }
                    .buttonStyle(LinkButtonStyle())
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, Theme.inset)
        .padding(.top, 4)
    }

    private var restrictionsSubtitle: String {
        if model.isLegacyBlock { return RestrictionsSummary.subtitle(entries: model.shownEntries, isAllowlist: model.shownAllowlist) }
        if model.isActiveAllowlist { return RestrictionsSummary.subtitle(entries: model.shownEntries, isAllowlist: true) }
        return String(format: NSLocalizedString("%@ · add more any time", comment: "e.g. 'Blocking 7 sites · add more any time'"),
                      RestrictionsSummary.headline(count: model.shownEntries.count, isAllowlist: false))
    }

    // MARK: time card (blocking)

    private var timeCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Eyebrow(text: NSLocalizedString("Time left", comment: "eyebrow"))
                    Spacer()
                    if let end = model.blockEndDate {
                        Text(String(format: NSLocalizedString("ends %@", comment: "ends <end time>"), EndTimePhrase.phrase(for: end, now: model.now)))
                            .font(.system(size: 12)).foregroundColor(Theme.sub)
                    }
                }
                switch model.timeState {
                case .countdown(let secs):
                    let parts = CountdownText.parts(seconds: secs)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let d = parts.days { Text(d).foregroundColor(Theme.sub) }
                        Text(parts.clock)
                    }
                    .font(.system(size: 46, weight: .light).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.6)
                case .verifyingEnd:
                    Text(NSLocalizedString("Verifying end time…", comment: "Waiting for network time before ending a block"))
                        .font(.system(size: 26, weight: .light))
                    Text(NSLocalizedString("The block ends once SelfControl confirms the time over the internet.", comment: ""))
                        .font(.system(size: 12)).foregroundColor(Theme.sub).fixedSize(horizontal: false, vertical: true)
                case .finishing:
                    Text(NSLocalizedString("Finishing", comment: "String shown when waiting for finished block to clear"))
                        .font(.system(size: 26, weight: .light))
                }
                if let f = model.elapsedFraction { ProgressBar(fraction: f) }
                if model.isLegacyBlock {
                    Text(NSLocalizedString("This block was started by an older version of SelfControl, so it can’t be extended or added to.", comment: ""))
                        .font(.system(size: 12)).foregroundColor(Theme.sub).fixedSize(horizontal: false, vertical: true)
                } else if model.isModernBlock, model.remainingSeconds != nil {
                    HStack(spacing: 4) {
                        Text(NSLocalizedString("Extend", comment: "")).font(.system(size: 12)).foregroundColor(Theme.sub)
                        Spacer()
                        Button("+15m") { model.sheet = .extend(presetMinutes: 15) }.buttonStyle(ChipButtonStyle())
                        Button("+1h") { model.sheet = .extend(presetMinutes: 60) }.buttonStyle(ChipButtonStyle())
                        Button(NSLocalizedString("More…", comment: "")) { model.sheet = .extend(presetMinutes: 240) }.buttonStyle(ChipButtonStyle())
                    }
                    .padding(.trailing, -6)
                }
            }
        }
    }

    // MARK: time card (override running)

    private var overrideTimeCard: some View {
        let secs = Int(ceil(model.override.activeRemainingSecs ?? 0))
        let total = Double(max(1, model.override.minutes * 60))
        let resumes = model.now.addingTimeInterval(TimeInterval(secs))
        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Eyebrow(text: NSLocalizedString("Sites open", comment: "eyebrow during override"), color: Theme.green)
                    Spacer()
                    Text(String(format: NSLocalizedString("blocking resumes %@", comment: ""), EndTimePhrase.phrase(for: resumes, now: model.now)))
                        .font(.system(size: 12)).foregroundColor(Theme.sub)
                }
                Text(CountdownText.minutesSeconds(secs)).font(.system(size: 46, weight: .light).monospacedDigit())
                ProgressBar(fraction: Double(secs) / total, tint: Theme.green, track: Theme.greenTrack)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Color(hex: 0x2F5A44), lineWidth: 1))
    }

    private var underlyingBlockRow: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("Block", comment: "")).fontWeight(.medium)
                    Text(NSLocalizedString("Still running underneath", comment: "")).font(.system(size: 12)).foregroundColor(Theme.sub)
                }
                Spacer()
                if let secs = model.remainingSeconds {
                    let p = CountdownText.parts(seconds: secs)
                    Text(String(format: NSLocalizedString("%@ left", comment: ""), [p.days, p.clock].compactMap { $0 }.joined(separator: " ")))
                        .foregroundColor(Theme.sub).monospacedDigit()
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    // MARK: overrides card

    private var overridesCard: some View {
        let o = model.override
        let fraction: Double? = model.overrideRunning ? (o.activeRemainingSecs ?? 0) / Double(max(1, o.minutes * 60)) : nil
        return Card(padding: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    PillsView(states: OverridePills.states(perDay: o.perDay, remainingToday: o.remainingToday, activeFraction: fraction, pendingSpend: false))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.remainingToday == 1 ? NSLocalizedString("1 override left today", comment: "")
                             : String(format: NSLocalizedString("%ld overrides left today", comment: ""), o.remainingToday))
                            .fontWeight(.medium)
                        Text(overridesSubtitle).font(.system(size: 12)).foregroundColor(Theme.sub)
                    }
                }
                Spacer()
                Button(NSLocalizedString("Use", comment: "use override")) { model.sheet = .overrideConfirm }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!canUseOverride)
            }
        }
    }

    private var canUseOverride: Bool {
        let o = model.override
        return !o.checking && !o.active && !model.overrideRunning && o.remainingToday > 0 && o.perDay > 0
    }

    private var overridesSubtitle: String {
        let o = model.override
        if model.overrideRunning { return NSLocalizedString("Available after this one ends", comment: "") }
        if o.checking { return NSLocalizedString("Checking status…", comment: "") }
        if o.remainingToday == 0 { return NSLocalizedString("None left today · resets at midnight", comment: "") }
        return String(format: NSLocalizedString("%ld minutes each", comment: ""), o.minutes)
    }
}
