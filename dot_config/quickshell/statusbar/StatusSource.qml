import QtQuick
import Quickshell
import Quickshell.Io
import "StatusSanitizer.js" as Sanitizer

Scope {
    id: root

    property var metrics: ({
        cpu: null,
        ram: null,
        io: null,
        gpu: null,
        ioTooltip: "Collecting a 30-second disk activity window",
        laptop: false,
        battery: null,
        batteryState: "",
        batteryTooltip: "Battery status unavailable",
        wifi: null,
        wifiConnected: false,
        wifiTooltip: "Wi-Fi disconnected",
        cpuTemp: null,
        gpuTemp: null
    })
    property var workspaces: []
    property var usage: ({
        claude: {
            percent: null,
            resetsAt: null,
            windowMinutes: null,
            secondaryPercent: null,
            secondaryResetsAt: null,
            secondaryWindowMinutes: null
        },
        codex: {
            percent: null,
            resetsAt: null,
            windowMinutes: null,
            secondaryPercent: null,
            secondaryResetsAt: null,
            secondaryWindowMinutes: null
        }
    })
    property var themeColors: ({
        accent: "#d4607a",
        accent_light: "#e87898",
        background: "#0a0e28",
        surface: "#2a3352",
        border: "#3c4268",
        text: "#d8dce8",
        text_dim: "#8088b4"
    })
    // Rolling per-series samples, oldest first, for the tooltip graphs.
    // Metrics arrive every second; usage arrives every 30 seconds.
    property var history: ({
        cpu: [],
        ram: [],
        io: [],
        gpu: [],
        wifi: [],
        battery: [],
        claude: [],
        codex: []
    })
    readonly property int historyLimit: 180
    property string lastWorkspaceJson: "[]"

    function pushHistory(updates: var): void {
        const next = {};
        for (const key in history) {
            const series = history[key];
            const value = updates[key];
            if (typeof value === "number" && Number.isFinite(value)) {
                const appended = series.concat([value]);
                next[key] = appended.length > historyLimit
                    ? appended.slice(appended.length - historyLimit)
                    : appended;
            } else {
                next[key] = series;
            }
        }
        history = next;
    }

    function accept(line: string): void {
        let snapshot;
        try {
            snapshot = JSON.parse(line);
        } catch (error) {
            return;
        }
        if (snapshot === null || typeof snapshot !== "object")
            return;
        if (snapshot.metrics !== null && typeof snapshot.metrics === "object") {
            root.metrics = Sanitizer.normalizeMetrics(root.metrics, snapshot.metrics);
            root.pushHistory({
                cpu: root.metrics.cpu,
                ram: root.metrics.ram,
                io: root.metrics.io,
                gpu: root.metrics.gpu,
                wifi: root.metrics.wifiConnected ? root.metrics.wifi : null,
                battery: root.metrics.battery
            });
        }
        if (snapshot.palette !== null && typeof snapshot.palette === "object")
            root.themeColors = Sanitizer.mergeObject(root.themeColors, snapshot.palette);
        if (Array.isArray(snapshot.workspaces)) {
            const normalized = Sanitizer.normalizeWorkspaces(snapshot.workspaces);
            const encoded = JSON.stringify(normalized);
            if (encoded !== root.lastWorkspaceJson) {
                root.lastWorkspaceJson = encoded;
                root.workspaces = normalized;
            }
        }
    }

    function acceptUsage(line: string): void {
        let snapshot;
        try {
            snapshot = JSON.parse(line);
        } catch (error) {
            return;
        }
        if (snapshot === null || typeof snapshot !== "object" || Array.isArray(snapshot))
            return;
        root.usage = Sanitizer.normalizeUsage(root.usage, snapshot);
        root.pushHistory({
            claude: root.usage.claude.percent,
            codex: root.usage.codex.percent
        });
    }

    Process {
        id: stream
        command: [Quickshell.env("HYPR_STATUS_STREAM")
            || Quickshell.env("HOME") + "/.local/bin/hypr-status-stream"]
        running: true

        stdout: SplitParser {
            onRead: data => root.accept(data)
        }

        onRunningChanged: {
            if (!running)
                restartTimer.restart();
        }
    }

    Timer {
        id: restartTimer
        interval: 2000
        repeat: false
        onTriggered: stream.running = true
    }

    Process {
        id: usageStream
        command: [Quickshell.env("STATUSBAR_AI_USAGE_STREAM")
            || Quickshell.env("HOME") + "/.local/bin/ai-usage-stream"]
        running: true

        stdout: SplitParser {
            onRead: data => root.acceptUsage(data)
        }

        onRunningChanged: {
            if (!running)
                usageRestartTimer.restart();
        }
    }

    Timer {
        id: usageRestartTimer
        interval: 5000
        repeat: false
        onTriggered: usageStream.running = true
    }
}
