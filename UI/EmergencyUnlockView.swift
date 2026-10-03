import SwiftUI
import AppKit

struct EmergencyUnlockView: View {
    @EnvironmentObject var model: AppModel
    @State private var entry = ""
    @FocusState private var focused: Bool

    private var minutesEstimate: Int {
        Int(ceil(Double(SC_TEDIUM_REQUIRED_ENTRIES) * Double(SC_TEDIUM_MIN_ENTRY_INTERVAL_SECS) / 60.0))
    }

    var body: some View {
        let t = model.tedium
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text(minutesEstimate <= 1
                 ? NSLocalizedString("Ends the whole block, even offline. Type each digit as it appears. It takes about a minute on purpose.", comment: "")
                 : String(format: NSLocalizedString("Ends the whole block, even offline. Type each digit as it appears. It takes about %ld minutes on purpose.", comment: ""), minutesEstimate))
                .foregroundColor(Theme.sub).lineSpacing(3).padding(.horizontal, 2)
                .fixedSize(horizontal: false, vertical: true)

            if t.blockRemoved {
                Card(padding: 16) {
                    Text(NSLocalizedString("Block removed.", comment: "tedium override: block removed message"))
                        .font(.system(size: 15, weight: .medium))
                }
            } else if let error = t.error {
                Card(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error).fixedSize(horizontal: false, vertical: true)
                        Button(NSLocalizedString("Try again", comment: "")) { model.beginTedium() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            } else {
                VStack(spacing: 14) {
                    Text(t.digit.map(String.init) ?? "–")
                        .font(.system(size: 84, weight: .light).monospacedDigit())
                        .frame(width: 120, height: 140)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel(Text(String(format: NSLocalizedString("Digit %@", comment: ""), t.digit.map(String.init) ?? "")))
                    TextField(NSLocalizedString("Type it, then Return", comment: ""), text: $entry)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 14))
                        .frame(width: 200, height: 38)
                        .background(Theme.field)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent, lineWidth: 2))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .focused($focused)
                        .onSubmit(submit)
                        .disabled(!t.started)
                    Group {
                        switch t.flash {
                        case .wrong?:
                            Text(String(format: NSLocalizedString("Wrong — −%d", comment: "tedium override: wrong digit penalty message"), Int(SC_TEDIUM_WRONG_ENTRY_PENALTY)))
                                .foregroundColor(Theme.danger)
                        case .tooFast?:
                            Text(NSLocalizedString("(too fast — ignored)", comment: "tedium override: entry ignored for arriving too fast"))
                                .foregroundColor(Theme.sub)
                        case nil:
                            Text(" ")
                        }
                    }
                    .font(.system(size: 12))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(NSLocalizedString("Progress", comment: "")).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(String(format: NSLocalizedString("%ld / %ld", comment: "tedium override progress label, e.g. 17 / 300"), t.progress, t.required))
                                .font(.system(size: 12).monospacedDigit()).foregroundColor(Theme.sub)
                        }
                        ProgressBar(fraction: t.required > 0 ? Double(t.progress) / Double(t.required) : 0, height: 6)
                        Text(String(format: NSLocalizedString("A wrong digit takes away %d. You can leave this screen; progress is kept for 10 minutes.", comment: ""), Int(SC_TEDIUM_WRONG_ENTRY_PENALTY)))
                            .font(.system(size: 11)).foregroundColor(Theme.sub).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.inset)
        .padding(.top, 4)
        .onAppear {
            if !model.tedium.started { model.beginTedium() }
            focused = true
        }
    }

    private func submit() {
        let text = entry
        entry = ""
        if !model.submitTedium(text) { NSSound.beep() }
        focused = true
    }
}
