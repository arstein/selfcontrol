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
        ]
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
