import SwiftUI

enum PreferencesSection: String, CaseIterable, Identifiable {
    case general, sources, shortcuts

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    @ObservedObject var store: SessionStore
    @State private var showsOptionalSources: Bool
    @State private var showsStatusGuide: Bool
    @State private var showsMoreGlobalShortcuts: Bool

    /// `expanded` opens every disclosure from the start, for previews and render checks.
    init(model: PreferencesModel, store: SessionStore, expanded: Bool = false) {
        self.model = model
        self.store = store
        _showsOptionalSources = State(initialValue: expanded)
        _showsStatusGuide = State(initialValue: expanded)
        _showsMoreGlobalShortcuts = State(initialValue: expanded)
    }
    @Environment(\.colorScheme) private var scheme

    static let windowSize = CGSize(width: 520, height: 500)

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $model.selection) {
                ForEach(PreferencesSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 288)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch model.selection {
                    case .general: general
                    case .sources: sources
                    case .shortcuts: shortcuts
                    }
                }
                .frame(maxWidth: 464)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
            .id(model.selection)
            .defaultScrollAnchor(.top)
        }
        .frame(minWidth: 420, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: General

    private var general: some View {
        Group {
            SettingsGroup(title: "Relay") {
                settingToggle("Open at login", detail: model.loginItemNotice,
                              value: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                SettingsDivider()
                settingToggle("Show the edge pill", detail: "Hover it at the edge of your screen to open Relay.",
                              value: $model.edgeVisible)
                SettingsDivider()
                settingToggle("Nudge me about chats", detail: "A short note appears when a chat finishes or needs you.",
                              value: $model.nudgesEnabled)
                if model.hasMultipleDisplays {
                    SettingsDivider()
                    SettingsRow {
                        SettingsLabel(title: "Display", detail: "Relay sits on one display at a time.")
                    } control: {
                        Button("Move to This Display", action: model.moveOverlay)
                            .controlSize(.small)
                    }
                }
            }
            SettingsGroup(title: "Summaries") {
                settingToggle("Summarize recent chat text",
                              detail: "See what changed and what’s next. Chat text stays on this Mac.",
                              value: $model.localPreviewsEnabled)
            }
            if store.hiddenCount > 0 {
                SettingsGroup(title: "Archive") {
                    SettingsRow {
                        SettingsLabel(title: "\(store.hiddenCount) archived \(store.hiddenCount == 1 ? "chat" : "chats")",
                                      detail: "Chats come back by themselves on new activity.")
                    } control: {
                        Button("Restore All", action: model.restoreArchived)
                            .controlSize(.small)
                    }
                }
            }
            SettingsGroup(title: "Statuses") {
                SettingsDisclosure(title: "What the statuses mean", isExpanded: $showsStatusGuide) {
                    VStack(alignment: .leading, spacing: 10) {
                        statusDefinition("Needs you", "An approval, decision or answer is pending.", group: .needsInput)
                        statusDefinition("Review", "The agent handed work back and you have not read it yet.", group: .finished)
                        statusDefinition("Working", "The app reports a turn in progress.", group: .working)
                        statusDefinition("Idle", "Nothing is happening. Idle chats stay out of the Inbox until new activity.",
                                         group: .quiet)
                        statusDefinition("Read", "A reply you opened or marked read. It stays under Review, dimmed, until you archive it.")
                        statusDefinition("Inactive", "An idle chat with no reported activity for eight hours.")
                        statusDefinition("Status unavailable", "Relay has no status signal for this chat.")
                    }
                }
            }
        }
    }

    // MARK: Sources

    private func isOn(_ source: Source) -> Bool { model.sourceEnabled[source] ?? false }

    private var sources: some View {
        Group {
            SettingsGroup(title: "Apps") {
                Button("Rescan", systemImage: "arrow.clockwise", action: model.refreshSources)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("Look for chats again now")
            } content: {
                sourceRow(.codex)
                if isOn(.codex) {
                    SettingsDivider(inset: Self.optionInset)
                    settingToggle("Include scheduled automation runs", inset: Self.optionInset, compact: true,
                                  value: Binding(get: { store.showsAutomationRuns }, set: { enabled in
                                      guard enabled != store.showsAutomationRuns else { return }
                                      store.setShowsAutomationRuns(enabled)
                                      model.refreshSources()
                                  }))
                }
                SettingsDivider()
                sourceRow(.claude)
                SettingsDivider()
                sourceRow(.cursor)
                SettingsDivider()
                sourceRow(.grok)
                if isOn(.grok) { grokOptions }
            }
            SettingsGroup(title: "More sources") {
                SettingsDisclosure(title: "Instinct via Messages", isExpanded: $showsOptionalSources) {
                    VStack(spacing: 0) {
                        sourceToggle(.instinct, title: "Track Instinct replies", flush: true)
                        Divider()
                        SettingsRow(flush: true) {
                            SettingsLabel(title: "Recipient",
                                          detail: model.instinctConfigured ? "Connected" : "Choose the Instinct chat in Messages.")
                        } control: {
                            Button(model.instinctConfigured ? "Edit…" : "Connect…", action: model.configureInstinct)
                                .controlSize(.small)
                        }
                        if model.instinctConfigured {
                            Divider()
                            SettingsRow(flush: true) {
                                SettingsLabel(title: "Reply tracking", detail: "Allow Relay to check for Messages replies.")
                            } control: {
                                Button("Open Privacy Settings", action: model.openFullDiskAccess)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Options of one app sit under its row, starting where its name starts.
    private static let optionInset: CGFloat = 13 + 20 + 10

    private func sourceRow(_ source: Source) -> some View {
        SettingsRow {
            HStack(spacing: 10) {
                SourceAppIcon(source: source, size: 20)
                Text(source.name).font(.system(size: 13))
            }
            .accessibilityHidden(true)
        } control: {
            Toggle(source.name, isOn: Binding(get: { isOn(source) }, set: { model.setSource(source, enabled: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(source.name)
        }
    }

    @ViewBuilder
    private var grokOptions: some View {
        let agents = store.availableGrokAgents
        let marked = agents.filter { store.mainGrokIDs.contains($0.id) }.count
        SettingsDivider(inset: Self.optionInset)
        SettingsRow(compact: true, inset: Self.optionInset) {
            SettingsLabel(title: "Agents shown")
        } control: {
            Picker("Grok Bot agents shown", selection: Binding(get: { store.grokMainOnly }, set: store.setGrokMainOnly)) {
                Text("All").tag(false)
                Text("Main only").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 150)
        }
        SettingsDivider(inset: Self.optionInset)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Main agents")
                    .font(.system(size: 13))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !agents.isEmpty {
                    Text("\(marked) of \(agents.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(agents.isEmpty ? "No Grok Bot agents found yet."
                 : store.grokMainOnly ? "Relay shows only the agents you check."
                 : "Checked agents get a Main badge. Choose Main only to hide the rest.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !agents.isEmpty { agentGrid(agents) }
        }
        .padding(.leading, Self.optionInset)
        .padding(.trailing, 13)
        .padding(.top, 9)
        .padding(.bottom, 11)
    }

    /// Two columns once the roster is long, read down the first column and then the second.
    private func agentGrid(_ agents: [GrokAgent]) -> some View {
        let columns = agents.count > 8 ? 2 : 1
        let rows = (agents.count + columns - 1) / columns
        return HStack(alignment: .top, spacing: 14) {
            ForEach(0..<columns, id: \.self) { column in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(agents.dropFirst(column * rows).prefix(rows)) { agent in
                        Toggle(isOn: Binding(get: { store.mainGrokIDs.contains(agent.id) },
                                             set: { store.setGrokMain(id: agent.id, isMain: $0) })) {
                            Text(agent.title)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .toggleStyle(.checkbox)
                        .frame(height: 22, alignment: .leading)
                        .help(agent.title)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        Group {
            SettingsGroup(title: "From any app") {
                shortcutRow("Show or hide Relay", keys: ["⌃⌥Space"], shortcut: .overlay)
                SettingsDivider()
                shortcutRow("Open the command palette", keys: ["⌃⌥K"], shortcut: .palette)
                SettingsDivider()
                SettingsDisclosure(title: "More", isExpanded: $showsMoreGlobalShortcuts) {
                    VStack(spacing: 0) {
                        shortcutRow("Open chat 1 to 9", detail: unavailableRowShortcuts, keys: ["⌃⌥1", "to", "⌃⌥9"], flush: true)
                        Divider()
                        shortcutRow("Jump to any row by number", keys: ["⌃⌥0"], shortcut: .jumpNumber, flush: true)
                        Divider()
                        shortcutRow("Show or hide previews", keys: ["⌃⌥D"], shortcut: .details, flush: true)
                        Divider()
                        shortcutRow("Review the next chat", keys: ["⌃⌥↵"], shortcut: .next, flush: true)
                        Divider()
                        shortcutRow("Archive a chat", keys: ["⌃⌥A"], shortcut: .archive, flush: true)
                    }
                }
            }
            SettingsGroup(title: "Open and find") {
                shortcutRow("Open the selected chat", keys: ["↵"])
                SettingsDivider()
                shortcutRow("Open chat 1 to 9", keys: ["1", "to", "9"])
                SettingsDivider()
                shortcutRow("Jump to any row by number", keys: ["0"])
                SettingsDivider()
                shortcutRow("Search chats", keys: ["/"])
                SettingsDivider()
                shortcutRow("Command palette, with every command", keys: ["⌘K"])
            }
            SettingsGroup(title: "Triage") {
                shortcutRow("Archive", keys: ["E"])
                SettingsDivider()
                shortcutRow("Archive all read chats", keys: ["⇧E"])
                SettingsDivider()
                shortcutRow("Move to Later, or back", keys: ["L"])
                SettingsDivider()
                shortcutRow("Later until a time", keys: ["H"])
                SettingsDivider()
                shortcutRow("Favorite or unfavorite", keys: ["F"])
                SettingsDivider()
                shortcutRow("Mark read or unread", keys: ["⌘U"])
                SettingsDivider()
                shortcutRow("Undo the last move", keys: ["Z"])
                SettingsDivider()
                shortcutRow("Restore from Archive", keys: ["R"])
            }
            SettingsGroup(title: "Move around") {
                shortcutRow("Move selection", keys: ["↑", "↓", "or", "J", "K"])
                SettingsDivider()
                shortcutRow("Jump between groups", keys: ["⌥↑", "⌥↓"])
                SettingsDivider()
                shortcutRow("Switch between Inbox, Favorites and Later", keys: ["Tab"])
                SettingsDivider()
                shortcutRow("Show or hide previews", keys: ["D"])
                SettingsDivider()
                shortcutRow("Leave search or close Relay", keys: ["esc"])
            }
        }
    }

    private func sourceToggle(_ source: Source, title: String? = nil, flush: Bool = false) -> some View {
        settingToggle(title ?? source.name, flush: flush,
                      value: Binding(get: { isOn(source) }, set: { model.setSource(source, enabled: $0) }))
    }

    private var unavailableRowShortcuts: String? {
        let rows = Shortcut.numbers.compactMap { Shortcut(rawValue: $0) }
            .filter { model.unavailableShortcuts.contains($0) }
            .map(\.glyph)
        if rows.isEmpty { return nil }
        return "Unavailable: \(rows.joined(separator: ", "))"
    }

    private func settingToggle(_ title: String, detail: String? = nil, inset: CGFloat = 13, compact: Bool = false,
                               flush: Bool = false, value: Binding<Bool>) -> some View {
        SettingsRow(compact: compact, inset: inset, flush: flush) {
            SettingsLabel(title: title, detail: detail)
                .accessibilityHidden(true)
        } control: {
            Toggle(title, isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityHint(detail ?? "")
        }
    }

    /// One shortcut per row. Keys are separate caps; "or" and "to" between them read as plain text.
    private func shortcutRow(_ title: String, detail: String? = nil, keys: [String], shortcut: Shortcut? = nil,
                             flush: Bool = false) -> some View {
        let unavailable = shortcut.map { model.unavailableShortcuts.contains($0) } == true
        return SettingsRow(compact: true, flush: flush) {
            SettingsLabel(title: title, detail: unavailable ? "Unavailable on this Mac." : detail)
        } control: {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    if key == "or" || key == "to" {
                        Text(key).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        ShortcutKeycap(text: key)
                    }
                }
            }
            .opacity(unavailable ? 0.45 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(unavailable ? "Unavailable on this Mac" : keys.joined(separator: " "))
    }

    /// A status, with the icon the sidebar uses for it where it has one.
    private func statusDefinition(_ title: String, _ detail: String, group: SessionGroup? = nil) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if let group { GroupGlyph(group: group, colors: OverlayColors(dark: scheme == .dark)) } else { Color.clear }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsGroup<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                accessory
            }
            // Titles line up with the text of the rows beneath them.
            .padding(.horizontal, 13)
            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.54))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(contrast == .increased ? 0.8 : 0.38))
                    .allowsHitTesting(false)
            }
        }
    }
}

extension SettingsGroup where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

/// A row. `inset` moves an option under the name of the app it belongs to; `flush` is for rows inside
/// a disclosure, which already has the card's padding.
private struct SettingsRow<Label: View, Control: View>: View {
    var compact = false
    var inset: CGFloat = 13
    var flush = false
    @ViewBuilder let label: Label
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            // The label takes every spare point, so a control must keep its own size or a button
            // collapses to an empty sliver.
            control
                .fixedSize()
        }
        .padding(.leading, flush ? 0 : inset)
        .padding(.trailing, flush ? 0 : 13)
        .padding(.vertical, compact ? 5 : 9)
        .frame(minHeight: compact ? 32 : 40)
    }
}

private struct SettingsDivider: View {
    var inset: CGFloat = 13

    var body: some View {
        Divider()
            .padding(.leading, inset)
            .padding(.trailing, 13)
    }
}

/// A row that opens to show more, inside a card like any other row.
private struct SettingsDisclosure<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 13)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                Divider().padding(.horizontal, 13)
                content
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
            }
        }
    }
}

private struct SettingsLabel: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13))
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One key, drawn like a key so a row of them reads as a combination.
private struct ShortcutKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary.opacity(0.78))
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)) }
            .fixedSize()
    }
}
