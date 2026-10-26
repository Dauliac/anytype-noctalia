## Context

See `proposal.md` for motivation. See `specs/{notifier,quick-add,api-client}/spec.md` for required behaviour. This document covers how we build it: component layout, state model, and the specific QML/Quickshell/HTTP patterns we lean on, with ASCII mockups of each UI surface and the data flow.

Hard constraints that shape every decision below:

- **Runtime is QML + QtQuick ECMAScript**, loaded by `PluginService.qml`. No native code, no external daemon.
- **Anytype API** is HTTP REST on `127.0.0.1:31009` with Bearer auth. Rate limit: 1 rps sustained, burst 60. No webhooks or SSE for objects as of 2025-11-08 - polling is the only option (see `research/anytype.md`).
- **Noctalia API injection**: every entry-point QML file gets a `pluginApi` property with `pluginSettings`, `saveSettings()`, `tr()`, `openPanel()`, `togglePanel()`, `mainInstance`, `withCurrentScreen()`. Shared state lives on the `main` entry (`Main.qml`) and is reachable from other entries via `pluginApi.mainInstance`.
- **Template reused**: structural lift from `references/noctalia-dev-noctalia-plugins/ntfy-notifications/`. Verified working pattern for XHR polling + Timer + ToastService + IpcHandler + persisted settings.

## Goals / Non-Goals

**Goals:**

- Ship a drop-in plugin: `~/.config/noctalia/plugins/anytype-noctalia/` with no further install steps.
- Keep MVP code budget to roughly `ntfy-notifications` size (one Main.qml, one BarWidget.qml, one Panel.qml, one Settings.qml, plus i18n).
- Fail quietly when Anytype is offline. The desktop app is often closed; the plugin must not throw errors into the user's bar.
- Favour explicit requests over clever subscriptions: polling is the only option today, so write the code for it clearly and keep swap-points for a future stream.

**Non-Goals:**

- Kanban board, status transitions, drag-and-drop: deferred to `anytype-kanban-todo` change.
- gRPC. Public gRPC still exists in `anytype-heart` but nothing we need justifies the native-binary cost.
- Multi-space UX. v1 lets the user pick one space in Settings; cross-space browsing comes later.
- Secure token storage via libsecret. v1 keeps the Bearer token in `pluginSettings` (plain JSON on disk under `~/.config/noctalia/`). Shell-out to `secret-tool` is a tracked follow-up.
- Phone-home telemetry or crash reporting.

## Decisions

### D1. In-shell QML plugin, no sidecar daemon

**Decision**: implement everything in QML + JS. No external process.

**Why**: The `ntfy-notifications` plugin at `references/noctalia-dev-noctalia-plugins/ntfy-notifications/Main.qml` already proves XHR + Timer + ToastService works end to end. The Anytype API is on localhost with no streaming, no TLS pinning, no binary payloads - QML's XMLHttpRequest covers it. A sidecar would add systemd units, IPC, packaging, and a long debug cycle for zero functional gain.

**Alternatives considered**:

- Rust/Go daemon talking gRPC to `anytype-heart`, pushing to QML over Unix sockets. Rejected: adds a process to supervise, adds a build toolchain, needs its own release pipeline, and gRPC's advantage (streaming) is wasted when there is no object event stream.
- Python helper via `Quickshell.Io.Process + curl`. Rejected: XHR works, so there is no reason to shell out.

### D2. One Timer per watched collection, not one for the whole plugin

**Decision**: `collections[i]` -> its own `Timer` with its own interval.

**Why**: Users will typically watch collections with very different cadences. An "Inbox" wants 10 s; a "Read Later" wants 120 s. One global Timer forces a lowest-common-denominator and burns the rate-limit budget for low-signal collections. Independent timers also make a collection going briefly offline (`unauthorized` for one space) local to that collection.

**Rate-limit math**: 1 rps sustained. If a user watches 4 collections at 15 s each, we average 4/15 = 0.27 rps. Even with the worst case of 10 collections at 10 s each (1 rps), we burn only the sustained budget - burst 60 handles the first-poll stampede.

### D3. Diff by `last_modified_date` cursor + object-id set

**Decision**: cache the latest `last_modified_date` seen per collection. Poll with `sort=-last_modified_date`. Diff the response ids against the cached id set to find new objects.

