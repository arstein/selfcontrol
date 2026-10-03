import AppKit
import Combine

enum Route: Hashable {
    case restrictions, overrides, settings, emergencyUnlock
}

enum SheetKind: Equatable {
    case overrideConfirm
    case extend(presetMinutes: Int)
}

enum TimeState: Equatable {
    case countdown(seconds: Int)
    case verifyingEnd   // modern block at 0: waiting for verified network time
    case finishing      // legacy block at 0: waiting for it to clear
}

struct OverrideStatus: Equatable {
    var perDay = 0
    var minutes = 0
    var remainingToday = 0
    var active = false
    var activeRemainingSecs: Double? = nil
    var checking = false   // no fresh daemon status yet (stale) - show counts, disable Use
}

enum TediumFlash: Equatable { case wrong, tooFast }

struct TediumState: Equatable {
    var started = false
    var digit: Int? = nil
    var progress = 0
    var required = Int(SC_TEDIUM_REQUIRED_ENTRIES)
    var flash: TediumFlash? = nil
    var blockRemoved = false
    var error: String? = nil
}

/// Single source of UI state for the SwiftUI window. Main-actor only.
/// `live == false` (previews/snapshots) never touches SCSettings, XPC, timers or NSApp.
@MainActor
final class AppModel: ObservableObject {
    // Navigation
    @Published var path: [Route] = []
    @Published var sheet: SheetKind? = nil

    // Block state
    @Published var isBlockRunning = false
    @Published var isAddingBlock = false
    @Published var isModernBlock = false
    @Published var isLegacyBlock = false
    @Published var timeState: TimeState = .countdown(seconds: 0)
    @Published var blockDurationSecs: Double? = nil
    @Published var isStuck = false
    @Published var override = OverrideStatus()

    // Lists
    @Published var editableEntries: [String] = []
    @Published var activeEntries: [String] = []
    @Published var isAllowlist = false
    @Published var isActiveAllowlist = false

    // Defaults mirrors
    @Published var blockDurationMinutes = 60
    @Published var maxBlockLengthMinutes = 1440
    @Published var overridePerDayDefault = Int(SC_OVERRIDE_DEFAULT_PER_DAY)
    @Published var overrideMinutesDefault = Int(SC_OVERRIDE_DEFAULT_MINUTES)
    @Published var keepWindowOnTop = false
    @Published var highlightInvalidHosts = true

    @Published var tedium = TediumState()

    /// Fixed "now" for previews/snapshots so end-time text is deterministic.
    var nowOverride: Date? = nil
    var now: Date { nowOverride ?? Date() }

    let live: Bool
    private let defaults: UserDefaults
    private var timer: Timer?
    private var strikes = 0
    private var statusInFlight = false
    private var statusRequestUptime: TimeInterval = 0
    private var lastStatus: (remaining: Double, active: Bool, remainingToday: Int, perDay: Int, uptime: TimeInterval)?
    private var defaultsObserver: NSObjectProtocol?
    private var flashWork: DispatchWorkItem?

