import SwiftUI

/// What a new person sees on first launch: what Side Eye found, how to open it, and the little there
/// is to learn. It reuses the Settings rows, so anything shown here looks the same there.
struct WelcomeView: View {
    @ObservedObject var model: PreferencesModel
    @ObservedObject var store: SessionStore
    let showSideEye: () -> Void
    let done: () -> Void
    @Environment(\.colorScheme) private var scheme

    /// Tall enough to show everything at once: a welcome nobody has to scroll.
    static let windowSize = CGSize(width: 480, height: 690)
    private static let apps: [Source] = [.codex, .claude, .cursor, .grok]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    VStack(alignment: .leading, spacing: 7) {
                        SettingsGroup(title: "Apps Side Eye found") { appRows }
                        Text("Side Eye reads these apps’ local files to list their chats. Nothing leaves this Mac.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 13)
                    }
                    SettingsGroup(title: "Open Side Eye") { openRows }
                    SettingsGroup(title: "What the list tells you") { statusRows }
                    SettingsGroup(title: "Keys worth knowing") { keyRows }
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 18)
            }
            Divider()
            HStack {
                Toggle("Open Side Eye at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                Spacer()
                Button("Get Started", action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 440, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome to Side Eye")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("One list for all your agent chats, at the edge of your screen.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var appRows: some View {
        ForEach(Array(Self.apps.enumerated()), id: \.element) { index, source in
            let status = model.status(for: source) ?? "Off"
            if index > 0 { SettingsDivider() }
            SettingsRow(compact: true) {
                HStack(spacing: 10) {
                    SourceAppIcon(source: source, size: 18)
                    Text(source.name).font(.system(size: 13))
                }
                .accessibilityHidden(true)
            } control: {
                HStack(spacing: 10) {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Toggle(source.name, isOn: Binding(get: { model.sourceEnabled[source] ?? false },
                                                      set: { model.setSource(source, enabled: $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel(source.name)
                        .accessibilityValue(status)
                }
            }
        }
    }

    @ViewBuilder
    private var openRows: some View {
        let taken = model.unavailableShortcuts.contains(.overlay)
        SettingsRow {
            SettingsLabel(title: "Hover the pill at the edge of your screen",
                          detail: taken ? "Another app already uses ⌃⌥Space, so that shortcut is off."
                                        : "Or press ⌃⌥Space from any app.")
        } control: {
            Button("Show Side Eye", action: showSideEye)
                .controlSize(.small)
        }
    }

    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            status(.needsInput, "An agent is waiting for your answer or approval.")
            status(.finished, "An agent finished and handed its work back.")
            status(.working, "An agent is busy. Nothing for you to do yet.")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
    }

    private func status(_ group: SessionGroup, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            GroupGlyph(group: group, colors: OverlayColors(dark: scheme == .dark))
                .frame(width: 16, height: 16)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            Text(group.label)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 70, alignment: .leading)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var keyRows: some View {
        let keys = [("↵", "Open"), ("E", "Archive"), ("L", "Later"), ("/", "Search"), ("⌘K", "All commands")]
        let column = GridItem(.flexible(), alignment: .leading)
        return LazyVGrid(columns: [column, column, column], alignment: .leading, spacing: 9) {
            ForEach(keys, id: \.0) { key, label in
                HStack(spacing: 7) {
                    ShortcutKeycap(text: key)
                    Text(label).font(.system(size: 13)).lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(label), \(key)")
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
    }
}