**Why**: Anytype returns `last_modified_date` on every object. Using it as a since-cursor keeps response payloads small. The id-set diff catches objects whose timestamp did not change but which were added to a collection via `POST .../lists/{list_id}/objects` (that endpoint modifies the collection, not the object).

**Edge case**: an object edited elsewhere will reappear with a bumped timestamp. That is a false positive for "new" - we handle it by requiring the id to be absent from the cached id set, not just by timestamp.

### D4. Read-state is a flat id set, mirrored to settings

**Decision**: `readMessageIds: string[]` persisted in `pluginSettings`, trimmed on each `persistReadIds()` to only ids still present in the live cache.

**Why**: Identical pattern to `ntfy-notifications/Main.qml:287`. Keeps settings bounded. Loses history on `markAllRead` of a stale id, which is fine - the object either reappears (will be re-marked unread) or is gone.

### D5. XHR, not fetch, not `Quickshell.Io`

**Decision**: use `XMLHttpRequest` directly in QML JS.

**Why**: Native to QtQuick. No imports, no promise polyfill, easy abort via `xhr.abort()`. `fetch` is not available in QtQuick JS. `Quickshell.Io.Process` is only needed if we need to shell out (keyring: future), not for HTTP.

**Pattern** (verbatim from the ntfy plugin, generalised):

```qml
var xhr = new XMLHttpRequest();
xhr.onreadystatechange = function() {
    if (xhr.readyState !== XMLHttpRequest.DONE) return;
    classify(xhr.status, xhr.responseText);
};
xhr.open("GET", url);
if (apiKey) xhr.setRequestHeader("Authorization", "Bearer " + apiKey);
xhr.send();
```

### D6. Error classification is centralised; UI branches on the class

**Decision**: `ApiClient.classify(xhr)` returns one of `{ok, offline, unauthorized, notFound, rateLimited, serverError, parseError}`. BarWidget + Panel switch on the class, not on raw status codes.

**Why**: Three UI surfaces need to render on the same errors; branching on the class once avoids drift.

### D7. Optimistic quick-add; two requests tolerated independently

**Decision**: quick-add fires `POST .../objects`, then on 2xx fires `POST .../lists/{id}/objects`. The first one succeeding counts as "object created"; the second failing is a visible warning but not a rollback.

**Why**: Anytype's current API has no transaction between create and add-to-collection. A user who sees "capture failed" after their object was in fact saved will build a duplicate - worse than a visible warning.

### D8. Token precedence: env var -> config file -> plugin settings

**Decision**: resolve the Bearer token on every request by walking three sources in order: `$ANYTYPE_API_KEY`, then `~/.config/anytype-noctalia/config.toml`, then `pluginSettings.apiKey`.

**Why**: the token is a long-lived credential shared across tools (CLI, scripts, future Noctalia widgets). Pinning it to Noctalia's `pluginSettings` JSON means it leaks into dotfiles sync, cannot be shared with `anytype-cli`, and cannot be chmod-protected independently of the shell config. A dedicated config file with mode 0600 is standard, discoverable, scriptable, and the user can edit it with their editor. The env-var layer on top lets dev sessions override without touching disk.

**Alternatives considered**:

- Plain `pluginSettings` only (previous draft). Rejected because the token leaks into Noctalia backups and cannot be shared with other tools.
- libsecret / kwallet / `secret-tool` for storage. Deferred: adds a shell-out, keyring daemon dependency, and complicates the "edit with your editor" story. Will revisit as a follow-up once a user asks.
- One keyring entry per space. Overkill for the v1 shape (one space, one key).

The config file is **optional**. When the user completes the pairing wizard in Settings, the plugin writes to the config file by default (0600). If the directory is read-only or missing, it falls back to `pluginSettings` with a visible warning in Settings.

**Config file schema** (TOML, all keys optional):

```toml
# ~/.config/anytype-noctalia/config.toml
mode       = "localhost"                   # or "server"
base_url   = "http://127.0.0.1:31009"      # localhost mode
server_url = "https://anytype.example.com" # server mode
api_key    = "..."                         # Bearer
space_id   = "bafy..."                     # default space
```

**Reactivity**: the plugin re-reads the config file when its mtime changes, so hand-edits take effect on the next poll without a Noctalia restart.

### D9. Two deployment modes: localhost + server

**Decision**: `pluginSettings.mode` is one of `"localhost"` (default) or `"server"`. localhost mode hits `127.0.0.1:31009`; server mode hits a user-supplied base URL.

