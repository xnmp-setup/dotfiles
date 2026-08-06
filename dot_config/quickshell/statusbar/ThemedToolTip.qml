import QtQuick
import QtQuick.Controls
import "StatusGraph.js" as StatusGraph

ToolTip {
    id: control

    required property var themeColors
    property int maximumWidth: 420
    // Recent samples, oldest first. Two or more numeric points draw a graph.
    property var history: []
    // Overlay a moving average for jittery series (CPU, IO, GPU, Wi-Fi).
    property bool smoothed: false
    property int smoothingWindow: 10
    // Pointer x in parent coordinates; the popup opens under (and tracks) the
    // pointer instead of a fixed per-cell position. Negative keeps the default.
    property real pointerX: -1
    readonly property color surfaceColor: themeColors.surface
    readonly property bool showsGraph: StatusGraph.numericValues(history).length >= 2

    x: pointerX >= 0
        ? pointerX - width / 2
        : parent ? (parent.width - width) / 2 : 0
    y: parent ? parent.height + 6 : 0

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

    onHistoryChanged: graphCanvas.requestPaint()
    onThemeColorsChanged: graphCanvas.requestPaint()

    contentItem: Column {
        spacing: 6

        Text {
            width: Math.min(
                control.maximumWidth - control.leftPadding - control.rightPadding,
                implicitWidth
            )
            text: control.text
            color: control.themeColors.text
            wrapMode: Text.Wrap
            font.family: "Inter"
            font.pixelSize: 12
            font.weight: Font.Medium
            lineHeight: 1.2
        }

        Canvas {
            id: graphCanvas
            visible: control.showsGraph
            width: 224
            height: 48

            onPaint: {
                const context = getContext("2d");
                context.reset();
                const values = StatusGraph.numericValues(control.history);
                if (values.length < 2)
                    return;
                const range = StatusGraph.bounds(values);
                const gutter = 30;
                const plotWidth = width - gutter;
                const top = 3;
                const bottom = height - 3;
                const yFor = value => bottom
                    - (value - range.min) / (range.max - range.min) * (bottom - top);
                const xFor = index => index / (values.length - 1) * plotWidth;
                const drawSeries = (series, style, lineWidth) => {
                    context.strokeStyle = style;
                    context.lineWidth = lineWidth;
                    context.lineJoin = "round";
                    context.beginPath();
                    let started = false;
                    for (let index = 0; index < series.length; index += 1) {
                        const value = series[index];
                        if (typeof value !== "number" || !Number.isFinite(value))
                            continue;
                        if (started)
                            context.lineTo(xFor(index), yFor(value));
                        else
                            context.moveTo(xFor(index), yFor(value));
                        started = true;
                    }
                    context.stroke();
                };

                const dim = control.themeColors.text_dim;
                drawSeries(
                    values,
                    control.smoothed ? Qt.alpha(dim, 0.45) : control.themeColors.accent_light,
                    control.smoothed ? 1 : 1.5
                );
                if (control.smoothed) {
                    drawSeries(
                        StatusGraph.movingAverage(values, control.smoothingWindow),
                        control.themeColors.accent_light,
                        1.6
                    );
                }

                context.fillStyle = dim;
                context.font = "8px Inter";
                context.textAlign = "right";
                context.fillText(Math.round(range.max), width, top + 6);
                context.fillText(Math.round(range.min), width, bottom);
            }
        }
    }

    background: Rectangle {
        color: control.surfaceColor
        border.width: 1
        border.color: control.themeColors.border
        radius: 6
    }
}
