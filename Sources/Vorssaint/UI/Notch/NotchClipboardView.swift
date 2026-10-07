// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The history as a vertical list of cards, with everything the panel's list
/// and the quick panel offer on each: paste or copy, pin, move, delete, and
/// the recent ones cleared in one go from the search row.
struct NotchClipboardView: View {
    @ObservedObject var service: NotchService
    let size: CGSize
    @ObservedObject private var history = ClipboardHistoryService.shared
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(DefaultsKey.clipboardHistoryEnabled) private var enabled = false
    @State private var query = ""
    @State private var copiedID: UUID?
    @State private var pinnedOnly = false
    /// The card the arrow keys chose from the search field, or the top result
    /// of a typed search; Return uses it the way a click would.
    @State private var highlightedID: UUID?
    @FocusState private var searching: Bool
    /// The search field shows only once it is wanted: the magnifier opens it,
    /// pointing at the magnifier opens it, and so does typing a letter.
    @State private var searchOpen = false
    @State private var hoveringSearch = false
    @Environment(\.notchSettingsPreview) private var preview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var text: ClipboardFeatureStrings { FeatureStrings.clipboard(l10n.language) }

    private var entries: [ClipboardHistoryEntry] {
        history.filteredEntries(matching: query).filter { !pinnedOnly || $0.isPinned }
    }

    /// Moving swaps neighbours in the list, which a search would misreport.
    private var canReorder: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var searchTokens: [String] {
        ClipboardHistorySearch.searchTokens(for: query)
    }

    /// The island draws its text in white and never in the accent color, so a
    /// match stands out by weight alone.
    private func searchText(_ string: String, matching tokens: [String]) -> Text {
        SearchHighlightText.text(string, tokens: tokens, fontSize: 12, highlightColor: nil)
    }

