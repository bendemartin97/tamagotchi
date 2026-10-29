# Tamagotchi

A macOS desktop pet that watches over your Claude Code and Codex sessions. Every agent session gets its own mini pet
with a fixed look. The big pet shows new notifications as a speech bubble for two minutes; after that they wait in
the inbox until you deal with them.

The interface text is in German, since it was built for daily use by a German-speaking developer.

## Features

- **Pets:** mood follows the real state (working, waiting for you, done, asleep), with props for questions, running
  pipelines, visual reviews and merges. Drag to move; click opens the most urgent notification or the chat.
- **Overview window** (double-click the pet or press ⌃⌥I), with every agent in a sidebar:
  - **Live:** key numbers, one card per agent with its current prompt and tool, MRs that need attention, today's
    timeline.
  - **Inbox:** sections for up next, can wait, read, snoozed and done. Search, filters, snooze, pinning, manual
    priority, undo and keyboard control.
  - **Tasks and MRs:** ticket, workspace and session for every task. For red pipelines, the tail of the failed job log
    and "fix it"; for open review threads, "hand comments to an agent".
  - **Report:** standup note and end-of-day summary to copy, time per ticket, booked to ClickUp on click.
  - **Agent view:** overview, turn history from the transcript, changes (git state, diff, edited files), questions
    and usage (context chart, tool counts).
- **Watchdog:** flags agents that keep failing, go in circles, stay silent for a long time or run out of context.
- **Menu bar:** the app icon with a dot when an agent is waiting (orange) or a pipeline is red (red), plus a short menu.
- **Quiet mode:** while you share your screen (Zoom, Teams, Meet, Slack) or turn it on by hand, the pets disappear.
  Afterwards you get a single summary instead of a pile of bubbles.
- **Chat and tasks:** questions go to `claude -p`; work requests run as their own Claude Code session after you
  confirm them.

## Data sources

- Claude Code hooks append to `~/.claude/tamagotchi/events.jsonl` (`pet.sh` and `notify.sh`, kept in a separate
  dotfiles repo).
- GitLab via `glab`, GitHub via `gh`, ClickUp through the ClickUp MCP inside `claude -p`.
- State lives in `~/.claude/tamagotchi/state.json`.

## Build

```sh
./build.sh          # builds ~/Applications/Tamagotchi.app and (re)starts the LaunchAgent
tools/icon.sh       # render AppIcon.icns from the pixel pet
tools/icon.sh x.png # or from your own 1024×1024 PNG with transparent corners
```

The current icon comes from `icon-source.png`, generated with the prompt in `ICON-PROMPT.md`.
`tools/squircle.swift` cuts out the squircle and places it on the macOS icon grid, and `tools/icon.sh` turns it into
`AppIcon.icns`.

Requires the Xcode Command Line Tools (swiftc), macOS 14 or later, and Screen Recording permission for the chat.
