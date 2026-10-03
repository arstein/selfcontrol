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

/// Outcome of a running-block action. `.cancelled` = nothing to report (auth cancel, not live).
enum ActionResult: Equatable {
    case ok
    case cancelled
    case failed(String)
}

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
    /// Set by a sheet while its daemon call is in flight; the sheet can't be dismissed then.
    @Published var sheetBusy = false

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
    // nonisolated(unsafe) only so deinit can invalidate it; otherwise touched on main only.
    nonisolated(unsafe) private var timer: Timer?
    private var finishingSinceUptime: TimeInterval?
    private var stuckReported = false
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
        timer?.invalidate()
    }

    /// nil when !live: previews/tests run inside the app process and must never reach it.
    private var appController: AppController? { live ? NSApp.delegate as? AppController : nil }

    /// Assigns only on change, so per-second reloads don't spam objectWillChange.
    private func assign<T: Equatable>(_ kp: ReferenceWritableKeyPath<AppModel, T>, _ v: T) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

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

    func stopTicking() {
        timer?.invalidate()
        timer = nil
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

        assign(\.isBlockRunning, SCUIUtilities.blockIsRunning())
        let modern = SCBlockUtilities.modernBlockIsRunning()
        assign(\.isModernBlock, modern)
        assign(\.isLegacyBlock, !modern && SCBlockUtilities.legacyBlockIsRunning())
        assign(\.isAddingBlock, appController?.addingBlock ?? false)
        assign(\.activeEntries, settings.value(forKey: "ActiveBlocklist") as? [String] ?? [])
        assign(\.isActiveAllowlist, settings.bool(forKey: "ActiveBlockAsWhitelist"))
        assign(\.blockDurationSecs, (settings.value(forKey: "BlockDurationSecs") as? NSNumber)?.doubleValue)
        reloadDefaults()
        updateTime()
        refreshOverride()

        if wasRunning != isBlockRunning {
            if !isBlockRunning && tedium.blockRemoved {
                // let the "Block removed." state show briefly before resetting
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, !self.isBlockRunning else { return }
                    self.resetNavigation()
                }
            } else {
                resetNavigation()
            }
        }
    }

    private func resetNavigation() {
        assign(\.path, [])
        assign(\.sheet, nil)
        if !isBlockRunning { assign(\.tedium, TediumState()) }
    }

    func reloadDefaults() {
        guard live else { return }
        assign(\.editableEntries, defaults.stringArray(forKey: "Blocklist") ?? [])
        assign(\.isAllowlist, defaults.bool(forKey: "BlockAsWhitelist"))
        assign(\.maxBlockLengthMinutes, max(1, defaults.integer(forKey: "MaxBlockLength")))
        assign(\.blockDurationMinutes, defaults.integer(forKey: "BlockDuration"))
        assign(\.overridePerDayDefault, defaults.integer(forKey: "OverridePerDay"))
        assign(\.overrideMinutesDefault, defaults.integer(forKey: "OverrideMinutes"))
        assign(\.keepWindowOnTop, defaults.bool(forKey: "TimerWindowFloats"))
        assign(\.highlightInvalidHosts, defaults.bool(forKey: "HighlightInvalidHosts"))
        // keep the Ready duration inside the (possibly lowered) max, as the old KVO did
        if !isBlockRunning && blockDurationMinutes > maxBlockLengthMinutes {
            setBlockDuration(maxBlockLengthMinutes)
        }
    }

    // MARK: - Time (port of TimerWindowController -updateTimerDisplay:)

    private func updateTime() {
        guard isBlockRunning else {
            assign(\.timeState, .countdown(seconds: 0))
            finishingSinceUptime = nil
            stuckReported = false
            assign(\.isStuck, false)
            if live && NSApp.dockTile.badgeLabel != nil { NSApp.dockTile.badgeLabel = nil }
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
        // Non-finite remaining fails closed into the finishing/verifying state (never Int(ceil(nan/inf))).
        // Finite values are clamped so the Int conversion can't trap.
        let secs = remaining.isFinite ? Int(ceil(min(max(remaining, -1e9), 1e9))) : -1
        let finishingState: TimeState = isModernBlock ? .verifyingEnd : .finishing
        // Obj-C semantics: the first tick at/below zero (or any tick at exactly 0) just switches
        // to finishing and restarts the stuck clock; only time spent past zero while already
        // finishing counts toward "stuck". Measured in monotonic uptime, not tick count.
        let alreadyFinishing = timeState == .verifyingEnd || timeState == .finishing
        let nowUptime = SCTrustedClock.continuousUptimeSecs()
        if secs > 0 {
            assign(\.timeState, .countdown(seconds: secs))
            finishingSinceUptime = nil
            stuckReported = false
            assign(\.isStuck, false)
        } else if secs == 0 || !alreadyFinishing || finishingSinceUptime == nil {
            assign(\.timeState, finishingState)
            finishingSinceUptime = nowUptime
            stuckReported = false
            assign(\.isStuck, false)
        } else {
            assign(\.timeState, finishingState)
            let stuck = nowUptime - (finishingSinceUptime ?? nowUptime) >= 300
            if stuck && !stuckReported {
                stuckReported = true
                NSLog("WARNING: Block should have ended! Probable failure to remove.")
                SCSentry.captureError(SCErr.error(withCode: 105))
            }
            assign(\.isStuck, stuck)
        }
        updateDockBadge(seconds: secs)
    }

    private func updateDockBadge(seconds: Int) {
        guard defaults.bool(forKey: "BadgeApplicationIcon"), seconds > 0 else {
            if NSApp.dockTile.badgeLabel != nil { NSApp.dockTile.badgeLabel = nil }
            return
        }
        let hours = seconds / 3600
        var minutes = (seconds % 3600) / 60
        // round minutes up, standard when we aren't displaying seconds
        if seconds % 60 > 0 && minutes != 59 { minutes += 1 }
        let label = String(format: "%02d:%02d", hours, minutes)
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    // MARK: - Overrides (port of -refreshOverrideUI / -renderOverrideStatus)

    private func refreshOverride() {
        let settings = SCSettings.shared()
        let policy = settings.value(forKey: "OverridePolicy") as? [String: Any]
        let perDay = (policy?["perDay"] as? NSNumber)?.intValue ?? 0
        let minutes = (policy?["minutes"] as? NSNumber)?.intValue ?? 0
        guard isModernBlock, perDay > 0 else {
            assign(\.override, OverrideStatus(perDay: perDay, minutes: minutes))
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
            assign(\.override, OverrideStatus(perDay: s.perDay, minutes: minutes, remainingToday: s.remainingToday,
                                              active: s.active, activeRemainingSecs: (s.active && shown > 0) ? shown : nil,
                                              checking: false))
            return
        }
        let remaining = (state?["remainingToday"] as? NSNumber)?.intValue ?? 0
        assign(\.override, OverrideStatus(perDay: perDay, minutes: minutes, remainingToday: remaining,
                                          active: false, activeRemainingSecs: nil, checking: true))
    }

    // MARK: - Navigation

    func push(_ route: Route) {
        // No edits while a block is starting: installBlock reads the restrictions
        // and override settings from defaults only after the auth prompt.
        if isAddingBlock && route != .emergencyUnlock { return }
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
        let ud = defaults
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

    // MARK: - Running-block actions

    /// Display text for an error; nil when there's nothing to show (no error, or auth cancel).
    static func message(for error: Error?) -> String? {
        guard let ns = error as NSError? else { return nil }
        return SCUIUtilities.displayableError(ns)?.localizedDescription
    }

    static func result(for error: Error?) -> ActionResult {
        guard error != nil else { return .ok }
        guard let msg = message(for: error) else { return .cancelled }
        return .failed(msg)
    }

    func addToRunningBlock(_ raw: String, completion: @escaping (ActionResult) -> Void) {
        guard live, let ac = appController else { completion(.cancelled); return }
        // AppController guarantees completion on the main queue.
        ac.addEntries(toRunningBlock: raw) { [weak self] error in
            MainActor.assumeIsolated {
                self?.reload()
                completion(AppModel.result(for: error))
            }
        }
    }

    func extendBlock(minutes: Int, completion: @escaping (ActionResult) -> Void) {
        guard live, let ac = appController else { completion(.cancelled); return }
        // AppController guarantees completion on the main queue.
        ac.extendRunningBlock(byMinutes: minutes) { [weak self] error in
            MainActor.assumeIsolated {
                self?.reload()
                completion(AppModel.result(for: error))
            }
        }
    }

    func invokeOverride(completion: @escaping (ActionResult) -> Void) {
        guard live, let xpc = appController?.xpc else { completion(.cancelled); return }
        xpc.invokeOverride { [weak self] _, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                // never trust pre-invoke cached status; force a fresh daemon poll
                self.lastStatus = nil
                self.statusInFlight = false
                self.refreshOverride()
                completion(AppModel.result(for: error))
            }
        }
    }

    func stopBlockManually() {
        guard live else { return }
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
                    self.tedium.error = (error.domain == kSelfControlErrorDomain && error.code == 321)
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
                    switch error.domain == kSelfControlErrorDomain ? error.code : 0 {
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
