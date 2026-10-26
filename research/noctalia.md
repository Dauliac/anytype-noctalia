# Noctalia research  -  building an Anytype plugin

Research for an Anytype plugin for the Noctalia desktop shell. All claims link to
the primary source (GitHub repo, raw QML, or Quickshell docs).

Target feature set:

1. Toast / badge when a new object lands in an Anytype collection.
2. Quick-add an item into an Anytype list from the shell.
3. (Later) Kanban-ish todo panel backed by Anytype.

---

## 1. Canonical repository

- **Shell**: [`github.com/noctalia-dev/noctalia-shell`](https://github.com/noctalia-dev/noctalia-shell)
   -  `default_branch=main` is the **v5 C++ rewrite** (early alpha, no Qt / no QML; verified via
  `gh api repos/noctalia-dev/noctalia-shell` returning `"language":"C++"`).
- **QML / Quickshell version** lives on the **`legacy-v4`** branch of the same repo
  ([tree view](https://github.com/noctalia-dev/noctalia-shell/tree/legacy-v4)). This is the
  branch to target today  -  the plugin system described below is a v4 feature and v5 is not
  usable yet.
- **Plugin registry** (official): [`github.com/noctalia-dev/noctalia-plugins`](https://github.com/noctalia-dev/noctalia-plugins)
   -  ~90 plugins, each a top-level directory. This is the repo an Anytype plugin would
  eventually PR into (or be hosted externally and registered as a custom source).

ghq-cloneable:

```sh
ghq get github.com/noctalia-dev/noctalia-shell
ghq get github.com/noctalia-dev/noctalia-plugins
# then: cd ~/ghq/github.com/noctalia-dev/noctalia-shell && git checkout legacy-v4
```

---

## 2. Architecture (v4 / legacy-v4 branch)

Noctalia v4 is a pure **[Quickshell](https://quickshell.org/)** config  -  Quickshell is a
QtQuick/QML framework for building Wayland desktop shells, loaded by running
`quickshell -p path/to/shell.qml`
([Quickshell intro](https://quickshell.org/docs/guide/introduction/)).

### Root layout of `legacy-v4`

Verified via `gh api 'repos/noctalia-dev/noctalia-shell/contents?ref=legacy-v4'`:

```
shell.qml              # entrypoint loaded by `quickshell`
Modules/               # UI surfaces: Bar, Dock, Notification, OSD, Panels, …
  Bar/
    Bar.qml
    Widgets/           # ~30 built-in bar widgets (one QML file each)
    Extras/            # BarPill, BarWidgetLoader, …
  Panels/
    Plugins/
      PluginPanelSlot.qml   # the mounting point for plugin panels
    Settings/, Launcher/, ControlCenter/, …
  Notification/ Notification.qml
  Dock/ OSD/ LockScreen/ Toast/ Tooltip/ DesktopWidgets/
Services/              # QML singletons (business logic)
  Noctalia/
    PluginRegistry.qml      # scans ~/.config/noctalia/plugins/
    PluginService.qml       # loads/unloads plugin Components, hot reload, APIs
    UpdateService.qml, SupporterService.qml, …
  UI/, Media/, Networking/, Power/, Theming/, …
Widgets/               # N*.qml  -  the design-system primitives
  NButton, NTextInput, NPopupContextMenu, NListView, NTabView,
  NPluginSettingsPopup, …
Commons/               # Settings.qml, Style.qml, I18n.qml, Logger.qml, Icons.qml
Helpers/               # sha256.js, utility JS
Assets/ Shaders/ Scripts/
```

### Config format

Despite the v5 README advertising TOML, **v4 uses JSON** on disk, read and mutated via a
`Settings` singleton (`Commons/Settings.qml`) and a per-plugin `pluginSettings` object
persisted via `saveSettings()` (see §3). Plugin manifests are `manifest.json`.

### Rendering model

Everything is a QML `Item` tree mounted inside Quickshell `PanelWindow`s (bars, panels,
overlays) and `FloatingWindow`s. Panels, launchers, OSDs, notifications all extend the same
pattern: a QML component declaring geometry + content, instantiated per-screen.
([Quickshell type listing](https://quickshell.org/docs/types/))

---

## 3. Extension model  -  **drop-in plugin directory, no fork required**

Noctalia v4 ships a first-class plugin system. There is **no need to fork the shell**.

### Where plugins live

`PluginRegistry.qml` sets `pluginsDir = Settings.configDir + "plugins"` and reads a
`plugins.json` describing installed plugins and enabled state
([PluginRegistry.qml](https://github.com/noctalia-dev/noctalia-shell/blob/legacy-v4/Services/Noctalia/PluginRegistry.qml)).
On startup, `PluginService.qml` discovers each plugin, loads its `manifest.json`, creates a
QML `Component` from the declared entry points, and mounts instances into a
`pluginContainer` placeholder owned by `shell.qml`
([PluginService.qml](https://github.com/noctalia-dev/noctalia-shell/blob/legacy-v4/Services/Noctalia/PluginService.qml)).

### Plugin on-disk layout

From the [plugins repo README](https://github.com/noctalia-dev/noctalia-plugins/blob/main/README.md)
and [AGENTS.md](https://github.com/noctalia-dev/noctalia-plugins/blob/main/AGENTS.md):

```
my-plugin/
  manifest.json         # required
  README.md             # required
  preview.png           # required, 960x540
  Main.qml              # shared state + IPC handlers (optional but recommended)
  BarWidget.qml         # bar entry (optional)
  Panel.qml             # overlay popup (optional)
  ControlCenterWidget.qml  # control-center tile (optional)
  Settings.qml          # settings UI (optional)
  DesktopWidget.qml, DesktopWidgetSettings.qml  (optional)
  LauncherProvider.qml  # launcher search provider (optional)
  i18n/                 # translations
```

### Manifest skeleton (minimum)

```jsonc
{
  "id": "anytype",
  "name": "Anytype",
  "version": "0.1.0",
  "minNoctaliaVersion": "3.6.0",
  "license": "MIT",
  "repository": "https://github.com/Dauliac/anytype-noctalia",
  "description": "Anytype collections, lists, and todos in Noctalia",
  "tags": ["Productivity", "Bar", "Panel"],
  "entryPoints": {
    "main":       "Main.qml",
    "barWidget":  "BarWidget.qml",
    "panel":      "Panel.qml",
    "settings":   "Settings.qml"
  },
  "dependencies": { "plugins": [] },
  "metadata": { "defaultSettings": { /* schema goes here */ } }
}
```

### The `pluginApi` object (injected into every entry point)

Every QML entry point receives `property var pluginApi: null`, exposing
([AGENTS.md source](https://github.com/noctalia-dev/noctalia-plugins/blob/main/AGENTS.md)):

| Member                        | Purpose |
|-------------------------------|---------|
| `pluginSettings`              | mutable settings dict, persisted via `saveSettings()` |
| `manifest`                    | read-only `manifest.json` contents |
| `pluginId`, `pluginDir`       | identity + absolute path on disk |
| `mainInstance`                | handle to the `Main.qml` instance (shared state hub) |
| `tr(key, interp)` / `trp(…)`  | i18n lookup against `i18n/` |
| `openPanel(screen, widget)` / `togglePanel(screen, widget)` | panel control |
| `saveSettings()`              | persist `pluginSettings` to disk |
| `withCurrentScreen(cb)`       | resolve the active screen inside IPC handlers |
| `panelOpenScreen`             | screen where this plugin's panel is currently open |

### Distribution

Official plugins PR to `noctalia-dev/noctalia-plugins` (CI validates +
auto-regenerates `registry.json`). Third-party plugins can live in any Git
repo and be registered as a **custom plugin source**  -  `PluginRegistry.qml`
distinguishes official vs custom via `generateCompositeKey(pluginId, sourceUrl)`
(official keeps the plain id; custom gets a `<sha256-prefix>:<id>` composite). So
`anytype-noctalia` can ship as a standalone repo; users add the source URL in
Noctalia's plugin manager UI.

### Hot reload

`PluginService.qml` wires `FileView` watchers over the plugin dir when
`Settings.isDebug` is true  -  edit a `.qml` under `~/.config/noctalia/plugins/anytype/`
and the component is torn down and re-instantiated. Big dev-loop win.

---

## 4. Reference modules to study first (in order)

Rank-ordered for the Anytype plugin. All on `legacy-v4` branch unless noted.

### Reference plugins in `noctalia-dev/noctalia-plugins`

| Plugin | Why it matters for Anytype |
|---|---|
| **[`todo`](https://github.com/noctalia-dev/noctalia-plugins/tree/main/todo)** | Closest functional analogue: pages (columns), per-item CRUD, panel UI, bar widget showing a count, export subprocess. Has `BarWidget + ControlCenterWidget + DesktopWidget + Main + Panel + Settings`  -  a maximal set of entry points. Study [`Main.qml`](https://github.com/noctalia-dev/noctalia-plugins/blob/main/todo/Main.qml) for the shared-state pattern and [`Panel.qml`](https://github.com/noctalia-dev/noctalia-plugins/blob/main/todo/Panel.qml) for the list UI. |
| **[`ntfy-notifications`](https://github.com/noctalia-dev/noctalia-plugins/tree/main/ntfy-notifications)** | Mirror of use case (1): poll an HTTP endpoint, keep an unread set, raise toasts, badge the bar widget. [`Main.qml`](https://github.com/noctalia-dev/noctalia-plugins/blob/main/ntfy-notifications/Main.qml) shows the `Timer`-driven poll loop, `IpcHandler`, and read-state persistence. |
| **[`rss-feed`](https://github.com/noctalia-dev/noctalia-plugins/tree/main/rss-feed)** | Same HTTP-poll + unread-count idiom, with a `_seenInitialUnreadSet` guard so you don't toast every item on first fetch  -  a trap the Anytype plugin will hit. ([`BarWidget.qml`](https://github.com/noctalia-dev/noctalia-plugins/blob/main/rss-feed/BarWidget.qml)) |
| **[`obsidian-provider`](https://github.com/noctalia-dev/noctalia-plugins/tree/main/obsidian-provider)** | A plugin that integrates an external knowledge app via `LauncherProvider.qml`  -  the exact shape a "quick-add to Anytype list" launcher entry would take. |
| **[`habitica`](https://github.com/noctalia-dev/noctalia-plugins/tree/main/habitica)** | Another external-service plugin  -  todo-list-ish with avatar display, HTTP polling, settings UI. Second data point for the "sync external SaaS state" pattern. |

### Reference QML inside the shell itself

| Path (on `legacy-v4`) | Why |
|---|---|
| [`Modules/Bar/Widgets/CustomButton.qml`](https://github.com/noctalia-dev/noctalia-shell/blob/legacy-v4/Modules/Bar/Widgets/CustomButton.qml) | Canonical pattern for a bar widget with context menu, per-widget settings, screen/section awareness. Copy its property boilerplate. |
| [`Modules/Panels/Plugins/PluginPanelSlot.qml`](https://github.com/noctalia-dev/noctalia-shell/blob/legacy-v4/Modules/Panels/Plugins/PluginPanelSlot.qml) | How the shell mounts a plugin's `Panel.qml`. Tells you what properties your Panel must expose (`geometryPlaceholder`, `allowAttach`, size properties). |
| [`Modules/Bar/Widgets/NotificationHistory.qml`](https://github.com/noctalia-dev/noctalia-shell/blob/legacy-v4/Modules/Bar/Widgets/NotificationHistory.qml) | Native notification-badge widget; the toast + unread badge pattern the Anytype plugin wants to copy. |
| [`Widgets/NPopupContextMenu.qml`](https://github.com/noctalia-dev/noctalia-shell/blob/legacy-v4/Widgets/NPopupContextMenu.qml) + [`NListView.qml`](https://github.com/noctalia-dev/noctalia-shell/blob/legacy-v4/Widgets/NListView.qml) + [`NTextInput.qml`](https://github.com/noctalia-dev/noctalia-shell/blob/legacy-v4/Widgets/NTextInput.qml) | The design-system primitives you'll actually assemble into a Kanban. All plugin UIs should import `qs.Widgets` and compose these  -  do not re-implement. |

**Top 2 to read before writing any code**:
1. `noctalia-plugins/todo/Main.qml` + `Panel.qml`  -  the whole state model.
2. `noctalia-plugins/ntfy-notifications/Main.qml`  -  the poll+toast model.

---

## 5. Quickshell APIs relevant to this plugin

Verified against [quickshell.org/docs](https://quickshell.org/docs/) (the old
`quickshell.outfoxxed.me` domain 301s here).

### Notifications

[`Quickshell.Services.Notifications`](https://quickshell.org/docs/types/Quickshell.Services.Notifications/)
exposes `NotificationServer` + `Notification`  -  but these are for **implementing a
notification daemon** (receive side). The shell itself cannot *send* a desktop
notification from this module.

Workarounds used by every reference plugin:

- **In-shell toast**  -  call the shell's own `ToastService` singleton:
  `ToastService.showNotice("…")` / `.showError("…")`. Used by [`todo/Main.qml`](https://github.com/noctalia-dev/noctalia-plugins/blob/main/todo/Main.qml) via `import qs.Services.UI`.
- **System-wide notification**  -  spawn `notify-send` via `Quickshell.Io.Process`.

### HTTP

**No HTTP client type exists in Quickshell.Io** (verified against
[Quickshell.Io docs](https://quickshell.org/docs/types/Quickshell.Io/)  -  module lists
`Process`, `FileView`, `IpcHandler`, `Socket`, `SocketServer`, `DataStream`,
`StdioCollector`, `JsonAdapter`; no HTTP). All existing plugins (ntfy, rss-feed, github-feed,
habitica) call out to **`curl` via `Quickshell.Io.Process`** and parse the JSON response via
`StdioCollector`.

Pattern (observed in `ntfy-notifications/Main.qml`):

```qml
Process {
  id: fetch
  running: false
  command: ["curl", "-s", "-H", "Authorization: Bearer " + token, url]
  stdout: StdioCollector {
    onStreamFinished: {
      const data = JSON.parse(this.text);
      // …handle response, trigger toasts, update ListModel
    }
  }
}
```

For the Anytype plugin this means: shell out to the local Anytype gRPC/HTTP gateway (or the
`anytype-heart` CLI if one exists) through `Process`.

### Panels / popups

- `PanelWindow`  -  the layer-shell window every bar/overlay uses.
- `PopupWindow`  -  anchored transient windows.
  Both covered in [Quickshell.Widgets](https://quickshell.org/docs/types/Quickshell.Widgets/).
- Inside a Noctalia plugin you don't instantiate `PanelWindow` directly  -  you declare a
  `Panel.qml` and the shell mounts it via `PluginPanelSlot.qml`.

### Persistent state

Two layers:

1. **Plugin settings**: mutate `pluginApi.pluginSettings` (a plain JS object) and call
   `pluginApi.saveSettings()`  -  Noctalia persists it as JSON. Used for every piece of
   per-plugin config and lightweight state (read-markers, last-seen IDs, cached ids).
2. **Larger blobs** (e.g. a cached collection snapshot): `Quickshell.Io.FileView` with
   `JsonAdapter` on a file under `pluginApi.pluginDir`. See
   [`FileView` docs](https://quickshell.org/docs/types/Quickshell.Io/).

### IPC (external control)

`Quickshell.Io.IpcHandler` with `target: "plugin:anytype"` lets users wire a keybind to
e.g. `qs ipc call plugin:anytype addItem "<text>"` for the quick-add use case. Pattern is
all over the reference plugins (`ntfy-notifications/Main.qml`, `todo/Main.qml`).

---

## 6. Other repos worth cloning as references

```sh
ghq get github.com/noctalia-dev/noctalia-shell          # the shell itself (checkout legacy-v4)
ghq get github.com/noctalia-dev/noctalia-plugins        # ~90 plugin exemplars
ghq get github.com/quickshell-mirror/quickshell         # Quickshell source (QML type reference)
ghq get github.com/outfoxxed/quickshell-examples        # minimal Quickshell demo configs
ghq get github.com/MaySeikatsu/noctalia-shell-wallust   # live Noctalia fork  -  shows how users customise
```

Notes:

- `quickshell-mirror/quickshell` is the GitHub mirror of the Forgejo-hosted upstream at
  [`git.outfoxxed.me/quickshell/quickshell`](https://git.outfoxxed.me/quickshell/quickshell).
  If the mirror is stale, clone from Forgejo instead.
- `outfoxxed/quickshell-examples` has not been verified to exist at that exact slug  -  if
  `ghq get` fails, swap for the "Build Your Own Bar" tutorial repo linked from
  [tonybtw.com/tutorial/quickshell](https://tonybtw.com/tutorial/quickshell/).
- `MaySeikatsu/noctalia-shell-wallust` is one of several active Noctalia forks surfaced by
  [`github.com/topics/noctalia`](https://github.com/topics/noctalia); clone 1–2 forks to see
  what real user customization looks like.

Inside `noctalia-plugins`, zoom in on these subdirectories specifically:

- `todo/`  -  closest functional analogue
- `ntfy-notifications/`  -  HTTP poll + toast pattern
- `rss-feed/`  -  HTTP poll + unread set + initial-fetch guard
- `obsidian-provider/`  -  external-app integration via LauncherProvider
- `habitica/`  -  SaaS integration + settings UI
- `calendar-widget/`, `weekly-calendar/`  -  richer panel layouts worth cribbing for Kanban UI

---

## 7. Open questions for the Anytype side

Out of scope for this doc but flagged so follow-up research can start:

- Does Anytype expose a stable local API we can hit from `curl`? Anytype's "any-sync" and
  `anytype-heart` daemon are the usual integration points, but public API stability is
  unclear.
- Collection-change notifications: do we poll (easy, matches `ntfy`/`rss-feed` plugins) or
  subscribe to a websocket / gRPC stream (needs a sidecar helper, since Quickshell has
  neither client built in)?
- Auth model  -  API tokens vs device-pairing vs the Anytype CLI's existing session.

---

## Sources

- [github.com/noctalia-dev/noctalia-shell](https://github.com/noctalia-dev/noctalia-shell)  -  main repo
- [github.com/noctalia-dev/noctalia-shell/tree/legacy-v4](https://github.com/noctalia-dev/noctalia-shell/tree/legacy-v4)  -  QML/Quickshell branch
- [github.com/noctalia-dev/noctalia-plugins](https://github.com/noctalia-dev/noctalia-plugins)  -  official plugin registry
- [noctalia-plugins/AGENTS.md](https://github.com/noctalia-dev/noctalia-plugins/blob/main/AGENTS.md)  -  plugin API ref
- [Quickshell documentation](https://quickshell.org/docs/) (formerly quickshell.outfoxxed.me)
- [Quickshell.Io module](https://quickshell.org/docs/types/Quickshell.Io/)
- [Quickshell.Services.Notifications module](https://quickshell.org/docs/types/Quickshell.Services.Notifications/)
- [Quickshell.Widgets module](https://quickshell.org/docs/types/Quickshell.Widgets/)
- [tux.fan  -  Noctalia overview post](https://tux.fan/2026/07/14/noctalia-wayland-desktop-shell-2026/)
- [github.com/topics/noctalia](https://github.com/topics/noctalia)  -  community forks index
