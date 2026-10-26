// Main.qml - plugin entry point. Owns shared state exposed via
// pluginApi.mainInstance to BarWidget / Panel / Settings.
//
// Composition:
//   ApiClient    -> HTTP + auth
//   ConfigFile   -> ~/.config/anytype-noctalia/config.toml
//   per-collection pollers -> poll + diff + unread + toast

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

Item {
    id: root
    property var pluginApi: null

    // --- Settings fallback chain ---
    property var cfg: pluginApi?.pluginSettings || ({})
    property var defaults: pluginApi?.manifest?.metadata?.defaultSettings || ({})

    // --- Settings (reactive) ---
    readonly property string mode: cfg.mode ?? defaults.mode ?? "localhost"
    readonly property string spaceId: cfg.spaceId ?? defaults.spaceId ?? ""
    readonly property var collections: cfg.collections ?? defaults.collections ?? []
    readonly property var notificationFields: cfg.notificationFields ?? defaults.notificationFields ?? ["created_date", "created_by"]
    readonly property bool enableToasts: cfg.enableToasts ?? defaults.enableToasts ?? true
    readonly property bool showUnreadBadge: cfg.showUnreadBadge ?? defaults.showUnreadBadge ?? true
    readonly property int feedMaxItems: cfg.feedMaxItems ?? defaults.feedMaxItems ?? 50
    readonly property string kanbanCollectionId: cfg.kanbanCollectionId ?? defaults.kanbanCollectionId ?? ""

    property var readMessageIds: cfg.readMessageIds ?? defaults.readMessageIds ?? []

    // --- Derived state (shared) ---
    property var objectsByCollection: ({})
    property var cursorByCollection: ({})
    property var backoffUntil: ({})

    property int unreadCount: 0
    property string lastErrorClass: "ok"
    property bool isLoading: false

    // --- Child components ---
    property ConfigFile configFile: ConfigFile {
        id: configFile
    }

    property ApiClient apiClient: ApiClient {
        id: apiClient
        pluginApi: root.pluginApi
        configFile: configFile
    }

    // --- Signals ---
    signal newObjectsEvent(string collectionId, var newEntries)
    signal panelOpened()
    signal panelClosed()

    // ============================================================
    // Field rendering (shared with Panel and toast)
    // ============================================================

    function _formatDate(ts) {
        if (!ts) return "";
        var d = new Date(ts);
        var now = new Date();
        if (d.toDateString() === now.toDateString()) {
            return Qt.formatTime(d, "hh:mm");
        }
        return Qt.formatDate(d, "yyyy-MM-dd");
    }

    function _formatRelative(ts) {
        if (!ts) return "";
        var d = new Date(ts);
        var diff = (Date.now() - d.getTime()) / 1000;
        if (diff < 60) return "just now";
        if (diff < 3600) return Math.floor(diff / 60) + "m ago";
        if (diff < 86400) return Math.floor(diff / 3600) + "h ago";
        return Math.floor(diff / 86400) + "d ago";
    }

    function _renderField(entry, fieldId) {
        switch (fieldId) {
            case "created_date":       return _formatDate(entry.when ? entry.when.created_date : 0);
            case "created_by":         return (entry.who && entry.who.created_by) ? "by " + entry.who.created_by : "";
            case "last_modified_date": return _formatRelative(entry.when ? entry.when.last_modified_date : 0);
            case "last_modified_by":   return (entry.who && entry.who.last_modified_by) ? "edited by " + entry.who.last_modified_by : "";
            case "collection_name":    return (entry.where && entry.where.collection_name) || "";
            case "type_name":          return entry.what_type || "";
            case "tag":                return entry.tag ? "#" + entry.tag : "";
            case "snippet":            return (entry.snippet || "").slice(0, 60);
            case "space_name":         return (entry.where && entry.where.space_name) || "";
            default:                   return "";
        }
    }

    function renderFields(entry, fieldIds) {
        var parts = [];
        for (var i = 0; i < fieldIds.length; i++) {
            var seg = _renderField(entry, fieldIds[i]);
            if (seg && seg.length > 0) parts.push(seg);
        }
        return parts.join(" - ");
    }

    // Panel-feed-only: ALWAYS prefix collection name per spec "Collection name remains visible per row"
    function renderFeedSubline(entry) {
        var fields = notificationFields.slice();
        var filtered = fields.filter(function(f) { return f !== "collection_name"; });
        var rest = renderFields(entry, filtered);
        var cn = (entry.where && entry.where.collection_name) || "";
        if (rest.length === 0) return cn;
        if (cn.length === 0) return rest;
        return cn + " - " + rest;
    }

    // ============================================================
    // Entry assembly
    // ============================================================

    function _buildEntry(obj, collection) {
        var detail = obj.details || {};
        return {
            id: obj.id || "",
            why: "added_to:" + collection.id,
            what: obj.name || obj.title || "(untitled)",
            what_type: (obj.type && obj.type.name) || obj.type_key || "",
            who: {
                created_by: obj.created_by || detail.created_by || "",
                last_modified_by: obj.last_modified_by || detail.last_modified_by || ""
            },
            when: {
                created_date: obj.created_date || detail.created_date || 0,
                last_modified_date: obj.last_modified_date || detail.last_modified_date || 0
            },
            where: {
                collection_name: collection.name || "",
                collection_id: collection.id,
                space_name: cfg.spaceName || "",
                space_id: root.spaceId
            },
            snippet: obj.snippet || "",
            tag: (obj.tags && obj.tags.length > 0) ? obj.tags[0] : "",
            raw: obj
        };
    }

    // ============================================================
    // Per-collection polling
    // ============================================================

    property Component _pollerComponent: Timer {
        property var collection
        property int clampedInterval: Math.max(5, (collection && collection.pollInterval ? collection.pollInterval : 15))
        interval: clampedInterval * 1000
        running: collection && collection.enabled !== false && root.spaceId.length > 0 && apiClient.resolveToken().length > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: root.pollCollection(collection)
    }

    Repeater {
        model: root.collections
        delegate: Loader {
            sourceComponent: root._pollerComponent
            onLoaded: {
                item.collection = modelData;
            }
        }
    }

    function pollCollection(collection) {
        if (!collection || !collection.id) return;
        var now = Date.now();
        var backoff = root.backoffUntil[collection.id] || 0;
        if (backoff > now) return;

        root.isLoading = true;
        var since = root.cursorByCollection[collection.id] || 0;

        apiClient.listCollectionObjects(root.spaceId, collection.id, since, function(res) {
            root.isLoading = false;

            if (!res.ok) {
                root.lastErrorClass = res.class;
                if (res.class === "offline" || res.class === "unauthorized") {
                    root.backoffUntil[collection.id] = Date.now() + 60000;
                }
                return;
            }

            root.lastErrorClass = "ok";
            root.backoffUntil[collection.id] = 0;

            var objects = (res.data && (res.data.objects || res.data.items)) || res.data || [];
            if (!Array.isArray(objects)) objects = [];

            root._applyPollResult(collection, objects);
        });
    }

    function _applyPollResult(collection, objects) {
        var prev = root.objectsByCollection[collection.id] || [];
        var prevIds = {};
        for (var i = 0; i < prev.length; i++) prevIds[prev[i].id] = true;

        var isFirstPoll = (root.cursorByCollection[collection.id] || 0) === 0 && prev.length === 0;

        var newEntries = [];
        var merged = [];
        var maxTs = root.cursorByCollection[collection.id] || 0;

        for (var j = 0; j < objects.length; j++) {
            var entry = _buildEntry(objects[j], collection);
            if (entry.when.last_modified_date > maxTs) maxTs = entry.when.last_modified_date;
            if (!prevIds[entry.id]) newEntries.push(entry);
            merged.push(entry);
        }

        root.cursorByCollection[collection.id] = maxTs;
        root.objectsByCollection[collection.id] = merged;
        root.objectsByCollection = root.objectsByCollection;

        if (isFirstPoll) {
            var ids = root.readMessageIds.slice();
            for (var k = 0; k < merged.length; k++) {
                if (ids.indexOf(merged[k].id) === -1) ids.push(merged[k].id);
            }
            root.readMessageIds = ids;
            root._persistReadIds();
            root._updateUnread();
            return;
        }

        if (newEntries.length > 0) {
            if (root.enableToasts) root._toast(collection, newEntries);
            root.newObjectsEvent(collection.id, newEntries);
        }

        root._updateUnread();
    }

    // ============================================================
    // Toasts
    // ============================================================

    function _toast(collection, newEntries) {
        if (newEntries.length === 1) {
            var e = newEntries[0];
            var body = renderFields(e, root.notificationFields);
            if (root.notificationFields.indexOf("collection_name") === -1) {
                body = collection.name + (body.length > 0 ? " - " + body : "");
            }
            if (typeof ToastService !== "undefined") {
                ToastService.showNotice(e.what, body, "bell");
            }
        } else {
            var msg = (pluginApi && pluginApi.tr) ? pluginApi.tr("toast.newObjects", { count: newEntries.length, collection: collection.name })
                      : (newEntries.length + " new objects in " + collection.name);
            if (typeof ToastService !== "undefined") {
                ToastService.showNotice(msg, "", "bell");
            }
        }
    }

    // ============================================================
    // Unread
    // ============================================================

    function _updateUnread() {
        var readSet = {};
        for (var i = 0; i < root.readMessageIds.length; i++) readSet[root.readMessageIds[i]] = true;
        var count = 0;
        for (var cid in root.objectsByCollection) {
            var arr = root.objectsByCollection[cid];
            for (var j = 0; j < arr.length; j++) {
                if (!readSet[arr[j].id]) count++;
            }
        }
        root.unreadCount = count;
    }

    function isMessageRead(id) {
        return root.readMessageIds.indexOf(id) !== -1;
    }

    function markAsRead(id) {
        if (root.readMessageIds.indexOf(id) !== -1) return;
        var ids = root.readMessageIds.slice();
        ids.push(id);
        root.readMessageIds = ids;
        root._persistReadIds();
        root._updateUnread();
    }

    function markAllAsRead() {
        var ids = root.readMessageIds.slice();
        for (var cid in root.objectsByCollection) {
            var arr = root.objectsByCollection[cid];
            for (var i = 0; i < arr.length; i++) {
                if (ids.indexOf(arr[i].id) === -1) ids.push(arr[i].id);
            }
        }
        root.readMessageIds = ids;
        root._persistReadIds();
        root._updateUnread();
    }

    function markVisibleAsRead(visibleIds) {
        var ids = root.readMessageIds.slice();
        for (var i = 0; i < visibleIds.length; i++) {
            if (ids.indexOf(visibleIds[i]) === -1) ids.push(visibleIds[i]);
        }
        root.readMessageIds = ids;
        root._persistReadIds();
        root._updateUnread();
    }

    function _persistReadIds() {
        if (!pluginApi) return;
        var liveIds = {};
        for (var cid in root.objectsByCollection) {
            var arr = root.objectsByCollection[cid];
            for (var i = 0; i < arr.length; i++) liveIds[arr[i].id] = true;
        }
        var trimmed = root.readMessageIds.filter(function(id) { return liveIds[id]; });
        root.readMessageIds = trimmed;
        pluginApi.pluginSettings.readMessageIds = trimmed;
        pluginApi.saveSettings();
    }

    // ============================================================
    // Unified feed (newest-first across all watched collections)
    // ============================================================

    function unifiedFeed() {
        var all = [];
        for (var cid in root.objectsByCollection) {
            var arr = root.objectsByCollection[cid];
            for (var i = 0; i < arr.length; i++) all.push(arr[i]);
        }
        all.sort(function(a, b) {
            var at = (a.when && a.when.last_modified_date) || 0;
            var bt = (b.when && b.when.last_modified_date) || 0;
            return bt - at;
        });
        return all.slice(0, root.feedMaxItems);
    }

    // ============================================================
    // IPC
    // ============================================================

    IpcHandler {
        target: "plugin:anytype-noctalia"

        function toggle() {
            if (pluginApi) pluginApi.withCurrentScreen(function(screen) { pluginApi.togglePanel(screen); });
        }

        function refresh() {
            for (var i = 0; i < root.collections.length; i++) {
                root.pollCollection(root.collections[i]);
            }
        }

        function markAllRead() {
            root.markAllAsRead();
        }

        function add(text) {
            root.quickAdd(text || "");
        }
    }

    // ============================================================
    // Quick-add
    // ============================================================

    function quickAdd(text) {
        if (!text || text.length === 0) return;
        var targetCollectionId = cfg.defaultTargetCollectionId || "";
        var typeKey = cfg.defaultTypeKey || "ot-task";
        apiClient.createObject(root.spaceId, { name: text, type_key: typeKey }, function(res) {
            if (!res.ok) {
                if (typeof ToastService !== "undefined") {
                    ToastService.showError((pluginApi && pluginApi.tr) ? pluginApi.tr("quickAdd.failed") : "Quick-add failed: " + res.class);
                }
                return;
            }
            var newId = (res.data && (res.data.id || (res.data.object && res.data.object.id))) || "";
            if (newId && targetCollectionId) {
                apiClient.addToCollection(root.spaceId, targetCollectionId, [newId], function(res2) {
                    if (!res2.ok) {
                        if (typeof Logger !== "undefined" && Logger.w) {
                            Logger.w("anytype", "created but not added to collection:", res2.class);
                        }
                    }
                });
            }
            if (cfg.toastOnQuickAdd && typeof ToastService !== "undefined") {
                ToastService.showNotice((pluginApi && pluginApi.tr) ? pluginApi.tr("quickAdd.ok") : "Added", text, "plus");
            }
        });
    }

    // ============================================================
    // Mode-aware offline message for Panel
    // ============================================================

    function offlineMessage() {
        if (mode === "server") {
            var url = cfg.serverUrl || "";
            return "Cannot reach " + url;
        }
        return "Anytype desktop is not running. Start it from your launcher.";
    }
}
