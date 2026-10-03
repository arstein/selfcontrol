import AppKit
import SwiftUI
import Combine

/// Owns the single app window. Obj-C (AppController) drives it via the @objc API.
@objc(MainWindowController)
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let model: AppModel
    private var cancellables = Set<AnyCancellable>()

    @objc init(liveModel: Bool) {
        model = AppModel(live: liveModel)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.windowWidth, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "SelfControl"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar makes the titlebar 52pt tall, so the traffic
        // lights sit centered in our 52pt header (Theme.headerHeight).
        window.toolbar = NSToolbar(identifier: "SelfControlMainToolbar")
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.bgNSColor
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: Theme.windowWidth, height: Theme.windowMinHeight)
        window.contentMaxSize = NSSize(width: Theme.windowWidth, height: 4000)
        super.init(window: window)

        window.contentView = NSHostingView(rootView: RootView().environmentObject(model))
        window.delegate = self
        if !window.setFrameUsingName("SelfControlMainWindow") { window.center() }
        window.setFrameAutosaveName("SelfControlMainWindow")

        // "Keep window on top while blocking" applies live (spec §6.4)
        Publishers.CombineLatest(model.$keepWindowOnTop, model.$isBlockRunning)
            .receive(on: RunLoop.main)
            .sink { [weak window] onTop, running in window?.level = (onTop && running) ? .floating : .normal }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc func refresh() { model.reload() }
    @objc func startTicking() { model.startTicking() }
    @objc func showSettings() { bringForward(); model.push(.settings) }
    @objc func showRestrictions() { bringForward(); model.push(.restrictions) }
    @objc func showEmergencyUnlock() { bringForward(); model.path = [.emergencyUnlock] }

    private func bringForward() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
