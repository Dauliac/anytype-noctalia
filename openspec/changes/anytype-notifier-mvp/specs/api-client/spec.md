## Purpose

Shared HTTP client that talks to an Anytype API endpoint. Supports two deployment modes: `localhost` (default, hits the Anytype desktop app on `127.0.0.1:31009`) and `server` (hits an Any-Sync self-hosted node or a remote relay). Owns Bearer-token acquisition (challenge pairing), token resolution via a precedence chain (env var -> config file -> plugin settings), request assembly, error classification, and rate-limit-friendly retry. Every other capability (notifier, quick-add) issues requests through this client only.

## ADDED Requirements

### Requirement: Pair-with-Anytype flow via challenge code

The plugin SHALL offer a pairing flow that acquires a Bearer token using Anytype's challenge endpoints, without ever asking the user to copy-paste a token from Anytype settings.

#### Scenario: Successful pairing
- **WHEN** the user opens Settings and clicks "Pair with Anytype"
- **AND** the plugin posts to `POST /v1/auth/challenges` and receives a `challenge_id`
- **AND** the user types the 4-digit code that Anytype displays into the Settings input
- **AND** the plugin posts to `POST /v1/auth/api_keys` with `challenge_id` + the code
- **THEN** the plugin SHALL store the returned `api_key` in `pluginSettings.apiKey` via `saveSettings()`
- **AND** the Settings UI SHALL switch to a "Paired" state showing the first 6 characters of the key

#### Scenario: User typed the wrong code
- **WHEN** `POST /v1/auth/api_keys` returns 4xx
- **THEN** the plugin SHALL NOT clobber any previously-stored key
- **AND** SHALL show an inline error `pluginApi.tr("auth.wrongCode")`
- **AND** SHALL keep the Settings UI in the "awaiting code" state so the user can retry

#### Scenario: Anytype desktop app is not running during pairing
- **WHEN** `POST /v1/auth/challenges` returns `status === 0` (connection refused)
- **THEN** the Settings UI SHALL show `pluginApi.tr("error.offline")` with an "Open Anytype" hint
- **AND** SHALL NOT consume the challenge slot

### Requirement: Bearer-token on every API call

All non-pairing HTTP requests SHALL send `Authorization: Bearer <apiKey>` from `pluginSettings.apiKey`.

#### Scenario: Token present
- **WHEN** the client issues `GET /v1/spaces` or any other authed endpoint
- **THEN** the request SHALL include `Authorization: Bearer <apiKey>`

#### Scenario: Token missing or empty
- **WHEN** `pluginSettings.apiKey` is empty or missing
- **THEN** the client SHALL short-circuit the request and emit a "notPaired" error without touching the network

### Requirement: Error classification

The client SHALL classify every response into one of: `ok`, `offline`, `unauthorized`, `notFound`, `rateLimited`, `serverError`, `parseError`.

#### Scenario: Connection refused
- **WHEN** XHR completes with `status === 0`
- **THEN** classification SHALL be `offline`

#### Scenario: Expired or revoked token
- **WHEN** XHR completes with `status === 401` or `403`
- **THEN** classification SHALL be `unauthorized`
- **AND** the error payload SHALL include `shouldRePair: true`

#### Scenario: Rate limited
- **WHEN** XHR completes with `status === 429`
- **THEN** classification SHALL be `rateLimited`
- **AND** the error payload SHALL carry the `Retry-After` header value in seconds, defaulting to 2 if absent

### Requirement: Rate-limit-friendly retry

The client SHALL honor Anytype's 1 rps sustained + 60 burst rate limit by not retrying faster than `Retry-After` on a 429.

#### Scenario: 429 with Retry-After header
- **WHEN** classification is `rateLimited` with `retryAfter = 5`
- **THEN** the client SHALL schedule exactly one retry after 5 seconds (using a QML `Timer`)
- **AND** SHALL NOT retry further on a second 429 - instead propagates the error to the caller

### Requirement: Concurrency

Only one in-flight request per endpoint SHALL be allowed. A second call for the same endpoint while one is pending SHALL return the pending promise, not open a new XHR.

#### Scenario: Two near-simultaneous polls on the same collection
- **WHEN** the Timer fires while a previous poll for the same collection is still in flight
- **THEN** the Timer-triggered call SHALL be dropped silently (no second XHR)

### Requirement: Base URL is overridable

The base URL SHALL default to `http://127.0.0.1:31009` and SHALL be overridable from Settings for users running Anytype on a non-default port.

#### Scenario: Custom base URL
- **WHEN** `pluginSettings.baseUrl` is `http://127.0.0.1:31010`
- **THEN** all requests SHALL target that base

### Requirement: Deployment mode (localhost vs server)

The client SHALL support two deployment modes, selectable in Settings and persisted in `pluginSettings.mode`:

