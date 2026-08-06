---
name: build-reference-matched-ui
description: "Create or substantially redesign application interfaces through a heavyweight reference-first workflow: generate independent high-detail UI references with imagegen/gpt-img-2, refine them against a functional control inventory, implement multiple candidates, repeatedly capture and compare exact states and breakpoints, and require fresh adversarial acceptance. Use for greenfield UI builds, full-page or application redesigns, complex multi-state component overhauls, or explicit high-fidelity visual matching where independent references and candidate comparison are justified. Do not use for small deterministic UI edits such as changing a color or design token, spacing, typography value, border, icon, copy, or a localized CSS/theme rule."
---

# Build Reference-Matched UI

Build the visual authority before styling the product, then treat independent review—not implementer confidence—as the completion gate.

## Applicability gate

Use this workflow only for substantial design work that benefits from independent visual exploration and competing implementations. If the requested result is already fully specified and can be implemented as a localized, deterministic change to an existing interface, handle it directly without invoking this skill.

Read [references/acceptance-rubric.md](references/acceptance-rubric.md) before auditing a generated reference, comparing a candidate, or requesting final review.

## Non-negotiable rules

- Generate the reference before inspecting or changing the implementation's aesthetic layer.
- Inspect existing code only to discover behavior, data, controls, states, and constraints during the reference phase. Do not derive the reference's styling, layout, typography, imagery, or ornament from the current UI.
- Use `$imagegen` and verify from tool metadata or environment documentation that its backend is `gpt-img-2`. Select `gpt-img-2` when a model selector is exposed. Never silently substitute a different image model. If the backend cannot be confirmed as `gpt-img-2`, report `BLOCKED: gpt-img-2 unavailable or unverified` and do not lock a reference or implement the UI.
- Never pass current implementation screenshots, current styled renders, or reference comps derived from them into reference generation.
- Preserve every real workflow. Do not remove required controls to match an image, and do not add controls the application does not implement.
- Produce at least two runnable implementation candidates before selecting a direction. Candidate plurality is a hard gate.
- Never self-certify completion. Require an independent fresh reviewer to return `ACCEPT` under the rubric.
- Treat `REJECT`, `PARTIAL`, unavailable review, missing evidence, or an unresolved functional mismatch as incomplete.

## 1. Inventory functional intent

Perform a behavior-only inspection of requirements, routes, components, tests, accessibility labels, menus, and state transitions. Record a control inventory with:

- screen and state;
- required controls and exact labels;
- menus, dialogs, and their open/closed states;
- enabled, disabled, selected, empty, error, and loading behavior;
- data density and realistic content constraints;
- responsive breakpoints and required viewports;
- accessibility requirements;
- existing functionality that must not regress;
- explicitly unimplemented functionality that must not appear.

Resolve functional ambiguity before image generation. Do not use visual details from the current implementation in this inventory.

## 2. Generate an independent reference set

Write a standalone product-design prompt from the functional inventory and user brief. Include:

- exact canvas dimensions and viewport;
- application purpose and information hierarchy;
- all required controls, menus, labels, and states;
- expected content density;
- typography hierarchy and reading requirements;
- material, color, imagery, and atmosphere goals;
- accessibility and responsive constraints;
- explicit anti-patterns and forbidden invented functionality;
- output framing such as straight-on screenshot, no device frame, and no annotations.

Do not mention the current implementation, its CSS, its layout, its shortcomings, or its screenshots. Do not include implementation images as imagegen inputs.

Generate the primary state first. Generate a companion reference for every materially different state required to implement the surface, including open menus, dialogs, drawers, empty/error states, and mobile layouts. Reuse only already-approved generated reference imagery when continuity between reference states is required.

Save each original image, exact prompt, confirmed `gpt-img-2` generation metadata, timestamp, dimensions, and a `referencesUsed` list. The list must be empty unless it names another generated reference-state image or a user-supplied brand asset. Do not lock an image with unknown or different model provenance.

## 3. Refine the reference until it is functionally true

Audit each generated image line by line against the control inventory before asking the user to approve it.

Reject and regenerate or edit a reference when any required control is missing, duplicated, mislabeled, clipped, unreachable, or assigned to the wrong state; when an unimplemented control appears; or when the visual hierarchy contradicts the intended workflow.

Repeat generation and functional audit until all inventory rows pass. Image beauty never compensates for a false interaction model.

Present the functionally valid reference set to the user for approval. After approval:

1. Record the approved paths and file hashes.
2. Mark the set `REFERENCE_LOCKED` in the task evidence.
3. Do not regenerate or reinterpret the reference without explicit user approval.

