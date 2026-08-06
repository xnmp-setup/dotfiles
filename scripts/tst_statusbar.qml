import QtQuick
import QtQuick.Controls
import QtTest
import "../dot_config/quickshell/statusbar"
import "../dot_config/quickshell/statusbar/StatusLayout.js" as StatusLayout
import "../dot_config/quickshell/statusbar/StatusSanitizer.js" as Sanitizer

TestCase {
    id: testCase
    name: "StatusBarMetrics"

    readonly property var themeColors: ({
        accent: "#fe8019",
        accent_light: "#fea45c",
        background: "#282828",
        surface: "#4b4840",
        border: "#625d51",
        text: "#ebdbb2",
        text_dim: "#a89984"
    })

    Component {
        id: metricComponent

        MetricCell {
            label: "CPU"
            themeColors: testCase.themeColors
        }
    }

    Component {
        id: workspaceComponent

        WorkspaceContextMenu {
            themeColors: testCase.themeColors
        }
    }

    Component {
        id: workspaceEditorComponent

        WorkspaceNameEditor {
            initialText: "Deep work"
            themeColors: testCase.themeColors
        }
    }

    Component {
        id: workspaceEditorRowComponent

        Row {
            id: editorRow

            property bool editing: true
            readonly property alias editorLoader: loader
            spacing: 5

            Loader {
                id: loader

                active: editorRow.editing
                visible: active
                width: active && item ? item.implicitWidth : 0
                height: active && item ? item.implicitHeight : 0
                sourceComponent: WorkspaceNameEditor {
                    initialText: "Deep work"
                    themeColors: testCase.themeColors
                }
            }

            Rectangle {
                width: 20
                height: 24
            }
        }
    }

    function colorAt(value): string {
        const metric = createTemporaryObject(metricComponent, this, { value: value });
        verify(metric !== null);
        return metric.displayColor.toString();
    }

    function metricAt(value): var {
        const metric = createTemporaryObject(metricComponent, this, { value: value });
        verify(metric !== null);
        return metric;
    }

    function test_thresholds(): void {
        compare(colorAt(null), "#ebdbb2");
        compare(colorAt(49), "#ebdbb2");
        compare(colorAt(50), "#fabd2f");
        compare(colorAt(75), "#fabd2f");
        compare(colorAt(76), "#fb4934");
        compare(colorAt(100), "#fb4934");
    }

    function test_workspace_context_menu_exposes_rename_and_shortcut(): void {
        const menu = createTemporaryObject(workspaceComponent, this);
        verify(menu !== null);
        compare(menu.shortcutLabel, "Alt+F2");
        compare(menu.modal, false);
        compare(menu.focus, true);
        compare(menu.popupType, Popup.Window);
        verify((menu.closePolicy & Popup.CloseOnEscape) !== 0);
        verify((menu.closePolicy & Popup.CloseOnPressOutside) !== 0);

        menu.open();
        tryCompare(menu, "visible", true);
        tryCompare(menu, "activeFocus", true);
        menu.dismissOnFocusLoss(false);
        tryCompare(menu, "visible", false);
    }

    function test_workspace_editor_prefills_selects_and_limits_input(): void {
        const editor = createTemporaryObject(workspaceEditorComponent, this);
        verify(editor !== null);
        compare(editor.editorText, "Deep work");
        compare(editor.maximumLength, 32);
        compare(editor.focusRequested, true);
        tryCompare(editor, "inputHasFocus", true);

        editor.editorText = "123456789012345678901234567890123";
        compare(editor.editorText, "12345678901234567890123456789012");
    }

    function test_workspace_editor_submits_trimmed_name_with_enter(): void {
        const editor = createTemporaryObject(workspaceEditorComponent, this);
        verify(editor !== null);
        let submittedName = null;
        editor.submitted.connect(name => submittedName = name);
        editor.editorText = "  project alpha  ";
        tryCompare(editor, "inputHasFocus", true);

        keyClick(Qt.Key_Return);

        compare(submittedName, "project alpha");
    }

    function test_workspace_editor_allows_empty_reset(): void {
        const editor = createTemporaryObject(workspaceEditorComponent, this);
        verify(editor !== null);
        let submittedName = null;
        editor.submitted.connect(name => submittedName = name);
        editor.editorText = "   ";

        editor.submit();

        compare(submittedName, "");
    }

    function test_workspace_editor_cancels_on_escape_or_focus_loss(): void {
        const escapeEditor = createTemporaryObject(workspaceEditorComponent, this);
        verify(escapeEditor !== null);
        let escapeCancelled = false;
        escapeEditor.cancelled.connect(() => escapeCancelled = true);
        tryCompare(escapeEditor, "inputHasFocus", true);

        keyClick(Qt.Key_Escape);

        verify(escapeCancelled);

        const blurEditor = createTemporaryObject(workspaceEditorComponent, this);
        verify(blurEditor !== null);
        let blurCancelled = false;
        blurEditor.cancelled.connect(() => blurCancelled = true);
        tryCompare(blurEditor, "inputHasFocus", true);

        blurEditor.dismissOnFocusLoss(false);

        verify(blurCancelled);
    }

    function test_workspace_editor_releases_row_width_when_closed(): void {
        const row = createTemporaryObject(workspaceEditorRowComponent, this);
        verify(row !== null);
        compare(row.editorLoader.width, 160);
        compare(row.implicitWidth, 185);

        row.editing = false;

        compare(row.editorLoader.visible, false);
        tryCompare(row, "implicitWidth", 20);
    }

    function test_numeric_column_does_not_move_with_digit_count(): void {
        const oneDigit = metricAt(5);
        const twoDigits = metricAt(55);
        const threeDigits = metricAt(100);
        compare(oneDigit.valueColumnX, twoDigits.valueColumnX);
        compare(twoDigits.valueColumnX, threeDigits.valueColumnX);
        compare(oneDigit.valueColumnRight, threeDigits.valueColumnRight);
    }

    function test_explicit_severity_and_units_keep_the_same_value_column(): void {
        const temperature = createTemporaryObject(metricComponent, this, {
            value: 86,
            suffix: "°",
            severity: 2
        });
        const disconnected = createTemporaryObject(metricComponent, this, {
            formattedValue: "OFF",
            severity: 1
        });
        verify(temperature !== null);
        verify(disconnected !== null);
        compare(temperature.displayText, "86°");
        compare(temperature.displayColor.toString(), "#fb4934");
        compare(disconnected.displayText, "OFF");
        compare(disconnected.displayColor.toString(), "#fabd2f");
        compare(temperature.valueColumnX, disconnected.valueColumnX);
        compare(temperature.valueColumnRight, disconnected.valueColumnRight);
    }

    function test_malformed_workspace_payload_is_bounded_and_safe(): void {
        const raw = [];
        raw.push(null);
        raw.push({ id: -4, clients: [] });
        raw.push({
            id: 2,
            clients: [{ icon: null, class: null, tabs: -10 }, "broken"],
            claude: Number.POSITIVE_INFINITY
        });
        for (let index = 0; index < 100; index += 1)
            raw.push({ id: index + 3, clients: [{}] });
        raw.push({ id: 999, clients: [] });

        const normalized = Sanitizer.normalizeWorkspaces(raw);
        compare(normalized.length, 64);
        compare(normalized[0].id, 2);
        compare(normalized[0].name, "2");
        compare(normalized[0].clients[0].icon, "application-x-executable");
        compare(normalized[0].clients[0].class, "application");
        compare(normalized[0].clients[0].tabs, 1);
        compare(normalized[0].claude, 0);
        verify(normalized.every(workspace => workspace.clients.length > 0));
    }

    function test_malformed_metrics_are_bounded_before_rendering(): void {
        const base = {
            cpu: 5,
            ram: 10,
            io: 20,
            gpu: 30,
            laptop: false,
            battery: null,
            wifi: null,
            wifiConnected: false,
            cpuTemp: null,
            gpuTemp: null,
            ioTooltip: "ok",
            batteryTooltip: "ok",
            wifiTooltip: "ok"
        };
        const normalized = Sanitizer.normalizeMetrics(base, {
            cpu: "9".repeat(10000),
            ram: Number.POSITIVE_INFINITY,
            io: 900,
            gpu: { percent: 90 },
            laptop: "yes",
            battery: -50,
            wifi: 61,
            wifiConnected: true,
            cpuTemp: 20,
            gpuTemp: 900,
            ioTooltip: "x".repeat(10000)
        });
        compare(normalized.cpu, 5);
        compare(normalized.ram, 10);
        compare(normalized.io, 100);
        compare(normalized.gpu, 30);
        compare(normalized.laptop, false);
        compare(normalized.battery, 0);
        compare(normalized.wifi, 61);
        compare(normalized.wifiConnected, true);
        compare(normalized.cpuTemp, null);
        compare(normalized.gpuTemp, null);
        compare(normalized.ioTooltip.length, 512);
    }

    function test_2560_layout_keeps_maximum_telemetry_clear_of_clock(): void {
        const width = 2560;
        const clockWidth = 180;
        const metricCount = 8;
        const metricWidth = 96;
        const rightMargin = 12;
        const minimumGap = 12;
        verify(StatusLayout.telemetryClearsClock(
            width,
            clockWidth,
            metricCount,
            metricWidth,
            rightMargin,
            minimumGap
        ));
        verify(StatusLayout.telemetryLeft(width, metricCount, metricWidth, rightMargin)
            >= StatusLayout.clockRight(width, clockWidth) + minimumGap);
    }
}
