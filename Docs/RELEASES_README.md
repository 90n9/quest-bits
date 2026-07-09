# QuestBits — Releases

Public download page for **QuestBits**, a native macOS todo + Pomodoro app with a
bundled MCP server so **Claude Code** can manage your tasks for you.

Source lives in the private repo `90n9/quest-bits`. Every tagged release there
(`vX.Y.Z`) is built by CI and published here as a downloadable DMG, and this
repo's `appcast.xml` feeds the app's built-in auto-updater.

## Features

- **Projects → Tasks** — group work into projects; tasks have detail notes,
  links, due dates, priorities, dependencies, and short codes (`GEN-3`).
- **Pomodoro focus timer** — one global timer (25/5/15, configurable) with a
  live countdown in the menu bar and daily focus stats.
- **Claude Code integration** — the app registers its MCP server automatically;
  ask Claude to add, edit, move, or complete tasks in natural language and the
  app reflects changes within ~1.5 s.
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
`mcpServers.todo`. Start a fresh Claude Code session, then just ask:

```
list my todo projects
add a task "Fix login bug" to the General project and mark it in progress
what tasks are still todo?
how many pomodoros did I do today?
```

## Notes

- macOS 14 (Sonoma) or later.
- This repo hosts binaries, release notes, and the update feed only — no source code.
- Release notes for each version come from the project changelog; see each
  release's description.
