// Panel.qml - Anytype plugin dropdown panel.
// Three blocks:
//   1. Latest updates feed (unified across all watched collections)
//   2. Kanban slot (inert placeholder in MVP; filled by Phase 2)
//   3. Quick-add footer

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Services.UI
import qs.Widgets

Item {
    id: root
    property var pluginApi: null

    readonly property var geometryPlaceholder: panelContainer
    property real contentPreferredWidth: 420 * Style.uiScaleRatio
    property real contentPreferredHeight: 720 * Style.uiScaleRatio
    readonly property bool allowAttach: true

    anchors.fill: parent

    readonly property var main: pluginApi?.mainInstance
    readonly property string errClass: main ? main.lastErrorClass : "ok"
    readonly property bool isLoading: main ? main.isLoading : false
    readonly property bool showError: errClass === "offline" || errClass === "unauthorized" || errClass === "notPaired"

    readonly property var feedEntries: main ? main.unifiedFeed() : []
    readonly property string kanbanCollectionId: main ? main.kanbanCollectionId : ""
    readonly property var kanbanCollection: {
        if (!main || !kanbanCollectionId) return null;
        for (var i = 0; i < main.collections.length; i++) {
            if (main.collections[i].id === kanbanCollectionId) return main.collections[i];
        }
        return null;
    }
    readonly property int kanbanCount: {
        if (!main || !kanbanCollectionId) return 0;
        var arr = main.objectsByCollection[kanbanCollectionId];
        return arr ? arr.length : 0;
    }

    // Mark visible as read on open
    Component.onCompleted: {
        if (main) {
            var ids = [];
            for (var i = 0; i < feedEntries.length; i++) ids.push(feedEntries[i].id);
            main.markVisibleAsRead(ids);
        }
    }

    Rectangle {
        id: panelContainer
        anchors.fill: parent
        color: Color.mSurface
        radius: Style.radiusL
        border.color: Style.capsuleBorderColor
        border.width: Style.capsuleBorderWidth

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Style.marginM
            spacing: Style.marginM

            // ====================== Header ======================
            RowLayout {
                Layout.fillWidth: true
                spacing: Style.marginS

                NText {
                    text: "Anytype"
                    font.weight: Style.fontWeightBold
                    pointSize: Style.fontSizeL
                    Layout.fillWidth: true
                }

                NIconButton {
                    icon: "refresh"
                    enabled: !root.isLoading
                    onClicked: {
                        if (main) for (var i = 0; i < main.collections.length; i++) main.pollCollection(main.collections[i]);
                    }
                }

                NIconButton {
                    icon: "settings"
                    onClicked: {
                        if (pluginApi) BarService.openPluginSettings(null, pluginApi.manifest);
                    }
                }
            }

            // ================= Error state =======================
            Rectangle {
                visible: root.showError
                Layout.fillWidth: true
                Layout.preferredHeight: 120
                color: Color.mSurfaceVariant
                radius: Style.radiusM

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: Style.marginS

                    NIcon {
                        icon: root.errClass === "offline" ? "database-off" : "key-off"
                        width: 32; height: 32
                        color: Color.mOnSurfaceVariant
                        Layout.alignment: Qt.AlignHCenter
                    }

                    NText {
                        text: root.errClass === "offline"
                              ? (main ? main.offlineMessage() : "Offline")
                              : "Re-pair in Settings"
                        color: Color.mOnSurfaceVariant
                        horizontalAlignment: Text.AlignHCenter
                        Layout.fillWidth: true
                    }
                }
            }

            // ================= Latest updates feed =======================
            ColumnLayout {
                visible: !root.showError
                Layout.fillWidth: true
                spacing: Style.marginXS

                RowLayout {
                    Layout.fillWidth: true

                    NText {
                        text: "Latest updates"
                        font.weight: Style.fontWeightBold
                        Layout.fillWidth: true
                    }
                    NText {
                        text: main ? (main.unreadCount > 0 ? "* " + main.unreadCount + " unread" : "all read") : ""
                        color: main && main.unreadCount > 0 ? Color.mPrimary : Color.mOnSurfaceVariant
                        pointSize: Style.fontSizeS
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(360, Math.max(80, root.feedEntries.length * 56))
                    color: Color.mSurfaceVariant
                    radius: Style.radiusM

                    ListView {
                        anchors.fill: parent
                        anchors.margins: Style.marginS
                        model: root.feedEntries
                        clip: true
                        spacing: Style.marginXS
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: Item {
                            width: ListView.view.width
                            height: 52

                            readonly property var entry: modelData
                            readonly property bool unread: main ? !main.isMessageRead(entry.id) : false

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Style.marginS
                                anchors.rightMargin: Style.marginS

                                NText {
                                    text: unread ? "*" : " "
                                    color: Color.mPrimary
                                    font.weight: Style.fontWeightBold
                                    Layout.preferredWidth: 12
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2

                                    NText {
                                        text: entry.what
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        font.weight: unread ? Style.fontWeightBold : Style.fontWeightRegular
                                    }
                                    NText {
                                        text: main ? main.renderFeedSubline(entry) : ""
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        color: Color.mOnSurfaceVariant
                                        pointSize: Style.fontSizeS
                                    }
                                }

                                NIconButton {
                                    icon: "chevron-right"
                                    visible: unread && hoverArea.containsMouse
                                    onClicked: if (main) main.markAsRead(entry.id)
                                }
                            }

                            MouseArea {
                                id: hoverArea
                                anchors.fill: parent
                                hoverEnabled: true
                            }
                        }

                        NText {
                            visible: root.feedEntries.length === 0
                            anchors.centerIn: parent
                            text: "Nothing new."
                            color: Color.mOnSurfaceVariant
                        }
                    }
                }
            }

            // ================= Kanban slot =======================
            ColumnLayout {
                visible: !root.showError
                Layout.fillWidth: true
                spacing: Style.marginXS

                RowLayout {
                    Layout.fillWidth: true

                    NText {
                        text: root.kanbanCollection
                              ? "Kanban: " + root.kanbanCollection.name
                              : "Kanban"
                        font.weight: Style.fontWeightBold
                        Layout.fillWidth: true
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 100
                    color: Color.mSurfaceVariant
                    radius: Style.radiusM

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: Style.marginS

                        NText {
                            visible: !root.kanbanCollection
                            text: "Pick a collection in Settings to turn it into a Kanban board."
                            color: Color.mOnSurfaceVariant
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                            Layout.preferredWidth: 320
                        }

                        NText {
                            visible: !!root.kanbanCollection
                            text: "Kanban board coming in a future update."
                            color: Color.mOnSurfaceVariant
                            horizontalAlignment: Text.AlignHCenter
                        }

                        NText {
                            visible: !!root.kanbanCollection
                            text: "Current count: " + root.kanbanCount + " objects"
                            color: Color.mOnSurface
                            horizontalAlignment: Text.AlignHCenter
                            pointSize: Style.fontSizeS
                        }
                    }
                }
            }

            // ================= Quick-add footer =======================
            RowLayout {
                visible: !root.showError
                Layout.fillWidth: true
                spacing: Style.marginS

                TextField {
                    id: quickAddInput
                    Layout.fillWidth: true
                    placeholderText: "Quick add..."
                    enabled: !quickAddBusy
                    onAccepted: submit()
                }

                property bool quickAddBusy: false

                NButton {
                    text: "Add"
                    enabled: quickAddInput.text.length > 0 && !quickAddBusy
                    onClicked: submit()
                }

                function submit() {
                    if (quickAddInput.text.length === 0) return;
                    quickAddBusy = true;
                    var text = quickAddInput.text;
                    quickAddInput.text = "";
                    if (main) main.quickAdd(text);
                    // best-effort: unlock after a tick (callbacks fire async)
                    unlockTimer.restart();
                }

                Timer {
                    id: unlockTimer
                    interval: 1500
                    onTriggered: parent.quickAddBusy = false
                }
            }
        }
    }
}
