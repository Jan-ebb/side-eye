import SwiftUI

enum PreferencesSection: String, CaseIterable, Identifiable {
    case general, sources, shortcuts

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    @ObservedObject var store: SessionStore
    @State private var showsOptionalSources = false
    @State private var showsStatusGuide = false
    @State private var showsMoreGlobalShortcuts = false

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
                VStack(alignment: .leading, spacing: 16) {
                    switch model.selection {
                    case .general: general
                    case .sources: sources
                    case .shortcuts: shortcuts
                    }
                }
                .frame(maxWidth: 464)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .id(model.selection)
            .defaultScrollAnchor(.top)
        }
        .frame(minWidth: 420, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var general: some View {
        Group {
            SettingsGroup(title: "Overlay") {
                settingToggle("Show edge pill", detail: "Hover at the edge of your display to open Relay.",
                              value: $model.edgeVisible)
                SettingsDivider()
                settingToggle("Show nudges", detail: "See when a chat finishes or needs input.",
                              value: $model.nudgesEnabled)
                if model.hasMultipleDisplays {
                    SettingsDivider()
                    SettingsRow {
                        SettingsLabel(title: "Overlay display", detail: "Move Relay to the display under your pointer.")
                    } control: {
                        Button("Move here", action: model.moveOverlay)
                            .controlSize(.small)
                    }
                }
            }
            SettingsGroup(title: "Chat summaries") {
                settingToggle("Summarize recent chat text",
                              detail: "See what changed and what’s next. Chat text stays on this Mac.",
                              value: $model.localPreviewsEnabled)
            }
            SettingsGroup(title: "Startup") {
                settingToggle("Open at login", detail: model.loginItemNotice,
                              value: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
            }
            if store.hiddenCount > 0 {
                SettingsGroup(title: "Archived chats") {
                    SettingsRow {
                        SettingsLabel(title: "\(store.hiddenCount) archived")
                    } control: {
                        Button("Restore all", action: model.restoreArchived)
                            .controlSize(.small)
                    }
                }
            }
            statusGuide
        }
    }

    private var sources: some View {
        Group {
            grokSettings
            SettingsGroup(title: "Other sources") {
                sourceToggle(.codex)
                SettingsDivider()
                settingToggle("Show automation runs", detail: "Include scheduled Codex runs in Relay.",
                              value: Binding(get: { store.showsAutomationRuns }, set: { enabled in
                                  guard enabled != store.showsAutomationRuns else { return }
                                  store.setShowsAutomationRuns(enabled)
                                  model.refreshSources()
                              }))
                SettingsDivider()
                sourceToggle(.claude)
                SettingsDivider()
                sourceToggle(.cursor)
            }
            DisclosureGroup(isExpanded: $showsOptionalSources) {
                SettingsGroup(title: "Instinct via Messages") {
                    sourceToggle(.instinct)
                    SettingsDivider()
                    SettingsRow {
                        SettingsLabel(title: "Recipient",
                                      detail: model.instinctConfigured ? "Connected" : "Choose the Instinct chat in Messages.")
                    } control: {
                        Button(model.instinctConfigured ? "Edit…" : "Connect…", action: model.configureInstinct)
                            .controlSize(.small)
                    }
                    if model.instinctConfigured {
                        SettingsDivider()
                        SettingsRow {
                            SettingsLabel(title: "Reply tracking", detail: "Allow Relay to check for Messages replies.")
                        } control: {
                            Button("Open privacy settings", action: model.openFullDiskAccess)
                                .controlSize(.small)
                        }
                    }
                }
                .padding(.top, 10)
            } label: {
                Text("Additional sources")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 2)
            Button("Refresh chats", systemImage: "arrow.clockwise", action: model.refreshSources)
                .controlSize(.small)
                .padding(.horizontal, 2)
        }
    }

    private var grokSettings: some View {
        let agents = store.availableGrokSessions
        let markedCount = agents.filter { store.mainGrokIDs.contains($0.id) }.count
        return SettingsGroup(title: "Grok Bot") {
            sourceToggle(.grok, title: "Track chats")
            SettingsDivider()
            SettingsRow {
                SettingsLabel(title: "Show in Relay")
            } control: {
                Picker("Grok Bot agents shown", selection: Binding(get: { store.grokMainOnly },
                                                                  set: store.setGrokMainOnly)) {
                    Text("All agents").tag(false)
                    Text("Main agents").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 204)
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Mark main agents")
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if !agents.isEmpty {
                        Text("\(markedCount) marked")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if agents.isEmpty {
                    Text(model.sourceEnabled[.grok] == true
                         ? "No recent Grok Bot agents. Open a chat to add it here."
                         : "Turn on Grok Bot to find your agents.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if markedCount == 0 {
                        Text(store.grokMainOnly
                             ? "Check an agent to show it in Relay."
                             : "Check the agents you want to keep when filtering.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(agents) { agent in
                            Toggle(isOn: Binding(get: { store.mainGrokIDs.contains(agent.id) },
                                                 set: { store.setGrokMain(id: agent.id, isMain: $0) })) {
                                Text(agent.title)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .toggleStyle(.checkbox)
                            .frame(minHeight: 26, alignment: .leading)
                            .help(agent.title)
                        }
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.top, 11)
            .padding(.bottom, 9)
        }
    }

    private var shortcuts: some View {
        Group {
            SettingsGroup(title: "From any app") {
                shortcutRow("Show or hide Relay", key: "⌃⌥Space", shortcut: .overlay)
                SettingsDivider()
                shortcutRow("Open the command palette", detail: "Find any chat or command by typing.",
                            key: "⌃⌥K", shortcut: .palette)
            }
            SettingsGroup(title: "When Relay is open") {
                shortcutRow("Command palette", detail: "Every command shows its key here.", key: "⌘K")
                SettingsDivider()
                shortcutRow("Open rows 1 through 9", key: "1–9")
                SettingsDivider()
                shortcutRow("Jump to a row", detail: "Type a row number, then press Return.", key: "0")
                SettingsDivider()
                shortcutRow("Show or hide previews", key: "D")
                SettingsDivider()
                shortcutRow("Archive the selected chat", key: "E")
                SettingsDivider()
                shortcutRow("Archive all read chats", detail: "Clears every reply you have already read out of the Inbox.",
                            key: "⇧E")
                SettingsDivider()
                shortcutRow("Restore a chat from Archive", key: "R")
                SettingsDivider()
                shortcutRow("Move to or from Later", key: "L")
                SettingsDivider()
                shortcutRow("Later until a time", detail: "The chat comes back by itself, marked unread.", key: "H")
                SettingsDivider()
                shortcutRow("Favorite or unfavorite a chat", detail: "A favorite stays where it is and also appears under Favorites.", key: "F")
                SettingsDivider()
                shortcutRow("Search chats", key: "/")
                SettingsDivider()
                shortcutRow("Move selection", key: "J  K  or  ↑  ↓")
                SettingsDivider()
                shortcutRow("Jump between groups", key: "⌥↑  ⌥↓")
                SettingsDivider()
                shortcutRow("Open the selected chat", key: "Return")
                SettingsDivider()
                shortcutRow("Mark read or unread", key: "⌘U")
                SettingsDivider()
                shortcutRow("Undo the last move", key: "Z")
                SettingsDivider()
                shortcutRow("Exit search or close Relay", key: "Esc")
            }
            DisclosureGroup(isExpanded: $showsMoreGlobalShortcuts) {
                SettingsGroup(title: "Global shortcuts") {
                    shortcutRow("Open rows 1 through 9", detail: unavailableRowShortcuts, key: "⌃⌥1…9")
                    SettingsDivider()
                    shortcutRow("Jump to a row", key: "⌃⌥0", shortcut: .jumpNumber)
                    SettingsDivider()
                    shortcutRow("Show or hide previews", key: "⌃⌥D", shortcut: .details)
                    SettingsDivider()
                    shortcutRow("Review the next chat", key: "⌃⌥Return", shortcut: .next)
                    SettingsDivider()
                    shortcutRow("Archive a chat", key: "⌃⌥A", shortcut: .archive)
                }
                .padding(.top, 10)
            } label: {
                Text("More shortcuts from any app")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 2)
        }
    }

    private var statusGuide: some View {
        DisclosureGroup(isExpanded: $showsStatusGuide) {
            VStack(alignment: .leading, spacing: 9) {
                statusDefinition("Needs you", "An approval, decision, or answer is pending.")
                statusDefinition("Review", "The agent handed work back and you have not read it yet.")
                statusDefinition("Read", "A reply you opened or marked read. It stays under Review, dimmed, until you archive it.")
                statusDefinition("Working", "The source reports an active turn.")
                statusDefinition("Idle", "Nothing is happening. Idle chats stay out of the Inbox until new activity.")
                statusDefinition("Inactive", "An idle chat with no reported activity for eight hours.")
                statusDefinition("Status unavailable", "Relay has no status signal for this chat.")
            }
            .padding(.top, 10)
        } label: {
            Text("What statuses mean")
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 2)
    }

    private func sourceToggle(_ source: Source, title: String? = nil) -> some View {
        settingToggle(title ?? source.name,
                      value: Binding(get: { model.sourceEnabled[source] ?? false },
                                     set: { model.setSource(source, enabled: $0) }))
    }

    private var unavailableRowShortcuts: String? {
        let rows = Shortcut.numbers.compactMap { Shortcut(rawValue: $0) }
            .filter { model.unavailableShortcuts.contains($0) }
            .map(\.glyph)
        if rows.isEmpty { return nil }
        return "Unavailable shortcuts \(rows.joined(separator: ", "))"
    }

    private func settingToggle(_ title: String, detail: String? = nil, value: Binding<Bool>) -> some View {
        SettingsRow {
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

    private func shortcutRow(_ title: String, detail: String? = nil, key: String,
                             shortcut: Shortcut? = nil) -> some View {
        SettingsRow(compact: true) {
            SettingsLabel(title: title, detail: shortcut.map { model.unavailableShortcuts.contains($0) } == true
                          ? "Unavailable on this Mac." : detail)
        } control: {
            ShortcutKeycap(text: key)
        }
    }

    private func statusDefinition(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
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

private struct SettingsRow<Label: View, Control: View>: View {
    var compact = false
    @ViewBuilder let label: Label
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            control
        }
        .padding(.horizontal, 13)
        .padding(.vertical, compact ? 4 : 9)
        .frame(minHeight: compact ? 27 : 40)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 13)
            .padding(.trailing, 13)
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

private struct ShortcutKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}
