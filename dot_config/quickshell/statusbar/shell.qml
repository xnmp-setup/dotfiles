//@ pragma IconTheme hicolor

import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    property bool barVisible: true
    property int renameRequestSerial: 0
    property string candidate: Quickshell.env("STATUSBAR_CANDIDATE") === "instrument"
        ? "instrument"
        : "segmented"

    StatusSource {
        id: source
    }

    IpcHandler {
        target: "bar"

        function toggle(): void {
            root.barVisible = !root.barVisible;
        }

        function show(): void {
            root.barVisible = true;
        }

        function hide(): void {
            root.barVisible = false;
        }

        function visible(): bool {
            return root.barVisible;
        }

        function renameCurrentWorkspace(): void {
            root.renameRequestSerial += 1;
        }
    }

    Variants {
        model: Quickshell.screens

        StatusBar {
            required property var modelData

            screen: modelData
            barVisible: root.barVisible
            candidate: root.candidate
            statusSource: source
            renameRequestSerial: root.renameRequestSerial
        }
    }
}
