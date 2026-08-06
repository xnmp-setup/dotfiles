import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Menu {
    id: menu

    required property var themeColors
    readonly property string shortcutLabel: renameShortcut.text

    signal renameRequested

    width: 238
    padding: 6
    modal: false
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

    background: Rectangle {
        color: menu.themeColors.surface
        border.width: 1
        border.color: menu.themeColors.border
        radius: 6
    }

    MenuItem {
        id: renameItem

        implicitHeight: 38
        text: "Rename workspace"
        onTriggered: menu.renameRequested()

        background: Rectangle {
            radius: 4
            color: renameItem.highlighted
                ? Qt.lighter(menu.themeColors.surface, 1.16)
                : "transparent"
        }

        contentItem: RowLayout {
            spacing: 12

            Text {
                Layout.fillWidth: true
                text: renameItem.text
                color: menu.themeColors.text
                font.family: "Inter"
                font.pixelSize: 13
                font.weight: Font.Medium
            }

            Text {
                id: renameShortcut

                text: "Alt+F2"
                color: menu.themeColors.text_dim
                font.family: "JetBrains Mono"
                font.pixelSize: 11
            }
        }
    }
}