**Why**: Anytype runs in two sensible shapes:

- Most desktop users have the Anytype desktop app running; it binds the local HTTP API on 31009. localhost is the right default.
- Power users (self-hosted Any-Sync node, homelab, remote work box) want to hit an API endpoint they manage, not require the GUI app to be running on the same machine. The HTTP contract is identical in both cases - only the base URL and the "what to tell the user when offline" change.

**UI differences by mode**:

- localhost + offline -> "Open Anytype desktop" button in the Panel error state.
- server + offline -> "Check your server at <url>" message, no desktop launch button.
- localhost + 401 -> "Re-pair" (user re-opens the Anytype app, re-does the challenge flow).
- server + 401 -> "Edit your API key in Settings" (challenge flow may not exist on the server; the user supplies the key by hand).

**Challenge pairing** is a localhost-mode feature; server mode defaults to a plain token-paste UI because an arbitrary server may not implement the 4-digit challenge endpoint. The pairing wizard renders either flow based on `mode`.

### D11. Panel layout: unified feed + Kanban slot

**Decision**: the Panel body is NOT grouped by collection. Watched-collection updates fold into one time-sorted "Latest updates" feed. A separate "Kanban" block below it renders exactly ONE user-designated collection (`pluginSettings.kanbanCollectionId`) as a board.

**Why**:

- The user already has to look at each collection individually inside Anytype. The whole point of the Noctalia panel is to see "what changed everywhere" at a glance - grouping by collection re-fragments that view and makes the "which is newest" question hard.
- The `collection_name` field is already carried on every entry's payload (per D10) and surfaces in the row sub-line, so the user never loses the "where" context when the grouping is dropped.
- Kanban is a fundamentally different *interaction model* (board, columns, drag) than a feed (list, scroll, mark read). Mixing them in one block means a bad compromise for both.
- One Kanban board, not N: a per-watched-collection board makes the Panel 3x taller and splits the user's attention. The Kanban role is specifically "my active task board"; the user picks one.

**MVP vs Phase 2 split**:

- MVP ships: the Panel layout (feed + Kanban slot + quick-add), the Settings UI for picking the Kanban collection + status property, and an inert placeholder in the slot (two states: not-configured / configured-but-coming-soon with live object count).
- Phase 2 (`anytype-kanban-todo` change): fills the slot - columns from the status property's values, cards per object, drag-and-drop between columns, status-transition requests through ApiClient, keyboard navigation.

Locking the layout in MVP means Phase 2 is additive, not a redesign.

**Alternatives considered**:

- Grouped feed (previous draft). Rejected per above.
- Tabs (Feed | Kanban). Rejected: hides half the information. The Panel is already short-lived; forcing a click to switch views adds friction.
- Multi-collection Kanban (one board per watched collection, swipeable). Rejected: user picks collections for different purposes - one Kanban role is the simple, honest shape.

### D10. Notification field template; defaults = `created_date`, `created_by`

**Decision**: toast + Panel-row content is composed from `pluginSettings.notificationFields: string[]`, defaulting to `["created_date", "created_by"]`. Supported field ids: see `specs/notifier/spec.md` -> "Supported notification fields".

**Why**: "What was added, when, by whom, where" is the information the user actually wants from a notification. Hard-coding one format locks the plugin out of use cases where (for example) a team shares one space and wants `created_by` and `space_name` but not timestamps. A field list is minimal UI, minimal spec surface, and future-proof - new fields are a Settings addition only.

**Rendering model**: every cached entry carries a structured payload (`why/what/who/when/where`). The display template is a view over the payload, not a cache contract - toggling fields never requires re-polling.

**Alternatives considered**:

- Jinja-style string template (`"{created_date} by {created_by}"`). Rejected: templating in QML is awkward, invites bad user input, and gains little expressiveness over an ordered id list.
- Fixed format (what we had before). Rejected per the use-case above.
- Markdown-rich notification content. Rejected: `ToastService.showNotice` is plain text; no gain.

## ASCII mockups

### M1. BarWidget states

```
+---------+     +-----------+     +-----------+     +-----------+     +-----------+
|   [A]   |     |   [A]#1   |     |  [A]#12   |     |  [A!]     |     |  [A?]     |
+---------+     +-----------+     +-----------+     +-----------+     +-----------+
  idle            1 unread          12 unread         offline           needs
                                                      (Anytype          re-pair
                                                       closed)
```

