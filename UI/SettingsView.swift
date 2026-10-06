import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("EvaluateCommonSubdomains") private var commonSubdomains = true
    @AppStorage("ClearCaches") private var clearCaches = true
    @AppStorage("IncludeLinkedDomains") private var linkedDomains = true
    @AppStorage("VerifyInternetConnection") private var verifyInternet = true
    @AppStorage("HighlightInvalidHosts") private var highlightInvalid = true
    @AppStorage("BadgeApplicationIcon") private var dockBadge = true
    @AppStorage("TimerWindowFloats") private var keepOnTop = false
    @AppStorage("BlockSoundShouldPlay") private var soundOn = false
    @AppStorage("BlockSound") private var soundIndex = 5
    @AppStorage("EmergencyUnlockEnabled") private var emergencyUnlock = true
    @State private var showCustomMax = false
    @State private var customMaxText = ""

    private let maxPresets: [Int] = [1440, 2880, 10080, 43200]   // spec §6.4: 1 day, 2 days, 1 week, 30 days

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                groupLabel(NSLocalizedString("Blocking", comment: "settings group"))
                Card {
                    HStack {
                        Text(NSLocalizedString("Longest block allowed", comment: ""))
                        Spacer()
                        maxBlockMenu
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    RowDivider()
                    toggle(NSLocalizedString("Block common subdomains", comment: ""), $commonSubdomains)
                    RowDivider()
                    toggle(NSLocalizedString("Clear browser cache on start", comment: ""), $clearCaches)
                    RowDivider()
                    toggle(NSLocalizedString("Include linked sites in allowlists", comment: ""), $linkedDomains,
                           subtitle: NSLocalizedString("Slower to start", comment: ""))
                    RowDivider()
                    toggle(NSLocalizedString("Check internet before starting", comment: ""), $verifyInternet)
                    RowDivider()
                    toggle(NSLocalizedString("Highlight invalid entries", comment: ""), $highlightInvalid)
                    RowDivider()
                    toggle(NSLocalizedString("Emergency unlock", comment: ""), $emergencyUnlock, subtitle: emergencyUnlockSubtitle)
                }
                groupLabel(NSLocalizedString("Window & sound", comment: "settings group"))
                Card {
                    HStack {
                        Text(NSLocalizedString("Sound when a block ends", comment: ""))
                        Spacer()
                        soundMenu
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    RowDivider()
                    toggle(NSLocalizedString("Show countdown in Dock", comment: ""), $dockBadge)
                    RowDivider()
                    toggle(NSLocalizedString("Keep window on top while blocking", comment: ""), $keepOnTop)
                }
            }
            .padding(.horizontal, Theme.inset)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
    }

    private var emergencyUnlockSubtitle: String {
        // the toggle only affects the next block; the running one keeps what it started with
        if model.isBlockRunning { return NSLocalizedString("Changes apply to your next block", comment: "") }
        return String(format: NSLocalizedString("End a block early by typing %ld random digits", comment: ""), Int(SC_TEDIUM_REQUIRED_ENTRIES))
    }

    private func groupLabel(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.4)
            .foregroundColor(Theme.sub).padding(.horizontal, 4).padding(.top, 4)
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>, subtitle: String? = nil) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundColor(Theme.sub) }
            }
        }
        .toggleStyle(SCSwitchStyle())
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var maxBlockMenu: some View {
        Menu {
            ForEach(maxPresets, id: \.self) { m in
                Button(DurationText.short(minutes: m)) { model.setMaxBlockLength(m) }
            }
            Divider()
            Button(NSLocalizedString("Custom…", comment: "")) {
                customMaxText = "\(MaxLengthDays.days(fromMinutes: model.maxBlockLengthMinutes))"
                showCustomMax = true
            }
        } label: {
            Text(DurationText.short(minutes: model.maxBlockLengthMinutes))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .valuePill()
        .popover(isPresented: $showCustomMax, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("Longest block, in days (1–30)", comment: "")).font(.system(size: 12))
                HStack {
                    TextField("7", text: $customMaxText).frame(width: 90)
                        .onSubmit(applyCustomMax)
                    Button(NSLocalizedString("Set", comment: ""), action: applyCustomMax).keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
    }

    private func applyCustomMax() {
        // Whole days 1–30, stored in minutes; invalid input leaves the popover open.
        guard let m = MaxLengthDays.minutes(fromInput: customMaxText) else { NSSound.beep(); return }
        model.setMaxBlockLength(m)
        showCustomMax = false
    }

    private var soundMenu: some View {
        let names = SCConstants.systemSoundNames
        return Menu {
            Button(NSLocalizedString("Off", comment: "no sound")) { soundOn = false }
            Divider()
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                Button(name) { selectSound(index: index, names: names) }
            }
        } label: {
            Text(soundOn && soundIndex < names.count ? names[soundIndex] : NSLocalizedString("Off", comment: "no sound"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .valuePill()
    }

    /// Port of PreferencesGeneralViewController -soundSelectionChanged: (preview + errors 310/311).
    private func selectSound(index: Int, names: [String]) {
        guard index >= 0 && index < names.count else {
            NSLog("WARNING: User selected unknown alert sound index %ld.", index)
            let err = SCErr.error(withCode: 310)
            SCSentry.captureError(err)
            Dialog.afterCurrentAction { SCUIUtilities.presentError(err) }
            return
        }
        soundIndex = index
        soundOn = true
        if let sound = NSSound(named: NSSound.Name(names[index])) {
            sound.play()
        } else {
            NSLog("WARNING: Alert sound not found.")
            let err = SCErr.error(withCode: 311)
            SCSentry.captureError(err)
            Dialog.afterCurrentAction { SCUIUtilities.presentError(err) }
        }
    }
}

private extension View {
    /// Mock E-Settings value button: 24pt pill, #3a3a41, radius 6.
    func valuePill() -> some View {
        self.padding(.horizontal, 8)
            .frame(height: 24)
            .background(Theme.valuePill)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
