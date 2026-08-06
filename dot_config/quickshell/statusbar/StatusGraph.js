.pragma library

// Trailing moving average. Non-numeric entries contribute nothing but keep
// their slot so the smoothed series stays aligned with the raw one.
function movingAverage(values, windowSize) {
    const result = [];
    for (let index = 0; index < values.length; index += 1) {
        const start = Math.max(0, index - windowSize + 1);
        let sum = 0;
        let count = 0;
        for (let cursor = start; cursor <= index; cursor += 1) {
            const value = values[cursor];
            if (typeof value === "number" && Number.isFinite(value)) {
                sum += value;
                count += 1;
            }
        }
        result.push(count > 0 ? sum / count : null);
    }
    return result;
}

// Accepts plain JS arrays and the QVariantList shape that `property var`
// values take on when they cross QML object boundaries (Array.isArray is
// false for the latter, so only length + indexing may be relied upon).
function numericValues(values) {
    const result = [];
    if (values === null || values === undefined
            || typeof values.length !== "number")
        return result;
    for (let index = 0; index < values.length; index += 1) {
        const value = values[index];
        if (typeof value === "number" && Number.isFinite(value))
            result.push(value);
    }
    return result;
}

// Y-axis bounds padded so a flat series still renders mid-band instead of
// hugging an edge.
function bounds(values) {
    const numbers = numericValues(values);
    if (numbers.length === 0)
        return null;
    let minimum = Math.min.apply(null, numbers);
    let maximum = Math.max.apply(null, numbers);
    if (maximum - minimum < 4) {
        const center = (maximum + minimum) / 2;
        minimum = center - 2;
        maximum = center + 2;
    }
    return { min: minimum, max: maximum };
}
