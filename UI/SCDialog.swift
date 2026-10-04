import AppKit
import SwiftUI

/// Result of `Dialog.run`: which button was pressed and the suppression checkbox state.
@objc(SCDialogResult)
final class DialogResult: NSObject {
    /// Index into `buttons`; the cancel button (Esc) returns its own index.
    @objc let buttonIndex: Int
    @objc let suppressionChecked: Bool

    init(buttonIndex: Int, suppressionChecked: Bool) {
        self.buttonIndex = buttonIndex
        self.suppressionChecked = suppressionChecked
    }
}

/// Custom-styled, app-modal replacement for NSAlert (dark card look). Called from
/// Obj-C and Swift; always on the main thread.
@objc(SCDialog)
final class Dialog: NSObject {
    static let cardWidth: CGFloat = 320
    /// Transparent margin around the card so its own rounded border and shadow show.
    static let margin = EdgeInsets(top: 20, leading: 20, bottom: 28, trailing: 20)

    /// buttons: left-to-right order as displayed. primaryIndex: the accent-colored button (or -1 for none).
    /// cancelIndex: button triggered by Esc / closing (or -1). defaultIndex: button triggered by Return (or -1).
    @MainActor @objc static func run(title: String, message: String?, buttons: [String],
                                     primaryIndex: Int, cancelIndex: Int, defaultIndex: Int,
                                     suppressionTitle: String?) -> DialogResult {
        let buttons = buttons.isEmpty ? [NSLocalizedString("OK", comment: "OK button")] : buttons
        var suppressed = false
        var pressed = cancelIndex >= 0 ? cancelIndex : 0

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                            styleMask: [.titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // the card draws its own soft shadow
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let content = DialogContent(title: title, message: message, buttons: buttons,
                                    primaryIndex: primaryIndex, cancelIndex: cancelIndex, defaultIndex: defaultIndex,
                                    suppressionTitle: suppressionTitle) { index, checked in
            pressed = index
            suppressed = checked
            NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: index))
        }
        let host = NSHostingView(rootView: content.padding(margin).noFocusRing())
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.setContentSize(size)
        position(panel, size: size)

        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return DialogResult(buttonIndex: pressed, suppressionChecked: suppressed)
    }

    /// Convenience: single "OK" button (primary, default, cancel).
    @MainActor @objc static func inform(title: String, message: String?) {
        _ = run(title: title, message: message, buttons: [NSLocalizedString("OK", comment: "OK button")],
                primaryIndex: 0, cancelIndex: 0, defaultIndex: 0, suppressionTitle: nil)
    }

    /// Shows an NSError: displayableError(...) first; nil → show nothing.
    /// Title = localizedDescription, message = localizedRecoverySuggestion (may be nil).
    @MainActor @objc static func showError(_ error: Error) {
        guard let shown = SCUIUtilities.displayableError(error as NSError).map({ $0 as NSError }) else { return }
        inform(title: shown.localizedDescription, message: shown.localizedRecoverySuggestion)
    }

    /// Centers over the main window if it's visible, otherwise on the main screen.
    @MainActor private static func position(_ panel: NSPanel, size: NSSize) {
        let anchor: NSRect
        if let main = (NSApp.delegate as? AppController)?.mainWindowController?.window, main.isVisible {
            anchor = main.frame
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            anchor = screen.visibleFrame
        } else {
            panel.center()
            return
        }
        let frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        panel.setFrameOrigin(NSPoint(x: (anchor.midX - frame.width / 2).rounded(),
                                     y: (anchor.midY - frame.height / 2).rounded()))
    }
}

/// The dialog card. Rendered standalone by the snapshot renderer, so it holds no
/// window state of its own beyond the checkbox.
struct DialogContent: View {
    let title: String
    let message: String?
    let buttons: [String]
    let primaryIndex: Int
    let cancelIndex: Int
    let defaultIndex: Int
    let suppressionTitle: String?
    let onButton: (Int, Bool) -> Void

    @State private var suppressed = false

    /// Clicks inside the ~28pt title-bar band never reach SwiftUI; the margin plus
    /// this top padding keeps the title (and everything clickable) below it.
    private static let topPadding: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: 0xD4D4DA))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            if let suppressionTitle {
                DialogCheckbox(title: suppressionTitle, isOn: $suppressed)
                    .padding(.top, 14)
            }
            buttonRow.padding(.top, 18)
        }
        .padding(.horizontal, 20).padding(.bottom, 20).padding(.top, Self.topPadding)
        .frame(width: Dialog.cardWidth, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.fieldBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }

    @ViewBuilder private var buttonRow: some View {
        HStack(spacing: 8) {
            ForEach(buttons.indices, id: \.self) { i in
                dialogButton(i)
            }
        }
    }

    @ViewBuilder private func dialogButton(_ i: Int) -> some View {
        let base = Button(buttons[i]) { onButton(i, suppressed) }
        let styled: AnyView = (i == primaryIndex || buttons.count == 1)
            ? AnyView(base.buttonStyle(PrimaryButtonStyle()).frame(height: 40))
            : AnyView(base.buttonStyle(SecondaryButtonStyle(height: 40, fullWidth: true)))
        if i == cancelIndex && i == defaultIndex {
            // One button answering both Esc and Return: the visible Return
            // binding goes on the button, Esc via a hidden twin.
            styled.keyboardShortcut(.defaultAction)
                .background(Button("") { onButton(i, suppressed) }
                    .keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false).accessibilityHidden(true))
        } else if i == cancelIndex {
            styled.keyboardShortcut(.cancelAction)
        } else if i == defaultIndex {
            styled.keyboardShortcut(.defaultAction)
        } else {
            styled
        }
    }
}

/// Custom square checkbox (not the system one): 14pt rounded square, accent fill when checked.
struct DialogCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(isOn ? Theme.accent : Theme.field)
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(isOn ? Theme.accent : Theme.fieldBorder, lineWidth: 1)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 14, height: 14)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }
}
