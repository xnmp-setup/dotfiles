import QtQuick
import Quickshell
import Quickshell.Widgets

Item {
    id: root

    required property string kind
    required property int count
    required property var themeColors

    implicitWidth: sessionRow.implicitWidth
    implicitHeight: 22

    Row {
        id: sessionRow
        anchors.centerIn: parent
        spacing: 3

        Image {
            visible: root.kind === "claude"
            anchors.verticalCenter: parent.verticalCenter
            width: 16
            height: 16
            source: Quickshell.shellPath("assets/claude.png")
            fillMode: Image.PreserveAspectFit
            mipmap: true
        }

        Image {
            visible: root.kind === "codex"
            anchors.verticalCenter: parent.verticalCenter
            width: 16
            height: 16
            source: Quickshell.shellPath("assets/openai.svg")
            fillMode: Image.PreserveAspectFit
            mipmap: true
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.count
            color: root.kind === "claude" ? root.themeColors.accent_light : root.themeColors.text
            font.family: "JetBrains Mono"
            font.pixelSize: 12
            font.weight: Font.DemiBold
        }
    }
}
