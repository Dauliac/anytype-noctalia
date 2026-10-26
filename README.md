# anytype-noctalia

Noctalia Shell plugin bridging the Anytype local HTTP API: notify on new objects in watched collections, quick-add from the bar, and (soon) a Kanban view over one collection.

## Repo layout

```
plugin/           # the shippable Noctalia plugin (QML + QtQuick JS)
  manifest.json
  Main.qml  ApiClient.qml  ConfigFile.qml  BarWidget.qml  Panel.qml  Settings.qml
  i18n/en.json  i18n/fr.json
  README.md

openspec/         # OpenSpec design artifacts
  changes/anytype-notifier-mvp/{proposal,design,tasks}.md + specs/
  changes/anytype-kanban-todo/   (Phase 2, deferred)

research/         # written research artifacts (anytype API, noctalia architecture)
references/       # symlinked ghq clones of upstream repos (gitignored)
mise.toml         # intentionally minimal; QML needs no runtime toolchain
```

## Target features

1. Notify when a new object is added to a watched Anytype collection.
2. Quick-add an object to a collection from the Noctalia bar.
3. Phase 2: Kanban-style view over one user-designated collection.

## Toolchain

Pure QML. No node, no bundlers, no test runner.

Noctalia loads the plugin by dropping it under `~/.config/noctalia/plugins/anytype-noctalia/`. Dev loop is: edit a `.qml` file, hot-reload picks it up (Noctalia debug mode). Static checks can be run with the Qt-provided `qmllint plugin/*.qml` and `qmlformat -i plugin/*.qml` if your distro ships them.

## Design

See `openspec/changes/anytype-notifier-mvp/`:

- [proposal.md](openspec/changes/anytype-notifier-mvp/proposal.md) - why + what + capabilities + impact
- [design.md](openspec/changes/anytype-notifier-mvp/design.md) - decisions D1-D11, ASCII mockups M1-M5, risks
- [tasks.md](openspec/changes/anytype-notifier-mvp/tasks.md) - 9 sections, 56 leaf tasks
- `specs/{api-client, notifier, quick-add}/spec.md` - requirements with scenarios

## Research

- [research/anytype.md](research/anytype.md) - API surface, auth, polling
- [research/noctalia.md](research/noctalia.md) - plugin architecture, entry points

## State

Execution tracked in beads (`bd ready`, `bd list`). Current state: all headless-completable work closed; blocking:human beads remain for live-Noctalia / live-Anytype verifications.
