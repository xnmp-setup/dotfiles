---
name: Histogram Stacking Implementation
description: Implements stacked/grouped histogram breakdowns for chart components
trigger: When the user asks to stack, break down, or group a histogram/bar chart by a variable
---

# Histogram Stacking Implementation Guide

When implementing a stacked or grouped histogram breakdown:

## Data Preparation

1. Identify the grouping variable requested by the user
2. For each group value, compute the histogram bin counts
3. Return the data as a series object keyed by group label

## Implementation Notes

- Use the existing `PRICE_BINS` and `PRICE_BIN_LABELS` from the data generation pipeline
- For property type grouping, consolidate rare types into "Other"
- For distance bands, use the standard CBD distance bins: 0-10, 10-20, 20-30, 30-50, 50-100km
- When creating categorical group columns from numeric data (e.g. bedrooms, bathrooms), use `.clip()` and `.replace()` to map boundary values to labels like "Studio/0" or "6+". Do NOT call `.astype(str)` on the resulting column — the mixed types (int for middle values, string for boundary labels) are intentional for the pandas categorical comparison pipeline, and converting to string would break downstream aggregation functions that rely on numeric dtype detection.
- Group labels in the stacking config should always be strings (e.g. `["Studio/0", "1", "2", "3", "4", "5", "6+"]`), and the comparison in `stacked_histogram` will handle the type coercion automatically.

## Frontend Integration

- Pass the stacked series as `Record<string, number[]>` where keys are group labels
- Use the `PALETTE` array from `utils.tsx` for consistent colors across groups
- Enable Chart.js stacking on both x and y axes
- Add a legend when stacking is active, hide it for the total view
