import SwiftUI
import AppKit

struct ReadyView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: Theme.gap) {
            if model.deepRunning { DeepBlockBanner() }
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
                RowDivider()
                NavRow(title: NSLocalizedString("Deep Block", comment: "row"),
                       subtitle: model.deepRowSubtitle,
                       action: { model.push(.deepBlock) }) {
                    Text("\(model.entries(.deep).count)").foregroundColor(Theme.sub)
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
                DurationTicks(maxMinutes: model.maxBlockLengthMinutes, scale: model.durationScale,
                              selectedMinutes: model.blockDurationMinutes) { model.setBlockDuration($0) }
                    .disabled(model.isAddingBlock)
                    .padding(.top, -4)
            }
        }
    }
}

/// Tick marks + tappable labels at their true slider positions (1h, 8h, 1 day, 1 week, max).
struct DurationTicks: View {
    let maxMinutes: Int
    let scale: DurationScale
    let selectedMinutes: Int
    let select: (Int) -> Void

    private static let labelPadding: CGFloat = 3
    private static let font = NSFont.systemFont(ofSize: 12)

    var body: some View {
        GeometryReader { geo in
            let w = Double(geo.size.width)
            let anchors = TickLayout.anchors(maxMinutes: maxMinutes)
            // Tick x matches the knob centre at that duration, as a fraction of the row width.
            let positions = anchors.map { w > 0 ? Double(DurationSlider.knobCenterX(position: scale.position(for: $0.minutes), width: geo.size.width)) / w : 0 }
            let widths = anchors.map { Double(Self.labelWidth($0.label)) }
            let placed = TickLayout.visibleTicks(anchors: anchors, positions: positions, labelWidths: widths, trackWidth: w, minGap: 6)
            ZStack(alignment: .topLeading) {
                ForEach(Array(anchors.enumerated()), id: \.offset) { i, _ in
                    Rectangle().fill(Theme.faint)
                        .frame(width: 1, height: 4)
                        .position(x: CGFloat(positions[i] * w), y: 2)
                }
                ForEach(placed, id: \.index) { p in
                    let tick = anchors[p.index]
                    Button(tick.label) { select(tick.minutes) }
                        .buttonStyle(TickLabelStyle(selected: tick.minutes == selectedMinutes))
                        .frame(width: CGFloat(widths[p.index]))
                        .position(x: CGFloat(p.labelCenter), y: 15)
                }
            }
        }
        .frame(height: 24)
    }

    private static func labelWidth(_ label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: font]).width) + labelPadding * 2
    }
}

struct TickLabelStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: selected ? .medium : .regular))
            .lineLimit(1)
            .fixedSize()
            .foregroundColor(selected ? Theme.chipSelectedText : Theme.sub)
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