Left-click toggles Panel. Right-click opens context menu: `[Refresh] [Mark all read] [Settings]`. The plugin does not launch or supervise the Anytype desktop app or any self-hosted node - it only observes the HTTP endpoint. Starting Anytype is out of scope; see the Risks table and the follow-up Nix home-manager module note at the end of this document.

### M2. Panel: unified feed + kanban slot + quick-add

Panel opens below the bar widget. Width 420 px, max height 720 px. Three vertical blocks:

1. **Latest updates** - one unified, time-sorted feed over ALL watched collections (NOT grouped per collection)
2. **Kanban** - a single collection the user designates in Settings as "the kanban collection", rendered as a board (MVP ships this slot inert; filled by the Phase-2 `anytype-kanban-todo` change)
3. **Quick-add** - footer input

The sample names (`Inbox`, `Read Later`, `Tasks`) are **example user collections** chosen in Settings - the plugin ships no names. `Read Later` stands in for a low-urgency bucket (saved articles, bookmarks) polled at 120 s, next to `Inbox` at 15 s - this is the per-collection interval story from D2. `Tasks` is a placeholder for the collection the user designates for Kanban.

```
+--------------------------------------------------+
|  Anytype                     [refresh] [...]     |
+--------------------------------------------------+
|  Latest updates                      * 4 unread  |
|  +--------------------------------------------+  |
|  |  * Buy milk                                |  |
|  |      Inbox - 14:03 - by julien             |  |
|  |  * Call Mom                                |  |
|  |      Tasks - 14:01 - by julien             |  |
|  |  * Reply to Alice                          |  |
|  |      Inbox - 13:51 - by julien             |  |
|  |    "Anytype API" article                   |  |
|  |      Read Later - 09:12 - by julien        |  |
|  +--------------------------------------------+  |
|                                                  |
|  Kanban: Tasks                         [config]  |
|  +--------------------------------------------+  |
|  |  Backlog | Todo    | Doing   | Done        |  |
|  |  --------|---------|---------|-----------  |  |
|  |  * clean | * Buy   | * Call  | * Reply     |  |
|  |    docs  |   milk  |   Mom   |   to Alice  |  |
|  |          |         |         |             |  |
|  |          |         |         |             |  |
|  +--------------------------------------------+  |
|                                                  |
+--------------------------------------------------+
|  Quick add -> Inbox         v                    |
|  +--------------------------------------------+  |
|  |  Type something and press Enter...         |  |
|  +--------------------------------------------+  |
|                               [Add]              |
+--------------------------------------------------+
```

Legend:
- Rows marked `*` are unread (added since last Panel open).
- The sub-line under each title renders the fields from `pluginSettings.notificationFields` (default `created_date` + `created_by`). The source collection is **always** rendered as the first segment of the sub-line in the unified feed, so the user can tell at a glance which watched collection the entry came from, even if they removed `collection_name` from the field list.
- Hover on a row reveals a "mark read" chevron.
- `Kanban: Tasks` block shows the collection name designated as the Kanban collection via Settings (`pluginSettings.kanbanCollectionId`). The MVP ships the frame + an inert placeholder; status columns, drag-and-drop, and status transitions are the deliverable of the Phase-2 `anytype-kanban-todo` change.

**MVP Kanban slot - inert states:**

Not configured (no collection selected):

```
|  Kanban                                           |
|  +--------------------------------------------+  |
|  |  Pick a collection in Settings to turn it  |  |
|  |  into a Kanban board.                      |  |
|  |                                            |  |
|  |                   [Open Settings]          |  |
|  +--------------------------------------------+  |
```

Configured but Phase-2 not yet landed:

```
|  Kanban: Tasks                                   |
|  +--------------------------------------------+  |
|  |  Kanban board coming in a future update.   |  |
|  |  Current count:  12 objects                |  |
|  +--------------------------------------------+  |
```

Error state replaces the body. The plugin does not offer to launch Anytype - it reports the condition and defers to the user's own session management:

```
+--------------------------------------------------+
|  Anytype                     [refresh] [...]     |
+--------------------------------------------------+
|                                                  |
|       Anytype desktop is not running.            |
|       Start it from your launcher.               |
|                                                  |
+--------------------------------------------------+
```

Server-mode variant:

