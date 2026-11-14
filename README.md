# Relay

Relay is a native macOS menu bar app for keeping parallel agent conversations within reach. The bundled build is for Apple silicon and requires macOS 14 or later. Open Relay.app and hover over the small tab on the right edge. Open Settings from the sidebar’s more button or the Relay menu bar icon.

Drag the edge pill up or down to dock it at a different height. Relay saves its position on each display. Hover to grow the pill into the sidebar, and move away to shrink it back. Relay uses native Force Touch feedback on reveal and after a drag settles. Its animations follow the system Reduce Motion setting.

The sidebar opens with one line per chat. Press **D** or use the preview button to add a preview under every chat: its latest summary, or where it runs until a summary exists. Press **D** again to hide them all. Relay remembers your choice.

## Switching

| Shortcut | Action |
| --- | --- |
| ⌃⌥Space | Open or close the sidebar from any app. |
| ⌘K, or ⌃⌥K from any app | Open the command palette. Type a chat’s name to switch to it, or a command to run it. Each command shows its key. |
| / | Search the current list. Results are one flat list, best match first, and Return opens the top one. |
| 1–9 | Open rows 1–9 from top to bottom. |
| 0 | Jump to any numbered row. Type the number, then press Return. |
| D | Show or hide previews. |
| E | Archive the selected chat. |
| ⇧E | Archive every reply you have already read, in one step. Z undoes it. |
| R | In Archive, restore the selected chat to the Inbox. |
| L | Move the selected chat to Later, or back to the Inbox from the Later list. |
| F | Favorite the selected chat, or unfavorite it. P works too. |
| H | Later until a time: in an hour, this evening, tomorrow morning or next week. The chat comes back by itself, marked unread. |
| J / K | Move down or up, like ↓ and ↑. |
| Z | Undo the last move. ⌘Z works too. |
| ⌥↑ / ⌥↓ | Jump to the previous or next group. |
| Tab | Switch between Inbox, Favorites and Later. |

Single keys act on the list when Relay is open. Letters are commands, so typing only searches after / or inside ⌘K. Opening Relay with a keyboard shortcut shows it instantly; hovering the pill grows it out of the edge. See **Settings → Shortcuts** for shortcuts that work from other apps.

Relay has two views. The **Inbox** is where you triage: it groups chats by what the agent is doing, **Needs you**, **Review** and **Working**, each newest first, with a tinted header that stays pinned while you scroll. Reading a chat never moves it: an unread chat has a bold title and a dot, and reading it dims the row and removes the dot. A reply you have read stays under Review until you archive it. The Review header counts only unread replies and offers **Archive N read** (⇧E) for the rest. A chat moves only when its agent asks, finishes or starts a turn, or when you archive it or move it to Later. Idle chats stay out of the Inbox; search and ⌘K still find them, and new activity brings them back. When nothing needs you, the list says so at the top. **Favorites** is the lasting list of chats you keep coming back to. Favorite a chat with F, the star that replaces its time on hover, ⌘K or the right-click menu. It keeps its place in the Inbox, and Favorites lists it in the order you added it until you unfavorite it, even after you archive it or its app stops reporting it. Up to 30. **Later** is one list ordered by when chats come back, soonest first; every row shows its return time, or “No date” when it waits for you. Chats in Later stay out of the attention count and nudges until you move them back. Status shows once per view: group headers in the Inbox, and a status icon on each row in Favorites, Later, search results and ⌘K. The active tab stays selected between sidebar openings.

Use Up and Down as soon as the sidebar opens, including on hover. The next chat to act on is selected when the sidebar opens, so Return opens it: a new input request first, then an unread reply. The bar under the list shows the keys that list is for: Later, Archive and Open in the Inbox, Unfavorite in Favorites, Restore in Archive. After you archive a chat or move it to Later, the same bar offers Z to undo it. Use ⌘U to mark read or unread. Escape exits search or closes the sidebar. Choose **Show Archive** from the Relay menu bar icon, or **Go to Archive** in ⌘K, to browse archived chats. Press R there to restore the selected chat. An archived chat comes back by itself, unread, when its agent finishes a new turn, starts one or asks for input, so long-lived chats such as Cursor projects never hide new work. A chat you archive while its agent is still working comes back when that run ends. Add a chat URL from the same menu bar icon.

