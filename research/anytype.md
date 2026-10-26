# Anytype Integration Surface (late 2026)

Research for the Noctalia desktop-shell plugin.

Target capabilities we need to serve:

1. Notify when a new object lands in a specific collection/set
2. Create new objects (optionally into a collection) from the shell
3. Drive a Kanban-style todolist (status transitions on objects)

---

## 1. API transport

**HTTP REST, served by the desktop app on localhost.** No separate daemon to run,
no gRPC required for the common path.

- **Base URL:** `http://127.0.0.1:31009` (default). The current stable prefix
  is `/v1/...`; `/v2/...` is a pre-release that exposes objects as editable
  JSON documents and adds collection-scoped endpoints. See
  [Anytype API reference 2025-11-08](https://developers.anytype.io/docs/reference/2025-11-08/anytype-api/).
- **Introduced in:** desktop release 0.46.x (Local API).
- **Spec:** OpenAPI 3.1 at
  [openapi-2025-11-08.yaml](https://raw.githubusercontent.com/anyproto/anytype-api/main/docs/reference/openapi-2025-11-08.yaml).
- **gRPC still exists** inside `anytype-heart` (the embedded middleware shipped
  with the desktop client) and is reachable in advanced scenarios (file ops,
  chat streaming, backup/restore). For a desktop-shell plugin the HTTP API is
  the right default; gRPC is only needed if we discover a gap. See
  [anyproto/anytype-heart](https://github.com/anyproto/anytype-heart).

**Daemon requirement:** The Anytype desktop app must be running. There is no
headless mode exposed on the HTTP API; the port only binds while the client
process is live. Plan for the "Anytype not running" state.

---

## 2. Auth model

Bearer-token, with a pairing step up front. Two ways to obtain the token:

- **Manual (recommended for a dev install):** Settings -> API Keys -> "Create
  new" in the desktop app.
- **Programmatic challenge flow** (for first-run UX inside Noctalia):

  1. `POST /v1/auth/challenges` with the app name. The desktop app pops a
     4-digit code visible only to the user; the response carries a
     `challenge_id`.
  2. `POST /v1/auth/api_keys` with `challenge_id` + the 4-digit code typed
     back by the user. Response contains `api_key`.
  3. Store the key. All future calls:
     `Authorization: Bearer <api_key>`.

Source: [Authentication guide](https://developers.anytype.io/docs/guides/get-started/authentication).

The token is scoped to the signed-in local vault; there is no OAuth or
remote exchange. Treat it like an SSH key: offer "re-pair" if it ever stops
working after a vault reset.

---

## 3. Endpoints we need

All verified against the 2025-11-08 reference.

### Discover the vault

- `GET /v1/spaces` -> list spaces ([list_spaces](https://developers.anytype.io/docs/reference/2025-11-08/anytype-api/)).
- `GET /v1/spaces/{space_id}` -> single space.

### List objects in a collection / set

- **v1 (stable):** `GET /v1/spaces/{space_id}/objects` with query-string
  filters -- e.g. `?type=task&done=false&tags[in]=urgent`. Supports
  `offset` and `limit`. Returns id, name, icon, type info, snippet,
  layout, blocks, details. See
  [list-objects](https://developers.anytype.io/docs/reference/2025-11-08/list-objects/).
- **v2 (pre-release, cleaner for our use):**
  `GET /v2/spaces/{space_id}/collections/{collection_id}/objects` --
  returns the collection's membership in insertion order. See
  [get-collection-objects](https://developers.anytype.io/docs/reference/v2/get-collection-objects/).
  Use this once v2 stabilizes; fall back to v1 + a type/tag filter today.

### Create an object

- `POST /v1/spaces/{space_id}/objects` with `{name, icon, description,
  body (markdown), source (bookmarks), template, type_key, ...}`. See
  [create-object](https://developers.anytype.io/docs/reference/2025-11-08/create-object).
- The create endpoint does NOT atomically add the new object to a
  collection. Follow it with:

### Add object(s) to a collection / list

- `POST /v1/spaces/{space_id}/lists/{list_id}/objects` -- body is a
  JSON array of object IDs. See
  [add-list-objects](https://developers.anytype.io/docs/reference/2025-11-08/add-list-objects/).

### Kanban status transitions

Status in Anytype is a tag / property on the object. The flow is:

1. Look up the type/property via `GET /v1/.../types` and `.../properties`.
2. Patch the object with the new status value. The 2025-11-08 OpenAPI
   exposes `update_space` and object edit routes; the v2 "objects as
   JSON" model is designed exactly for this -- edit the JSON doc, PATCH
   it back. For the shell MVP, use the v1 object-update route and treat
   status as a tag.

### Global search (handy for "where is this object")

- `POST /v1/search` with `{query, types[], sort}` + `?offset=&limit=`.
  See [Searching and Filtering](https://developers.anytype.io/docs/guides/get-started/searching/).

---

## 4. Change-notification story

**There is no general-purpose subscription, webhook, or SSE stream for
object/collection changes in the public HTTP API as of 2025-11-08.**

What exists:

- **Chat API only** has SSE message streaming (`Last-Event-ID` resume) --
  added June 2026. This is scoped to chat messages, not objects.
  Confirmed in the changelog
  ([changelog](https://developers.anytype.io/docs/reference/changelog/)).
- The MCP server [anyproto/anytype-mcp](https://github.com/anyproto/anytype-mcp)
  explicitly excludes event-stream tools ("they don't produce bounded
  results") and recommends message-listing instead -- confirming that
  stream tooling is not generalized.
- Community discussions ([anyproto discussion #218](https://github.com/orgs/anyproto/discussions/218))
  explicitly ask for webhooks and event streaming for agent triggers;
  the "Collections 2.0" architectural work in the
  [Feb 2026 community update](https://blog.anytype.io/february-community-update-2026/)
  acknowledges it as a direction but has not shipped.

**Implication for Noctalia:** poll. Pattern:

- Keep a per-collection cursor = max `last_modified_date` (or hash of the
  ID list) from the previous `list` call.
- Poll `GET /v1/spaces/{space_id}/objects?type=...&sort=-last_modified_date`
  (or the v2 collection endpoint) on a tunable interval. 10-30s is
  friendly to the rate limiter (see below).
- Diff against the cached snapshot -> fire the "new object" shell
  notification locally.

If/when Anytype ships object SSE, swap the poller for a stream consumer
without changing the shell-facing API.

---

## 5. Rate limits & operational constraints

Primary source: [Rate Limits](https://developers.anytype.io/docs/guides/fundamentals/rate-limits/).

- Token-bucket: **sustained 1 req/s, burst 60**.
- 429 on breach; honor `Retry-After`.
- Hard-disable (not recommended in production) with
  `ANYTYPE_API_DISABLE_RATE_LIMIT=1` on the Anytype process.
- Everything runs on `127.0.0.1` -- no TLS, no cross-origin story. Keep
  the Bearer token in the user's keyring (libsecret / kwallet).
- API only answers while the desktop app is running. Detect the port
  being closed and surface "Anytype offline" cleanly.
- Multiple concurrent clients are fine (the limit is per-process on the
  server side), but share one token per Noctalia install.

---

## 6. Official SDK repo (ghq form)

Anytype does not ship an "official SDK" package; the official stance is
**OpenAPI + the developer portal is the source of truth**. The anchor
repo to clone is the portal + OpenAPI spec itself:

- `github.com/anyproto/anytype-api` -- OpenAPI, guides, examples, and
  the "Start building" portal. Treat this as the canonical reference;
  generate a client from the OpenAPI if you want typed bindings.

Officially-adjacent clients built in-house by Any Association:

- `github.com/anyproto/anytype-raycast` -- the Raycast extension
  (TypeScript, HTTP). Closest in spirit to a desktop-shell integration.
- `github.com/anyproto/anytype-mcp` -- MCP server (HTTP, polling model).

For heavy lifting (if we need gRPC later):

- `github.com/anyproto/anytype-heart` -- middleware shipped inside the
  desktop app; owns the gRPC + protobuf surface.

---

## 7. Reference integrations to clone

Picked for diversity of transport (all HTTP), language, and relevance to a
shell/notifier use case:

1. **`github.com/anyproto/anytype-raycast`** -- official. TypeScript,
   HTTP, implements browse / search / create flows. Best blueprint for
   "shell panel talking to localhost Anytype".
2. **`github.com/anyproto/anytype-mcp`** -- official. HTTP client with
   explicit polling patterns and a clean read-only tool model.
3. **`github.com/stevelr/anytype`** -- active (last touched Sep 2026),
   CLI + Rust library + MCP server. Supports both HTTP and gRPC; good
   reference for daemon detection, credential storage, and markdown
   round-trips. ~34 stars but 696 commits.
4. **`github.com/ablunier/anytype-client`** -- TypeScript, ESM-only,
   targets API v2, zero runtime deps, runs in Node/Deno/Bun/Electron.
   Returns errors as values (useful for a notifier that must stay
   quiet on transient 403/404). Minimal but current.
5. **`github.com/lanesawyer/anytype_rs`** -- Rust library + CLI. Author
   flags it as "vibe-coded, not comprehensive" -- include only as a
   secondary reference for CLI patterns.
6. **`github.com/charlesneimog/anytype-client`** -- Python client,
   ~96 stars. Useful if we ever want a quick scripting entry point;
   not needed for Noctalia itself.

If limiting to five, drop (5).

---

## 8. Open questions / to-watch

- v2 stabilization date -- it will likely replace the ad-hoc
  "list objects + filter by type" pattern with first-class collection
  endpoints.
- Collections 2.0 architectural work ([Feb 2026 update](https://blog.anytype.io/february-community-update-2026/))
  -- will reshape how sets vs collections are modeled.
- Webhook / SSE for objects -- actively requested, not promised. Design
  Noctalia's internal change-notification interface so the poller is
  swappable without reaching into the shell layer.

---

## Sources

- [Anytype API Reference 2025-11-08](https://developers.anytype.io/docs/reference/2025-11-08/anytype-api/)
- [Anytype API Changelog](https://developers.anytype.io/docs/reference/changelog/)
- [Authentication Guide](https://developers.anytype.io/docs/guides/get-started/authentication)
- [Rate Limits](https://developers.anytype.io/docs/guides/fundamentals/rate-limits/)
- [List Objects](https://developers.anytype.io/docs/reference/2025-11-08/list-objects/)
- [Create Object](https://developers.anytype.io/docs/reference/2025-11-08/create-object)
- [Add Objects to List](https://developers.anytype.io/docs/reference/2025-11-08/add-list-objects/)
- [v2 Get Collection Objects](https://developers.anytype.io/docs/reference/v2/get-collection-objects/)
- [Searching and Filtering](https://developers.anytype.io/docs/guides/get-started/searching/)
- [OpenAPI spec 2025-11-08](https://raw.githubusercontent.com/anyproto/anytype-api/main/docs/reference/openapi-2025-11-08.yaml)
- [anyproto/anytype-api](https://github.com/anyproto/anytype-api)
- [anyproto/anytype-heart](https://github.com/anyproto/anytype-heart)
- [anyproto/anytype-raycast](https://github.com/anyproto/anytype-raycast)
- [anyproto/anytype-mcp](https://github.com/anyproto/anytype-mcp)
- [anyproto discussion #218: webhook/event asks](https://github.com/orgs/anyproto/discussions/218)
- [Feb 2026 community update: Collections 2.0](https://blog.anytype.io/february-community-update-2026/)
- [stevelr/anytype (Rust CLI + lib + MCP)](https://github.com/stevelr/anytype)
- [ablunier/anytype-client (TypeScript v2)](https://github.com/ablunier/anytype-client)
- [lanesawyer/anytype_rs (Rust)](https://github.com/lanesawyer/anytype_rs)
- [charlesneimog/anytype-client (Python)](https://github.com/charlesneimog/anytype-client)