```
+--------------------------------------------------+
|  Anytype                     [refresh] [...]     |
+--------------------------------------------------+
|                                                  |
|       Cannot reach https://anytype.ex.com        |
|       Last error: connect timeout (10s)          |
|                                                  |
+--------------------------------------------------+
```

### M3. Settings (one page)

```
+--------------------------------------------------+
|  Anytype -> Noctalia                             |
+--------------------------------------------------+
|                                                  |
|  Connection                                      |
|  +--------------------------------------------+  |
|  |  Mode: ( ) Localhost (desktop)             |  |
|  |        (o) Server (self-hosted/remote)     |  |
|  |                                            |  |
|  |  Server URL [https://anytype.ex.com     ]  |  |
|  |                                            |  |
|  |  Token source: config file                 |  |
|  |      ~/.config/anytype-noctalia/           |  |
|  |          config.toml   [open] [reload]     |  |
|  |                                            |  |
|  |  Status: Paired  (key: 3f8c21...)          |  |
|  |                      [Re-pair] [Clear key] |  |
|  +--------------------------------------------+  |
|                                                  |
|  Space                                           |
|  +--------------------------------------------+  |
|  |  [v Personal (default)                   ] |  |
|  +--------------------------------------------+  |
|                                                  |
|  Watched collections                             |
|  +--------------------------------------------+  |
|  |  [x] Inbox                 poll: [ 15 ] s  |  |
|  |  [x] Read Later            poll: [120 ] s  |  |
|  |  [x] Tasks                 poll: [ 30 ] s  |  |
|  |  [ ] Projects              poll: [ 60 ] s  |  |
|  |  [+ Pick from Anytype...]                  |  |
|  +--------------------------------------------+  |
|                                                  |
|  Kanban collection                               |
|  +--------------------------------------------+  |
|  |  Which watched collection to render as a   |  |
|  |  Kanban board in the Panel:                |  |
|  |                                            |  |
|  |  [v Tasks                           ]      |  |
|  |      (None - hide the Kanban block)        |  |
|  |                                            |  |
|  |  Status property on this collection's      |  |
|  |  type:                                     |  |
|  |  [v status                          ]      |  |
|  +--------------------------------------------+  |
|                                                  |
|  Notification fields              [restore def.] |
|  +--------------------------------------------+  |
|  |  Shown in toast + Panel row sub-line,      |  |
|  |  in order:                                 |  |
|  |                                            |  |
|  |  1. [v Creation date         ]  [-]        |  |
|  |  2. [v Created by            ]  [-]        |  |
|  |     [+ Add field...]                       |  |
|  |                                            |  |
|  |  Preview:  14:03 - by julien               |  |
|  +--------------------------------------------+  |
|                                                  |
|  Quick-add                                       |
|  +--------------------------------------------+  |
|  |  Default target: [v Inbox              ]   |  |
|  |  Default type:   [v Task               ]   |  |
|  +--------------------------------------------+  |
|                                                  |
|  Notifications                                   |
|  +--------------------------------------------+  |
|  |  [x] Toast on new objects                  |  |
|  |  [x] Show unread badge                     |  |
|  |  [ ] Toast when quick-add succeeds         |  |
|  +--------------------------------------------+  |
|                                                  |
|  About                                           |
|  anytype-noctalia v0.1.0  |  Docs  |  GitHub     |
+--------------------------------------------------+
```

The "Add field..." button opens a picker with the ids from `specs/notifier/spec.md` -> "Supported notification fields". The ordered list is both the display order and the content: dropping a field hides it from toasts and the Panel row immediately.

Localhost-mode variant hides the "Server URL" row and shows a "Base URL" row (defaulting to `http://127.0.0.1:31009`) instead.

The "Token source" row reflects the precedence from D8: shows "env var" (dim), "config file", or "plugin settings" depending on which source currently supplies the key. `[open]` launches `$EDITOR` on the file; `[reload]` forces a re-read.

Pairing sub-state (localhost mode, shown when "Re-pair" is clicked):

```
Status: Pairing...  Anytype should show a 4-digit code.

  Code: [ _ _ _ _ ]        [Confirm]  [Cancel]
```

Pairing sub-state (server mode - no challenge endpoint assumed):

```
Status: Awaiting token.

  Paste your Bearer token:
  +--------------------------------------------+
  |  [                                       ] |
  +--------------------------------------------+

                           [Save]   [Cancel]
```