A newly completed turn or input request produces a quiet edge nudge. The edge pill shows the number of chats that still need attention. Pending input requests count until they’re resolved or archived, even after you read them.

Row numbers follow the displayed order. Review rows show the age of their last completion. Other rows show the age of their latest reported activity. Hover on a row to see its status, the full local date and time and its summary when available.

**Needs you** stays visible while a decision or answer is pending. **Review** holds work the agent has handed back; unread ones are new. **Working** marks an active turn reported by the source. Grok Bot keeps no running flag on disk, so Relay counts a Grok chat as working while your message is the newest one, and for up to 15 minutes after a progress note such as “The search is running”. **Idle** means the source has reported no new update or request, and **Inactive** marks idle chats with eight hours without reported activity. **Read** means you opened an update in Relay, marked it read, or its source marked it read. A read reply stays in Review, dimmed, until you archive it; Grok Bot and Cursor report it as read rather than idle.

**Summarize recent chat text** uses a local model to write one sentence about the latest request, result, and any supported next action. Relay reads bounded excerpts from the apps’ local caches and keeps the summary in memory. The model runs only when needed and shuts down when idle. Rows rely on available source metadata when a recent transcript is absent.

Completion and input nudges show the same sentence. If it finishes after the nudge appears, Relay adds it to the visible card.

## Sources

| Source | Discovery and signals | Switching |
| --- | --- | --- |
| Codex desktop | Up to 32 non-archived chats active in the last 24 hours. Completion and read state come from local history. Input requests use the installed app’s live status when available. | Exact thread link |
| Claude Code | Live Desktop and terminal sessions, plus available CLI background jobs. Working, waiting, and completion come from the session registry and CLI. | Exact Desktop link or terminal TTY. Terminal switching can require macOS Automation access. Ghostty needs 1.4 or later for TTY lookup. |
| Cursor | Local agent chats and cloud agents active in the last 48 hours. Status comes from available generation, approval, and unread fields. | Exact local or cloud agent link |
| Grok Bot | Agent chats active in the last 48 hours. The local roster supplies unread replies and requests for input. | Exact agent link. The roster identifies the agent even when an unread reply is in one of its subthreads. |
| Instinct | Enter the one-to-one recipient under **Sources → Set Instinct recipient**. Grant Relay Full Disk Access in System Settings to detect unread replies in Messages. | Native Messages recipient link |

Relay scans local metadata about every four seconds and keeps archived chats and source settings in local preferences. The Messages query reads timestamps and delivery flags for the configured conversation. Changes to apps’ local formats can affect discovery or state reporting.

To show only your main Grok Bot agents, open **Settings → Sources**, check them in the Grok Bot list, and select **Main agents** under **Show in Relay**. The sidebar shows a **Main** badge on your marked agents.

Scheduled Codex automation runs are hidden by default. Turn on **Show automation runs** under **Settings → Sources** to include them in the sidebar, attention count, and nudges.

## Build and check

Install Xcode or its command-line tools, then run:

```sh
./Scripts/package.sh /path/to/Relay.app
/path/to/Relay.app/Contents/MacOS/Relay --self-test
/path/to/Relay.app/Contents/MacOS/Relay --ui-check
/path/to/Relay.app/Contents/MacOS/Relay --diagnostics
```

The diagnostics report counts, route availability, and the number of summaries generated locally. Run the UI check with the main app closed so it can register the same shortcuts. Add `--pointer-check` to test the real global shortcut and pointer hover, which briefly moves the pointer.

For a build with local inference, set `RELAY_SUMMARY_MODEL` to the verified GGUF file in [the model notes](ModelLicenses/RelaySummary.md) when running the packaging script. Relay uses an existing compatible `llama-server` and connects over a private Unix socket.

[Linear’s design refresh](https://linear.app/now/behind-the-latest-design-refresh), [Mobbin’s navigation references](https://mobbin.com/blog/how-to-use-mobbin-mcp), and the [Wispr Flow edge bar](https://docs.wisprflow.ai/articles/1790396454-move-and-dock-the-flow-bar-on-desktop) informed the overlay. [Codex deep links](https://learn.chatgpt.com/docs/reference/commands#deep-links) and the [Claude Code agent view](https://code.claude.com/docs/en/agent-view#read-session-state-from-a-script) document the underlying entry points.
