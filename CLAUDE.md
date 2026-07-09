# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & run

No Xcode, no SPM, no `Package.swift` — everything compiles directly with `swiftc` (Swift 6.3, macOS 14+).

```bash
Scripts/build-app.sh                # local default: DEV flavor → "build/QuestBits Dev.app"
FLAVOR=prod Scripts/build-app.sh    # production flavor → build/QuestBits.app (CI implies this)
Scripts/make-dmg.sh                 # package build/QuestBits.app → build/QuestBits.dmg (prod only)
open "build/QuestBits Dev.app"
VERSION=1.2.0 Scripts/build-app.sh  # override bundle version (CI passes the git tag here)
```

**Dev vs prod flavor.** Local builds default to a fully isolated **QuestBits Dev** app
(compiled with `-D DEV_BUILD` into *both* binaries): bundle id `com.local.todoapp.dev`,
database `~/Library/Application Support/TodoAppDev/`, MCP registration key
`mcpServers.quest-bits-dev`, orange DEV badge in the sidebar footer. It never touches
production data or the prod `todo` registration. CI builds (`GITHUB_ACTIONS=true`)
and `FLAVOR=prod` produce the production QuestBits.app.

`build-app.sh` compiles two separate binaries and links libsqlite3 (`-lsqlite3`) into each:
- `Contents/Resources/mcp-server/todo-mcp` ← `Sources/TodoCore/*.swift` + `Sources/TodoMCP/*.swift`
- `Contents/MacOS/QuestBits` ← `Sources/TodoCore/*.swift` + `Sources/TodoApp/*.swift` (+ Sparkle.framework)

The app binary links **Sparkle 2.6.4** for auto-updates. `build-app.sh` downloads it to
`vendor/Sparkle/` (gitignored) on first run — first build needs network. Signing is
inside-out (Sparkle helpers → framework → binaries → app); don't revert to
`codesign --deep`. Sparkle auto-checks are compiled on only in CI builds
(`GITHUB_ACTIONS=true`), so local dev bundles never self-replace with a release.

**`TodoCore` is shared *source*, not a library** — its `.swift` files are recompiled into both binaries. A change in `TodoCore/` affects the app and the MCP server; rebuild both.

## Verifying changes

There is no test suite. Verify by exercising the real binaries:

```bash
# MCP smoke test — no app restart needed. Point at a throwaway DB.
MCP="build/QuestBits Dev.app/Contents/Resources/mcp-server/todo-mcp"
TODO_DB_PATH=/tmp/qb-test.sqlite \
  echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_projects","arguments":{}}}' | "$MCP"
```

- `TODO_DB_PATH` overrides the DB location — always use it for tests so you don't touch real data.
- The live app registers its MCP server on launch; a Claude Code session started **before** launch won't see it — start a fresh session to pick up MCP changes.

## Architecture

Two processes share **one SQLite database in WAL mode** so the SwiftUI app and the Claude-Code-spawned MCP server can read/write concurrently:

```
SwiftUI app (window + menu bar)  ─┐                        ┌─ todo-mcp (MCP server, spawned by Claude Code)
                                  ├─ ~/Library/Application Support/TodoApp/db.sqlite (+ -wal/-shm)
                                  ─┘  app polls the file every 1.5s and reloads on external writes
```

- **No push/FSEvents.** `AppModel` polls the DB on a 1.5s `Timer` (`AppModel.swift`) — external MCP writes surface with up to ~1.5s lag. This is deliberate; keep the polling model unless replacing it wholesale.
- **`Store` (`TodoCore/Store.swift`, ~1.5k lines) is the single source of truth** for all data mutation and the widest / most delicate file. Cross-process writes use `BEGIN IMMEDIATE` with re-checks *inside* the transaction (e.g. dependency-cycle and reachability guards), plus a one-level transaction-nesting guard. Preserve this pattern — naive `INSERT`/`UPDATE` outside a transaction can race the other process.
- **MCP server** speaks JSON-RPC 2.0 over stdio with **no external SDK** — hand-rolled in `TodoMCP/MCPServer.swift`; tool schemas in `TodoMCP/ToolDefinitions.swift`; entrypoint `main.swift` is just `MCPServer().run()`.
- **Self-registration:** on first launch the app writes itself into `~/.claude.json` under `mcpServers.quest-bits` — `mcpServers.quest-bits-dev` for dev-flavor builds (`TodoApp/MCPRegistration.swift`). Each flavor auto-migrates its own legacy key name (`todo` / `todo-dev`) when it points at a QuestBits binary.
- **App scene** is a `WindowGroup` + `MenuBarExtra` (`TodoApp/TodoApp.swift`) — the menu-bar countdown is the real `MenuBarExtra`, not a hand-rolled `NSStatusItem`. Pomodoro logic in `PomodoroEngine.swift`, local notifications in `NotificationScheduler.swift`, key commands in `Shortcuts.swift`. Nearly all UI is in `Views.swift`.

### id-or-code duality
Projects have a short code (`GEN`), tasks have one too (`GEN-3`). **Every MCP tool that takes an `id` also accepts a `code`** — this is a core convenience (`move_task {code:"GEN-3", to_project_code:"DFC"}`). When adding or changing a tool, keep both lookup paths working.

## Releases & CI

Source lives in the **private** `90n9/quest-bits`; built DMGs are published to the **public** `90n9/quest-bits-releases`.

- Push a tag to release: `git tag vX.Y.Z && git push origin vX.Y.Z`. `.github/workflows/release.yml` builds a DMG on macOS and creates a GitHub release on the public repo (via the `RELEASES_REPO_TOKEN` PAT secret).
- **Auto-update (Sparkle):** CI signs the DMG with the `SPARKLE_ED_PRIVATE_KEY` secret and prepends an item to `appcast.xml` in the public releases repo (the app's `SUFeedURL` points at that file's raw main URL). The matching public key is baked into Info.plist by `build-app.sh`. Rotating the key breaks updates for already-shipped builds.
- **Release notes come from `CHANGELOG.md`** — the workflow extracts that tag's `## [X.Y.Z]` block. Add an entry (under `## [Unreleased]` or a new `## [X.Y.Z]`) **before** tagging.
- Git remote uses the SSH host alias **`github.com-90n9`** (`git@github.com-90n9:90n9/quest-bits.git`), not plain `github.com` — the local `gh` CLI is authed to a different account and can't reach 90n9.
- Builds are **ad-hoc code-signed** (no Apple Developer cert). Shared builds need a one-time Gatekeeper allow: `xattr -dr com.apple.quarantine /Applications/QuestBits.app`.
