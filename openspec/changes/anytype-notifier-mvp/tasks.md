## 1. Scaffold

- [ ] 1.1 Copy `references/noctalia-dev-noctalia-plugins/ntfy-notifications/` into `plugin/` and rename id/name in `manifest.json` to `anytype-noctalia` / "Anytype -> Noctalia"
- [ ] 1.2 Set `minNoctaliaVersion` to `4.4.1` and `entryPoints` to `{main, barWidget, panel, settings}`
- [ ] 1.3 Replace `metadata.defaultSettings` with the Anytype-shaped defaults (`mode: "localhost"`, `baseUrl`, `serverUrl`, `apiKey`, `spaceId`, `collections`, `defaultTargetCollectionId`, `defaultTypeKey`, `notificationFields: ["created_date", "created_by"]`, `kanbanCollectionId: ""`, `kanbanStatusPropertyId: ""`, `feedMaxItems: 50`, `enableToasts`, `showUnreadBadge`, `readMessageIds`)
- [ ] 1.4 Verify Noctalia hot-loads the stub plugin: run Noctalia in debug mode, confirm the empty widget renders on the bar

## 2. ApiClient (capability: api-client)

- [ ] 2.1 Extract HTTP logic from `ntfy-notifications/Main.qml` into a reusable `ApiClient` component inside `Main.qml` (QtObject singleton pattern)
- [ ] 2.2 Implement deployment-mode selection: `pluginSettings.mode` of `"localhost"` or `"server"`; `effectiveBaseUrl()` picks `baseUrl` or `serverUrl` accordingly per `specs/api-client/spec.md` -> "Deployment mode"
- [ ] 2.3 Implement `requestChallenge()` + `pair(challengeId, code)` for localhost mode per `specs/api-client/spec.md` -> "Pair-with-Anytype flow"
- [ ] 2.4 Implement server-mode token entry: plain token-paste in Settings; no challenge endpoint call
- [ ] 2.5 Implement `classify(xhr)` returning one of `{ok, offline, unauthorized, notFound, rateLimited, serverError, parseError}` per `specs/api-client/spec.md` -> "Error classification". The `offline` payload carries `openAnytypeDesktop: boolean` keyed off `mode`.
- [ ] 2.6 Implement `get(path)` / `post(path, body)` with Bearer header, 10 s timeout, single-flight guard per path, and `Retry-After` handling (one retry max on 429)
- [ ] 2.7 Implement `listCollectionObjects(spaceId, collectionId, sinceTs)` + `createObject(spaceId, body)` + `addToCollection(spaceId, listId, ids[])` as thin wrappers over get/post
- [ ] 2.8 Verify with a live local Anytype in **localhost mode**: pair via 4-digit code, list, create, add. Confirm 401 flips `unauthorized` and closing Anytype flips `offline` within 60 s.
- [ ] 2.9 Verify **server mode**: point `serverUrl` at a locally-running `anytype-cli serve` / `anytype-heart` under `references/Dauliac-anytype-cli` or `references/anyproto-anytype-mcp`; perform list + create against it

## 2b. Token resolution + config file (capability: api-client)

- [ ] 2b.1 Implement `resolveToken()` walking env var -> `~/.config/anytype-noctalia/config.toml` -> `pluginSettings.apiKey`, taking the first non-empty source per `specs/api-client/spec.md` -> "Token resolution precedence"
- [ ] 2b.2 Implement a minimal TOML reader (small `parseToml()` or shell-out to `tomlq` if trivial) that returns `{mode, base_url, server_url, api_key, space_id}` from the config file; tolerate missing / malformed input per the spec's "Config file schema" + "Partial config" scenarios
- [ ] 2b.3 Implement mtime polling: a slow `Timer` (interval: 2 s) checks `FileInfo.lastModified` on the config file; on change, re-run `resolveToken()` and emit `configFileChanged`
- [ ] 2b.4 Implement config-file write on successful pairing: write `api_key`, `mode`, `space_id` with mode 0600; on write failure fall back to `saveSettings()` per "Pairing with read-only config dir" scenario
- [ ] 2b.5 Implement the one-time toast warning when the file is loaded with permissions wider than 0600
- [ ] 2b.6 Verify by (a) deleting plugin settings, dropping a hand-crafted `config.toml`, confirming the plugin uses it; (b) editing the file to swap tokens, confirming the change takes effect without restart; (c) setting `ANYTYPE_API_KEY=x` in Noctalia's launch env and confirming it overrides the file

## 3. Notifier (capability: notifier)

