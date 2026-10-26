## Why

Noctalia Shell is my Wayland desktop and Anytype is my knowledge/task vault. Right now, moving items between the two is a context switch: I open the Anytype app, hunt for the right collection, add or check items, close it. For high-signal collections (an Inbox, a reading list, a daily log) I also want to know when something new lands without polling the app myself.

Anytype shipped a local HTTP API in desktop 0.46.x. Noctalia loads community plugins as QML directories under `~/.config/noctalia/plugins/<id>/`. A `ntfy-notifications` plugin already exists in `noctalia-plugins` that uses XMLHttpRequest + Timer + ToastService + IpcHandler - the exact architectural shape we need. Combining the two is now mostly plumbing.

Writing this as an in-shell QML plugin (no sidecar daemon) keeps the surface small: one plugin directory, no systemd unit, no extra process to supervise. The Anytype API is on `127.0.0.1:31009` with a Bearer token - XHR from QML reaches it directly.

## What Changes

- Add a new Noctalia plugin: `anytype-noctalia` (shippable to the `noctalia-plugins` registry later).
- Bar widget: unread badge showing the count of new objects across all watched collections since last-read.
- Panel: dropdown with three vertical blocks: a unified "Latest updates" feed (newest-first across ALL watched collections, NOT grouped per-collection), a "Kanban" block tied to ONE user-designated collection (slot ships inert in MVP; filled by Phase-2 `anytype-kanban-todo`), and a quick-add input.
- Toasts: fire a `ToastService.showNotice` when a new object appears in a watched collection (deduped by object id).
- Settings: pair-with-Anytype flow (challenge + 4-digit code for localhost mode, plain token-paste for server mode), per-collection watch list with per-collection poll interval, deployment-mode toggle (localhost / server), notification-field template (default: `created_date`, `created_by`), Kanban-collection designation + status-property picker (persisted in MVP, used by Phase-2).
- Config file at `~/.config/anytype-noctalia/config.toml` (TOML, 0600): single source of truth for the Bearer token, deployment mode, base URL, default space. Resolved with precedence `ANYTYPE_API_KEY` > config file > `pluginSettings`.
- IPC: `qs ipc call plugin:anytype-noctalia toggle | refresh | add` so the user can bind keys or run it from scripts.

Kanban todolist view is NOT part of this change - it will be a follow-up `anytype-kanban-todo` change.

## Capabilities

### New Capabilities

- `notifier`: Watch one or more Anytype collections and surface new objects via unread badge + toasts + a unified time-sorted "Latest updates" feed in the Panel. Covers polling, diff-against-cache, deduplication, read-state tracking, the user-configurable notification-field template (defaults: `created_date`, `created_by`), and the Kanban-collection designation + status-property picker (persisted and surfaced as an inert slot in the Panel; actual board interactions deferred to the Phase-2 `anytype-kanban-todo` change).
- `quick-add`: Create a new Anytype object from the Noctalia panel. Covers the create-object request, auto-add to a target collection, and optimistic UI confirmation.
- `api-client`: Shared Anytype HTTP client used by notifier and quick-add. Covers two deployment modes (localhost / server), auth pairing (challenge flow for localhost; token paste for server), token resolution via env-var -> config-file -> plugin-settings precedence, config-file lifecycle (read, re-read on mtime change, write on pairing), base-URL handling, error classification (offline / unauthorized / rate-limited / server), and the retry policy that honors `Retry-After`.

### Modified Capabilities

(none - new plugin, no existing specs)

## Impact

- **New code**: plugin directory `plugin/` at the repo root (shippable as `anytype-noctalia`), containing `manifest.json` + `Main.qml` + `BarWidget.qml` + `Panel.qml` + `Settings.qml` + `i18n/`.
- **New config file** (user-owned): `~/.config/anytype-noctalia/config.toml` written by the pairing wizard (mode 0600). Documented but not required - the plugin resolves the token via env var -> config file -> plugin settings.
- **Runtime deps**: either (a) a running Anytype desktop app on the user's machine, OR (b) a reachable self-hosted Any-Sync API endpoint. Noctalia Shell `>= 4.4.1` (same floor as `ntfy-notifications`). No native binaries, no sidecar daemon. **The plugin does not start, stop, or supervise the Anytype process** - that is the user's session management's job (launcher, systemd user units, Nix home-manager module as a future follow-up).
- **Secrets**: Bearer token resolved via env var -> `~/.config/anytype-noctalia/config.toml` -> `pluginSettings`. Config file is the preferred location; it is written with mode 0600 on pairing and shared with other tools (e.g. `anytype-cli`). `secret-tool`/`libsecret` is a tracked follow-up.
- **Network**: localhost HTTP (default) OR arbitrary user-supplied URL (server mode). HTTPS not enforced in server mode (localhost dev convenience) but encouraged with an inline warning.
- **Rate limits**: Anytype limits to 1 req/s sustained, burst 60. Default poll interval 15s per collection keeps us well under even with 4 collections.
- **Testing**: server mode can be exercised locally via `references/Dauliac-anytype-cli` and a short `anytype-cli serve`-equivalent probe; no production server required.
- **References cloned** under `references/`: `anytype-api`, `anytype-raycast`, `anytype-mcp`, `noctalia-plugins/ntfy-notifications`, `noctalia-plugins/todo`.
