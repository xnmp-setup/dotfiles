# Acceptance rubric

Use this rubric for reference functional audits, candidate scoring, discrepancy tracking, and final adversarial review.

## Reference functional audit

Require 100% agreement with the control inventory before locking a reference:

- every required control exists once in the correct state;
- exact user-facing labels are correct where specified;
- menus and dialogs contain the intended items and actions;
- enabled, disabled, selected, destructive, and primary states are unambiguous;
- no unimplemented or decorative fake control appears;
- no required control is clipped, occluded, or visually unreachable;
- content density is sufficient to expose wrapping and overflow risks;
- every required responsive or transient state has a reference image.

Regenerate or edit on any failure. Do not average functional errors into a visual score.

## Fidelity categories

Judge reference and actual at identical pixel dimensions and scale.

### FUNCTIONAL CONTRACT

- Preserve all controls, labels, workflows, states, and accessibility semantics.
- Permit no missing, duplicated, invented, fake, or unreachable controls.
- Require all targeted behavioral and end-to-end tests to pass.

Any failure is an automatic `REJECT`.

### COMPOSITION AND GEOMETRY

- Match major region edges and proportions within 4px.
- Match component height, width, alignment, and repeated spacing within 2px.
- Match reading measure, density, fixed/sticky behavior, and viewport crop.
- Permit no clipping, accidental overflow, collision, or unexplained blank region.

### TYPOGRAPHY

- Match font category/family and intended optical character.
- Match principal font sizes within 0.5px, line-height within 0.025, and weight exactly when the reference's intended weight is available.
- Match hierarchy, wrapping, tracking, casing, and baseline alignment.
- Treat default-looking or undersized utility typography as a mismatch when the reference is authored.

### MATERIAL, COLOR, AND DEPTH

- Measure sampled colors. Require ΔE ≤ 3 for major surfaces and ≤ 5 for small accents. If color measurement cannot be performed, the category cannot be marked `MATCH`.
- Match border weight, radii, shadow purpose, texture strength, and ornament frequency.
- Reject generic gradients, glow, glass, card chrome, or repeated decoration absent from the reference.

### IMAGERY AND ICON CRAFT

- Preserve focal subject, crop, scale, contrast, and text-safe areas.
- Keep salient landmarks within 1% of the relevant axis for position and apparent size.
- Match icon family, stroke weight, optical size, and state treatment.
- Reject inconsistent stock imagery or glyphs that weaken a bespoke visual system.

### RESPONSIVE AND ACCESSIBLE BEHAVIOR

- Preserve the reference hierarchy at every required breakpoint, even when layout transforms.
- Require comfortable targets: 44×44px by default, or a documented platform exception no smaller than the product's established floor.
- Meet WCAG contrast requirements, visible focus, keyboard operation, and reduced-motion expectations.
- Permit no mobile label collision, hidden primary action, modal trap, or off-screen menu item.

## Verdict vocabulary

- `MATCH`: Every stated numerical threshold is satisfied and no visually salient craft discrepancy remains. Antialiasing and equivalent dynamic content may differ only when they do not change geometry, hierarchy, wrapping, color measurement, or interaction.
- `MISMATCH`: Any threshold failure, any visually salient craft difference, any missing measurement, or any functional/accessibility failure.

Do not use `PARTIAL` for the final gate. Final acceptance requires every category to be `MATCH`.

## Candidate scorecard

Use measurements to rank candidates, but never let a total score hide a gate failure.

| Category | Candidate A | Candidate B | Evidence |
|---|---:|---:|---|
| Functional contract | Pass/Fail | Pass/Fail | Tests and inventory |
| Composition and geometry | 0–5 | 0–5 | Pixel measurements |
| Typography | 0–5 | 0–5 | Computed styles and wraps |
| Material, color, and depth | 0–5 | 0–5 | Samples and visual evidence |
| Imagery and icon craft | 0–5 | 0–5 | Crop and icon comparison |
| Responsive and accessible | 0–5 | 0–5 | Breakpoint captures and checks |

Select only among candidates whose functional contract passes. Lower discrepancy wins; scores are not acceptance.

## Neutral final reviewer prompt

Use a prompt equivalent to the following. Substitute artifact paths without adding implementation history or suspected defects.

> Act as an independent adversarial UI fidelity reviewer in an isolated fresh context. Do not edit files and do not rely on implementation-author screenshots. First cross-check the functional control inventory against the original user brief and supplied requirements, routes, components, accessibility labels, and tests. Launch the exact supplied passing build, reproduce every required state, and create your own captures at the locked dimensions. Hash the locked references, your captures, and the reviewed commit/worktree state. Compare each locked reference with your corresponding capture at the same dimensions. Apply the supplied low-tolerance rubric exactly, including all required measurements. Return `GATE: ACCEPT` only if FUNCTIONAL CONTRACT, COMPOSITION AND GEOMETRY, TYPOGRAPHY, MATERIAL COLOR AND DEPTH, IMAGERY AND ICON CRAFT, and RESPONSIVE AND ACCESSIBLE BEHAVIOR are all `MATCH`. Return `GATE: REJECT` if reproduction, capture, hashing, or a required measurement cannot be completed. For every mismatch, cite reference and actual locations, measurements, severity, and observable evidence. Do not infer intent, reward effort, or relax tolerances because the implementation is generally attractive.

Require the reviewer output to begin with `GATE: ACCEPT` or `GATE: REJECT`, followed by a category table and severity-ranked evidence.
