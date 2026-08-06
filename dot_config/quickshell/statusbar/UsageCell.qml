import QtQuick
import QtQuick.Controls

Item {
    id: root

    required property string provider
    required property var usage
    required property var themeColors
    property bool compact: false
    property bool last: false
    property double nowEpoch: Date.now() / 1000
    readonly property string providerName: provider === "claude" ? "CLAUDE" : "CODEX"
    readonly property var percent: usage ? usage.percent : null
    readonly property var resetsAt: usage ? usage.resetsAt : null
    readonly property string percentText: percent === null || percent === undefined
        ? "--"
        : percent + "%"
    readonly property string resetText: resetsAt === null || resetsAt === undefined
        ? "waiting"
        : "↻ " + countdownText(resetsAt)
    readonly property color displayColor: percentageColor()
    readonly property real percentColumnX: percentLabel.mapToItem(root, 0, 0).x
    readonly property real resetColumnX: resetLabel.mapToItem(root, 0, 0).x

    function windowLabel(minutes: var): string {
        if (minutes === null || minutes === undefined)
            return "current window";
        if (minutes % 10080 === 0)
            return minutes / 10080 + "-week window";
        if (minutes % 1440 === 0)
            return minutes / 1440 + "-day window";
        if (minutes % 60 === 0)
            return minutes / 60 + "-hour window";
        return minutes + "-minute window";
    }

    function fullReset(timestamp: var): string {
        if (timestamp === null || timestamp === undefined)
            return "reset unavailable";
        return "resets " + Qt.formatDateTime(
            new Date(timestamp * 1000),
            "ddd d MMM yyyy HH:mm t"
        );
    }

    function countdownText(timestamp: var): string {
        if (typeof timestamp !== "number" || !Number.isFinite(timestamp))
            return "waiting";
        const remaining = Math.max(0, Math.floor(timestamp - nowEpoch));
        const days = Math.floor(remaining / 86400);
        const hours = Math.floor((remaining % 86400) / 3600);
        const minutes = Math.floor((remaining % 3600) / 60);
        if (days > 0)
            return days + "d " + hours + "h " + minutes + "m";
        if (hours > 0)
            return hours + "h " + minutes + "m";
        if (minutes > 0)
            return minutes + "m";
        return "<1m";
    }

    function tooltipText(): string {
        const product = provider === "claude" ? "Claude Code" : "Codex";
        if (percent === null || percent === undefined)
            return product + " usage unavailable · waiting for fresh account activity";
        let text = product + " " + windowLabel(usage.windowMinutes)
            + " · " + percentText + " used · " + fullReset(resetsAt);
        if (usage.secondaryPercent !== null && usage.secondaryPercent !== undefined) {
            text += "\n" + windowLabel(usage.secondaryWindowMinutes)
                + " · " + usage.secondaryPercent + "% used · "
                + fullReset(usage.secondaryResetsAt);
        }
        return text;
    }

    function percentageColor(): color {
        if (percent === null || percent === undefined)
            return themeColors.text_dim;
        if (percent >= 90)
            return "#fb4934";
        if (percent >= 75)
            return "#fabd2f";
        return themeColors.text;
    }

    implicitWidth: compact ? 39 : 188
    implicitHeight: 40

    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.nowEpoch = Date.now() / 1000
    }

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
        spacing: root.compact ? 2 : 4

        Image {
            anchors.verticalCenter: parent.verticalCenter
            width: root.compact ? 8 : 14
            height: width
            source: root.provider === "claude"
                ? "assets/claude.png"
                : "assets/openai.svg"
            fillMode: Image.PreserveAspectFit
            mipmap: true
        }

        Text {
            visible: !root.compact
            anchors.verticalCenter: parent.verticalCenter
            width: 38
            text: root.providerName
            color: root.themeColors.text_dim
            opacity: 0.72
            horizontalAlignment: Text.AlignRight
            font.family: "Inter"
            font.pixelSize: 9
            font.weight: Font.DemiBold
            font.letterSpacing: 0.45
        }

        Text {
            id: percentLabel
            anchors.verticalCenter: parent.verticalCenter
            width: root.compact ? 28 : 36
            clip: true
            text: root.percentText
            color: root.displayColor
            horizontalAlignment: Text.AlignLeft
            font.family: "JetBrains Mono"
            font.pixelSize: root.compact ? 9 : 12
            font.weight: Font.DemiBold
        }

        Text {
            id: resetLabel
            visible: !root.compact
            anchors.verticalCenter: parent.verticalCenter
            width: 76
            clip: true
            elide: Text.ElideRight
            text: root.resetText
            color: root.themeColors.text_dim
            opacity: 0.68
            font.family: "Inter"
            font.pixelSize: 10
            font.weight: Font.Medium
        }
    }

    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
    }

    ToolTip.visible: hoverArea.containsMouse
    ToolTip.text: root.tooltipText()
    ToolTip.delay: 350
}