- `localhost`: hits the Anytype desktop app on the loopback interface (default; the HTTP API bound by Anytype desktop >= 0.46.x).
- `server`: hits a user-supplied remote URL. This covers users running their own Any-Sync node, a corporate relay, or any future hosted Anytype API endpoint.

#### Scenario: Mode = localhost (default)
- **WHEN** `pluginSettings.mode` is unset or `"localhost"`
- **AND** `pluginSettings.baseUrl` is unset
- **THEN** every request SHALL target `http://127.0.0.1:31009`
- **AND** the "offline" classification SHALL carry a hint `openAnytypeDesktop: true`

#### Scenario: Mode = server with explicit URL
- **WHEN** `pluginSettings.mode === "server"`
- **AND** `pluginSettings.serverUrl` is `https://anytype.example.com`
- **THEN** every request SHALL target that base URL
- **AND** the "offline" classification SHALL carry a hint `openAnytypeDesktop: false` (because the user is not expected to launch a local desktop app)
- **AND** the plugin SHALL NOT suggest "re-pair" on `offline` - a server mode outage is not an auth problem

#### Scenario: Server mode requires HTTPS
- **WHEN** `pluginSettings.mode === "server"`
- **AND** the user types `http://` (not loopback) into `serverUrl`
- **THEN** the Settings UI SHALL show an inline warning but SHALL NOT block saving (localhost HTTP is still allowed for dev)

### Requirement: Token resolution precedence

The Bearer token in use SHALL be resolved on every request by walking this precedence chain, taking the first non-empty source:

1. Environment variable `ANYTYPE_API_KEY`
2. Config file field `api_key` at `${XDG_CONFIG_HOME:-~/.config}/anytype-noctalia/config.toml`
3. `pluginSettings.apiKey` (written by the in-shell pairing wizard)

#### Scenario: Config file wins over plugin settings
- **WHEN** `~/.config/anytype-noctalia/config.toml` has `api_key = "cfg-token"`
- **AND** `pluginSettings.apiKey` is `"settings-token"`
- **AND** `ANYTYPE_API_KEY` is unset
- **THEN** requests SHALL send `Authorization: Bearer cfg-token`

#### Scenario: Env var wins over config file
- **WHEN** `ANYTYPE_API_KEY=env-token`
- **AND** the config file has `api_key = "cfg-token"`
- **THEN** requests SHALL send `Authorization: Bearer env-token`

#### Scenario: No source yields a token
- **WHEN** all three sources are empty
- **THEN** the client SHALL emit `notPaired` without touching the network
- **AND** the Settings UI SHALL render the "Pair" entry point as primary

### Requirement: Config file read is safe and reactive

The plugin SHALL read `~/.config/anytype-noctalia/config.toml` on startup and SHALL re-read it when the file's mtime changes, so the user can edit it with their editor without restarting Noctalia.

#### Scenario: Config file missing
- **WHEN** the config file does not exist
- **THEN** the plugin SHALL fall through the precedence chain without logging an error
- **AND** SHALL NOT create the file eagerly - creation only happens when the user successfully pairs via Settings

#### Scenario: Config file world-readable
- **WHEN** the config file exists with permissions wider than 0600
- **THEN** the plugin SHALL still load it
- **AND** SHALL raise a one-time warning toast `pluginApi.tr("config.permissionsLax")` suggesting `chmod 600`

#### Scenario: Config file edited while plugin running
- **WHEN** the user replaces `api_key = "old"` with `api_key = "new"` in their editor
- **THEN** within one poll cycle the next request SHALL use the new value
- **AND** no restart SHALL be required

#### Scenario: Pairing writes to config file by default
- **WHEN** the user completes the challenge pairing in Settings
- **AND** `~/.config/anytype-noctalia/` is writable
- **THEN** the plugin SHALL write `api_key = "<new-token>"` to `config.toml` with mode 0600
- **AND** SHALL NOT also write to `pluginSettings.apiKey`

#### Scenario: Pairing with read-only config dir
- **WHEN** pairing completes but the config file cannot be written
- **THEN** the plugin SHALL fall back to writing `pluginSettings.apiKey` via `saveSettings()`
- **AND** SHALL show a persistent warning in Settings explaining the fallback and how to fix permissions

### Requirement: Config file schema

The config file SHALL be TOML with the following keys, all optional:

```toml
# ~/.config/anytype-noctalia/config.toml
mode      = "localhost"                   # or "server"
base_url  = "http://127.0.0.1:31009"      # overrides default when mode = localhost
server_url = "https://anytype.example.com" # used when mode = server
api_key   = "..."                         # Bearer token
space_id  = "bafy..."                     # default space to use
```

#### Scenario: Partial config file
- **WHEN** the file sets only `api_key` and omits every other key
- **THEN** the plugin SHALL use the file's `api_key` and fall back to `pluginSettings` for the other fields

#### Scenario: Unknown keys
- **WHEN** the file contains a key the plugin does not recognise
- **THEN** the plugin SHALL load the recognised keys and ignore the rest without error