- [ ] 3.1 Add `objectsByCollection: {[id: string]: Object[]}` + `cursorByCollection: {[id: string]: number}` as shared state on `Main.qml`
- [ ] 3.2 Instantiate one `Timer` per entry in `pluginSettings.collections`, with `interval: collection.pollInterval * 1000`, clamped to a 5 s minimum per `specs/notifier/spec.md` -> "Minimum interval enforced"
- [ ] 3.3 Implement `pollCollection(C)`: calls `ApiClient.listCollectionObjects`, applies the diff from `specs/notifier/spec.md` -> "Diff against cached snapshot", emits `newObjectsEvent` with the new ids
- [ ] 3.4 Build the structured per-entry payload `{id, why, what, who, when, where, raw}` from the Anytype object response, per `specs/notifier/spec.md` -> "Why / Who / When / Where captured per unread entry"
- [ ] 3.4a Implement `renderFields(entry, fieldIds)` composing a plain-text display string from an ordered list of field ids (defaults `["created_date", "created_by"]`) per `specs/notifier/spec.md` -> "Supported notification fields"; collapse empty segments so there are no `" -  - "` artifacts
- [ ] 3.4b Wire `newObjectsEvent` -> `ToastService.showNotice(entry.what, renderFields(entry, pluginSettings.notificationFields), "bell")`, respecting `pluginSettings.enableToasts` and the single-vs-multi message rules
- [ ] 3.5 Implement `unreadCount` derived property + `isMessageRead` / `markAsRead` / `markAllAsRead` / `persistReadIds`, lifted from `ntfy-notifications/Main.qml:256-295` and generalised across collections
- [ ] 3.6 Add `IpcHandler` with target `plugin:anytype-noctalia` exposing `toggle()`, `refresh()`, `markAllRead()`
- [ ] 3.7 Implement offline-backoff: when `classify` is `offline` for 60 s, slow polling to 60 s cadence until a successful call
- [ ] 3.8 Verify by adding an object in Anytype inside a watched collection and observing: toast fires, badge increments, panel shows the new object, panel opening clears the badge.

## 4. BarWidget

- [ ] 4.1 Copy the `ntfy-notifications/BarWidget.qml` layout and swap the icon to a brand mark (e.g. "database" or custom SVG) with the standard `isVertical` handling
- [ ] 4.2 Bind badge count to `pluginApi.mainInstance.unreadCount`; hide badge when 0 or `pluginSettings.showUnreadBadge === false`
- [ ] 4.3 Add icon variants for `offline` and `needsRePair`, driven by `pluginApi.mainInstance.lastErrorClass`
- [ ] 4.4 Left-click `pluginApi.togglePanel(screen, root)`; right-click opens an `NPopupContextMenu` with `[Refresh, Mark all read, Settings]` (no "Open Anytype" entry - starting Anytype is out of scope)
- [ ] 4.5 Verify by cycling states manually: close Anytype -> offline icon; revoke key via Anytype Settings -> needs-re-pair icon; both without the plugin crashing

## 5. Panel

- [ ] 5.1 Build the three-block Panel layout from the mockup in `design.md` -> "M2": "Latest updates" feed on top, "Kanban" block in the middle, "Quick add" footer. No per-collection grouping.
- [ ] 5.1a "Latest updates" feed: flatten `objectsByCollection[*]` into one array, sort by `entry.when.last_modified_date` descending, cap at `pluginSettings.feedMaxItems` (default 50)
- [ ] 5.2 Each feed row renders object name as the title and `renderFields(entry, pluginSettings.notificationFields)` as a dim sub-line, **always prefixed with `entry.where.collection_name` + " - "** so the user never loses the "which collection" context even when `collection_name` is not in the field list; hover reveals a per-row "mark read" chevron
- [ ] 5.3 On Panel open, call `markVisibleAsRead()` which collects the ids currently rendered **in the feed only** (NOT the Kanban block) and routes to `markAsRead` (batched)
- [ ] 5.3a Kanban slot - MVP ships inert: render "not configured" placeholder when `pluginSettings.kanbanCollectionId` is empty, "coming in a future update" placeholder with live `objectsByCollection[kanbanCollectionId].length` otherwise. No columns, no drag-and-drop - those are the Phase-2 `anytype-kanban-todo` deliverable.
- [ ] 5.4 Build the error-state body (localhost: "Anytype desktop is not running. Start it from your launcher." / server: "Cannot reach <url>. Last error: <msg>"). Observational only - no launch button, no process control.
- [ ] 5.5 Build the quick-add footer: text input + collection selector (defaults to `pluginSettings.defaultTargetCollectionId`) + Add button
- [ ] 5.6 Wire quick-add Submit to `ApiClient.createObject` -> `ApiClient.addToCollection` with optimistic UI from `specs/quick-add/spec.md` -> "Optimistic UI"
- [ ] 5.7 Add inline confirmation / inline error states for 3 s on success / failure
- [ ] 5.8 Verify end to end: open panel, type "test", pick Inbox, Submit; row appears instantly, Anytype shows it in the Inbox collection, inline "Added" fades out

