import SwiftUI

enum PreferencesSection: String, CaseIterable, Identifiable {
    case general, sources, shortcuts

    var id: Self { self }
    /// The pane that lists apps is called Apps everywhere the person sees it.
    var title: String { self == .sources ? "Apps" : rawValue.capitalized }
}

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    @ObservedObject var store: SessionStore
    @State private var showsOptionalSources: Bool
    @State private var showsStatusGuide: Bool
    @State private var showsAgentChoices: Bool
    /// The main agents when the pane opened. They lead the list and stay put while you check and
    /// uncheck, so nothing jumps under the pointer.
    @State private var leadingAgentIDs: Set<String>?
    @State private var rescan = RescanState.idle

    private enum RescanState { case idle, scanning, done }

    /// `expanded` opens every disclosure from the start, for previews and render checks.
    init(model: PreferencesModel, store: SessionStore, expanded: Bool = false) {
        self.model = model
        self.store = store
        _showsOptionalSources = State(initialValue: expanded)
        _showsStatusGuide = State(initialValue: expanded)
        _showsAgentChoices = State(initialValue: expanded)
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
                        Divider()
                        // These are labels a row can carry, not further statuses, so they start at the edge.
                        Text("A row can also say")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        statusDefinition("Read", "A reply you opened or marked read. It stays under Review, dimmed, until you archive it.")
                        statusDefinition("Inactive", "An idle chat with no reported activity for eight hours.")
                        statusDefinition("Status unavailable", "Relay has no status signal for this chat.")
                    }
                }
            }
        }
    }

    // MARK: Apps

    private func isOn(_ source: Source) -> Bool { model.sourceEnabled[source] ?? false }

    private var sources: some View {
        Group {
            SettingsGroup(title: "Relay watches") {
                rescanButton
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
            SettingsGroup(title: "More apps") {
                SettingsDisclosure(title: "Instinct via Messages", isExpanded: $showsOptionalSources) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("An agent you reach by text message. Relay watches one Messages conversation for its replies.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 8)
                        Divider()
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
        .onAppear { if leadingAgentIDs == nil { leadingAgentIDs = store.mainGrokIDs } }
    }

    /// Rescan answers back: it says it is scanning, then that it has, once a new scan arrives.
    private var rescanButton: some View {
        Button {
            guard rescan != .scanning else { return }
            let before = store.lastScan
            rescan = .scanning
            model.refreshSources()
            Task { @MainActor in
                for _ in 0..<40 where store.lastScan == before { try? await Task.sleep(for: .milliseconds(100)) }
                rescan = store.lastScan == before ? .idle : .done
                try? await Task.sleep(for: .seconds(3))
                if rescan == .done { rescan = .idle }
            }
        } label: {
            switch rescan {
            case .idle: Label("Rescan", systemImage: "arrow.clockwise")
            case .scanning: Label("Scanning…", systemImage: "arrow.clockwise")
            case .done: Label("Scanned just now", systemImage: "checkmark")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .help("Look for chats again now. Relay also scans by itself every few seconds.")
    }

    /// Options of one app sit under its row, starting where its name starts.
    private static let optionInset: CGFloat = 13 + 20 + 10

    /// What the last scan found for an app, or why it found nothing.
    private func sourceStatus(_ source: Source) -> String? {
        guard isOn(source) else { return nil }
        if model.sourcePresent[source] == false { return "Not found on this Mac" }
        if store.isLoading { return "Looking for chats…" }
        let found = store.foundCount(for: source)
        if found == 0 { return source == .cursor || source == .grok ? "No chats in the last 48 hours" : "No recent chats" }
        let chats = "\(found) \(found == 1 ? "chat" : "chats")"
        guard source == .grok, store.grokMainOnly else { return chats }
        return "\(chats), \(store.foundCount(for: .grok, mainOnly: true)) from main agents"
    }

    private func sourceRow(_ source: Source) -> some View {
        let status = sourceStatus(source)
        return SettingsRow {
            HStack(spacing: 10) {
                SourceAppIcon(source: source, size: 20)
                SettingsLabel(title: source.name, detail: status)
            }
            .accessibilityHidden(true)
        } control: {
            Toggle(source.name, isOn: Binding(get: { isOn(source) }, set: { model.setSource(source, enabled: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(source.name)
                .accessibilityValue(status ?? "")
        }
    }

    @ViewBuilder
    private var grokOptions: some View {
        let agents = orderedAgents
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
        if store.grokMainOnly {
            SettingsDivider(inset: Self.optionInset)
            settingToggle("Show new agents automatically", inset: Self.optionInset, compact: true,
                          value: Binding(get: { store.includesNewGrokAgents }, set: store.setIncludesNewGrokAgents))
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
                Text(agents.isEmpty ? "No Grok Bot agents found yet." : "Relay shows only the agents you check.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if !agents.isEmpty { agentGrid(agents) }
            }
            .padding(.leading, Self.optionInset)
            .padding(.trailing, 13)
            .padding(.top, 9)
            .padding(.bottom, 11)
        } else if !agents.isEmpty {
            // With every agent shown, main agents only earn a badge, so the list stays folded.
            SettingsDivider(inset: Self.optionInset)
            SettingsDisclosure(title: "Choose main agents", detail: "\(marked) of \(agents.count)",
                               inset: Self.optionInset, isExpanded: $showsAgentChoices) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Checked agents get a Main badge. Choose Main only to hide the rest.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    agentGrid(agents)
                }
            }
        }
    }

    /// Main agents first, then agents created this week, then the rest; each part by name.
    private var orderedAgents: [GrokAgent] {
        let agents = store.availableGrokAgents
        let leading = leadingAgentIDs ?? store.mainGrokIDs
        let now = Date()
        func rank(_ agent: GrokAgent) -> Int { leading.contains(agent.id) ? 0 : agent.isNew(now: now) ? 1 : 2 }
        return (0...2).flatMap { level in agents.filter { rank($0) == level } }
    }

    /// Two columns once the roster is long, read down the first column and then the second.
    private func agentGrid(_ agents: [GrokAgent]) -> some View {
        let columns = agents.count > 8 ? 2 : 1
        let rows = (agents.count + columns - 1) / columns
        let now = Date()
        return HStack(alignment: .top, spacing: 14) {
            ForEach(0..<columns, id: \.self) { column in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(agents.dropFirst(column * rows).prefix(rows)) { agent in
                        let isMain = store.mainGrokIDs.contains(agent.id)
                        Toggle(isOn: Binding(get: { store.mainGrokIDs.contains(agent.id) },
                                             set: { store.setGrokMain(id: agent.id, isMain: $0) })) {
                            HStack(spacing: 6) {
                                Text(agent.title)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if agent.isNew(now: now) && !isMain {
                                    Text("New")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .padding(.horizontal, 5)
                                        .frame(height: 15)
                                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                                        .fixedSize()
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .toggleStyle(.checkbox)
                        .frame(height: 22, alignment: .leading)
                        .help(agent.title)
                        .accessibilityValue(agent.isNew(now: now) && !isMain ? "New" : "")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Shortcuts

    /// Only the shortcuts Relay cannot show elsewhere. Everything that works inside Relay is listed,
    /// with its key, in the command palette.
    private var shortcuts: some View {
        Group {
            SettingsGroup(title: "From any app") {
                shortcutRow("Show or hide Relay", keys: ["⌃⌥Space"], shortcut: .overlay)
                SettingsDivider()
                shortcutRow("Open the command palette", keys: ["⌃⌥K"], shortcut: .palette)
                SettingsDivider()
                shortcutRow("Review the next chat", keys: ["⌃⌥↵"], shortcut: .next)
                SettingsDivider()
                shortcutRow("Archive a chat", keys: ["⌃⌥A"], shortcut: .archive)
                SettingsDivider()
                shortcutRow("Open chat 1 to 9", detail: unavailableRowShortcuts, keys: ["⌃⌥1–9"])
                SettingsDivider()
                shortcutRow("Jump to any row by number", keys: ["⌃⌥0"], shortcut: .jumpNumber)
                SettingsDivider()
                shortcutRow("Show or hide previews", keys: ["⌃⌥D"], shortcut: .details)
            }
            SettingsGroup(title: "In Relay") {
                shortcutRow("Command palette",
                            detail: "Lists every command with its key. Single letters such as E, L and F act on the selected chat.",
                            keys: ["⌘K"])
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
        return "Another app already uses \(rows.map { "⌃⌥" + $0 }.joined(separator: ", "))."
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

    /// One shortcut per row, drawn as one key cap. A shortcut another app holds says so.
    private func shortcutRow(_ title: String, detail: String? = nil, keys: [String], shortcut: Shortcut? = nil,
                             flush: Bool = false) -> some View {
        let unavailable = shortcut.map { model.unavailableShortcuts.contains($0) } == true
        return SettingsRow(compact: true, flush: flush) {
            SettingsLabel(title: title, detail: unavailable
                          ? "Another app already uses this shortcut. Free it there, then reopen Relay." : detail)
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
        .accessibilityValue(unavailable ? "In use by another app" : keys.joined(separator: " "))
    }

    /// A status with the icon the sidebar uses for it, or a plain label definition without one.
    private func statusDefinition(_ title: String, _ detail: String, group: SessionGroup? = nil) -> some View {
        HStack(alignment: .top, spacing: 9) {
            if let group {
                GroupGlyph(group: group, colors: OverlayColors(dark: scheme == .dark))
                    .frame(width: 16, height: 16)
            }
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

/// A row that opens in place to show more. The triangle sits on the left, as it does across macOS;
/// a chevron on the right would promise another screen.
private struct SettingsDisclosure<Content: View>: View {
    let title: String
    var detail: String? = nil
    /// Where the title starts. The triangle hangs to its left.
    var inset: CGFloat = 13 + SettingsDisclosure.triangleWidth
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var triangleWidth: CGFloat { 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 0) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: Self.triangleWidth, alignment: .leading)
                    Text(title).font(.system(size: 13))
                    Spacer(minLength: 8)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, inset - Self.triangleWidth)
                .padding(.trailing, 13)
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                Divider()
                    .padding(.leading, inset)
                    .padding(.trailing, 13)
                content
                    .padding(.leading, inset)
                    .padding(.trailing, 13)
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
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary.opacity(0.78))
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)) }
            .fixedSize()
    }
}