## 4. Define the fidelity contract

Translate the locked references into measurable implementation targets:

- major region geometry and reading measure;
- component dimensions, spacing, alignment, and density;
- font families, sizes, weights, line heights, and hierarchy;
- surface colors, borders, shadows, radii, and ornament frequency;
- image crop, focal point, scale, and contrast treatment;
- control states, responsive transformations, and touch targets.

Use the thresholds in the acceptance rubric. Record any unavoidable platform rendering variance before implementation; do not invent exceptions after seeing a poor match.

## 5. Create candidate implementations

Only after `REFERENCE_LOCKED`, inspect the existing aesthetic implementation and build at least two candidates from the same functional baseline.

Keep candidates isolated and runnable using the repository's safest native mechanism: feature variants, temporary branches/worktrees, or parallel component/theme files. Preserve unrelated user changes. Do not delete a non-selected candidate without authorization.

Each candidate must:

- implement the complete control inventory;
- use real interactions and data rather than painted or fake controls;
- preserve keyboard, focus, and responsive behavior;
- render every reference state at the exact reference viewport;
- include any required assets with provenance;
- pass targeted behavioral checks before visual scoring.

Capture all candidates with identical deterministic data, fonts loaded, animations settled, and the same viewport/device scale. Score them independently with the rubric. Select the candidate with the smallest structural and typographic discrepancy, not the one with the most ornament.

## 6. Run the continuous comparison loop

Maintain a discrepancy ledger for every reference state and breakpoint. Compare the locked reference and current capture at the same pixel dimensions and scale.

For each discrepancy, record:

- category;
- reference measurement or visual evidence;
- actual measurement or visual evidence;
- numerical or optical delta;
- severity and salience;
- root cause;
- intended correction.

Use overlays, image-diff tooling, sampled colors, and browser measurements when available. Visual judgment must be supported by concrete evidence.

Correct root causes in coherent batches. After every UI-affecting code or asset change, regardless of perceived impact:

1. rerun the complete targeted behavioral check set;
2. recapture every locked reference state and breakpoint;
3. compare again from the locked images;
4. update the discrepancy ledger;
5. verify that no state regressed.

Continue until the implementer can find no rubric violation. This is readiness for review, not completion.

## 7. Verify production behavior

Run the repository's relevant lint, type, unit, integration, accessibility, and end-to-end checks. Add behavioral regression coverage for defects found during visual work, especially clipped menus, unreachable footer actions, missing controls, and breakpoint collisions.

Capture final evidence only from a passing build.

## 8. Require fresh adversarial acceptance

Start a new reviewer in an isolated fresh context that did not generate the reference, implement candidates, participate in comparisons, or receive previous findings. Use no inherited conversation history. Record the reviewer agent/session identifier and exact prompt. The reviewer must not edit files.

Provide the reviewer only:

- the locked reference images;
- the approved acceptance rubric;
- the original user brief and authoritative functional-requirement paths;
- the functional control inventory;
- route, component, accessibility-label, and test paths used to derive the inventory;
- required states and breakpoints;
- relevant test results;
- the exact passing commit/worktree identifier;
- deterministic seed and capture commands;
- source paths for checking functional or accessibility risks.

Do not provide the implementation story, suspected defects, desired verdict, previous reviews, or explanations that bias where the reviewer looks. Use the neutral reviewer prompt in the acceptance rubric.

Require the reviewer to launch the exact passing build, reproduce every required state, and create its own captures at the locked dimensions. The reviewer must compare those independent captures—not implementer-selected screenshots—to the references. Require hashes for the reviewed reference images, independently captured images, and reviewed commit/worktree state. If the reviewer cannot reproduce or capture the build, the gate is `REJECT`.

Accept completion only when the fresh reviewer returns `ACCEPT` with every rubric category marked `MATCH`. If the reviewer returns anything else:

1. record the verdict unchanged;
2. return to the comparison loop;
3. fix and recapture all affected states;
4. request a new fresh final reviewer.

If an independent reviewer is unavailable, report `BLOCKED: independent acceptance review unavailable`. Never replace the reviewer with self-assessment.

## Required handoff evidence

Report:

- locked reference paths, hashes, prompts, and provenance;
- the functional control inventory;
- candidate identifiers and comparison scores;
- final capture paths for every state and breakpoint;
- final reference, capture, and reviewed-state hashes;
- the final discrepancy ledger;
- verification commands and results;
- independent reviewer identity/session, isolated-context confirmation, exact prompt, and verbatim gate verdict.

Do not call the UI complete without this evidence.
