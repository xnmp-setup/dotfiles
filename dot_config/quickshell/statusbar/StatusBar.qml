import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import "StatusLayout.js" as StatusLayout

PanelWindow {
    id: bar

    required property bool barVisible
    required property string candidate
    required property var statusSource
    required property int renameRequestSerial
    property int editingWorkspaceId: 0
    property bool renameRequestsReady: false
    readonly property var themeColors: statusSource.themeColors
    readonly property bool editingWorkspaceExists: editingWorkspaceId === 0
        || statusSource.workspaces.some(workspace => workspace.id === editingWorkspaceId
            && workspace.monitor === screen.name)
    readonly property bool showCpuTemp: statusSource.metrics.cpuTemp !== null
        && statusSource.metrics.cpuTemp !== undefined
    readonly property bool showGpuTemp: statusSource.metrics.gpuTemp !== null
        && statusSource.metrics.gpuTemp !== undefined
    readonly property bool showLaptop: statusSource.metrics.laptop === true
    readonly property int metricCellCount: 4 + (showCpuTemp ? 1 : 0)
        + (showGpuTemp ? 1 : 0) + (showLaptop ? 2 : 0)
    readonly property int metricCellWidth: 96
    readonly property int usageCellWidth: 188
    readonly property int compactUsageCellWidth: 39
    readonly property bool compactUsage: !StatusLayout.rightRegionClearsClock(
        width,
        clockCell.implicitWidth,
        metricCellCount * metricCellWidth + 2 * usageCellWidth,
        12,
        12
    )
    readonly property bool rightRegionClearsClock: StatusLayout.rightRegionClearsClock(
        width,
        clockCell.implicitWidth,
        rightRegion.implicitWidth,
        12,
        12
    )

    function temperatureSeverity(value: var): int {
        return value >= 85 ? 2 : 1;
    }

    function batterySeverity(value: var): int {
        if (value === null || value === undefined)
            return 1;
        return value <= 10 ? 2 : value <= 25 ? 1 : 0;
    }

    function wifiSeverity(connected: bool, value: var): int {
        if (!connected || value === null || value === undefined)
            return 1;
        return value < 20 ? 2 : value < 40 ? 1 : 0;
    }

    function beginFocusedWorkspaceRename(): void {
        const focusedWorkspace = Hyprland.focusedWorkspace;
        if (!focusedWorkspace)
            return;
        const belongsToBar = statusSource.workspaces.some(
            workspace => workspace.id === focusedWorkspace.id
                && workspace.monitor === screen.name
        );
        if (belongsToBar)
            editingWorkspaceId = focusedWorkspace.id;
    }

    onEditingWorkspaceExistsChanged: {
        if (!editingWorkspaceExists)
            editingWorkspaceId = 0;
    }
    onRenameRequestSerialChanged: {
        if (renameRequestsReady)
            beginFocusedWorkspaceRename();
    }

    Component.onCompleted: renameRequestsReady = true

    visible: barVisible
    implicitHeight: 40
    exclusiveZone: barVisible ? 40 : 0
    color: themeColors.background
    focusable: editingWorkspaceId > 0

    HyprlandFocusGrab {
        id: renameFocusGrab

        windows: [bar]
        active: bar.editingWorkspaceId > 0
        onCleared: {
            if (bar.editingWorkspaceId > 0)
                bar.editingWorkspaceId = 0;
        }
    }

    anchors {
        top: true
        left: true
        right: true
    }

    Rectangle {
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        height: 1
        color: bar.themeColors.border
    }

    Item {
        id: workspaceViewport
        anchors {
            left: parent.left
            right: clockCell.left
            top: parent.top
            bottom: parent.bottom
            leftMargin: 8
            rightMargin: 12
        }
        clip: true

        RowLayout {
            id: workspaces
            anchors {
                left: parent.left
                verticalCenter: parent.verticalCenter
            }
            spacing: 8

            Repeater {
                model: bar.statusSource.workspaces.filter(
                    workspace => workspace.monitor === bar.screen.name
                )

                WorkspaceChip {
                    required property var modelData

                    workspaceData: modelData
                    candidate: bar.candidate
                    themeColors: bar.themeColors
                    editing: bar.editingWorkspaceId === modelData.id
                    onRenameStarted: workspaceId => {
                        bar.editingWorkspaceId = workspaceId;
                    }
                    onRenameFinished: {
                        if (bar.editingWorkspaceId === modelData.id)
                            bar.editingWorkspaceId = 0;
                    }
                }
            }
        }
    }

    ClockCell {
        id: clockCell
        anchors.centerIn: parent
        themeColors: bar.themeColors
        z: 2
    }

    RowLayout {
        id: rightRegion
        anchors {
            right: parent.right
            rightMargin: 12
            verticalCenter: parent.verticalCenter
        }
        spacing: 0
        z: 1

        RowLayout {
            id: telemetry
            spacing: 0

            MetricCell {
                label: "CPU"
                value: bar.statusSource.metrics.cpu
                tooltip: "Total CPU use"
                themeColors: bar.themeColors
            }
            MetricCell {
                label: "RAM"
                value: bar.statusSource.metrics.ram
                tooltip: "Used memory, excluding readily reclaimable cache"
                themeColors: bar.themeColors
            }
            MetricCell {
                label: "IO"
                value: bar.statusSource.metrics.io
                tooltip: bar.statusSource.metrics.ioTooltip || "Disk busy time over the trailing 30 seconds"
                themeColors: bar.themeColors
            }
            MetricCell {
                label: "GPU"
                value: bar.statusSource.metrics.gpu
                tooltip: "Graphics processor use"
                themeColors: bar.themeColors
            }

            Loader {
                active: bar.showCpuTemp
                sourceComponent: MetricCell {
                    label: "CPU°"
                    value: bar.statusSource.metrics.cpuTemp
                    suffix: "°"
                    severity: bar.temperatureSeverity(value)
                    tooltip: "CPU package temperature · shown only at 75°C or hotter"
                    themeColors: bar.themeColors
                }
            }
            Loader {
                active: bar.showGpuTemp
                sourceComponent: MetricCell {
                    label: "GPU°"
                    value: bar.statusSource.metrics.gpuTemp
                    suffix: "°"
                    severity: bar.temperatureSeverity(value)
                    tooltip: "GPU temperature · shown only at 75°C or hotter"
                    themeColors: bar.themeColors
                }
            }
            Loader {
                active: bar.showLaptop
                sourceComponent: MetricCell {
                    label: "WIFI"
                    value: bar.statusSource.metrics.wifi
                    formattedValue: bar.statusSource.metrics.wifiConnected
                        && value !== null && value !== undefined ? value + "%" : "OFF"
                    severity: bar.wifiSeverity(bar.statusSource.metrics.wifiConnected, value)
                    tooltip: bar.statusSource.metrics.wifiTooltip || "Wi-Fi status unavailable"
                    themeColors: bar.themeColors
                }
            }
            Loader {
                active: bar.showLaptop
                sourceComponent: MetricCell {
                    label: "BAT"
                    value: bar.statusSource.metrics.battery
                    severity: bar.batterySeverity(value)
                    tooltip: bar.statusSource.metrics.batteryTooltip || "Battery status unavailable"
                    themeColors: bar.themeColors
                }
            }
        }

        UsageCell {
            provider: "claude"
            usage: bar.statusSource.usage.claude
            themeColors: bar.themeColors
            compact: bar.compactUsage
        }

        UsageCell {
            provider: "codex"
            usage: bar.statusSource.usage.codex
            themeColors: bar.themeColors
            compact: bar.compactUsage
            last: true
        }
    }
}
