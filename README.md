# Side Eye

Side Eye is a macOS menu bar app that puts your agent chats from Codex, Claude Code, Cursor and Grok Bot in one list at the edge of your screen. It shows which agents need you, which have finished and which are still working, and one key takes you to the right chat.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/inbox-dark.png">
  <img src="docs/inbox.png" width="402" alt="Side Eye’s Inbox, with chats grouped under Needs you, Review and Working">
</picture>

## Install

Side Eye needs macOS 14 or later and runs on Apple silicon and Intel. Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/Jan-ebb/side-eye/main/install.sh | bash
```

It downloads the newest release, checks it against the SHA-256 published with it, puts Side Eye.app in Applications and opens it. Run it again to update. [The script](install.sh) is short if you want to read it first.

Use this command and not the zip on the Releases page. A browser marks every file it downloads, and macOS refuses to open a marked app unless Apple has reviewed it, which it has not done for Side Eye. `curl` adds no such mark.

To build it yourself instead, install Xcode or its command-line tools and run:

```sh
git clone https://github.com/Jan-ebb/side-eye.git
cd side-eye
./Scripts/package.sh "/Applications/Side Eye.app"
open "/Applications/Side Eye.app"
```

A copy you build this way gets its summaries a little differently; see [Build and check](#build-and-check).

## First run

Side Eye has no Dock icon. It lives in the menu bar and as a small pill on the right edge of your screen. The first time you open it, a welcome window shows which apps it found, how to open the sidebar and what its three statuses mean. It comes back at each launch until you close it, and you can reopen it any time from the menu bar icon under **Welcome to Side Eye…**.

- Hover the pill, or press ⌃⌥Space from any app, to open the sidebar.
- Side Eye opens at login from its first launch, so it is back after a restart. Untick **Open Side Eye at login** in the welcome window, or turn off **Open at login** in Settings, to stop that.
- Side Eye needs no permissions to start. Opening a Claude Code chat that runs in a terminal asks for Automation access once, so Side Eye can switch to the right tab.
- [Summaries](#summaries) are optional. The welcome window and **Settings → General** offer to download the model for them, 1.1 GB, once.
- If the Inbox is empty, it says why: no supported app was found, or none has a chat yet.
- **Settings → Apps** shows how many chats the last scan found for each app.

## Privacy

Side Eye reads each app’s local files on your Mac to list its chats. It sends nothing anywhere: it has no account and collects no analytics. The only time it goes online is to download the summary model, and only when you press **Install**. Summaries then run on that model on your Mac through a private socket, so no chat text leaves it.

## The sidebar

Hover the pill to grow it into the sidebar, and move away to shrink it back. Opening it with ⌃⌥Space shows it instantly. Drag the pill up or down to dock it at a different height; Side Eye saves its position on each display. It uses native Force Touch feedback on reveal and after a drag settles, and its animations follow the system Reduce Motion setting.

The sidebar has three lists: **Inbox**, **Favorites** and **Later**. Each tab shows how many chats it lists, and the active tab stays selected between openings.

It opens with one line per chat. Press **D** or use the preview button to add a preview under every chat: its latest [summary](#summaries), or where it runs until a summary exists. Press **D** again to hide them all. Side Eye remembers your choice.

Open Settings from the sidebar’s more button or the Side Eye menu bar icon.

### Statuses

Every chat has one status, always written in words: on the group headers in the Inbox, and on each row in Favorites, Later, search results and ⌘K.

- **Needs you**: a decision or answer is pending. That covers a request made in the middle of a run, such as an approval or a question dialog, in every app. For Claude Code chats in the Claude app it also covers a reply that ends with a question for you: the reply shows under Review when it finishes and moves to Needs you a moment later, once Claude has noted that it is waiting on you.
- **Review**: the agent has handed work back. Unread ones are new.
- **Working**: the app reports a turn in progress.
- **Idle**: the app has reported no new update or request. **Inactive** marks an idle chat with eight hours without reported activity.

A row can also say **Read**: you opened the update in Side Eye, marked it read, or its app marked it read. A read reply stays under Review, dimmed, until you archive it.

### Inbox

The Inbox is where you triage. It groups chats by status, **Needs you**, **Review** and **Working**, each newest first, with a tinted header that stays pinned while you scroll. When nothing needs you, the list says so at the top.

- Titles come in two styles: bold with a dot when there is something new for you, plain otherwise. Reading a chat only makes its row plain. It never moves it.
- A chat moves only when its agent asks, finishes or starts a turn, or when you archive it or move it to Later.
- The Review header says how many replies are unread and offers **Archive N read chats** (⇧E) for the rest.
- Idle chats stay out of the Inbox. Search and ⌘K still find them, and new activity brings them back.
- Row numbers follow the displayed order. Review rows show the age of their last completion, other rows the age of their latest reported activity. Hover a row to see its status, the full local date and time, and its summary when there is one.

### Favorites

Favorites is the lasting list of chats you keep coming back to. Favorite a chat with F, the star that replaces its time on hover, ⌘K or the right-click menu. It keeps its place in the Inbox, and Favorites lists it in the order you added it until you unfavorite it, even after you archive it or its app stops reporting it. Favorites holds up to 30 chats.

### Later

Later is one list ordered by when chats come back, soonest first. Press L to move a chat there, or H to give it a return time: in an hour, this evening, tomorrow morning or next week. A chat with a return time shows it beside an alarm, and one saved without a time keeps its usual timestamp.

Chats in Later stay out of the pill’s count and out of nudges. A chat leaves Later when you move it back, when its return time comes, or when its agent does something new: finishes a turn, starts one or asks for input. One you moved to Later while its agent was working comes back when that run ends.

### Archive

Press E to archive the selected chat, and Z to undo. To browse archived chats, choose **Show Archive** from the Side Eye menu bar icon or **Go to Archive** in ⌘K, and press R there to restore one.

An archived chat comes back by itself, unread, when its agent finishes a new turn, starts one or asks for input, so long-lived chats such as Cursor projects never hide new work. A chat you archive while its agent is still working comes back when that run ends.

### Nudges and the pill

A newly completed turn or input request produces a quiet nudge at the screen edge, and the pill shows the number of chats that still need attention. Pending input requests count until they’re resolved or archived, even after you read them.

### Keys

Single keys act on the list while the sidebar is open. Letters are commands, so typing only searches after / or inside ⌘K. The next chat to act on is selected when the sidebar opens, a new input request first, then an unread reply, so Return opens it. The bar under the list shows the keys that list is for, and offers Z after you archive a chat or move it to Later.

| Key | Action |
| --- | --- |
| ↑ / ↓, or K / J | Move up or down. They work as soon as the sidebar opens, including on hover. |
| Return | Open the selected chat. |
| 1–9 | Open rows 1–9 from top to bottom. |
| 0 | Jump to any numbered row. Type the number, then press Return. |
| ⌥↑ / ⌥↓ | Jump to the previous or next group. |
| Tab / ⇧Tab | Switch between Inbox, Favorites and Later. |
| / | Search the current list. Results are one flat list, best match first, and Return opens the top one. |
| ⌘K | Open the command palette. Type a chat’s name to switch to it, or a command to run it. Each command shows its key. |
| D | Show or hide previews. |
| E, or Delete | Archive the selected chat. Favorites keeps its chats, so archive from the Inbox or Later. |
| ⇧E | Archive every reply you have already read, in one step. |
| R | In Archive, restore the selected chat to the Inbox. |
| L | Move the selected chat to Later, or back to the Inbox from the Later list. |
| H | Later until a time. The chat comes back by itself, marked unread. |
| F | Favorite the selected chat, or unfavorite it. P works too. |
| ⌘U | Mark as read or unread. |
| Z | Undo the last move. ⌘Z works too. |
| Esc | Leave search, or close the sidebar. |
| ⌘, | Open Settings. |

These work from any app. If another app already uses one, **Settings → Shortcuts** says so.

| Shortcut | Action |
| --- | --- |
| ⌃⌥Space | Open or close the sidebar. |
| ⌃⌥K | Open the command palette. |
| ⌃⌥↵ | Open the next chat that needs you. |
| ⌃⌥1–9 | Open the chat in that row. |
| ⌃⌥0 | Jump to any row by number. |
| ⌃⌥D | Show or hide previews. |
| ⌃⌥A | Archive the selected chat. With the sidebar closed, archive the chat you last opened from it. |

To give a chat Side Eye does not find a row of its own, choose **Add chat link…** from the menu bar icon and paste the chat’s share or deep link.

## Summaries

With summaries on, Side Eye writes one sentence per chat about the latest request, the result and any next action. It shows in previews, on hover and in nudges. Summaries are optional and off until you ask for them.

- **Getting them.** Press **Install** under **Settings → General**, or in the welcome window. Side Eye fetches the model, 1.1 GB from Hugging Face, checks it against a published SHA-256 and keeps it in `~/Library/Application Support/Side Eye/Models`. A file that fails the check is deleted. Settings can remove the model again.
- **Without the model.** Settings marks it **Not installed**. With previews on, the sidebar says so too, in a note at the top with an **Install…** button that opens Settings. Close the note and it stays away.
- **Where they run.** On your Mac, on [llama.cpp](https://github.com/ggml-org/llama.cpp), which the release download carries inside the app. Side Eye starts it only when needed, talks to it over a private Unix socket and shuts it down when idle.
- **What they read.** Bounded excerpts from the apps’ local caches. Summaries are kept in memory only. Where a recent transcript is absent, a row relies on what its app reports.
- **The first one is slow.** The very first summary on a Mac takes about 15 seconds longer on Apple silicon, while macOS prepares the model’s GPU code. After that it is cached.

A nudge shows the same sentence. If the sentence is ready only after the nudge appears, Side Eye adds it to the visible card.

The exact model and its license are in [the model notes](ModelLicenses/SideEyeSummary.md).

## Apps

| App | Discovery and signals | Switching |
| --- | --- | --- |
| Codex | Up to 32 non-archived chats active in the last 24 hours. Completion and read state come from local history. Input requests use the installed app’s live status when available. | Exact thread link |
| Claude Code | Live Desktop and terminal sessions, plus available CLI background jobs. Working, waiting, and completion come from the session registry and CLI. | Exact Desktop link or terminal TTY. Terminal switching can require macOS Automation access. Ghostty needs 1.4 or later for TTY lookup. |
| Cursor | Local agent chats and cloud agents active in the last 48 hours. Status comes from available generation, approval, and unread fields. | Exact local or cloud agent link |
| Grok Bot | Agent chats active in the last 48 hours. The local roster supplies unread replies and requests for input. | Exact agent link. The roster identifies the agent even when an unread reply is in one of its subthreads. |

Side Eye scans local metadata about every four seconds and keeps archived chats and app settings in local preferences. Changes to apps’ local formats can affect discovery or state reporting.

**Settings → Apps** lists the four apps. Each says how many chats the last scan found, or why it found none.

- **Codex.** Scheduled automation runs are hidden by default. Turn on **Include scheduled automation runs** to include them in the sidebar, the pill’s count and nudges.
- **Grok Bot, main agents.** To show only your main agents, choose **Main only** next to **Agents shown** and check as many agents as you like. The choices hold every agent in Grok Bot, including archived ones and ones with no recent chat. An agent you create later is shown by itself unless you turn off **Show new agents automatically**. The sidebar shows a **Main** badge on your marked agents.
- **Grok Bot, Working.** Grok Bot keeps no running flag on disk, so Side Eye reads the end of each transcript. A chat counts as working while a request waits for its first answer (up to 10 minutes for yours, 15 for one from another agent), for 5 minutes after a short first reply or a progress note such as “The search is running”, and for 20 seconds after any other message, because agents usually send several in a row.
- **Read replies.** Grok Bot and Cursor report a reply you have read as read rather than idle, so it stays under Review until you archive it.

## Build and check

`Scripts/package.sh` builds Side Eye.app for this Mac. `Scripts/release.sh` builds the download: a universal app with llama.cpp’s server inside, zipped, with its checksum in `dist/`. It needs cmake (`brew install cmake`). Pushing a tag such as `v0.18.0` that matches the `VERSION` file runs the release workflow, which publishes the zip as a GitHub release. The install command finds the newest release by itself.

To check a build, run:

```sh
./Scripts/package.sh "/path/to/Side Eye.app"
"/path/to/Side Eye.app/Contents/MacOS/SideEye" --self-test
"/path/to/Side Eye.app/Contents/MacOS/SideEye" --ui-check
"/path/to/Side Eye.app/Contents/MacOS/SideEye" --diagnostics
```

- `--self-test` runs the logic checks on sample chats and prints what passed.
- `--ui-check` opens the sidebar with sample chats and checks its layout and keys. Run it with the main app closed so it can register the same shortcuts. Add `--pointer-check` to test the real global shortcut and pointer hover, which briefly moves the pointer. `--settings-check` and `--welcome-check` open those two windows without touching your settings.
- `--diagnostics` scans your real chats and, after about 15 seconds, prints counts only: chats per app, how many can be opened, and how many summaries were generated locally. A newly built copy can report none generated on its first one or two runs: its server is still compiling GPU code when the report prints. Run it again.

A copy you build yourself has no llama.cpp server inside and uses Homebrew’s (`brew install llama.cpp`). To put one in, install cmake, run `./Scripts/llama-server.sh /tmp/llama-server` and set `SIDE_EYE_LLAMA_SERVER=/tmp/llama-server` when running the packaging script. That script fetches llama.cpp at a pinned commit and builds its server with nothing left to load from Homebrew. `./Scripts/release.sh` does both steps. To build a copy with the model inside as well, set `SIDE_EYE_SUMMARY_MODEL` to the verified GGUF file.

## Acknowledgements

[Linear’s design refresh](https://linear.app/now/behind-the-latest-design-refresh), [Mobbin’s navigation references](https://mobbin.com/blog/how-to-use-mobbin-mcp), and the [Wispr Flow edge bar](https://docs.wisprflow.ai/articles/1790396454-move-and-dock-the-flow-bar-on-desktop) informed the overlay. [Codex deep links](https://learn.chatgpt.com/docs/reference/commands#deep-links) and the [Claude Code agent view](https://code.claude.com/docs/en/agent-view#read-session-state-from-a-script) document the underlying entry points. Summaries run on [llama.cpp](https://github.com/ggml-org/llama.cpp) and Qwen3.5-2B; their licenses are in [ModelLicenses](ModelLicenses).

## License

[MIT](LICENSE).
