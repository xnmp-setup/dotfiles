# Tableau Frog — Implementation Plan

## Context
Build a composable, variables-first data exploration tool (Tableau alternative). The core idea: user assigns columns to axis slots (x, y, z/color), the app infers chart type. Multiple panels share one dataset; selecting a subset on one panel broadcasts a contrast lens to all others.

## Stack
- **Tauri v2** + **Svelte 5** + **Rust** (Polars for in-memory DataFrame)
- **D3 math modules** (d3-scale, d3-shape, d3-array) + raw SVG for charts
- No charting library — we need full control over selection + contrast overlays

## Project Structure

```
tableau-frog/
├── src/                          # Svelte frontend
│   ├── lib/
│   │   ├── stores/
│   │   │   ├── dataset.svelte.ts       # Column metadata after CSV load
│   │   │   ├── panels.svelte.ts        # Panel configs (axis assignments, chart data)
│   │   │   └── selection.svelte.ts     # Global selection + contrast broadcast
│   │   ├── components/
│   │   │   ├── Shell.svelte            # App chrome: toolbar + panel grid
│   │   │   ├── ColumnList.svelte       # Sidebar: draggable column pills
│   │   │   ├── Panel.svelte            # One chart panel (slots + chart)
│   │   │   ├── AxisSlot.svelte         # Drop target for x/y/z
│   │   │   └── charts/
│   │   │       ├── Scatter.svelte
│   │   │       ├── Line.svelte
│   │   │       ├── Histogram.svelte
│   │   │       ├── Bar.svelte
│   │   │       └── Distribution.svelte
│   │   ├── types.ts                    # Shared TS types mirroring Rust serde
│   │   ├── chart-inference.ts          # Pure fn: axis types → chart type
│   │   └── ipc.ts                      # Typed wrappers around tauri invoke()
│   └── routes/+page.svelte            # SPA entry
├── src-tauri/
│   ├── Cargo.toml
│   ├── src/
│   │   ├── main.rs                     # Tauri entry, register commands
│   │   ├── commands.rs                 # #[tauri::command] functions
│   │   ├── store.rs                    # DataStore wrapping polars DataFrame
│   │   ├── types.rs                    # ColumnInfo, ChartData, SelectionSpec, ContrastData
│   │   ├── compute.rs                  # Chart data computation
│   │   └── contrast.rs                 # Subset vs population log-ratios
```

## Rust Backend

**DataStore** (`store.rs`): Singleton in Tauri managed state. Wraps a polars `DataFrame`. On CSV load, infers column types:
- Float/Int → Numeric
- Utf8/Categorical → Categorical
- Date/Datetime → Timelike

**5 Tauri commands** (`commands.rs`):
- `load_csv(path)` → `Vec<ColumnInfo>`
- `get_column_info()` → `Vec<ColumnInfo>`
- `compute_chart_data(ChartRequest)` → `ChartData` (discriminated union: Scatter/Line/Histogram/Bar/Distribution/Heatmap)
- `compute_contrast(ContrastRequest)` → `ContrastData` (log-ratios per bin/bar/point)
- `get_selection_mask(SelectionSpec)` → `Vec<bool>`

**Contrast computation** (`contrast.rs`): Given a `SelectionSpec` and target panel's `ChartRequest`:
1. Build boolean mask from SelectionSpec
2. Compute chart data for full population and subset
3. For each element: `ln(p_subset / p_population)`, clamped to [-3, 3]

**Key design**: Backend sends render-ready data (binned/aggregated), never raw rows. A 50-bin histogram sends 50 objects, not 1M rows.

## Frontend

**State** (Svelte 5 runes):
- `dataset.svelte.ts`: `ColumnInfo[]` from loaded CSV
- `panels.svelte.ts`: `PanelConfig[]` — each panel has axis assignments, inferred chart type, fetched chart data, and contrast data
- `selection.svelte.ts`: `currentSelection: SelectionSpec | null`

**Core loop**:
1. Drag column to axis slot → panel config updates
2. `$derived` infers chart type from axis types
3. `$effect` calls `compute_chart_data` via IPC
4. Chart component renders SVG
5. User selects (box/click/drag) → emits `SelectionSpec`
6. All other panels' `$effect` calls `compute_contrast` → contrast overlay renders

**Charts**: Raw SVG + D3 scales. Each chart accepts optional `contrastData` prop; when present, uses `d3.scaleDiverging(d3.interpolateRdBu)` for fill colors.

**Drag-and-drop**: Native HTML DnD. Column pills in sidebar, drop targets on axis slots.

## Phased Build Order

### Phase 0: Scaffold
- Vite + Svelte 5 + TS, `cargo tauri init`, add polars, verify `cargo tauri dev`

### Phase 1: Data Loading
- `store.rs` + `load_csv` command + column type detection
- Frontend: file picker (Tauri dialog), `ColumnList.svelte`
- **Milestone**: Open CSV, see columns with type indicators

### Phase 2: First Chart (Histogram)
- `compute.rs` for histogram, `Histogram.svelte`, `Panel.svelte` with axis slots
- **Milestone**: Drag numeric column to x, see histogram

### Phase 3: Chart Inference + More Charts
- `chart-inference.ts`, Scatter, Bar, Line, Distribution
- Corresponding Rust compute functions
- **Milestone**: All rows of the inference table work

### Phase 4: Selection
- Rect select on Scatter, bin select on Histogram, click on Bar
- Wire to `selection.svelte.ts`
- **Milestone**: Select a region, see it highlighted

### Phase 5: Contrast (Killer Feature)
- `contrast.rs`, contrast coloring in all chart components
- Multi-panel layout with "+" to add panels
- **Milestone**: Select on panel A, see red/white/blue contrast on panel B

### Phase 6: Polish
- Parquet support, config file, performance opts, Canvas for dense scatter

## Verification
After each phase:
1. `cargo tauri dev` launches without errors
2. Phase-specific milestone works end-to-end
3. Final: load CSV → two panels → assign different axes → select on one → contrast visible on other
