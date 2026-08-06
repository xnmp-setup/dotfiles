.pragma library

function clockLeft(width, clockWidth) {
    return (width - clockWidth) / 2;
}

function clockRight(width, clockWidth) {
    return (width + clockWidth) / 2;
}

function telemetryLeft(width, metricCount, metricWidth, rightMargin) {
    return rightRegionLeft(width, metricCount * metricWidth, rightMargin);
}

function rightRegionLeft(width, regionWidth, rightMargin) {
    return width - rightMargin - regionWidth;
}

function rightRegionClearsClock(
    width,
    clockWidth,
    regionWidth,
    rightMargin,
    minimumGap
) {
    return rightRegionLeft(width, regionWidth, rightMargin)
        >= clockRight(width, clockWidth) + minimumGap;
}

function telemetryClearsClock(
    width,
    clockWidth,
    metricCount,
    metricWidth,
    rightMargin,
    minimumGap
) {
    return rightRegionClearsClock(
        width,
        clockWidth,
        metricCount * metricWidth,
        rightMargin,
        minimumGap
    );
}
