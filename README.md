# Relay

Relay is a native macOS menu bar app for keeping parallel agent conversations within reach. The bundled build is for Apple silicon and requires macOS 14 or later. Open Relay.app and hover over the small tab on the right edge. Open Settings from the sidebar’s more button or the Relay menu bar icon.

Drag the edge pill up or down to dock it at a different height. Relay saves its position on each display. Hover to grow the pill into the sidebar, and move away to shrink it back. Relay uses native Force Touch feedback on reveal and after a drag settles. Its animations follow the system Reduce Motion setting.

The sidebar opens in **Compact**, with one line per chat and a short summary for **Up next** when available. Press **D** or use the layout button to switch to **Briefing**, which adds a summary line under each row. Relay remembers the layout you choose.

## Switching

| Shortcut | Action |
| --- | --- |
| ⌃⌥Space | Open or close the sidebar from any app. |
| / | Search the current list. |
| 1–9 | Open rows 1–9 from top to bottom. |
| 0 | Jump to any numbered row. Type the number, then press Return. |
| D | Switch between Compact and Briefing. |
| E | Archive the selected chat. |
| L | Move the selected chat to Later, or back to All from the Later list. |
| Tab | Move to the next group, then on to Later. Shift-Tab goes back. |
| → / ← | Show or hide quiet chats. |

Single keys act on the list when Relay is open. While searching, they type into the query. See **Settings → Shortcuts** for shortcuts that work from other apps.

**All** groups chats by what they ask of you: **Needs input**, **To review**, **Working** and **Quiet**, each newest first. Quiet starts folded so the chats that need you stay in view; click its header or press → to show it, and Relay remembers your choice. Search always looks inside Quiet. When nothing needs you, the list says so at the top. **Later** groups its chats the same way. Chats in Later stay out of the attention count and nudges until you move them back. The active tab stays selected between sidebar openings.

Use Up and Down as soon as the sidebar opens, including on hover. The next chat to act on is selected when the sidebar opens, so Return opens it. The bar under the list shows the keys for the selected chat. After you archive a chat or move it to Later, the same bar offers ⌘Z to undo it. Use ⌘U to mark read or unread. Escape exits search or closes the sidebar. Choose **Show Archive** from the Relay menu bar icon to browse archived chats. Right-click a chat there to restore it. Add a chat URL from the same menu bar icon.

A newly completed turn or input request produces a quiet edge nudge. The edge pill shows the number of chats that still need attention. Pending input requests count until they’re resolved or archived, even after you read them.

Row numbers follow the displayed order, so 1 is always the next chat to act on. Rows in folded Quiet have no number until you show them. Finished rows show the age of their last completion. Other rows show the age of their latest reported activity. Hover on a row to see its status, the full local date and time and its summary when available.

**To review** marks a result to open. **Needs input** stays visible while a decision or answer is pending. **Working** marks an active turn reported by the source. **Quiet** means the source has reported no new update or request, and **Inactive** marks quiet sessions with eight hours without reported activity. **Read** means you opened an update in Relay, marked it read, or its source marked it read. A dot marks unread activity on rows with another status.

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

Relay scans local metadata about every four seconds and keeps archived sessions and source settings in local preferences. The Messages query reads timestamps and delivery flags for the configured conversation. Changes to apps’ local formats can affect discovery or state reporting.

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
