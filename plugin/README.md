# anytype-noctalia

Noctalia Shell plugin bridging the Anytype local HTTP API. Watch collections for new objects, quick-add from the bar, and (soon) manage a Kanban board, all without leaving Noctalia.

![preview](preview.png)

## Features

- **Bar widget**: database icon with unread count badge. Variants for offline (Anytype closed) and needs-re-pair (token revoked).
- **Panel**:
  - Latest updates: unified time-sorted feed across all watched collections.
  - Kanban slot: a dedicated collection rendered as a board (Phase 2; MVP ships the slot as a placeholder with live object count).
  - Quick-add: create a new object into your default target collection.
- **Settings**: pair with Anytype via a 4-digit challenge (localhost mode) or paste a Bearer token (server mode), pick a space, check which collections to watch (with per-collection poll intervals), designate the Kanban collection, pick which fields appear in notifications (defaults: creation date + created by).
- **IPC**: `qs ipc call plugin:anytype-noctalia toggle | refresh | markAllRead | add "text"`.

## Install

Drop the plugin directory under `~/.config/noctalia/plugins/anytype-noctalia/`, or submit through the official Noctalia plugins browser once published.

Requires Noctalia Shell >= 4.4.1 on the `legacy-v4` branch (the main branch is a C++ rewrite without the QML plugin loader).

## Pairing (localhost mode)

1. Make sure the Anytype desktop app is running.
2. Open Settings for the plugin, click Pair.
3. Anytype will display a 4-digit code - type it into the plugin.
4. The Bearer token is written to `~/.config/anytype-noctalia/config.toml` (mode 0600). This file is also honored on startup, so you can pre-provision one by hand.

## Pairing (server mode)

If you run a self-hosted Any-Sync node or any API-compatible endpoint, flip the mode in Settings and paste your Bearer token.

## Token precedence

Resolved in this order on every request:

1. `ANYTYPE_API_KEY` environment variable
2. `~/.config/anytype-noctalia/config.toml` `api_key` field
3. Plugin settings (`pluginSettings.apiKey`)

The config file is the preferred storage. Edit it with your editor; the plugin re-reads on mtime change without a Noctalia restart.

## Note on the Anytype process

**The plugin does not start, stop, or supervise Anytype.** Starting the desktop app or your self-hosted server is your session management's job (launcher, systemd user units, Nix home-manager). The plugin only observes the HTTP endpoint - when it is offline, the plugin reports it and keeps polling at a slow cadence until it comes back.

## Links

- Repo: https://github.com/Dauliac/anytype-noctalia
- Anytype API: https://developers.anytype.io
- Noctalia Shell: https://github.com/noctalia-dev/noctalia-shell
