import QtQuick
import QtQuick.Controls

ToolTip {
    id: control

    required property var themeColors
    property int maximumWidth: 420
    readonly property color surfaceColor: themeColors.surface

    // Status-bar hints should track the pointer without feeling sticky, while a
    // tiny guard avoids flashing a popup when crossing adjacent metrics.
    delay: 90
    timeout: -1
    padding: 10
    popupType: Popup.Window
    implicitWidth: Math.min(
        maximumWidth,
        contentItem.implicitWidth + leftPadding + rightPadding
    )

    contentItem: Text {
        text: control.text
        color: control.themeColors.text
        wrapMode: Text.Wrap
        font.family: "Inter"
        font.pixelSize: 12
        font.weight: Font.Medium
        lineHeight: 1.2
    }

    background: Rectangle {
        color: control.surfaceColor
        border.width: 1
        border.color: control.themeColors.border
        radius: 6
    }
}
