import SwiftUI

/// Common bottom-sheet chrome (spec §4): grabber, title, content, 16pt top radius.
struct BottomSheet<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule().fill(Color(hex: 0x55555D)).frame(width: 36, height: 4).frame(maxWidth: .infinity)
            Text(title).font(.system(size: 16, weight: .semibold))
            content
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(UnevenSheetShape())
        .overlay(UnevenSheetShape().stroke(Color(hex: 0x45454C), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 15, y: -8)
    }
}

struct UnevenSheetShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 16
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.maxY))
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addQuadCurve(to: CGPoint(x: r, y: 0), control: .zero)
        p.addLine(to: CGPoint(x: rect.maxX - r, y: 0))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: r), control: CGPoint(x: rect.maxX, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct OverrideConfirmSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var busy = false
    @State private var error: String? = nil

    var body: some View {
        let o = model.override
        let until = model.now.addingTimeInterval(TimeInterval(o.minutes * 60))
        BottomSheet(title: NSLocalizedString("Use an override?", comment: "")) {
            HStack(spacing: 12) {
                PillsView(states: OverridePills.states(perDay: o.perDay, remainingToday: o.remainingToday, activeFraction: nil, pendingSpend: true), width: 34)
                Text(String(format: NSLocalizedString("%ld left after this", comment: ""), max(0, o.remainingToday - 1)))
                    .font(.system(size: 12)).foregroundColor(Theme.sub)
            }
            (Text(NSLocalizedString("All sites open until ", comment: "override confirm, followed by a time"))
             + Text(EndTimePhrase.phrase(for: until, now: model.now)).bold()
             + Text(NSLocalizedString(". Once it starts it can’t be cancelled, and the block resumes on its own.", comment: "")))
                .foregroundColor(Color(hex: 0xD4D4DA)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.system(size: 12)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(NSLocalizedString("Cancel", comment: "")) { model.sheet = nil }
                    .buttonStyle(SecondaryButtonStyle(height: 40, fullWidth: true))
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                Button {
                    busy = true
                    error = nil
                    model.invokeOverride { result in
                        busy = false
                        switch result {
                        case .ok: model.sheet = nil
                        case .cancelled: break
                        case .failed(let message): error = message
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(NSLocalizedString("Use override", comment: ""))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(height: 40)
                .disabled(busy)
            }
        }
        .onChange(of: busy) { model.sheetBusy = $0 }
        .onDisappear { model.sheetBusy = false }
    }
}

struct ExtendSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var minutes: Int
    @State private var busy = false
    @State private var error: String? = nil

    init(initialMinutes: Int) { _minutes = State(initialValue: initialMinutes) }

    private var cap: Int { min(1440, model.maxBlockLengthMinutes) }   // daemon rejects > 24h per call (309)
    private var scale: DurationScale { DurationScale(maxMinutes: cap) }

    var body: some View {
        BottomSheet(title: NSLocalizedString("Extend this block?", comment: "")) {
            VStack(alignment: .leading, spacing: 2) {
                Text("+" + DurationText.short(minutes: minutes))
                    .font(.system(size: 24, weight: .light).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let end = model.blockEndDate {
                    Text(String(format: NSLocalizedString("New end: %@", comment: ""),
                                EndTimePhrase.phrase(for: end.addingTimeInterval(TimeInterval(minutes * 60)), now: model.now)))
                        .font(.system(size: 12)).foregroundColor(Theme.sub)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            DurationSlider(minutes: $minutes, scale: scale)
            HStack(spacing: 2) {
                ForEach([15, 60, 240, 480, 1440].filter { $0 <= cap }, id: \.self) { m in
                    Button("+" + DurationText.short(minutes: m)) { minutes = m }
                        .buttonStyle(ChipButtonStyle(selected: m == minutes))
                }
            }
            .padding(.horizontal, -6)
            Text(NSLocalizedString("Extending can’t be undone.", comment: "")).font(.system(size: 12)).foregroundColor(Theme.sub)
            if let error {
                Text(error).font(.system(size: 12)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(NSLocalizedString("Cancel", comment: "")) { model.sheet = nil }
                    .buttonStyle(SecondaryButtonStyle(height: 40, fullWidth: true))
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                Button {
                    busy = true
                    error = nil
                    model.extendBlock(minutes: minutes) { result in
                        busy = false
                        switch result {
                        case .ok: model.sheet = nil
                        case .cancelled: break
                        case .failed(let message): error = message
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(NSLocalizedString("Extend", comment: ""))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(height: 40)
                .disabled(busy)
            }
        }
        .onChange(of: busy) { model.sheetBusy = $0 }
        .onDisappear { model.sheetBusy = false }
        .onAppear { minutes = scale.snap(minutes) }
    }
}
