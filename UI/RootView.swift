import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HeaderBar()
                ZStack {
                    if let route = model.path.last {
                        screen(for: route)
                            .id(route)
                            .transition(.move(edge: .trailing))
                    } else {
                        rootScreen.transition(.move(edge: .leading))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
            }
            if let sheet = model.sheet {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture { if !model.sheetBusy { model.sheet = nil } }
                    .transition(.opacity)
                VStack { Spacer(); sheetView(sheet) }
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: model.path)
        .animation(.easeInOut(duration: 0.22), value: model.sheet)
        .frame(width: Theme.windowWidth)
        .frame(minHeight: Theme.windowMinHeight)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .foregroundColor(Theme.text)
        .font(.system(size: 13))
    }

    @ViewBuilder private var rootScreen: some View {
        if model.isBlockRunning { BlockingView() } else { ReadyView() }
    }

    @ViewBuilder private func screen(for route: Route) -> some View {
        switch route {
        case .restrictions: RestrictionsView()
        case .overrides: OverridesView()
        case .settings: SettingsView()
        case .emergencyUnlock: EmergencyUnlockView()
        }
    }

    @ViewBuilder private func sheetView(_ sheet: SheetKind) -> some View {
        switch sheet {
        case .overrideConfirm: OverrideConfirmSheet()
        case .extend(let preset): ExtendSheet(initialMinutes: preset)
        }
    }
}

/// 52pt header aligned with the traffic lights: Back + title on pushed cards,
/// centered status + settings on the root card.
struct HeaderBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if let route = model.path.last {
                Button { model.pop() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(model.sheet == nil ? .cancelAction : nil)
                .accessibilityLabel(Text("Back"))
                Text(title(for: route)).font(.system(size: 14, weight: .semibold))
                Spacer()
            } else {
                Spacer()
                HStack(spacing: 7) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                Spacer()
                Button { model.push(.settings) } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 14)).foregroundColor(Theme.sub)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(model.isAddingBlock)
                .accessibilityLabel(Text("Settings"))
            }
        }
        .padding(.leading, Theme.trafficLightInset)
        .padding(.trailing, Theme.inset)
        .frame(height: Theme.headerHeight)
    }

    private func title(for route: Route) -> String {
        switch route {
        case .restrictions: return NSLocalizedString("Restrictions", comment: "card title")
        case .overrides: return NSLocalizedString("Overrides", comment: "card title")
        case .settings: return NSLocalizedString("Settings", comment: "card title")
        case .emergencyUnlock: return NSLocalizedString("Emergency Unlock", comment: "card title")
        }
    }

    private var statusColor: Color {
        if !model.isBlockRunning { return Theme.idleDot }
        return model.overrideRunning ? Theme.green : Theme.accent
    }

    private var statusText: String {
        if model.isAddingBlock { return NSLocalizedString("Starting block…", comment: "header while starting") }
        if !model.isBlockRunning { return NSLocalizedString("Not blocking", comment: "header idle") }
        if model.overrideRunning { return NSLocalizedString("Override running", comment: "header during override") }
        return RestrictionsSummary.headline(count: model.shownEntries.count, isAllowlist: model.shownAllowlist)
    }
}

#if DEBUG
extension AppModel {
    /// Stub model for previews/snapshots. Never touches SCSettings/XPC.
    static func preview(_ configure: (AppModel) -> Void = { _ in }) -> AppModel {
        let m = AppModel(live: false)
        m.nowOverride = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 14, minute: 48))
        m.editableEntries = ["nytimes.com", "avclub.com", "danieldrezner.substack.com", "talkingpointsmemo.com", "slowboring.com", "natesilver.net", "17.0.0.0/8"]
        m.activeEntries = m.editableEntries
        m.blockDurationMinutes = 480
        m.maxBlockLengthMinutes = 43200
        m.overridePerDayDefault = 3
        m.overrideMinutesDefault = 15
        configure(m)
        return m
    }
}

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView().environmentObject(AppModel.preview()).frame(height: 640)
    }
}
#endif