### M4. Kanban (Phase 2 - included here for context, specced separately)

```
+-----------+-----------+-----------+-----------+
|  Backlog  |  Todo     |  Doing    |  Done     |
+-----------+-----------+-----------+-----------+
|  * item   |  * item   |  * item   |  * item   |
|  * item   |  * item   |           |  * item   |
|  * item   |           |           |           |
|           |           |           |           |
+-----------+-----------+-----------+-----------+
```

Phase 2 lives in a separate `anytype-kanban-todo` change. It reuses the api-client + notifier capabilities and adds a `kanban` entry-point + a `status` property wiring on the chosen Anytype type.

### M5. Data flow

```
                           +--------------------+
                           |  Anytype desktop   |
                           |  127.0.0.1:31009   |
                           +---------+----------+
                                     ^
                                     | HTTP (XHR, Bearer)
                                     |
+------------------+                 |
| Timer(C_i)       | --- poll(C_i) ->|
| interval[i]      |                 |
+------------------+                 |
       |                             |
       v                             |
  ApiClient.get()                    |
       |                             |
       v                             |
  classify(xhr) ---> {ok, offline, 401, 429, 5xx}
       |
       v
  diff(prev[C_i], response) --> newIds, cache update
       |
       +--> ToastService.showNotice(...)   (if enableToasts && newIds)
       |
       +--> root.objectsByCollection[C_i] = merged
       |
       +--> root.unreadCount recompute
       |
       +--> BarWidget rebinds (property observer)
       |
       +--> Panel refreshes if open (property observer)

User actions:
  BarWidget click    --> pluginApi.togglePanel(screen)
  Panel open         --> markVisibleAsRead() --> persistReadIds()
  Panel quick-add    --> ApiClient.post(create) --> ApiClient.post(addToList)
  IpcHandler         --> refresh / toggle / add / markAllRead
```

## Risks / Trade-offs

| Risk                                                             | Mitigation                                                                                                                                                 |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Anytype API v1 -> v2 rename of collection endpoints              | Isolate the two endpoints behind `ApiClient.listCollectionObjects()` and `addToCollection()`. Swap on upgrade; everything else keeps working.               |
| Rate limit (1 rps sustained) breached by many collections at low interval | D2 math caps the common case. Clamp min interval to 5 s per spec. Add a global guard that spaces out concurrent timer fires on the same tick (`Qt.callLater`). |
| User closes Anytype desktop; plugin keeps hitting a dead port    | D6 classification sends `offline` state to UI. Timer continues at a slow (60 s) cadence instead of configured until a successful call restores it.          |
| Bearer token leaks via `~/.config/noctalia/` JSON                | Document in Settings. Follow-up to shell out to `secret-tool` once asked for.                                                                               |
| Noctalia `main` branch is the v5 C++ rewrite - no plugin loading | Pin `minNoctaliaVersion: 4.4.1` in manifest.json. Document "legacy-v4 branch" in README.                                                                    |
| Quick-add race: two keystrokes send two requests                 | Disable Submit button + input while XHR in flight (D7 pattern).                                                                                            |
| QML XHR has no cookie jar, timeout defaults are long             | Explicit `xhr.timeout = 10000` on every call; treat timeout as `offline` for classification.                                                                |
| User expects the plugin to start Anytype when offline            | Out of scope. The plugin observes only. See "Out of scope" below for the follow-up path.                                                                    |

## Out of scope

Starting / supervising / restarting the Anytype desktop app or a self-hosted Any-Sync node is not the plugin's job. Rationale:

- Session management is already owned by the user's desktop stack (launcher, dinit, systemd user units, Nix home-manager, ...).
- Launching a GUI from a shell plugin invites CLI-vs-flatpak-vs-AppImage path discovery, environment issues, and failure modes the plugin has no good way to surface.
- Server mode is deliberately dumb about remote lifecycle - the server could be a corporate relay, a homelab box, or a shared instance.

**Follow-up paths** (not part of this change):

- A thin Nix home-manager module (`modules/anytype.nix`) that declares the Anytype desktop app and a `systemd --user` service with restart policy. Users on Nix can enable it; everyone else uses whatever they already have.
- Local smoke tests for server mode can use `anytype-cli` (already cloned at `references/Dauliac-anytype-cli`) or a short docker-compose stub bringing up `anytype-heart` headless. Both options sit outside the plugin bundle.