## 6. Settings

- [ ] 6.1 Build Settings from the mockup in `design.md` -> "M3": sections Connection / Space / Watched collections / Notification fields / Quick-add / Notifications / About
- [ ] 6.2 Connection section: Mode radio (Localhost / Server), Server URL field (shown only in server mode), Token source line (reflects precedence from D8), `[open]` button that launches `$EDITOR` on the config file, `[reload]` that forces a re-read, Pair button (opens the 4-digit sub-state in localhost mode, token-paste sub-state in server mode), Status row ("Paired", first 6 chars of key), Clear-key button
- [ ] 6.2a Notification fields section: ordered picker over the ids in `specs/notifier/spec.md` -> "Supported notification fields"; live preview line below the picker uses `renderFields(sampleEntry, chosenIds)`; "Restore defaults" button resets to `["created_date", "created_by"]`
- [ ] 6.3 Space picker: load `GET /v1/spaces` once Settings opens; render as `NComboBox`; writes to `pluginSettings.spaceId`
- [ ] 6.4 Watched-collections list: checkable rows loaded from `GET /v1/spaces/{spaceId}/lists` (or `.../collections` on v2); each row has a per-collection `pollInterval` spin box
- [ ] 6.4a Kanban-collection section: dropdown over currently-watched collections + "(None - hide the Kanban block)"; writes to `pluginSettings.kanbanCollectionId`. When set, load the collection's type and present a status-property picker over the type's `select`/`multi_select` properties; writes to `pluginSettings.kanbanStatusPropertyId`. Both values are **persisted but unused** by MVP code - Phase-2 consumes them.
- [ ] 6.5 Quick-add defaults: target collection + default type_key both come from the loaded lists / types for the selected space
- [ ] 6.6 Notifications toggles bind directly to `pluginSettings.enableToasts`, `pluginSettings.showUnreadBadge`, `pluginSettings.toastOnQuickAdd`
- [ ] 6.7 Verify Settings round-trip: change a value, close Settings, re-open; confirm it persisted via `saveSettings()`

## 7. i18n

- [ ] 7.1 Create `i18n/en.json` with all `pluginApi.tr(...)` keys referenced across Main, BarWidget, Panel, Settings
- [ ] 7.2 Add `i18n/fr.json` with the same keys translated (user's primary language per repo context)
- [ ] 7.3 Verify toggling Noctalia's locale switches labels correctly

## 8. Shippability

- [ ] 8.1 Add `plugin/README.md` with install instructions, screenshots, the pairing flow, and the "Anytype desktop must be running" note
- [ ] 8.2 Add `plugin/preview.png` from a real screenshot of the panel
- [ ] 8.3 Validate `manifest.json` against another official plugin's shape (`todo/manifest.json`)
- [ ] 8.4 Decide `official: false` for first PR to `noctalia-plugins`; leave headroom to request `official: true` later
- [ ] 8.5 Open an upstream PR to `noctalia-dev/noctalia-plugins` adding `anytype-noctalia/` (only after an in-tree review)

## 9. Verification

- [ ] 9.1 Manually walk every scenario in `specs/api-client/spec.md`
- [ ] 9.2 Manually walk every scenario in `specs/notifier/spec.md`
- [ ] 9.3 Manually walk every scenario in `specs/quick-add/spec.md`
- [ ] 9.4 Run with Anytype restarted mid-session: confirm plugin recovers without a Noctalia restart
- [ ] 9.5 Run with Anytype uninstalled: confirm the plugin's offline state is quiet (no error toasts, no console spam)
- [ ] 9.6 Run against a server-mode endpoint via `references/Dauliac-anytype-cli` or `references/anyproto-anytype-mcp` locally; confirm the Settings UI renders the server-mode variants (token-paste pairing, "Cannot reach <url>" placeholder) and that no "Open Anytype" affordances appear
- [ ] 9.7 Confirm the plugin never spawns a child process targeting Anytype (grep the final QML for `anytype-desktop`, `execDetached`, `Process {`) - starting Anytype is out of scope; the follow-up Nix module owns that
