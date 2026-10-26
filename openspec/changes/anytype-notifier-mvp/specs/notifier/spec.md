## Purpose

Watch one or more Anytype collections and surface new objects via unread-badge count, toast notifications, and panel entries. Owns per-collection polling, local snapshot caching, diff-against-last-snapshot to identify new objects, read-state tracking, and the IPC refresh handler.

## ADDED Requirements

### Requirement: Per-collection polling

The plugin SHALL poll each watched collection on an independent `Timer` whose interval comes from `pluginSettings.collections[i].pollInterval` (seconds, default 15, minimum 5).

#### Scenario: Collection added
- **WHEN** the user adds collection `C` to the watch list via Settings
- **THEN** a `Timer` for `C` SHALL start with `triggeredOnStart: true`
- **AND** the first poll SHALL execute inside the current QML tick

#### Scenario: Collection removed
- **WHEN** the user removes collection `C` from the watch list
- **THEN** the `Timer` for `C` SHALL stop
- **AND** all cached objects for `C` SHALL be dropped from `root.objectsByCollection[C.id]`
- **AND** the unread count SHALL be recomputed

#### Scenario: Minimum interval enforced
- **WHEN** the user sets `pollInterval` below 5 seconds
- **THEN** the plugin SHALL clamp the interval to 5 seconds and emit `Logger.w("anytype", "clamped poll interval")` without failing

### Requirement: Diff against cached snapshot

Each poll SHALL compare the returned object list against the last cached snapshot for that collection and SHALL emit a `newObjects` event for any object id present in the response but absent from the cache.

#### Scenario: First poll on a new collection
- **WHEN** `C.lastPollTimestamp === 0`
- **THEN** the plugin SHALL fetch the collection, store the snapshot, mark every returned id as "already read"
- **AND** SHALL NOT fire toasts for the initial batch

#### Scenario: Subsequent poll finds two new objects
- **WHEN** the previous snapshot had ids `[a, b, c]`
- **AND** the current response has ids `[a, b, c, d, e]`
- **THEN** `newObjects` SHALL be fired with `[d, e]`
- **AND** `d` and `e` SHALL be prepended to `root.objectsByCollection[C.id]`
- **AND** `root.unreadCount` SHALL increase by 2

#### Scenario: Object removed from collection
- **WHEN** the previous snapshot had `[a, b, c]`
- **AND** the current response has `[a, c]`
- **THEN** `b` SHALL be removed from the cache
- **AND** no toast SHALL fire
- **AND** any `b` entry in `pluginSettings.readMessageIds` SHALL be dropped on next `persistReadIds()`

### Requirement: Toast on new objects

When `pluginSettings.enableToasts` is true (default), each poll that discovers new objects SHALL show a toast via `ToastService.showNotice`. The toast content SHALL be composed from a user-configurable field template so the user controls which object metadata appears and in what order.

#### Scenario: Single new object with default template
- **WHEN** `newObjects` has one element `o` with `name = "Buy milk"`, `created_date = "2026-10-26T14:03:11Z"`, `created_by = "julien"`, hosted in collection `C.name = "Inbox"`
- **AND** the default template is active (title = object name, body shows **creation date** and **created by**)
- **THEN** `ToastService.showNotice` SHALL be called with:
  - title = `"Buy milk"` (the `what`)
  - body = `"Inbox - 14:03 - by julien"` (the `where - when - who`)
  - icon = `"bell"`

#### Scenario: Multiple new objects
- **WHEN** `newObjects` has `n > 1` elements for one collection
- **THEN** `ToastService.showNotice(pluginApi.tr("toast.newObjects", {count: n, collection: C.name}), "", "bell")` SHALL be called exactly once (no per-object toast storm)

#### Scenario: Toasts disabled
- **WHEN** `pluginSettings.enableToasts === false`
- **THEN** no `ToastService` call SHALL be made and the unread badge SHALL still update

### Requirement: Configurable notification fields

