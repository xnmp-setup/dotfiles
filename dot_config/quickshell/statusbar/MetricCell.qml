import QtQuick
import QtQuick.Controls

Item {
    id: root

    required property string label
    required property var themeColors
    property var value: null
    property string tooltip: ""
    property string suffix: "%"
    property string formattedValue: ""
    // -1 applies the default percentage thresholds; 0/1/2 force normal/warn/critical.
    property int severity: -1
    property bool last: false
    readonly property color displayColor: severityColor(value, severity)
    readonly property string displayText: displayValueText.text
    readonly property real valueColumnX: displayValueText.mapToItem(root, 0, 0).x
    readonly property real valueColumnRight: valueColumnX + displayValueText.width

    function valueColor(metric: var): color {
        if (metric === null || metric === undefined)
            return root.themeColors.text;
        if (metric > 75)
            return "#fb4934";
        if (metric >= 50)
            return "#fabd2f";
        return root.themeColors.text;
    }

    function severityColor(metric: var, level: int): color {
        if (level === 2)
            return "#fb4934";
        if (level === 1)
            return "#fabd2f";
        if (level === 0)
            return root.themeColors.text;
        return valueColor(metric);
    }

    // 71 px of fixed label/value content plus balanced outer gutters. The gutter
    // keeps dividers visually separate from both the preceding value and next label.
    implicitWidth: 96
    implicitHeight: 40

    Rectangle {
        visible: !root.last
        anchors {
            right: parent.right
            verticalCenter: parent.verticalCenter
        }
        width: 1
        height: 18
        color: root.themeColors.border
    }

    Row {
        anchors.centerIn: parent
        spacing: 4

        Text {
            width: 28
            text: root.label
            color: root.themeColors.text_dim
            opacity: 0.62
            horizontalAlignment: Text.AlignRight
            font.family: "Inter"
            font.pixelSize: 11
            font.weight: Font.DemiBold
            font.letterSpacing: 0.5
        }

        Text {
            id: displayValueText
            width: 38
            clip: true
            elide: Text.ElideRight
            text: root.formattedValue.length > 0
                ? root.formattedValue
                : root.value === null || root.value === undefined ? "--" : root.value + root.suffix
            color: root.displayColor
            horizontalAlignment: Text.AlignLeft
            font.family: "JetBrains Mono"
            font.pixelSize: 13
            font.weight: Font.Medium
        }
    }

    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
    }

    ToolTip.visible: hoverArea.containsMouse && root.tooltip.length > 0
    ToolTip.text: root.tooltip
    ToolTip.delay: 350
}
