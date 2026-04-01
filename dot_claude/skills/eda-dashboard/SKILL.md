---
name: eda-dashboard
description: Automated EDA pipeline for any CSV dataset. Produces data quality checks, cleaning, LightGBM regression model, and interactive React+Plotly.js dashboard. Use when user wants to explore, analyze, or build a dashboard for a dataset.
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Agent
---

# EDA Dashboard Generator

End-to-end pipeline: CSV dataset → data quality audit → cleaning → EDA → LightGBM regression → interactive React+Plotly.js dashboard.

## When to Use

When the user wants to:
- Explore or analyze a CSV dataset
- Build an interactive dashboard for data
- Run EDA (exploratory data analysis) on any dataset
- Train a regression model and visualize results

## Required Parameters

Ask the user for these if not provided:

| Parameter | Description | Example |
|-----------|-------------|---------|
| `dataset_path` | Path to the CSV file | `data/properties.csv` |
| `target_column` | Column to predict (regression target) | `price` |

## Optional Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `theme` | CBA gold (`#FFCC00`, `#b5920a`, `#fff9e6`) | Primary, accent, background hex colors |
| `project_dir` | Current working directory | Where to scaffold the project |
| `web_dir` | `web/` under project_dir | React app location |

## Pipeline Steps

Execute these in order. Commit after each major step per project conventions.

### Step 1: Project Setup

```bash
uv init  # if no pyproject.toml exists
uv add pandas matplotlib seaborn
```

### Step 2: Dataset Exploration

Read the CSV and produce an initial summary:
- Shape (rows x columns)
- Column dtypes
- Missing value counts
- Descriptive statistics (numeric columns)
- Unique value counts (categorical columns)
- Date range (if date columns exist)
- Target variable distribution (mean, median, std, skew, kurtosis)

### Step 3: Data Quality Audit

Check for these issues systematically:

1. **Implausible values**: For each numeric column, check min/max against domain expectations. Flag values that are physically impossible (e.g., negative bedrooms, 7 sqm houses).
2. **Extreme outliers**: Values beyond Q3 + 10*IQR or column max >> 99th percentile. Inspect these rows individually.
3. **Zero-encoded nulls**: Columns where 0 may mean "missing" rather than zero (e.g., 0 bedrooms on a house). Cross-reference with other columns for context.
4. **Misclassified categories**: Categorical values that contradict numeric columns (e.g., "Apartment" with 20,000 sqm lot).
5. **Duplicates**: Exact row duplicates AND near-duplicates (same values on key columns).
6. **Categorical inconsistencies**: Case/whitespace variations in string columns.

Present findings to the user before cleaning.

### Step 4: Data Cleaning Script

Create `clean_data.py` that:
- Removes rows with physically impossible values
- Removes entries with feature counts exceeding domain-reasonable thresholds
- Recodes zero-as-null to NaN for non-applicable rows
- Fixes misclassified categories (set implausible numeric fields to NaN)
- Removes duplicate rows (keep first)
- Removes extreme price outliers if appropriate
- Saves cleaned CSV to `data/{original_name}_clean.csv`
- Prints summary of changes

### Step 5: EDA Script

Create `eda.py` that generates:
- Target variable distribution (raw + log-transformed)
- Categorical breakdowns (counts + median target by category)
- Top/bottom groups by median target
- Correlation matrix (numeric columns vs target)
- Time series trends (if date column exists)
- Key scatter plots (target vs top correlated features)
- Geographic plots (if lat/lng columns exist)

Use `matplotlib.use("Agg")` for headless rendering.

### Step 6: Regression Model

Create `model.py`:

```python
# Key decisions:
# - Log-transform target if skew > 2 (log-normal distribution)
# - 5-fold cross-validation with early stopping
# - Feature engineering: encode categoricals, extract date parts,
#   create domain-relevant ratios
# - Report metrics in ORIGINAL scale (not log scale)
# - Save results to model_results.json including:
#   actuals[], predictions[], feature_importance[], fold_metrics[],
#   overall metrics, error_percentiles
```

Install: `uv add lightgbm scikit-learn`

LightGBM params baseline:
```python
{
    "objective": "regression",
    "metric": "mae",
    "learning_rate": 0.05,
    "num_leaves": 63,
    "min_child_samples": 20,
    "subsample": 0.8,
    "colsample_bytree": 0.8,
    "reg_alpha": 0.1,
    "reg_lambda": 0.1,
    "verbose": -1,
}
```

