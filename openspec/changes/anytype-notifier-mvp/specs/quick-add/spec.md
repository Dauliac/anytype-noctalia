## Purpose

Create a new Anytype object from the Noctalia panel and optionally add it to a target collection, so I can capture into Anytype without opening the app. Owns the quick-add UI inside the Panel, the create-object request, the optional add-to-collection follow-up, and the optimistic-UI feedback.

## ADDED Requirements

### Requirement: Quick-add input in Panel

The Panel SHALL render a quick-add input at the bottom with a target-collection selector and a Submit button.

#### Scenario: Target collection defaulted
- **WHEN** the Panel opens and the user has not yet picked a target collection in this session
- **THEN** the target SHALL default to `pluginSettings.defaultTargetCollectionId` (set in Settings)

#### Scenario: Submit with text
- **WHEN** the user types "Buy milk" and clicks Submit (or hits Enter)
- **THEN** the plugin SHALL `POST /v1/spaces/{spaceId}/objects` with `{name: "Buy milk", type_key: pluginSettings.defaultTypeKey}`
- **AND** on 2xx SHALL `POST /v1/spaces/{spaceId}/lists/{targetCollectionId}/objects` with the new object id
- **AND** SHALL clear the input
- **AND** SHALL show a transient inline confirmation `pluginApi.tr("quickAdd.ok")`

#### Scenario: Empty input
- **WHEN** the user clicks Submit with an empty input
- **THEN** no request SHALL be made and the input SHALL retain focus

### Requirement: Optimistic UI

The newly-created object SHALL appear in the Panel object list within one tick, before the server confirms, marked with an "in-flight" indicator.

#### Scenario: Successful create
- **WHEN** `POST .../objects` returns 2xx
- **THEN** the optimistic entry SHALL be replaced with the server-canonical entry (same id)
- **AND** the "in-flight" indicator SHALL be removed

#### Scenario: Create fails
- **WHEN** `POST .../objects` returns 4xx or 5xx
- **THEN** the optimistic entry SHALL be removed from the Panel
- **AND** an inline error SHALL show for 3 seconds (`pluginApi.tr("quickAdd.failed")`)
- **AND** the input SHALL restore the typed text so the user can retry without re-typing

### Requirement: Add-to-collection is best-effort

Create and add-to-collection are TWO requests. If the object was created but the add-to-collection call failed, the object SHALL still appear in Anytype (just not in the target collection).

#### Scenario: Create ok, add-to-collection fails
- **WHEN** `POST .../objects` returns 2xx with id `X`
- **AND** `POST .../lists/{C}/objects` returns 5xx
- **THEN** the optimistic entry SHALL remain in the Panel but SHALL show a "not added to collection" warning badge
- **AND** a one-off retry SHALL be queued; after a second failure the warning SHALL persist and `markAllRead` SHALL clear it

### Requirement: IPC add command

The plugin SHALL expose `qs ipc call plugin:anytype-noctalia add "<text>"` that creates an object with the given text as its name in the default target collection.

#### Scenario: Scripted add
- **WHEN** the user runs `qs ipc call plugin:anytype-noctalia add "Call Mom"`
- **THEN** the plugin SHALL perform the same create + add-to-collection flow as the panel input
- **AND** SHALL fire a `ToastService.showNotice("Added to <collection>", "Call Mom", "plus")` on success
- **AND** SHALL fire a `ToastService.showError(...)` on failure