    init(live: Bool = true, defaults: UserDefaults = .standard) {
        self.live = live
        self.defaults = defaults
        if live {
            defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reloadDefaults() }
            }
            reload()
        }
    }

    deinit {
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
    }

    private var appController: AppController? { NSApp.delegate as? AppController }

    // MARK: - Derived

    var shownEntries: [String] { (isBlockRunning && isModernBlock) ? activeEntries : editableEntries }
    var shownAllowlist: Bool { (isBlockRunning && isModernBlock) ? isActiveAllowlist : isAllowlist }
    var canStart: Bool { blockDurationMinutes != 0 && (!editableEntries.isEmpty || isAllowlist) && !isAddingBlock }
    var remainingSeconds: Int? { if case .countdown(let s) = timeState, s > 0 { return s } else { return nil } }
    var blockEndDate: Date? { remainingSeconds.map { now.addingTimeInterval(TimeInterval($0)) } }
    var elapsedFraction: Double? {
        guard let total = blockDurationSecs, total > 0, let rem = remainingSeconds else { return nil }
        return min(max(1 - Double(rem) / total, 0), 1)
    }
    var overrideRunning: Bool { override.active && (override.activeRemainingSecs ?? 0) > 0 }
    var canAddDuringBlock: Bool { isModernBlock && !isActiveAllowlist }
    var durationScale: DurationScale { DurationScale(maxMinutes: maxBlockLengthMinutes) }

    // MARK: - Lifecycle

    func startTicking() {
        guard live, timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        // AppController.refreshUserInterface handles block on/off side effects and calls back into reload().
        if let ac = appController { ac.refreshUserInterface() } else { reload() }
    }

    /// Re-read everything. Called by MainWindowController.refresh (from AppController.refreshUserInterface).
    func reload() {
        guard live else { return }
        let wasRunning = isBlockRunning
        let settings = SCSettings.shared()

        isBlockRunning = SCUIUtilities.blockIsRunning()
        isModernBlock = SCBlockUtilities.modernBlockIsRunning()
        isLegacyBlock = !isModernBlock && SCBlockUtilities.legacyBlockIsRunning()
        isAddingBlock = appController?.addingBlock ?? false
        activeEntries = settings.value(forKey: "ActiveBlocklist") as? [String] ?? []
        isActiveAllowlist = settings.bool(forKey: "ActiveBlockAsWhitelist")
        blockDurationSecs = (settings.value(forKey: "BlockDurationSecs") as? NSNumber)?.doubleValue
        reloadDefaults()
        updateTime()
        refreshOverride()

        if wasRunning != isBlockRunning {
            path = []
            sheet = nil
            if !isBlockRunning { tedium = TediumState() }
        }
    }

    func reloadDefaults() {
        guard live else { return }
        editableEntries = defaults.stringArray(forKey: "Blocklist") ?? []
        isAllowlist = defaults.bool(forKey: "BlockAsWhitelist")
        maxBlockLengthMinutes = max(1, defaults.integer(forKey: "MaxBlockLength"))
        blockDurationMinutes = defaults.integer(forKey: "BlockDuration")
        overridePerDayDefault = defaults.integer(forKey: "OverridePerDay")
        overrideMinutesDefault = defaults.integer(forKey: "OverrideMinutes")
        keepWindowOnTop = defaults.bool(forKey: "TimerWindowFloats")
        highlightInvalidHosts = defaults.bool(forKey: "HighlightInvalidHosts")
        // keep the Ready duration inside the (possibly lowered) max, as the old KVO did
        if !isBlockRunning && blockDurationMinutes > maxBlockLengthMinutes {
            setBlockDuration(maxBlockLengthMinutes)
        }
    }

    // MARK: - Time (port of TimerWindowController -updateTimerDisplay:)

    private func updateTime() {
        guard isBlockRunning else {
            timeState = .countdown(seconds: 0)
            strikes = 0
            isStuck = false
            return
        }
        let remaining: Double
        if let trusted = SCBlockUtilities.trustedRemainingBlockDurationSecs() {
            remaining = trusted.doubleValue
        } else if isModernBlock {
            // Obj-C: blockEndingDate_ = settings BlockEndDate (nil -> 0) for modern blocks.
            // Only reached for upstream-created blocks with no trusted-clock state.
            remaining = (SCSettings.shared().value(forKey: "BlockEndDate") as? Date)?.timeIntervalSinceNow ?? 0
        } else {
            // legacyBlockEndDate never returns nil (distantPast when unknown)
            remaining = SCMigrationUtilities.legacyBlockEndDate().timeIntervalSinceNow
        }
        let secs = Int(ceil(remaining))
        // Strikes only count when we're past zero AND already showing the finishing
        // state (Obj-C: numSeconds < 0 && label == finishingString); the first tick
        // at/below zero just switches to finishing and resets strikes.
        let alreadyFinishing = timeState == .verifyingEnd || timeState == .finishing
        if secs > 0 {
            timeState = .countdown(seconds: secs)
            strikes = 0
            isStuck = false
        } else if secs == 0 || !alreadyFinishing {
            timeState = isModernBlock ? .verifyingEnd : .finishing
            strikes = 0
            isStuck = false
        } else {
            timeState = isModernBlock ? .verifyingEnd : .finishing
            strikes += 1
            if strikes == 300 {
                NSLog("WARNING: Block should have ended! Probable failure to remove.")
                SCSentry.captureError(SCErr.error(withCode: 105))
            }
            isStuck = strikes >= 300
        }
        updateDockBadge(seconds: secs)
    }

    private func updateDockBadge(seconds: Int) {
        guard defaults.bool(forKey: "BadgeApplicationIcon"), seconds > 0 else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        let hours = seconds / 3600
        var minutes = (seconds % 3600) / 60
        // round minutes up, standard when we aren't displaying seconds
        if seconds % 60 > 0 && minutes != 59 { minutes += 1 }
        NSApp.dockTile.badgeLabel = String(format: "%02d:%02d", hours, minutes)
    }

    // MARK: - Overrides (port of -refreshOverrideUI / -renderOverrideStatus)

    private func refreshOverride() {
        let settings = SCSettings.shared()
        let policy = settings.value(forKey: "OverridePolicy") as? [String: Any]
        let perDay = (policy?["perDay"] as? NSNumber)?.intValue ?? 0
        let minutes = (policy?["minutes"] as? NSNumber)?.intValue ?? 0
        guard isModernBlock, perDay > 0 else {
            override = OverrideStatus(perDay: perDay, minutes: minutes)
            lastStatus = nil
            return
        }
        let nowUptime = SCTrustedClock.continuousUptimeSecs()
        if let xpc = appController?.xpc, !statusInFlight || (nowUptime - statusRequestUptime) > 3.0 {
            statusInFlight = true
            statusRequestUptime = nowUptime
            xpc.getOverrideStatus { [weak self] _, active, remainingSecs, remainingToday, polledPerDay, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.statusInFlight = false
                    if error == nil {
                        self.lastStatus = (remainingSecs, active, remainingToday, polledPerDay, SCTrustedClock.continuousUptimeSecs())
                    }
                    self.renderOverride()
                }
            }
        }
        renderOverride()
    }

    /// Interpolates ONLY with monotonic uptime since the last poll; stale (>5s) falls back to settings.
    private func renderOverride() {
        let settings = SCSettings.shared()
        let policy = settings.value(forKey: "OverridePolicy") as? [String: Any]
        let state = settings.value(forKey: "OverrideState") as? [String: Any]
        let perDay = (policy?["perDay"] as? NSNumber)?.intValue ?? 0
        let minutes = (policy?["minutes"] as? NSNumber)?.intValue ?? 0
        let nowUptime = SCTrustedClock.continuousUptimeSecs()

        if let s = lastStatus, nowUptime - s.uptime <= 5.0 {
            let shown = max(0, s.remaining - (nowUptime - s.uptime))
            // `active` mirrors the daemon's flag (Obj-C keeps Use disabled while lastActive_,
            // even if interpolation already reached 0); the countdown only shows while shown > 0.
            override = OverrideStatus(perDay: s.perDay, minutes: minutes, remainingToday: s.remainingToday,
                                      active: s.active, activeRemainingSecs: (s.active && shown > 0) ? shown : nil,
                                      checking: false)
            return
        }
        let remaining = (state?["remainingToday"] as? NSNumber)?.intValue ?? 0
        override = OverrideStatus(perDay: perDay, minutes: minutes, remainingToday: remaining,
                                  active: false, activeRemainingSecs: nil, checking: true)
    }

    // MARK: - Navigation

    func push(_ route: Route) {
        if path.last != route { path.append(route) }
    }

    func pop() {
        if !path.isEmpty { path.removeLast() }
    }

    // MARK: - Ready-screen actions

    func setBlockDuration(_ minutes: Int) {
        let clamped = min(max(minutes, 1), maxBlockLengthMinutes)
        blockDurationMinutes = clamped
        if live { defaults.set(clamped, forKey: "BlockDuration") }
    }

    func startBlock() {
        guard live, let ac = appController else { return }
        ac.addBlock(nil)   // all guards, alerts, auth + SMAppService flow live there
        reload()
    }

    func setOverridePerDay(_ n: Int) {
        let v = OverridePolicyLimits.clampPerDay(n)
        overridePerDayDefault = v
        if live { defaults.set(v, forKey: "OverridePerDay") }
    }

    func setOverrideMinutes(_ m: Int) {
        let v = min(max(m, OverridePolicyLimits.minutesRange.lowerBound), OverridePolicyLimits.minutesRange.upperBound)
        overrideMinutesDefault = v
        if live { defaults.set(v, forKey: "OverrideMinutes") }
    }

    func setMaxBlockLength(_ m: Int) {
        let v = min(max(m, 1), 43200)
        maxBlockLengthMinutes = v
        if live { defaults.set(v, forKey: "MaxBlockLength") }
        if !isBlockRunning && blockDurationMinutes > v { setBlockDuration(v) }
    }

    // MARK: - Restrictions (not blocking)

    /// Returns false if nothing usable was entered.
    @discardableResult
    func addEditableEntries(_ raw: String) -> Bool {
        let cleaned = live ? (SCMiscUtilities.cleanBlocklistEntry(raw) ?? []) : [raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()].filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return false }
        var list = editableEntries
        for e in cleaned where !list.contains(e) { list.append(e) }
        saveEditable(list)
        return true
    }

    func removeEditableEntry(_ entry: String) {
        saveEditable(editableEntries.filter { $0 != entry })
    }

    func importHosts(_ hosts: [String]) {
        var list = editableEntries
        for h in hosts where !list.contains(h) { list.append(h) }
        saveEditable(list)
    }

    private func saveEditable(_ list: [String]) {
        editableEntries = list
        guard live else { return }
        defaults.set(list, forKey: "Blocklist")
        NotificationCenter.default.post(name: NSNotification.Name("SCConfigurationChangedNotification"), object: self)
    }

    /// Port of DomainListWindowController -allowlistOptionChanged: (+ its warning).
    func setAllowlist(_ on: Bool) {
        guard on != isAllowlist else { return }
        if on && live { showAllowlistWarningIfNeeded() }
        isAllowlist = on
        guard live else { return }
        defaults.set(on, forKey: "BlockAsWhitelist")
        NotificationCenter.default.post(name: NSNotification.Name("SCConfigurationChangedNotification"), object: self)
    }

    private func showAllowlistWarningIfNeeded() {
        // Verbatim port of DomainListWindowController.m -showAllowlistWarning.
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: "WhitelistAlertSuppress") else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Are you sure you want an allowlist block?", comment: "Allowlist block confirmation prompt")
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button"))
        alert.informativeText = NSLocalizedString("An allowlist block means that everything on the internet BESIDES your specified list will be blocked.  This includes the web, email, SSH, and anything else your computer accesses via the internet.  This can cause unexpected behavior. If a web site requires resources such as images or scripts from a site that is not on your allowlist, the site may not work properly.", comment: "allowlist block explanation")
        alert.showsSuppressionButton = true

        alert.runModal()

        if alert.suppressionButton?.state == .on {
            ud.set(true, forKey: "WhitelistAlertSuppress")
        }
    }

    // MARK: - Running-block actions (results come back as display strings; nil = success)

    static func message(for error: Error?) -> String? {
        guard let ns = error as NSError? else { return nil }
        return SCUIUtilities.displayableError(ns)?.localizedDescription
    }

    func addToRunningBlock(_ raw: String, completion: @escaping (String?) -> Void) {
        guard live, let ac = appController else { completion(nil); return }
        // AppController guarantees completion on the main queue.
        ac.addEntries(toRunningBlock: raw) { [weak self] error in
            MainActor.assumeIsolated {
                self?.reload()
                completion(AppModel.message(for: error))
            }
        }
    }

    func extendBlock(minutes: Int, completion: @escaping (String?) -> Void) {
        guard live, let ac = appController else { completion(nil); return }
        // AppController guarantees completion on the main queue.
        ac.extendRunningBlock(byMinutes: minutes) { [weak self] error in
            MainActor.assumeIsolated {
                self?.reload()
                completion(AppModel.message(for: error))
            }
        }
    }

    func invokeOverride(completion: @escaping (String?) -> Void) {
        guard live, let xpc = appController?.xpc else { completion(nil); return }
        xpc.invokeOverride { [weak self] _, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                // never trust pre-invoke cached status; force a fresh daemon poll
                self.lastStatus = nil
                self.statusInFlight = false
                self.refreshOverride()
                completion(AppModel.message(for: error))
            }
        }
    }

    func stopBlockManually() {
        appController?.stopBlockManually()
    }

    // MARK: - Emergency unlock (port of SCTediumWindowController)

    func beginTedium() {
        guard live, let xpc = appController?.xpc else { return }
        tedium.error = nil
        xpc.startTediumChallenge { [weak self] digit, progress, required, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = error as NSError? {
                    if SCMiscUtilities.errorIsAuthCanceled(error) { self.pop(); return }
                    self.tedium.error = error.code == 321
                        ? NSLocalizedString("No block is running.", comment: "tedium override: no block running error")
                        : (AppModel.message(for: error) ?? error.localizedDescription)
                    return
                }
                self.tedium = TediumState(started: true, digit: digit, progress: progress, required: required)
            }
        }
    }

    /// Returns false (caller beeps) if `text` isn't exactly one digit; nothing is sent then.
    @discardableResult
    func submitTedium(_ text: String) -> Bool {
        guard text.count == 1, let ch = text.first, ch.isASCII, let digit = Int(String(ch)) else { return false }
        guard live, let xpc = appController?.xpc else { return true }
        xpc.submitTediumEntry(digit) { [weak self] outcome, progress, nextDigit, blockRemoved, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = error as NSError? {
                    switch error.code {
                    case 322:
                        self.tedium.blockRemoved = true
                    case 323:
                        self.tedium.started = false
                        self.tedium.error = NSLocalizedString("The challenge was lost (SelfControl restarted). Open Emergency Unlock again to start over.", comment: "tedium override: challenge lost message")
                    default:
                        self.tedium.error = AppModel.message(for: error)
                    }
                    return
                }
                self.tedium.digit = nextDigit
                self.tedium.progress = progress
                switch SCTediumSubmitOutcome(rawValue: outcome) {
                case .wrongDigit?: self.flash(.wrong)
                case .ignoredTooFast?: self.flash(.tooFast)
                default: self.flash(nil)
                }
                if blockRemoved { self.tedium.blockRemoved = true }
            }
        }
        return true
    }

    private func flash(_ f: TediumFlash?) {
        flashWork?.cancel()
        tedium.flash = f
        guard f != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.tedium.flash = nil }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