    var body: some View {
        VStack(spacing: NotchLayout.rowSpacing) {
            header
                .background {
                    if !preview {
                        ClipboardKeyMonitor { handleKey(keyCode: $0, characters: $1, hasCommandModifier: $2, editing: $3) }
                            .frame(width: 0, height: 0)
                    }
                }
                // The page opens on the entry copied last, so Return pastes it
                // and the arrows move from it.
                .onAppear { if !preview { highlightedID = searchHighlight(keeping: nil) } }
            if !enabled, history.entries.isEmpty {
                // The panel offers the switch beside its caption; the page
                // says why it is empty and turns the history on from here.
                VStack(spacing: 10) {
                    NotchEmptyView(symbol: "doc.on.clipboard", message: text.disabled)
                    Button(text.enable) {
                        enabled = true
                        history.syncWithPreferences()
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                .frame(maxHeight: .infinity)
            } else if entries.isEmpty {
                NotchEmptyView(symbol: pinnedOnly ? "pin" : "doc.on.clipboard",
                               message: query.isEmpty && !pinnedOnly ? text.empty : text.noResults)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                card(entry, place: index).frame(height: NotchLayout.clipboardCardHeight)
                                    .id(entry.id)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: highlightedID) { _, id in
                        guard let id else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                    // A copied recent entry moves to the top, so the list
                    // follows it and the tick stays in view.
                    .onChange(of: copiedID) { _, id in
                        guard let id else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A new search starts from its top result instead of a row it hid,
        // and a row that leaves the list hands the highlight on the same way.
        .onChange(of: query) { _, _ in highlightedID = searchHighlight(keeping: nil) }
        .onChange(of: pinnedOnly) { _, _ in highlightedID = searchHighlight(keeping: nil) }
        .onChange(of: searchOpen) { _, open in
            guard !preview else { return }
            // Escape closes the search before it closes the island.
            service.setPageLayer(.clipboard, close: open ? { closeSearch() } : nil)
        }
        .onChange(of: searching) { _, focused in
            // A field left empty has nothing to keep open.
            if !focused, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { searchOpen = false }
        }
        .onDisappear { if !preview { service.setPageLayer(.clipboard, close: nil) } }
        .onChange(of: entries.map(\.id)) { _, _ in highlightedID = searchHighlight(keeping: highlightedID) }
        .onChange(of: service.clipboardPastePress) { _, press in
            guard let press, !preview else { return }
            guard entries.indices.contains(press.index) else {
                NSSound.beep()
                return
            }
            activate(entries[press.index])
        }
        .task(id: copiedID) {
            // The tick confirms one copy; leaving it on the row forever would
            // read as a permanent state instead of an answer.
            guard copiedID != nil else { return }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            copiedID = nil
        }
    }

    /// The entry fills the card; its actions sit in the bottom row.
    private func card(_ entry: ClipboardHistoryEntry, place: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { activate(entry) } label: {
                preview(entry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .contentShape(Rectangle())
            }
            .buttonStyle(NotchButtonStyle(lifts: false))
            .help(permissions.accessibility ? text.clickRowShortcut : text.copy)
            HStack(spacing: 4) {
                Image(systemName: entry.kind == .image ? "photo" : entry.kind == .files ? "doc" : "text.alignleft")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(entry.copiedAt, style: .time)
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 0)
                if place < 9, service.panelIsKey {
                    Text("⌘\(place + 1)")
                        .font(.system(size: 9.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                if entry.kind == .image, AppFeature.screenshot.isAvailable {
                    NotchIconButton(symbol: "pencil", title: text.edit) { history.editImage(entry) }
                }
                NotchIconButton(symbol: copiedID == entry.id ? "checkmark" : "doc.on.doc",
                                title: copiedID == entry.id ? text.copied : text.copy) { copy(entry) }
                NotchIconButton(symbol: entry.isPinned ? "pin.fill" : "pin",
                                title: entry.isPinned ? text.unpin : text.pin) {
                    history.togglePin(entry)
                }
                NotchIconButton(symbol: "trash", title: text.delete) { remove(entry) }
            }
            .frame(height: 28)
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
        .modifier(NotchControlSurface(cornerRadius: 14, selected: entry.isPinned))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(highlightedID == entry.id ? 0.34 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipped()
        .contextMenu { actions(entry) }
        .accessibilityAction(named: Text(text.moveUp)) { move(entry, .up) }
        .accessibilityAction(named: Text(text.moveDown)) { move(entry, .down) }
    }

    /// The quick panel's row menu: paste when the app may type, copy, pin,
    /// move within the list and delete.
    @ViewBuilder private func actions(_ entry: ClipboardHistoryEntry) -> some View {
        if permissions.accessibility {
            Button(l10n.s.menuPaste) { paste(entry) }
        }
        Button(text.copy) { copy(entry) }
        Divider()
        Button(entry.isPinned ? text.unpin : text.pin) { history.togglePin(entry) }
        Button(text.moveUp) { move(entry, .up) }
            .disabled(!canReorder || !history.canMove(entry, .up))
        Button(text.moveDown) { move(entry, .down) }
            .disabled(!canReorder || !history.canMove(entry, .down))
        Divider()
        Button(text.delete, role: .destructive) { remove(entry) }
    }

    /// The highlighted row, or with no search the entry copied last.
    private func searchHighlight(keeping current: UUID?) -> UUID? {
        NotchSupport.searchHighlight(keeping: current, in: entries.map(\.id), query: query)
            ?? NotchSupport.restingClipboardHighlight(entries.map { ($0.id, $0.isPinned) })
    }

    /// The row of actions. The search field is behind the magnifier until it
    /// is wanted, so the page keeps its room for the entries.
    @ViewBuilder private var header: some View {
        if searchOpen {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(text.search, text: $query).textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searching)
                    .accessibilityLabel(text.search)
                actionButtons
            }
            .padding(.horizontal, 12)
            .frame(height: NotchLayout.clipboardSearchHeight)
            .modifier(NotchControlSurface(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(searching ? 0.34 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.15), value: searching)
        } else {
            HStack(spacing: 8) {
                NotchIconButton(symbol: "magnifyingglass", title: text.search) { openSearch() }
                    .onHover { hoveringSearch = $0 }
                    .task(id: hoveringSearch) {
                        guard hoveringSearch, !preview else { return }
                        try? await Task.sleep(for: .milliseconds(250))
                        if !Task.isCancelled { openSearch() }
                    }
                Spacer(minLength: 0)
                actionButtons
            }
            .frame(height: NotchLayout.clipboardActionsHeight)
        }
    }

    @ViewBuilder private var actionButtons: some View {
        NotchIconButton(symbol: "pin", title: text.pinned, selected: pinnedOnly) {
            pinnedOnly.toggle()
        }
        NotchIconButton(symbol: "trash", title: text.clearRecent) {
            let ids = history.recentEntriesSnapshot
            DispatchQueue.main.async {
                guard NSAlert.confirmAboveIsland(String(format: text.clearRecentConfirmFormat, ids.count),
                                                 message: text.clearRecentConfirmMessage,
                                                 action: text.clearRecent, destructive: true,
                                                 cancel: text.cancel) else { return }
                history.clearRecent(ids)
                copiedID = nil
            }
        }
        .disabled(history.recentEntries.isEmpty)
        NotchIconButton(symbol: "arrow.up.forward.app", title: text.title) {
            service.perform { history.showHistoryWindow(preferNotch: false) }
        }
    }

    private func openSearch() {
        searchOpen = true
        // The field exists on the next pass, and only then can it take focus.
        DispatchQueue.main.async { searching = true }
    }

    private func closeSearch() {
        query = ""
        searching = false
        searchOpen = false
    }

    /// Up and Down move the highlight and Return pastes or copies it like a
    /// click, with or without the search field focused. A letter opens the
    /// search and starts it.
    private func handleKey(keyCode: UInt16, characters: String, hasCommandModifier: Bool, editing: Bool) -> Bool {
        guard let key = NotchSupport.clipboardKey(keyCode: keyCode, characters: characters,
                                                  hasCommandModifier: hasCommandModifier, editing: editing) else { return false }
        let ids = entries.map(\.id)
        switch key {
        case .move(let backwards):
            guard !ids.isEmpty else { return false }
            highlightedID = NotchSupport.steppedItem(from: highlightedID, in: ids, backwards: backwards)
            return true
        case .paste:
            guard let id = NotchSupport.clipboardPasteTarget(highlighted: highlightedID, in: ids),
                  let entry = entries.first(where: { $0.id == id }) else { return false }
            activate(entry)
            return true
        case .type(let typed):
            query += typed
            openSearch()
            return true
        }
    }

    private func activate(_ entry: ClipboardHistoryEntry) {
        if permissions.accessibility { paste(entry) } else { copy(entry) }
    }

    private func paste(_ entry: ClipboardHistoryEntry) {
        service.collapse()
        history.copyQuickEntry(entry)
    }

    private func copy(_ entry: ClipboardHistoryEntry) {
        // A copied recent entry moves to the top, so the second click of a
        // double click would copy whichever entry took its place.
        if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type),
           event.clickCount > 1 { return }
        history.copy(entry) { copied in
            if copied {
                copiedID = entry.id
            } else {
                NSSound.beep()
            }
        }
    }

    private func move(_ entry: ClipboardHistoryEntry, _ direction: ClipboardHistoryMoveDirection) {
        guard canReorder, history.canMove(entry, direction) else { return }
        history.move(entry, direction)
    }

    private func remove(_ entry: ClipboardHistoryEntry) {
        if copiedID == entry.id { copiedID = nil }
        history.remove(entry)
    }

    @ViewBuilder private func preview(_ entry: ClipboardHistoryEntry) -> some View {
        switch entry.kind {
        case .image:
            if let name = entry.imageFile {
                ClipboardThumbnailImage(source: .stored(name: name),
                                        aspectRatio: entry.imageAspectRatio,
                                        failureText: "\(text.imageEntryLabel) · \(entry.imageDimensionsLabel)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .help("\(text.imageEntryLabel) · \(entry.imageDimensionsLabel)")
            } else {
                searchText("\(text.imageEntryLabel) · \(entry.imageDimensionsLabel)", matching: searchTokens)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .files:
            // One image file shows itself; anything else reads as its name
            // or its count, the way the panel lists files.
            if entry.filePaths.count == 1, let path = entry.filePaths.first,
               ClipboardImageStore.isImageFile(atPath: path) {
                ClipboardThumbnailImage(source: .file(path: path),
                                        failureText: entry.fileNames.first ?? entry.preview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .help(path)
            } else {
                // A count of several files is no text the search reads.
                Label {
                    searchText(entry.filePaths.count == 1
                                   ? (entry.fileNames.first ?? entry.preview)
                                   : String(format: text.fileCountFormat, entry.filePaths.count),
                               matching: entry.filePaths.count == 1 ? searchTokens : [])
                } icon: {
                    Image(systemName: "folder")
                }
                .font(.system(size: 12))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .help(entry.filePaths.joined(separator: "\n"))
            }
        case .text:
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let color = entry.color {
                    ColorSwatch(color: color, size: 12)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                }
                searchText(entry.preview, matching: searchTokens)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Reads the arrow keys and Return before the search field's editor does,
/// which would otherwise spend them moving the caret, and the letters typed
/// while the field is closed. It lives as long as the page does.
private struct ClipboardKeyMonitor: NSViewRepresentable {
    var handleKey: (UInt16, String, Bool, Bool) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handleKey = handleKey
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(handleKey: handleKey)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var handleKey: (UInt16, String, Bool, Bool) -> Bool
        private var monitor: Any?

        init(handleKey: @escaping (UInt16, String, Bool, Bool) -> Bool) {
            self.handleKey = handleKey
        }

        func install(for view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                guard let self, let window = view?.window, event.window === window else { return event }
                let editor = (window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0 : nil }
                // A word being composed keeps its keys.
                guard editor?.hasMarkedText() != true else { return event }
                // Another text view, such as a dialog's, keeps its keys too.
                if editor == nil, window.firstResponder is NSTextView { return event }
                let held = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
                return self.handleKey(event.keyCode, event.characters ?? "", held, editor != nil) ? nil : event
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
