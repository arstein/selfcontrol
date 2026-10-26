#if DEBUG
import AppKit
import SwiftUI

/// `SelfControl.app/Contents/MacOS/SelfControl -SCRenderSnapshots /path/to/dir`
/// renders each screen state with a stub model to PNGs, then exits. Never touches
/// SCSettings, the daemon, or XPC.
@objc(SCSnapshotRenderer)
final class SnapshotRenderer: NSObject {
    @MainActor @objc static func runIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-SCRenderSnapshots"), i + 1 < args.count else {
            FileHandle.standardError.write("usage: SelfControl -SCRenderSnapshots <dir>\n".data(using: .utf8)!)
            return false
        }
        let dir = args[i + 1]
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, model) in states() {
            render(RootView().environmentObject(model), to: url.appendingPathComponent("\(name).png"))
        }
        for (name, dialog) in dialogs() {
            renderDialog(dialog, to: url.appendingPathComponent("\(name).png"))
        }
        return true
    }

    @MainActor private static func states() -> [(String, AppModel)] {
        func blocking(_ secs: Int, _ extra: (AppModel) -> Void = { _ in }) -> AppModel {
            AppModel.preview { m in
                m.isBlockRunning = true
                m.isModernBlock = true
                m.timeState = .countdown(seconds: secs)
                m.blockDurationSecs = Double(secs) * 2
                m.override = OverrideStatus(perDay: 3, minutes: 15, remainingToday: 2, active: false, activeRemainingSecs: nil, checking: false)
                extra(m)
            }
        }
        return [
            ("01-ready", AppModel.preview()),
            ("02-ready-starting", AppModel.preview { $0.isAddingBlock = true }),
            ("03-restrictions", AppModel.preview { $0.path = [.restrictions] }),
            ("04-restrictions-allowlist", AppModel.preview { $0.path = [.restrictions]; $0.isAllowlist = true }),
            ("05-overrides", AppModel.preview { $0.path = [.overrides] }),
            ("06-settings", AppModel.preview { $0.path = [.settings] }),
            ("06b-settings-block-running", blocking(13312) { $0.path = [.settings] }),
            ("07b-blocking-unlock-off", blocking(13312) { $0.emergencyUnlockAvailable = false }),
            ("07-blocking-sameday", blocking(3 * 3600 + 41 * 60 + 52)),
            ("08-blocking-multiday", blocking(86400 + 3 * 3600 + 41 * 60 + 52)),
            ("09-override-confirm", blocking(86400 + 13312) { $0.sheet = .overrideConfirm }),
            ("10-override-running", blocking(86400 + 13187) { m in
                m.override = OverrideStatus(perDay: 3, minutes: 15, remainingToday: 1, active: true, activeRemainingSecs: 767, checking: false)
            }),
            ("11-extend-sheet", blocking(13312) { $0.sheet = .extend(presetMinutes: 60) }),
            ("12-verifying-end", blocking(0) { $0.timeState = .verifyingEnd }),
            ("13-stuck", blocking(0) { $0.timeState = .finishing; $0.isModernBlock = false; $0.isLegacyBlock = true; $0.isStuck = true }),
            ("14-restrictions-during-block", blocking(13312) { $0.path = [.restrictions] }),
            ("15-allowlist-block", blocking(13312) { $0.isActiveAllowlist = true; $0.activeEntries = ["docs.google.com", "github.com"] }),
            ("16-emergency", blocking(13312) { m in
                m.path = [.emergencyUnlock]
                m.tedium = TediumState(started: true, digit: 7, progress: 117, required: 300, flash: nil)
            }),
            ("17-emergency-wrong", blocking(13312) { m in
                m.path = [.emergencyUnlock]
                m.tedium = TediumState(started: true, digit: 3, progress: 97, required: 300, flash: .wrong)
            }),
            ("18-restrictions-long", AppModel.preview { m in
                m.path = [.restrictions]
                m.editableEntries = (1...30).map { "site\($0).example.com" }
            }),
            ("22-ready-max30d", AppModel.preview { m in
                m.maxBlockLengthMinutes = 43200
                m.blockDurationMinutes = 1440
            }),
            ("22b-ready-at-max", AppModel.preview { m in
                m.maxBlockLengthMinutes = 43200
                m.blockDurationMinutes = 43200
            }),
            ("23-ready-max1d", AppModel.preview { m in
                m.maxBlockLengthMinutes = 1440
                m.blockDurationMinutes = 480
            }),
            ("24-overrides-10", AppModel.preview { m in
                m.path = [.overrides]
                m.overridePerDayDefault = 10
            }),
            ("25-blocking-10", blocking(86400 + 13187) { m in
                m.override = OverrideStatus(perDay: 10, minutes: 15, remainingToday: 6, active: true, activeRemainingSecs: 500, checking: false)
            }),
            ("26-ready-10", AppModel.preview { $0.overridePerDayDefault = 10 }),
            ("27-override-confirm-10", blocking(86400 + 13312) { m in
                m.override = OverrideStatus(perDay: 10, minutes: 15, remainingToday: 7, active: false, activeRemainingSecs: nil, checking: false)
                m.sheet = .overrideConfirm
            }),
            ("28-extend-multiday-1day", blocking(3 * 86400 + 13312) { m in
                m.maxBlockLengthMinutes = 43200
                m.sheet = .extend(presetMinutes: 1440)
            }),
            ("29-ready-deep-row", AppModel.preview { m in m.deepEntries = ["docs.google.com", "github.com", "mail.google.com"]; m.isDeepAllowlist = true }),
            ("30-deep-block-card", AppModel.preview { m in m.path = [.deepBlock]; m.deepEntries = ["docs.google.com", "github.com"]; m.isDeepAllowlist = true; m.deepDurationMinutes = 45 }),
            ("31-deep-list", AppModel.preview { m in m.path = [.deepList]; m.deepEntries = ["docs.google.com", "github.com"]; m.isDeepAllowlist = true }),
            ("32-deep-only-running", AppModel.preview { m in
                m.deepRunning = true; m.deepTimeState = .countdown(seconds: 1932)
                m.deepActiveEntries = ["docs.google.com", "github.com"]; m.isDeepActiveAllowlist = true }),
            ("33-both-running", blocking(13312) { m in
                m.deepRunning = true; m.deepTimeState = .countdown(seconds: 1932)
                m.deepActiveEntries = ["docs.google.com"]; m.isDeepActiveAllowlist = true }),
            ("34-deep-list-locked", AppModel.preview { m in
                m.path = [.deepList]; m.deepRunning = true; m.deepTimeState = .countdown(seconds: 1932)
                m.deepActiveEntries = ["docs.google.com", "github.com"]; m.isDeepActiveAllowlist = true }),
            ("35-deep-verifying", AppModel.preview { m in m.deepRunning = true; m.deepTimeState = .verifyingEnd }),
            ("36-deep-list-addable", AppModel.preview { m in
                m.path = [.deepList]; m.deepRunning = true; m.deepRecordUsable = true; m.deepTimeState = .countdown(seconds: 1932)
                m.deepActiveEntries = ["reddit.com", "youtube.com"]; m.isDeepActiveAllowlist = false }),
            ("37-list-address-only", AppModel.preview { m in
                m.path = [.restrictions]; m.isAllowlist = false
                m.editableEntries = ["nytimes.com", "www.nytimes.com", "danieldrezner.substack.com", "10.0.0.0/8"] }),
            ("38-extend-at-cap", blocking(86400) { m in
                m.maxBlockLengthMinutes = 1440
                m.sheet = .extend(presetMinutes: 60)
            }),
        ]
    }

    /// The SCDialog card (not the modal run), with the same copy as the live call sites.
    @MainActor private static func dialogs() -> [(String, DialogContent)] {
        let ok = NSLocalizedString("OK", comment: "OK button")
        return [
            ("19-dialog-allowlist", DialogContent(
                title: NSLocalizedString("Block everything except your list?", comment: "Allowlist block confirmation prompt"),
                message: NSLocalizedString("Only the sites you list will work — that includes email, chat and other apps that use the internet. Sites that load images or scripts from elsewhere may break.", comment: "allowlist block explanation"),
                buttons: [ok], primaryIndex: 0, cancelIndex: 0, defaultIndex: 0,
                suppressionTitle: NSLocalizedString("Don't show this again", comment: "allowlist warning suppression checkbox"),
                onButton: { _, _ in })),
            ("20-dialog-long-block", DialogContent(
                title: String(format: NSLocalizedString("Start a block for %@?", comment: "Long block warning title"), "3 days"),
                message: NSLocalizedString("You won't be able to end it early, even if you've blocked something you need. If your list is new, try a short block first.", comment: "Long block warning message"),
                buttons: [NSLocalizedString("Cancel", comment: "Button to cancel a long block"), NSLocalizedString("Start Block", comment: "Button to start a long block despite warnings")],
                primaryIndex: 1, cancelIndex: 0, defaultIndex: 0,
                suppressionTitle: NSLocalizedString("Don't warn me about long blocks", comment: "Long block warning suppression checkbox"),
                onButton: { _, _ in })),
            ("21-dialog-error", DialogContent(
                title: SCErr.error(withCode: 401).localizedDescription, message: nil,
                buttons: [ok], primaryIndex: 0, cancelIndex: 0, defaultIndex: 0, suppressionTitle: nil,
                onButton: { _, _ in })),
        ]
    }

    /// Renders a dialog card at its natural height on the window background color.
    @MainActor private static func renderDialog(_ dialog: DialogContent, to url: URL) {
        let view = dialog.padding(Dialog.margin).background(Color(nsColor: Theme.bgNSColor))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let out = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
        try? out.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Renders through a real NSHostingView in an offscreen window so AppKit-backed
    /// controls (TextField, Menu) draw correctly.
    @MainActor private static func render<V: View>(_ view: V, to url: URL) {
        let size = NSSize(width: Theme.windowWidth, height: 640)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        // The cache comes back in the display's space (Display P3); convert so the
        // PNG's pixel values match the sRGB hex tokens in Theme and the mocks.
        let out = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
        try? out.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