### Step 7: Interactive React Dashboard

Scaffold under `web/` directory:

```bash
npm create vite@latest web -- --template react-ts
cd web
bun install  # use bun per user preference
bun add react-plotly.js plotly.js-dist-min papaparse
bun add -D @types/papaparse @tailwindcss/vite tailwindcss
```

#### Critical Gotcha: react-plotly.js Import

**DO NOT** use `import Plot from "react-plotly.js"` — it imports the full 8MB plotly.js bundle and the default export is a module object, not a component.

**CORRECT** approach — use the factory pattern:

```tsx
// src/components/Plot.tsx
import factoryModule from "react-plotly.js/factory";
import Plotly from "plotly.js-dist-min";

const createPlotlyComponent =
  typeof factoryModule === "function"
    ? factoryModule
    : (factoryModule as { default: typeof factoryModule }).default;

const Plot = createPlotlyComponent(Plotly);
export default Plot;
```

Add type declarations in `src/types/plotly.d.ts`:
```typescript
declare module "react-plotly.js/factory" {
  import type Plotly from "plotly.js";
  import type { Component } from "react";
  interface PlotParams {
    data: Plotly.Data[];
    layout?: Partial<Plotly.Layout>;
    config?: Partial<Plotly.Config>;
    style?: React.CSSProperties;
    className?: string;
    useResizeHandler?: boolean;
  }
  function createPlotlyComponent(plotly: typeof Plotly): new () => Component<PlotParams>;
  export default createPlotlyComponent;
}
declare module "plotly.js-dist-min" {
  export * from "plotly.js";
  export { default } from "plotly.js";
}
```

#### Data Serving

Symlink data files into `web/public/`:
```bash
mkdir -p web/public/data
ln -sf ../../data/dataset_clean.csv web/public/data/
ln -sf ../../model_results.json web/public/
```

Configure Vite to allow parent directory access:
```typescript
server: { fs: { allow: [resolve(__dirname, "..")] } }
```

#### Dashboard Sections

Build these sections, each as its own component:

1. **Dataset Overview** — stat cards (rows, features, date range, target stats)
2. **Data Cleaning** — table of issues found and actions taken
3. **Target Distribution** — histogram with:
   - **Group-by dropdown** (categorical columns + binned numerics)
   - **Stack/overlay toggle**
   - **Linear/log scale toggle**
   - **Bin count slider**
4. **Category Breakdown** — horizontal bar charts (count + median target by category)
5. **Time Trends** — line chart with Plotly rangeslider, mean/median toggle
6. **Geographic Patterns** — WebGL scatter (use `scattergl` for 5K+ points), outlier toggle
7. **Feature Analysis** — box plots with outlier toggle, adjustable range
8. **Correlations** — interactive heatmap + sortable table with strength bars
9. **Model Results** — metrics cards, fold table, actual vs predicted scatter, residual analysis (absolute/percentage toggle), feature importance bar chart

#### Theme System

Define theme as CSS custom properties and a colors utility:
```typescript
// Parameterize with user-provided colors, default to CBA gold
const THEME = {
  primary: "#FFCC00",      // header accent, active nav
  accent: "#b5920a",       // chart colors, stat values
  background: "#fff9e6",   // page background
  card: "#ffffff",
  text: "#1a1a1a",
  muted: "#6b6b6b",
  border: "#e6d9a8",       // derive from primary
  hover: "#fff4cc",        // derive from background
};
```

#### Performance Notes

- Use `scattergl` (WebGL) trace type for scatter plots with >5K points
- Plotly.js-dist-min is ~1.5MB gzipped — acceptable for dashboards
- PapaParse handles 10K+ row CSVs in <200ms client-side
- Use `useMemo` for expensive computations (correlations, aggregations)

## Anti-Patterns to Avoid

1. **Don't pre-compute everything in Python** — let the React app compute aggregations client-side for interactivity
2. **Don't use `useEffect` for derived state** — use `useMemo` instead (per user preference)
3. **Don't embed base64 charts in HTML** — that's the old static report approach; the React app renders charts dynamically
4. **Don't import react-plotly.js directly** — always use the factory pattern (see gotcha above)
5. **Don't use npm** — use bun (per user preference)
