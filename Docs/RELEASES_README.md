# QuestBits — Releases

Public download page for **QuestBits**, a native macOS task tracker with a
bundled MCP server, command-line tool and Claude Code hooks, so **Claude Code**
agents can pick up and work on your tasks while you keep the overview.

Source lives in [`90n9/quest-bits`](https://github.com/90n9/quest-bits). Every tagged release there
(`vX.Y.Z`) is built by CI and published here as a downloadable DMG, and this
repo's `appcast.xml` feeds the app's built-in auto-updater.

## Features

- **Projects → Tasks** — group work into projects; tasks have detail notes,
  links, due dates, priorities, dependencies, and short codes (`GEN-3`).
- **Claude Code integration** — the app registers its MCP server automatically;
  ask Claude to add, edit, move, or complete tasks in natural language and the
  app reflects changes within ~1.5 s. Agents claim tasks so parallel sessions
  never collide, leave you questions and keep working, and record decisions.
- **Built for agent work** — typed links and a working branch per task,
  relations, milestones, and a project wiki agents search before asking again.
- **What needs you, in one place** — Waiting on you, Activity and Decisions
  pages, notifications when an agent needs you, and ✋ / ⚡ counts in the menu
  bar.
- **Claude Code hooks (opt-in)** — install them from Settings: a project brief
  at session start, context back after a compaction, and approval questions in
  QuestBits for risky calls (push, release, merge…) in a project's folder.
- **`questbits` CLI** — brief, list, show, export and import, linkable into
  `~/.local/bin` from Settings.
- **Auto-updates** — the app checks this repo's appcast hourly and installs new
  releases in place (Sparkle, Ed25519-signed).
- **Tiny & native** — pure Swift, no Electron. Cozy RPG parchment theme.

## Install

1. Download the latest `QuestBits_<version>.dmg` from the
   [Releases](https://github.com/90n9/quest-bits-releases/releases/latest) page.
2. Open the DMG and drag **QuestBits** into **Applications**.
3. First launch is blocked by Gatekeeper because the app is ad-hoc signed
   (not notarized by Apple) — macOS may claim the app is "damaged". It isn't;
   clear the quarantine flag once:

   ```bash
   xattr -dr com.apple.quarantine /Applications/QuestBits.app
   ```

   Then open QuestBits normally. Alternatively: try to open the app once, then
   go to **System Settings → Privacy & Security** and click **Open Anyway**.

You only need this on first install. From then on the app updates itself —
in-app updates are signed and don't re-trigger Gatekeeper.

> **Upgrading from 1.2.0 or older?** Those builds contained an update-key bug
> and cannot auto-update. Install the latest DMG manually once (steps above);
> auto-update works from 1.2.1 onward.

## Using it with Claude Code

On first launch the app registers its MCP server in `~/.claude.json` under
`mcpServers.quest-bits`. Start a fresh Claude Code session, then just ask:

```
list my todo projects
add a task "Fix login bug" to the General project and mark it in progress
what tasks are still todo?
how many tasks did I finish today?
```

## Notes

- macOS 14 (Sonoma) or later.
- This repo hosts binaries, release notes, and the update feed only — no source code.
- Release notes for each version come from the project changelog; see each
  release's description.
