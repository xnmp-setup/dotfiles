.pragma library

function clockLeft(width, clockWidth) {
    return (width - clockWidth) / 2;
}

function clockRight(width, clockWidth) {
    return (width + clockWidth) / 2;
}

function telemetryLeft(width, metricCount, metricWidth, rightMargin) {
    return width - rightMargin - metricCount * metricWidth;
}

function telemetryClearsClock(
    width,
    clockWidth,
    metricCount,
    metricWidth,
    rightMargin,
    minimumGap
) {
    return telemetryLeft(width, metricCount, metricWidth, rightMargin)
        >= clockRight(width, clockWidth) + minimumGap;
}
