// Settings.qml - Anytype plugin settings.
// Sections: Connection | Space | Watched collections | Kanban collection |
//           Notification fields | Quick-add | Notifications | About

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

ColumnLayout {
    id: root
    spacing: Style.marginM

    property var pluginApi: null
    property var cfg: pluginApi?.pluginSettings || ({})
    property var defaults: pluginApi?.manifest?.metadata?.defaultSettings || ({})
    readonly property var main: pluginApi?.mainInstance

    // Edit copies
    property string mode: cfg.mode ?? defaults.mode ?? "localhost"
    property string baseUrl: cfg.baseUrl ?? defaults.baseUrl ?? "http://127.0.0.1:31009"
    property string serverUrl: cfg.serverUrl ?? defaults.serverUrl ?? ""
    property string spaceId: cfg.spaceId ?? defaults.spaceId ?? ""
    property var collections: cfg.collections ?? defaults.collections ?? []
    property string defaultTargetCollectionId: cfg.defaultTargetCollectionId ?? defaults.defaultTargetCollectionId ?? ""
    property string defaultTypeKey: cfg.defaultTypeKey ?? defaults.defaultTypeKey ?? ""
    property var notificationFields: cfg.notificationFields ?? defaults.notificationFields ?? ["created_date", "created_by"]
    property string kanbanCollectionId: cfg.kanbanCollectionId ?? defaults.kanbanCollectionId ?? ""
    property string kanbanStatusPropertyId: cfg.kanbanStatusPropertyId ?? defaults.kanbanStatusPropertyId ?? ""
    property bool enableToasts: cfg.enableToasts ?? defaults.enableToasts ?? true
    property bool showUnreadBadge: cfg.showUnreadBadge ?? defaults.showUnreadBadge ?? true
    property bool toastOnQuickAdd: cfg.toastOnQuickAdd ?? defaults.toastOnQuickAdd ?? false

    // Pairing sub-state
    property string pairChallengeId: ""
    property string pairingState: "idle"  // idle | awaitingCode | serverTokenPaste | paired | error
    property string pairingError: ""

    // Loaded from Anytype (for pickers)
    property var spacesList: []
    property var listsForSpace: []

    function save(key, value) {
        if (!pluginApi) return;
        pluginApi.pluginSettings[key] = value;
        pluginApi.saveSettings();
    }

    // ============================================================
    // Available notification field ids
    // ============================================================
    readonly property var allFieldIds: [
        "created_date", "created_by", "last_modified_date", "last_modified_by",
        "collection_name", "type_name", "tag", "snippet", "space_name"
    ]

    function fieldLabel(id) {
        switch (id) {
            case "created_date":       return "Creation date";
            case "created_by":         return "Created by";
            case "last_modified_date": return "Last modified";
            case "last_modified_by":   return "Last modified by";
            case "collection_name":    return "Collection name";
            case "type_name":          return "Type";
            case "tag":                return "First tag";
            case "snippet":            return "Snippet";
            case "space_name":         return "Space name";
            default:                   return id;
        }
    }

    // ============================================================
    // Connection
    // ============================================================
    GroupBox {
        title: "Connection"
        Layout.fillWidth: true
        ColumnLayout {
            anchors.fill: parent
            spacing: Style.marginS

            RowLayout {
                NText { text: "Mode:" }
                RadioButton {
                    text: "Localhost (desktop)"
                    checked: root.mode === "localhost"
                    onToggled: if (checked) { root.mode = "localhost"; save("mode", "localhost"); }
                }
                RadioButton {
                    text: "Server (self-hosted/remote)"
                    checked: root.mode === "server"
                    onToggled: if (checked) { root.mode = "server"; save("mode", "server"); }
                }
            }

            RowLayout {
                visible: root.mode === "localhost"
                NText { text: "Base URL:" }
                TextField {
                    Layout.fillWidth: true
                    text: root.baseUrl
                    onEditingFinished: { root.baseUrl = text; save("baseUrl", text); }
                }
            }

            RowLayout {
                visible: root.mode === "server"
                NText { text: "Server URL:" }
                TextField {
                    Layout.fillWidth: true
                    text: root.serverUrl
                    placeholderText: "https://anytype.example.com"
                    onEditingFinished: { root.serverUrl = text; save("serverUrl", text); }
                }
            }

            NText {
                text: "Token source: " + (main && main.apiClient ? main.apiClient.tokenSource() : "unknown")
                color: Color.mOnSurfaceVariant
                pointSize: Style.fontSizeS
            }

            RowLayout {
                NButton {
                    text: "Pair"
                    enabled: root.pairingState === "idle" || root.pairingState === "error" || root.pairingState === "paired"
                    onClicked: {
                        if (root.mode === "server") {
                            root.pairingState = "serverTokenPaste";
                        } else {
                            root.pairingError = "";
                            root.pairingState = "awaitingCode";
                            if (main && main.apiClient) {
                                main.apiClient.requestChallenge("anytype-noctalia", function(res) {
                                    if (res.ok && res.data) {
                                        root.pairChallengeId = res.data.challenge_id || "";
                                    } else {
                                        root.pairingState = "error";
                                        root.pairingError = res.class;
                                    }
                                });
                            }
                        }
                    }
                }
                NButton {
                    text: "Clear key"
                    onClicked: {
                        save("apiKey", "");
                        if (main && main.configFile && main.configFile.writable) main.configFile.setApiKey("");
                        root.pairingState = "idle";
                    }
                }
            }

            // Pairing sub-state: awaiting 4-digit code (localhost)
            RowLayout {
                visible: root.pairingState === "awaitingCode"
                NText { text: "Code:" }
                TextField {
                    id: codeInput
                    Layout.preferredWidth: 100
                    inputMask: "9999"
                }
                NButton {
                    text: "Confirm"
                    onClicked: {
                        if (!main || !main.apiClient) return;
                        main.apiClient.pair(root.pairChallengeId, codeInput.text, function(res) {
                            if (res.ok && res.data && res.data.api_key) {
                                root.pairingState = "paired";
                                codeInput.text = "";
                                root.pairingError = "";
                                if (main.configFile && main.configFile.writable) {
                                    main.configFile.setApiKey(res.data.api_key);
                                } else {
                                    save("apiKey", res.data.api_key);
                                }
                            } else {
                                root.pairingState = "error";
                                root.pairingError = res.class;
                            }
                        });
                    }
                }
                NButton {
                    text: "Cancel"
                    onClicked: { root.pairingState = "idle"; codeInput.text = ""; }
                }
            }

            // Pairing sub-state: server token paste
            ColumnLayout {
                visible: root.pairingState === "serverTokenPaste"
                NText { text: "Paste your Bearer token:" }
                TextField {
                    id: tokenInput
                    Layout.fillWidth: true
                    echoMode: TextInput.Password
                }
                RowLayout {
                    NButton {
                        text: "Save"
                        onClicked: {
                            if (!main || !main.apiClient) return;
                            main.apiClient.setTokenDirectly(tokenInput.text);
                            tokenInput.text = "";
                            root.pairingState = "paired";
                        }
                    }
                    NButton {
                        text: "Cancel"
                        onClicked: { root.pairingState = "idle"; tokenInput.text = ""; }
                    }
                }
            }

            NText {
                visible: root.pairingState === "error"
                text: "Pairing error: " + root.pairingError
                color: Color.mError
            }
        }
    }

    // ============================================================
    // Space
    // ============================================================
    GroupBox {
        title: "Space"
        Layout.fillWidth: true

        RowLayout {
            anchors.fill: parent

            NText { text: "Space:" }
            ComboBox {
                Layout.fillWidth: true
                model: root.spacesList
                textRole: "name"
                valueRole: "id"
                currentIndex: {
                    for (var i = 0; i < root.spacesList.length; i++) {
                        if (root.spacesList[i].id === root.spaceId) return i;
                    }
                    return -1;
                }
                onActivated: {
                    var picked = root.spacesList[currentIndex];
                    if (picked) {
                        root.spaceId = picked.id;
                        save("spaceId", picked.id);
                        save("spaceName", picked.name);
                        root.reloadLists();
                    }
                }
            }
            NButton {
                text: "Load"
                onClicked: root.reloadSpaces()
            }
        }
    }

    function reloadSpaces() {
        if (!main || !main.apiClient) return;
        main.apiClient.listSpaces(function(res) {
            if (res.ok) {
                var arr = (res.data && (res.data.spaces || res.data.items)) || res.data || [];
                root.spacesList = Array.isArray(arr) ? arr : [];
            }
        });
    }

    function reloadLists() {
        if (!main || !main.apiClient || !root.spaceId) return;
        main.apiClient.listSpaceLists(root.spaceId, function(res) {
            if (res.ok) {
                var arr = (res.data && (res.data.lists || res.data.items)) || res.data || [];
                root.listsForSpace = Array.isArray(arr) ? arr : [];
            }
        });
    }

    // ============================================================
    // Watched collections
    // ============================================================
    GroupBox {
        title: "Watched collections"
        Layout.fillWidth: true

        ColumnLayout {
            anchors.fill: parent
            spacing: Style.marginXS

            Repeater {
                model: root.listsForSpace
                delegate: RowLayout {
                    required property int index
                    required property var modelData
                    Layout.fillWidth: true

                    CheckBox {
                        text: modelData.name || modelData.id
                        checked: root.isWatched(modelData.id)
                        onToggled: root.toggleWatch(modelData, checked)
                    }
                    Item { Layout.fillWidth: true }
                    NText { text: "poll:"; pointSize: Style.fontSizeS }
                    SpinBox {
                        from: 5; to: 3600
                        value: root.pollIntervalFor(modelData.id)
                        onValueChanged: root.setPollInterval(modelData.id, value)
                        enabled: root.isWatched(modelData.id)
                    }
                    NText { text: "s"; pointSize: Style.fontSizeS }
                }
            }
        }
    }

    function isWatched(cid) {
        for (var i = 0; i < root.collections.length; i++) {
            if (root.collections[i].id === cid) return true;
        }
        return false;
    }

    function pollIntervalFor(cid) {
        for (var i = 0; i < root.collections.length; i++) {
            if (root.collections[i].id === cid) return root.collections[i].pollInterval || 15;
        }
        return 15;
    }

    function toggleWatch(coll, checked) {
        var next = root.collections.slice();
        if (checked) {
            next.push({ id: coll.id, name: coll.name, pollInterval: 15, enabled: true });
        } else {
            next = next.filter(function(c) { return c.id !== coll.id; });
        }
        root.collections = next;
        save("collections", next);
    }

    function setPollInterval(cid, v) {
        var next = root.collections.slice();
        for (var i = 0; i < next.length; i++) {
            if (next[i].id === cid) { next[i].pollInterval = Math.max(5, v); }
        }
        root.collections = next;
        save("collections", next);
    }

    // ============================================================
    // Kanban collection
    // ============================================================
    GroupBox {
        title: "Kanban collection"
        Layout.fillWidth: true

        ColumnLayout {
            anchors.fill: parent
            spacing: Style.marginS

            NText {
                text: "Which watched collection to render as a Kanban board:"
                color: Color.mOnSurfaceVariant
                pointSize: Style.fontSizeS
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            ComboBox {
                Layout.fillWidth: true
                model: {
                    var m = [{id: "", name: "(None - hide the Kanban block)"}];
                    for (var i = 0; i < root.collections.length; i++) m.push(root.collections[i]);
                    return m;
                }
                textRole: "name"
                currentIndex: {
                    if (!root.kanbanCollectionId) return 0;
                    for (var i = 0; i < root.collections.length; i++) {
                        if (root.collections[i].id === root.kanbanCollectionId) return i + 1;
                    }
                    return 0;
                }
                onActivated: {
                    var picked = (currentIndex === 0) ? { id: "" } : root.collections[currentIndex - 1];
                    root.kanbanCollectionId = picked.id;
                    save("kanbanCollectionId", picked.id);
                }
            }

            NText {
                text: "Status property (used by Phase 2 Kanban board):"
                color: Color.mOnSurfaceVariant
                pointSize: Style.fontSizeS
            }
            TextField {
                Layout.fillWidth: true
                text: root.kanbanStatusPropertyId
                placeholderText: "status"
                enabled: root.kanbanCollectionId.length > 0
                onEditingFinished: { root.kanbanStatusPropertyId = text; save("kanbanStatusPropertyId", text); }
            }
        }
    }

    // ============================================================
    // Notification fields
    // ============================================================
    GroupBox {
        title: "Notification fields"
        Layout.fillWidth: true

        ColumnLayout {
            anchors.fill: parent
            spacing: Style.marginS

            NText {
                text: "Shown in toast + Panel row sub-line, in order:"
                color: Color.mOnSurfaceVariant
                pointSize: Style.fontSizeS
            }

            Repeater {
                model: root.notificationFields
                delegate: RowLayout {
                    required property int index
                    required property string modelData
                    Layout.fillWidth: true

                    NText { text: (index + 1) + "." }
                    ComboBox {
                        Layout.fillWidth: true
                        model: root.allFieldIds
                        currentIndex: root.allFieldIds.indexOf(modelData)
                        displayText: root.fieldLabel(modelData)
                        onActivated: {
                            var next = root.notificationFields.slice();
                            next[index] = root.allFieldIds[currentIndex];
                            root.notificationFields = next;
                            save("notificationFields", next);
                        }
                    }
                    NButton {
                        text: "-"
                        onClicked: {
                            var next = root.notificationFields.slice();
                            next.splice(index, 1);
                            root.notificationFields = next;
                            save("notificationFields", next);
                        }
                    }
                }
            }

            RowLayout {
                NButton {
                    text: "+ Add field"
                    onClicked: {
                        var next = root.notificationFields.slice();
                        for (var i = 0; i < root.allFieldIds.length; i++) {
                            if (next.indexOf(root.allFieldIds[i]) === -1) { next.push(root.allFieldIds[i]); break; }
                        }
                        root.notificationFields = next;
                        save("notificationFields", next);
                    }
                }
                NButton {
                    text: "Restore defaults"
                    onClicked: {
                        root.notificationFields = ["created_date", "created_by"];
                        save("notificationFields", root.notificationFields);
                    }
                }
            }

            NText {
                text: "Preview: " + root.previewFields()
                color: Color.mOnSurface
                pointSize: Style.fontSizeS
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
            }
        }
    }

    function previewFields() {
        var sample = {
            why: "added_to:sample",
            what: "Sample",
            what_type: "Task",
            who: { created_by: "julien", last_modified_by: "julien" },
            when: { created_date: Date.now(), last_modified_date: Date.now() - 300000 },
            where: { collection_name: "Inbox", collection_id: "sample", space_name: "Personal", space_id: "s1" },
            snippet: "Sample snippet text", tag: "urgent"
        };
        return main ? main.renderFields(sample, root.notificationFields) : "";
    }

    // ============================================================
    // Quick-add defaults
    // ============================================================
    GroupBox {
        title: "Quick-add"
        Layout.fillWidth: true

        ColumnLayout {
            anchors.fill: parent
            spacing: Style.marginS

            RowLayout {
                NText { text: "Default target:" }
                ComboBox {
                    Layout.fillWidth: true
                    model: root.collections
                    textRole: "name"
                    currentIndex: {
                        for (var i = 0; i < root.collections.length; i++) {
                            if (root.collections[i].id === root.defaultTargetCollectionId) return i;
                        }
                        return -1;
                    }
                    onActivated: {
                        var picked = root.collections[currentIndex];
                        if (picked) { root.defaultTargetCollectionId = picked.id; save("defaultTargetCollectionId", picked.id); }
                    }
                }
            }

            RowLayout {
                NText { text: "Default type:" }
                TextField {
                    Layout.fillWidth: true
                    text: root.defaultTypeKey
                    placeholderText: "ot-task"
                    onEditingFinished: { root.defaultTypeKey = text; save("defaultTypeKey", text); }
                }
            }
        }
    }

    // ============================================================
    // Notifications
    // ============================================================
    GroupBox {
        title: "Notifications"
        Layout.fillWidth: true

        ColumnLayout {
            anchors.fill: parent

            CheckBox {
                text: "Toast on new objects"
                checked: root.enableToasts
                onToggled: { root.enableToasts = checked; save("enableToasts", checked); }
            }
            CheckBox {
                text: "Show unread badge"
                checked: root.showUnreadBadge
                onToggled: { root.showUnreadBadge = checked; save("showUnreadBadge", checked); }
            }
            CheckBox {
                text: "Toast when quick-add succeeds"
                checked: root.toastOnQuickAdd
                onToggled: { root.toastOnQuickAdd = checked; save("toastOnQuickAdd", checked); }
            }
        }
    }

    // ============================================================
    // About
    // ============================================================
    NText {
        text: "anytype-noctalia v" + (pluginApi?.manifest?.version || "?")
        color: Color.mOnSurfaceVariant
        pointSize: Style.fontSizeS
        Layout.fillWidth: true
    }

    Component.onCompleted: {
        reloadSpaces();
        if (spaceId.length > 0) reloadLists();
    }
}
