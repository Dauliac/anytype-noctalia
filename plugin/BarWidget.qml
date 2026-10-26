import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Services.UI
import qs.Widgets

Item {
    id: root

    property var pluginApi: null
    property ShellScreen screen
    property string widgetId: ""
    property string section: ""
    property int sectionWidgetIndex: -1
    property int sectionWidgetsCount: 0

    readonly property string screenName: screen ? screen.name : ""
    readonly property string barPosition: Settings.getBarPositionForScreen(screenName)
    readonly property bool isVertical: barPosition === "left" || barPosition === "right"
    readonly property real capsuleHeight: Style.getCapsuleHeightForScreen(screenName)
    readonly property real barFontSize: Style.getBarFontSizeForScreen(screenName)

    readonly property var main: pluginApi?.mainInstance
    readonly property int unreadCount: main ? main.unreadCount : 0
    readonly property string errClass: main ? main.lastErrorClass : "ok"
    readonly property bool offline: errClass === "offline"
    readonly property bool needsRePair: errClass === "unauthorized" || errClass === "notPaired"
    readonly property bool showBadge: {
        if (!main) return false;
        if (unreadCount <= 0) return false;
        var cfg = pluginApi?.pluginSettings;
        var defaults = pluginApi?.manifest?.metadata?.defaultSettings;
        return cfg?.showUnreadBadge ?? defaults?.showUnreadBadge ?? true;
    }
    readonly property string iconName: {
        if (offline) return "database-off";
        if (needsRePair) return "key-off";
        return "database";
    }

    // Track previous count for pulse animation
    property int previousUnreadCount: 0

    implicitWidth: isVertical ? capsuleHeight : contentRow.implicitWidth + Style.marginM * 2
    implicitHeight: isVertical ? capsuleHeight * 1.5 : capsuleHeight

    // Context menu
    NPopupContextMenu {
        id: contextMenu
        model: [
            { "label": pluginApi?.tr("menu.refresh"), "action": "refresh", "icon": "refresh" },
            { "label": pluginApi?.tr("menu.markAllRead"), "action": "markAllRead", "icon": "circle-check" },
            { "label": pluginApi?.tr("menu.settings"), "action": "settings", "icon": "settings" }
        ]
        onTriggered: action => {
            contextMenu.close();
            PanelService.closeContextMenu(screen);
            if (action === "settings") {
                BarService.openPluginSettings(root.screen, pluginApi.manifest);
            } else if (action === "refresh" && main) {
                for (var i = 0; i < main.collections.length; i++) main.pollCollection(main.collections[i]);
            } else if (action === "markAllRead" && main) {
                main.markAllAsRead();
            }
        }
    }

    Rectangle {
        id: capsule
        anchors.centerIn: parent
        width: root.implicitWidth
        height: root.implicitHeight
        radius: Style.radiusM
        color: mouseArea.containsMouse ? Color.mHover : Style.capsuleColor
        border.color: Style.capsuleBorderColor
        border.width: Style.capsuleBorderWidth

        MouseArea {
            id: mouseArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton

            onClicked: mouse => {
                if (mouse.button === Qt.LeftButton) {
                    if (pluginApi) pluginApi.togglePanel(root.screen, root);
                } else if (mouse.button === Qt.RightButton) {
                    PanelService.showContextMenu(contextMenu, root, screen);
                }
            }

            onEntered: {
                var text = unreadCount > 0
                    ? pluginApi?.tr("widget.tooltipWithCount", { count: unreadCount })
                    : pluginApi?.tr("widget.tooltip");
                TooltipService.show(root, text, BarService.getTooltipDirection());
            }

            onExited: {
                TooltipService.hide();
            }
        }

        // Horizontal layout
        RowLayout {
            id: contentRow
            anchors.centerIn: parent
            spacing: Style.marginXS
            visible: !isVertical

            NIcon {
                icon: root.iconName
                width: root.barFontSize * 1.4
                height: width
                color: root.needsRePair ? Color.mError
                     : root.offline ? Color.mOnSurfaceVariant
                     : unreadCount > 0 ? Color.mPrimary
                     : (mouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface)
            }

            // Badge
            Rectangle {
                visible: root.showBadge
                width: Math.max(badgeText.implicitWidth + Style.marginS * 2, height)
                height: root.barFontSize * 1.3
                radius: height / 2
                color: Color.mPrimary

                NText {
                    id: badgeText
                    anchors.centerIn: parent
                    text: unreadCount > 99 ? "99+" : unreadCount.toString()
                    pointSize: root.barFontSize * 0.7
                    applyUiScale: false
                    color: Color.mOnPrimary
                    font.weight: Style.fontWeightBold
                }

                // Pulse animation on new messages
                SequentialAnimation {
                    id: pulseAnimation
                    loops: 2
                    PropertyAnimation {
                        target: capsule
                        property: "scale"
                        from: 1.0; to: 1.1
                        duration: 150
                        easing.type: Easing.OutQuad
                    }
                    PropertyAnimation {
                        target: capsule
                        property: "scale"
                        from: 1.1; to: 1.0
                        duration: 150
                        easing.type: Easing.InQuad
                    }
                }
            }
        }

        // Vertical layout
        ColumnLayout {
            anchors.centerIn: parent
            spacing: Style.marginXXS
            visible: isVertical

            NIcon {
                icon: root.iconName
                width: root.barFontSize * 1.4
                height: width
                color: root.needsRePair ? Color.mError
                     : root.offline ? Color.mOnSurfaceVariant
                     : unreadCount > 0 ? Color.mPrimary
                     : (mouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface)
                Layout.alignment: Qt.AlignHCenter
            }

            NText {
                visible: root.showBadge
                text: unreadCount > 99 ? "99+" : unreadCount.toString()
                pointSize: root.barFontSize * 0.6
                applyUiScale: false
                color: Color.mPrimary
                font.weight: Style.fontWeightBold
                Layout.alignment: Qt.AlignHCenter
            }
        }
    }

    // Watch for unread count changes to trigger pulse
    onUnreadCountChanged: {
        if (unreadCount > previousUnreadCount && previousUnreadCount >= 0) {
            pulseAnimation.start();
        }
        previousUnreadCount = unreadCount;
    }
}
