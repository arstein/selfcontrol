import SwiftUI
import AppKit

struct RestrictionsView: View {
    @EnvironmentObject var model: AppModel
    @State private var input = ""
    @State private var error: String? = nil
    @State private var busy = false
    @State private var hovered: String? = nil
    @State private var listHeight: CGFloat = 0
    @State private var importNote: String? = nil
    @State private var importNoteToken = 0

    private var blocking: Bool { model.isBlockRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Card {
                RadioRow(title: NSLocalizedString("Block these sites", comment: ""),
                         subtitle: NSLocalizedString("Everything else stays open", comment: ""),
                         selected: !model.shownAllowlist, enabled: !blocking) { model.setAllowlist(false) }
                RowDivider()
                RadioRow(title: NSLocalizedString("Allow only these sites", comment: ""),
                         subtitle: NSLocalizedString("Everything else is blocked", comment: ""),
                         selected: model.shownAllowlist, enabled: !blocking) { model.setAllowlist(true) }
            }

            // Spec §6.2: shown disabled (not hidden) when the running block can't take additions.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    SCTextField(placeholder: NSLocalizedString("Add a site, e.g. reddit.com", comment: ""), text: $input, onSubmit: add)
                        .disabled(!addAllowed)
                    Button(NSLocalizedString("Add", comment: ""), action: add)
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(width: 64)
                        .disabled(!addAllowed || input.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
                .opacity(addAllowed ? 1 : 0.5)
                if addAllowed, let error {
                    Text(error).font(.system(size: 12)).foregroundColor(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.shownEntries.enumerated()), id: \.element) { index, entry in
                            entryRow(entry)
                            if index < model.shownEntries.count - 1 { RowDivider() }
                        }
                        if model.shownEntries.isEmpty {
                            Text(model.shownAllowlist
                                 ? NSLocalizedString("Nothing allowed — every site will be blocked.", comment: "")
                                 : NSLocalizedString("No sites yet. Add one above.", comment: ""))
                                .foregroundColor(Theme.sub).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ListHeightKey.self, value: g.size.height)
                    })
                }
                // hug the rows; scroll only once they outgrow the window
                .frame(maxHeight: listHeight > 0 ? listHeight : nil)
                .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            }
            .layoutPriority(-1)

            if let importNote {
                Text(importNote).font(.system(size: 12)).foregroundColor(Theme.warning).padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(caption).font(.system(size: 11)).foregroundColor(Theme.sub).padding(.horizontal, 2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack {
                if !blocking {
                    Menu { importItems } label: {
                        Text(NSLocalizedString("Import…", comment: "")).font(.system(size: 12)).foregroundColor(Theme.sub)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                Button(NSLocalizedString("Export…", comment: "")) { (NSApp.delegate as? AppController)?.save(nil) }
                    .buttonStyle(.plain).foregroundColor(Theme.sub).font(.system(size: 12))
                Spacer()
                Text(model.shownEntries.count == 1 ? NSLocalizedString("1 site", comment: "")
                     : String(format: NSLocalizedString("%ld sites", comment: ""), model.shownEntries.count))
                    .font(.system(size: 12)).foregroundColor(Theme.sub)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, Theme.inset)
        .padding(.top, 4)
    }

    private var addAllowed: Bool { !blocking || model.canAddDuringBlock }

    private var caption: String {
        if !blocking { return NSLocalizedString("Entries cover their common subdomains (www. etc.) when that setting is on.", comment: "") }
        if model.isLegacyBlock { return NSLocalizedString("This block was started by an older version of SelfControl, so sites can’t be added to it.", comment: "") }
        if !model.isModernBlock { return NSLocalizedString("This block can’t be changed from here.", comment: "") }
        if model.isActiveAllowlist { return NSLocalizedString("Sites can’t be added to an allowlist block.", comment: "") }
        return NSLocalizedString("Sites can be added during a block, never removed.", comment: "")
    }

    @ViewBuilder private func entryRow(_ entry: String) -> some View {
        let invalid = model.highlightInvalidHosts && !HostValidity.isValid(entry)
        HStack(spacing: 10) {
            Text(entry).lineLimit(1).truncationMode(.middle)
                .foregroundColor(invalid ? Theme.warning : Theme.text)
                .help(invalid ? NSLocalizedString("This doesn’t look like a valid host or IP address.", comment: "") : "")
            Spacer()
            if entry.contains("/") { Text(NSLocalizedString("IP range", comment: "")).font(.system(size: 11)).foregroundColor(Theme.sub) }
            if !blocking {
                // Always reserve the button's 22pt slot so rows don't change height on hover.
                Button { model.removeEditableEntry(entry) } label: {
                    Image(systemName: "minus").font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22).background(Color(hex: 0x4A4A52)).clipShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .opacity(hovered == entry ? 1 : 0)
                .allowsHitTesting(hovered == entry)
                .accessibilityLabel(Text(String(format: NSLocalizedString("Remove %@", comment: ""), entry)))
            }
        }
        .frame(minHeight: 22)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(hovered == entry && !blocking ? Color(hex: 0x33333A) : Color.clear)
        .contentShape(Rectangle())   // hover/click anywhere on the row, including the empty middle
        .onHover { inside in hovered = inside ? entry : (hovered == entry ? nil : hovered) }
        .contextMenu {
            if !blocking { Button(NSLocalizedString("Remove", comment: "")) { model.removeEditableEntry(entry) } }
        }
    }

    @ViewBuilder private var importItems: some View {
        Button(NSLocalizedString("Common Distracting Sites", comment: "")) { importList(HostImporter.commonDistractingWebsites()) }
        Button(NSLocalizedString("News & Publications", comment: "")) { importList(HostImporter.newsAndPublications()) }
        Divider()
        Button(NSLocalizedString("Incoming Mail Servers (Mail)", comment: "")) { importList(HostImporter.incomingMailHostnamesFromMail()) }
        Button(NSLocalizedString("Outgoing Mail Servers (Mail)", comment: "")) { importList(HostImporter.outgoingMailHostnamesFromMail()) }
        Button(NSLocalizedString("Incoming Mail Servers (MailMate)", comment: "")) { importList(HostImporter.incomingMailHostnamesFromMailMate()) }
        Button(NSLocalizedString("Outgoing Mail Servers (MailMate)", comment: "")) { importList(HostImporter.outgoingMailHostnamesFromMailMate()) }
        Button(NSLocalizedString("Incoming Mail Servers (Thunderbird)", comment: "")) { importList(HostImporter.incomingMailHostnamesFromThunderbird()) }
        Button(NSLocalizedString("Outgoing Mail Servers (Thunderbird)", comment: "")) { importList(HostImporter.outgoingMailHostnamesFromThunderbird()) }
        Divider()
        Button(NSLocalizedString("From File…", comment: "")) { (NSApp.delegate as? AppController)?.open(nil) }
    }

    private func importList(_ hosts: [Any]?) {
        let skipped = model.importHosts((hosts ?? []).compactMap { $0 as? String })
        importNoteToken += 1
        let token = importNoteToken
        importNote = HostValidity.skippedNote(count: skipped)
        guard importNote != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if importNoteToken == token { importNote = nil }
        }
    }

    private func add() {
        guard !busy else { return }   // Return in the field bypasses the button's .disabled
        guard addAllowed else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        error = nil
        if !blocking {
            if model.addEditableEntries(text) { input = "" }
            else { error = NSLocalizedString("That doesn’t look like a site address.", comment: "") }
            return
        }
        // Validate before asking for authorization; add nothing if any entry is invalid.
        guard model.isAcceptableEntry(text) else {
            error = NSLocalizedString("That doesn’t look like a site address.", comment: "")
            return
        }
        busy = true
        model.addToRunningBlock(text) { result in
            busy = false
            switch result {
            case .ok: input = ""
            case .cancelled: break
            case .failed(let message): error = message
            }
        }
    }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
