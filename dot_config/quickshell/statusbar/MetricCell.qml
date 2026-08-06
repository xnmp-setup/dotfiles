import QtQuick

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
    // Hot-only companion temperature rendered after the value (CPU/GPU cells).
    property var temperature: null
    // Nerd Font glyph shown instead of the text label when the font exists.
    property string iconText: ""
    // Recent samples for the hover graph; smoothHistory overlays a moving average.
    property var history: []
    property bool smoothHistory: false
    property bool last: false
    readonly property bool showTemperature: temperature !== null
        && temperature !== undefined
    // Hack Nerd Font is assumed by the WezTerm config on every platform, but a
    // machine without it degrades to the plain text label rather than tofu.
    readonly property bool iconAvailable: iconText.length > 0
        && Qt.fontFamilies().indexOf("Hack Nerd Font") !== -1
    readonly property color displayColor: severityColor(value, severity)
    readonly property string displayText: displayValueText.text
    readonly property string temperatureText: temperatureValueText.text
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
    // A visible hot temperature widens the cell by its own column.
    implicitWidth: 96 + (showTemperature ? 34 : 0)
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
            anchors.verticalCenter: parent.verticalCenter
            text: root.iconAvailable ? root.iconText : root.label
            color: root.iconAvailable ? root.displayColor : root.themeColors.text_dim
            opacity: root.iconAvailable ? 0.9 : 0.62
            horizontalAlignment: Text.AlignRight
            font.family: root.iconAvailable ? "Hack Nerd Font" : "Inter"
            font.pixelSize: root.iconAvailable ? 15 : 11
            font.weight: root.iconAvailable ? Font.Normal : Font.DemiBold
            font.letterSpacing: root.iconAvailable ? 0 : 0.5
        }

        Text {
            id: displayValueText
            width: 38
            anchors.verticalCenter: parent.verticalCenter
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

        Text {
            id: temperatureValueText
            visible: root.showTemperature
            width: root.showTemperature ? 30 : 0
            anchors.verticalCenter: parent.verticalCenter
            clip: true
            text: root.showTemperature ? root.temperature + "°" : ""
            color: root.temperature >= 85 ? "#fb4934" : "#fabd2f"
            horizontalAlignment: Text.AlignLeft
            font.family: "JetBrains Mono"
            font.pixelSize: 13
            font.weight: Font.Medium
        }
    }

    HoverHandler {
        id: hoverHandler
    }

    ThemedToolTip {
        visible: hoverHandler.hovered && root.tooltip.length > 0
        text: root.tooltip
        themeColors: root.themeColors
        history: root.history
        smoothed: root.smoothHistory
        pointerX: hoverHandler.point.position.x
    }
}