The user SHALL choose which object properties appear in the toast and the Panel row via `pluginSettings.notificationFields`. The defaults SHALL be `["created_date", "created_by"]`. The ordered field list is the display order (left-to-right in the toast body, top-to-bottom under the row's title in the Panel).

#### Scenario: Default field set
- **WHEN** `pluginSettings.notificationFields` is unset
- **THEN** the effective field list SHALL be `["created_date", "created_by"]`
- **AND** both fields SHALL appear in the toast body separated by " - "

#### Scenario: User adds the collection name as a field
- **WHEN** the user picks `["collection_name", "created_date", "created_by"]` in Settings
- **THEN** the toast body for a new "Buy milk" object SHALL read `"Inbox - 14:03 - by julien"`

#### Scenario: User drops created_by
- **WHEN** the user picks `["created_date"]` only
- **THEN** the toast body SHALL read `"14:03"` with no author segment

#### Scenario: Empty field list is treated as "name only"
- **WHEN** the user picks `[]`
- **THEN** the toast SHALL render title = object name, body = "" (no fields)
- **AND** the Panel row SHALL render the object name only with no sub-line

### Requirement: Supported notification fields

The plugin SHALL support at least the following field ids. Fields not supported by a given Anytype type SHALL be rendered as the empty string, not an error.

| Field id            | Semantics                                                                                     | Rendered as                              |
| ------------------- | --------------------------------------------------------------------------------------------- | ---------------------------------------- |
| `created_date`      | Object's creation timestamp (when it was added to the vault)                                  | `HH:mm` if same day, else `YYYY-MM-DD`   |
| `created_by`        | Participant id or display name of the vault member who created the object                     | `by <name>`                              |
| `last_modified_date`| Last modification timestamp - useful for distinguishing "created" vs "re-added"               | relative: `"5m ago"`, `"2h ago"`         |
| `last_modified_by`  | Participant id of the last editor                                                             | `edited by <name>`                       |
| `collection_name`   | Name of the watched collection the object appeared in                                         | plain text                               |
| `type_name`         | Human-readable Anytype type ("Task", "Bookmark", "Note", ...)                                 | plain text                               |
| `tag`               | First tag of the object, if the type has a `tag` property                                     | `#tag`                                   |
| `snippet`           | Short excerpt of the object body                                                              | plain text, truncated to 60 chars        |
| `space_name`        | Name of the Anytype space the object lives in (for users with multiple spaces)                | plain text                               |

#### Scenario: Field unavailable on a given object
- **WHEN** `notificationFields` includes `tag` but the object's type has no tag property
- **THEN** the `tag` segment SHALL render as the empty string and SHALL NOT appear in the body
- **AND** the surrounding separators SHALL collapse (no `" -  - "` artifacts)

#### Scenario: Timestamp localisation
- **WHEN** rendering `created_date`
- **THEN** the timestamp SHALL use the user's locale via `Qt.formatDateTime(d, Locale.ShortFormat)`

### Requirement: Why / Who / When / Where captured per unread entry

Every entry added to the per-collection cache SHALL carry a structured payload with these fields even when the user has disabled some from the display template, so toggling display fields does not require re-fetching:

- `why` = presence in a watched collection (synthetic, `"added_to:<collectionId>"`); when polling detects an id gain, this reflects which watched collection surfaced it
- `what` = object `name`
- `who` = `created_by` (default) + `last_modified_by`
- `when` = `created_date` (default) + `last_modified_date`
- `where` = `collection_name` + `space_name`

#### Scenario: Payload shape
- **WHEN** a new object `o` is cached
- **THEN** the entry SHALL be `{id, why, what, who: {created_by, last_modified_by}, when: {created_date, last_modified_date}, where: {collection_name, collection_id, space_name, space_id}, raw}`
- **AND** `raw` SHALL hold the full Anytype response for the object (used by Panel's expand-row and by the Kanban change later)

#### Scenario: Toast rendering reads from the payload
- **WHEN** `pluginSettings.notificationFields` is `["created_date", "created_by"]`
- **THEN** the toast body SHALL be composed from `entry.when.created_date` and `entry.who.created_by` only
- **AND** the Panel row SHALL compose the same string from the same payload - single source of truth

### Requirement: Unread badge on BarWidget

The BarWidget SHALL display the sum of unread objects across all watched collections, 0 shown as hidden badge.

#### Scenario: Three unread across two collections
- **WHEN** collection A has 1 unread and collection B has 2 unread
- **THEN** the BarWidget SHALL show the count `3`

#### Scenario: All read
- **WHEN** every object across all collections is in `pluginSettings.readMessageIds`
- **THEN** the BarWidget SHALL show the icon with no badge

### Requirement: Mark-read on panel open

Opening the Panel SHALL mark currently-visible objects as read.

#### Scenario: Panel opened
- **WHEN** the user left-clicks the BarWidget and `pluginApi.togglePanel(screen)` opens the panel
- **THEN** every object id currently rendered in the "Latest updates" feed SHALL be added to `pluginSettings.readMessageIds`
- **AND** `persistReadIds()` SHALL be called
- **AND** the BarWidget badge SHALL recompute to zero within the next tick
- **AND** objects rendered only in the Kanban block SHALL NOT be marked read by panel open (they are not "notifications", they are a persistent board view)

### Requirement: Unified "Latest updates" feed

The Panel SHALL render a single time-sorted feed combining objects from all watched collections, NOT per-collection groups.

#### Scenario: Multiple watched collections produce entries
- **WHEN** collection `Inbox` has new entry `a` at `14:03` and collection `Tasks` has new entry `b` at `14:01`
- **THEN** the Panel feed SHALL show `a` above `b`, both in the same list
- **AND** no section headers like "Inbox:" or "Tasks:" SHALL be rendered

#### Scenario: Collection name remains visible per row
- **WHEN** an entry from collection `Inbox` is rendered in the unified feed
- **THEN** the row sub-line SHALL start with the collection name as its first segment, even if the user removed `collection_name` from `pluginSettings.notificationFields`
- **AND** the remaining fields SHALL follow the user's configured order after a " - " separator

### Requirement: Kanban collection designation

The user SHALL be able to designate at most one watched collection as the "Kanban collection" via `pluginSettings.kanbanCollectionId`. The Panel SHALL render a Kanban block below the "Latest updates" feed when a Kanban collection is set.

#### Scenario: No Kanban collection set
- **WHEN** `pluginSettings.kanbanCollectionId` is empty or references a collection not in the watch list
- **THEN** the Kanban block in the Panel SHALL render a "not configured" placeholder with an "Open Settings" button
- **AND** no polling SHALL run specifically for Kanban - the designated collection, if in the watch list, is already polled by the notifier

#### Scenario: Kanban collection set but Phase 2 not landed
- **WHEN** `pluginSettings.kanbanCollectionId` points at a watched collection
- **AND** this MVP change is deployed (Phase 2 `anytype-kanban-todo` not yet merged)
- **THEN** the Kanban block SHALL render a "coming in a future update" placeholder
- **AND** SHALL show the live object count of the designated collection (`objectsByCollection[kanbanCollectionId].length`)

#### Scenario: Status property picker
- **WHEN** the user picks a Kanban collection in Settings
- **THEN** the Settings UI SHALL load the type of that collection and present a status-property picker whose options are the type's `select` / `multi_select` properties
- **AND** the chosen property SHALL be persisted as `pluginSettings.kanbanStatusPropertyId`
- **AND** the MVP SHALL store it without using it; Phase 2 uses it to derive columns

### Requirement: IPC commands

The plugin SHALL register an `IpcHandler` with target `plugin:anytype-noctalia` exposing at minimum: `toggle`, `refresh`, `markAllRead`.

#### Scenario: refresh IPC
- **WHEN** the user runs `qs ipc call plugin:anytype-noctalia refresh`
- **THEN** every watched collection SHALL be polled immediately regardless of its Timer phase

### Requirement: Offline resilience

When the client reports `offline` or `unauthorized`, the plugin SHALL continue running without blocking the UI and SHALL expose the state to BarWidget and Panel.

#### Scenario: Anytype desktop app is closed
- **WHEN** every poll returns `offline` for 60 seconds
- **THEN** the BarWidget icon SHALL switch to the "offline" variant
- **AND** opening the Panel SHALL render an "Anytype is not running" placeholder in place of the object list
- **AND** polls SHALL continue every 60 seconds (not the configured interval) until a successful call restores normal cadence

#### Scenario: Token revoked
- **WHEN** a poll returns `unauthorized`
- **THEN** the BarWidget SHALL show the "needs re-pairing" variant
- **AND** the Panel SHALL show a "Re-pair in Settings" placeholder with a button that opens Settings
