import QtQuick

FocusScope {
    id: editor

    required property var themeColors
    property string initialText: ""
    property bool highlighted: false
    property alias editorText: nameInput.text
    readonly property alias inputHasFocus: nameInput.activeFocus
    readonly property bool focusRequested: focus && nameInput.focus
    readonly property int maximumLength: nameInput.maximumLength
    property bool completed: false

    signal submitted(string name)
    signal cancelled

    function activate(): void {
        focus = true;
        nameInput.focus = true;
        nameInput.forceActiveFocus(Qt.ShortcutFocusReason);
        nameInput.selectAll();
    }

    function submit(): void {
        if (completed)
            return;
        completed = true;
        submitted(nameInput.text.trim());
    }

    function cancel(): void {
        if (completed)
            return;
        completed = true;
        cancelled();
    }

    function dismissOnFocusLoss(hasFocus: bool): void {
        if (nameInput.heldFocus && !hasFocus)
            cancel();
    }

    implicitWidth: 160
    implicitHeight: 24
    focus: true

    Rectangle {
        anchors.fill: parent
        radius: 3
        color: editor.highlighted
            ? Qt.darker(editor.themeColors.accent, 1.34)
            : Qt.darker(editor.themeColors.surface, 1.22)
        border.width: 1
        border.color: editor.themeColors.accent
    }

    Text {
        anchors {
            left: parent.left
            right: parent.right
            verticalCenter: parent.verticalCenter
            leftMargin: 7
            rightMargin: 7
        }
        visible: nameInput.text.length === 0
        text: "Empty resets"
        color: editor.themeColors.text_dim
        font.family: "Inter"
        font.pixelSize: 12
        elide: Text.ElideRight
    }

    TextInput {
        id: nameInput

        property bool heldFocus: false

        anchors {
            fill: parent
            leftMargin: 7
            rightMargin: 7
        }
        text: editor.initialText
        color: editor.themeColors.text
        selectionColor: editor.themeColors.accent
        selectedTextColor: "#ffffff"
        font.family: "Inter"
        font.pixelSize: 13
        font.weight: Font.DemiBold
        verticalAlignment: TextInput.AlignVCenter
        maximumLength: 32
        selectByMouse: true
        clip: true
        focus: true

        Accessible.name: "Workspace name"
        Accessible.description: "Press Enter to rename, Escape to cancel; empty resets the name"

        Keys.onReturnPressed: event => {
            editor.submit();
            event.accepted = true;
        }
        Keys.onEnterPressed: event => {
            editor.submit();
            event.accepted = true;
        }
        Keys.onEscapePressed: event => {
            editor.cancel();
            event.accepted = true;
        }
        onActiveFocusChanged: {
            if (activeFocus)
                heldFocus = true;
            editor.dismissOnFocusLoss(activeFocus);
        }
    }

    Component.onCompleted: activate()
}
