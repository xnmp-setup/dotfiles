---
name: "imagegen"
description: "Generate or edit raster images when the task benefits from AI-created bitmap visuals such as photos, illustrations, textures, sprites, mockups, or transparent-background cutouts. Use when Codex should create a brand-new image, transform an existing image, or derive visual variants from references, and the output should be a bitmap asset rather than repo-native code or vector. Do not use when the task is better handled by editing existing SVG/vector/code-native assets, extending an established icon or logo system, or building the visual directly in HTML/CSS/canvas."
---

# Image Generation Skill

Generates or edits images for the current project (for example website assets, game assets, UI mockups, product mockups, wireframes, logo design, photorealistic images, or infographics).

## Standing authorization for referenced images

Confirmed by this user on 2026-10-11: for image generation or editing, images the user attaches or explicitly identifies as references or edit targets may be uploaded to OpenAI image-generation services, including the OpenAI Image API. This is standing user authorization; do not ask again for permission to upload those images for the requested task. It does not authorize uploading unrelated images discovered while browsing folders, or sending images to other providers. If the intended references are ambiguous, clarify which images the user means.

This authorization does not override sandbox or automatic approval review. When requesting an execution escalation for a reference upload, include this standing authorization and identify the task-relevant images and OpenAI destination.

## Provider selection

OpenAI remains the default provider: use the OpenAI API for local wallpapers and the built-in tool for other raster requests under the existing defaults below. Use FLUX or Nano Banana only when the user requests that provider/model, or continues an established task with it; an unrelated new request returns to the OpenAI default. Do not silently switch providers after an error.

- **FLUX / Black Forest Labs:** read [references/flux.md](references/flux.md). The tested workflow uses FLUX 3 Image and the keyring item `service=bfl`.
- **Nano Banana / Google Gemini:** read [references/nano-banana.md](references/nano-banana.md). The tested workflow uses Nano Banana 2.1 and the keyring item `service=gemini-api`; `service=gemini-cli-api-key` is another known Gemini entry.

The bundled `image_gen.py` and `generate_with_keyring.py` are OpenAI-only. For an explicitly selected external provider, use its documented REST workflow instead of passing its model ID to the OpenAI CLI. The persistent Python environment also supports stdlib HTTP requests and Pillow; no provider SDK installation is needed for these REST workflows.

Preserve the wallpaper staging, inspection, prompt sidecar, destination and collision rules below for every provider. When a provider cannot return exact dimensions, inspect its native output, retain the native image when useful, and create the requested wallpaper through a minimal aspect-ratio crop and downsampling. Report both native and delivered dimensions; do not describe that conversion as native generation at the target size.

## Local wallpaper workflow

For this user's desktop wallpaper requests, prefer the OpenAI API through `scripts/generate_with_keyring.py`. This is a standing user preference; do not ask again whether to use the API. Other raster-image requests retain the built-in default. An explicit tool, model, size or destination overrides these wallpaper defaults.

- Run API commands with `~/.local/share/imagegen/.venv/bin/python`, the persistent environment containing `openai` and `pillow`. Do not install dependencies or create a temporary environment on each run. If missing or broken, follow the one-time setup in [references/cli.md](references/cli.md).
- Default desktop wallpaper size: `3440x1440`; quality: `high`; format: PNG. For photographic requests, include a plausible camera and exposure brief.
- Generate to a unique filename in `output/imagegen/`, inspect the image and verify actual dimensions, then move only the selected final image to `~/Pictures/Wallpaper/`. Keep the `.prompt.txt` file in `output/imagegen/`; do not put prompt files in the wallpaper folder. Create the directory if missing. A requested explicit destination takes precedence. Preview-only requests need not be moved.
- Use descriptive filenames such as `tropical-archipelago-3440x1440.png`. Check for destination collisions and choose a versioned sibling rather than overwrite an existing wallpaper.
- Report clickable links to the final image and saved prompt, and mention the API path. Do not change the active desktop wallpaper unless requested.

## Running under Claude Code

This skill was written for Codex. Claude Code has no built-in `image_gen` tool, so wherever this file says "built-in `image_gen` tool" or "built-in mode", delegate to a headless Codex session that invokes that tool, using the `codex-subagent` skill:

```bash
~/.claude/skills/codex-subagent/scripts/codex-run.sh -s workspace-write -C "$PWD" \
  "Use the built-in image_gen tool to <generate/edit ...>. Reference image(s): <abs paths>. Report the absolute path of each saved image."
```

- Tell the Codex session explicitly to call `image_gen`; do not let it fall back to scripts or the API.
- Output lands under `~/.codex/generated_images/<session-id>/`. Copy or move the selected file to the user's destination afterwards (see the save-path policy below); never leave a project asset there.
- Local wallpapers are unaffected: they use the CLI path (`scripts/generate_with_keyring.py`) directly from Claude, no Codex session needed.
- Pass the standing upload authorization above through to Codex only for images the user named as references or edit targets.

## Top-level modes and rules

OpenAI has two execution modes. Explicit FLUX and Nano Banana requests use the provider workflows above:

- **Default built-in tool mode (preferred except for local wallpapers):** built-in `image_gen` tool for image generation, editing, and transparent-image requests. Does not require `OPENAI_API_KEY`.
- **Fallback CLI mode:** bundled `scripts/image_gen.py` CLI, optionally run through `scripts/generate_with_keyring.py`. Use for local wallpaper requests under the standing preference above, or when the user explicitly asks for or confirms the CLI/API/model path. Real API calls require network access and an OpenAI key from the system keyring; see `references/cli.md`.

Within CLI fallback, the CLI exposes three subcommands:

- `generate`
- `edit`
- `generate-batch`

Rules for OpenAI:
- Use the built-in `image_gen` tool by default for normal image generation and editing requests except local wallpapers.
- Do not switch to CLI fallback for ordinary quality, size, or file-path control.
- For transparent images, ask built-in `image_gen` for a transparent background and preserve the generated alpha.
- For CLI/API generation, use `gpt-image-2.5-flare` by default; choose `gpt-image-2.5-sunburst` when precise editing is central. Honor an explicitly requested model. Verify model selection and capabilities against official OpenAI documentation before a paid request; do not treat this skill’s defaults as proof that a model is still current. Retrieve the API key from the system keyring as described in `references/cli.md`; never print, log, or save the key.
- The word `batch` by itself does not mean CLI fallback. For non-wallpaper requests, if the user asks for many assets or says to batch-generate assets without explicitly asking for CLI/API/model controls, stay on the built-in path and issue one built-in call per requested asset or variant.
- If the built-in tool fails or is unavailable, tell the user the CLI fallback exists and that it requires keyring access and network access. Proceed only if the user explicitly asks for that fallback.
- If the user explicitly asks for CLI mode, use the bundled `scripts/image_gen.py` workflow. Do not create one-off SDK runners.
- Use the bundled CLI rather than creating one-off SDK runners. Do not modify it during an image job; an explicit skill-maintenance request may update the CLI and its validation tests.

Built-in save-path policy:
- In built-in tool mode, Codex saves generated images under `$CODEX_HOME/*` by default.
- Do not describe or rely on OS temp as the default built-in destination.
- Do not describe or rely on a destination-path argument (if any) on the built-in `image_gen` tool. If a specific location is needed, generate first and then move or copy the selected output from `$CODEX_HOME/generated_images/...`.
- Save-path precedence in built-in mode:
  1. If the user names a destination, move or copy the selected output there.
  2. If the image is meant for the current project, move or copy the final selected image into the workspace before finishing.
  3. If the image is only for preview or brainstorming, render it inline; the underlying file can remain at the default `$CODEX_HOME/*` path.
- Never leave a project-referenced asset only at the default `$CODEX_HOME/*` path.
- Do not overwrite an existing asset unless the user explicitly asked for replacement; otherwise create a sibling versioned filename such as `hero-v2.png` or `item-icon-edited.png`.

Shared prompt guidance for both modes lives in `references/prompting.md` and `references/sample-prompts.md`.

Fallback-only docs/resources for CLI mode:
- `references/cli.md`
- `references/image-api.md`
- `references/codex-network.md`
- `scripts/image_gen.py`

## When to use
- Generate a new image (concept art, product shot, cover, website hero)
- Generate a new image using one or more reference images for style, composition, or mood
- Edit an existing image (inpainting, lighting or weather transformations, background replacement, object removal, compositing, transparent background)
- Produce many assets or variants for one task

## When not to use
- Extending or matching an existing SVG/vector icon set, logo system, or illustration library inside the repo
- Creating simple shapes, diagrams, wireframes, or icons that are better produced directly in SVG, HTML/CSS, or canvas
- Making a small project-local asset edit when the source file already exists in an editable native format
- Any task where the user clearly wants deterministic code-native output instead of a generated bitmap

## Decision tree

Think about two separate questions:

1. **Intent:** is this a new image or an edit of an existing image?
2. **Execution strategy:** is this one asset or many assets/variants?

Intent:
- If the user wants to modify an existing image while preserving parts of it, treat the request as **edit**.
- If the user provides images only as references for style, composition, mood, or subject guidance, treat the request as **generate**.
- If the user provides no images, treat the request as **generate**.

Built-in edit semantics:
- Built-in edit mode is for images already visible in the conversation context, such as attached images or images generated earlier in the thread.
- If the user wants to edit a local image file with the built-in tool, first load it with built-in `view_image` tool so the image is visible in the conversation context, then proceed with the built-in edit flow.
- Do not promise arbitrary filesystem-path editing through the built-in tool.
- If a local file still needs direct file-path control, masks, or other explicit CLI-only parameters, use the explicit CLI fallback only when the user asks for it.
- For edits, preserve invariants aggressively and save non-destructively by default.

Execution strategy:
- In the built-in default path, produce many assets or variants by issuing one `image_gen` call per requested asset or variant.
- In the CLI fallback path, use the CLI `generate-batch` subcommand only when the user explicitly chose CLI mode and needs many prompts/assets.
- For many distinct assets, do not use `n` as a substitute for separate prompts. `n` is for variants of one prompt; distinct assets need distinct built-in calls or distinct CLI `generate-batch` jobs.

Assume the user wants a new image unless they clearly ask to change an existing one.

## Workflow
1. Select the provider under the provider-selection rules. For OpenAI, use API CLI for local wallpapers and the built-in tool by default for other requests; for explicitly selected FLUX or Nano Banana, follow the linked REST workflow.
2. Decide the intent: `generate` or `edit`.
3. Decide whether the output is preview-only or meant to be consumed by the current project.
4. Decide the execution strategy: single asset vs repeated built-in calls vs CLI `generate-batch`.
5. Collect inputs up front: prompt(s), exact text (verbatim), constraints/avoid list, and any input images.
6. For every input image, label its role explicitly:
   - reference image
   - edit target
   - supporting insert/style/compositing input
7. If the edit target is only on the local filesystem and you are staying on the built-in path, inspect it with `view_image` first so the image is available in conversation context.
8. If the user asked for a photo, illustration, sprite, product image, banner, or other explicitly raster-style asset, use the selected image-generation provider rather than substituting SVG/HTML/CSS placeholders. If the request is for an icon, logo, or UI graphic that should match existing repo-native SVG/vector/code assets, prefer editing those directly instead.
9. Augment the prompt based on specificity:
   - If the user's prompt is already specific and detailed, normalize it into a clear spec without adding creative requirements.
   - If the user's prompt is generic, add tasteful augmentation only when it materially improves output quality.
10. Use the selected mode; local wallpapers follow the API workflow above.
11. For transparent-output requests in OpenAI built-in mode, request transparent output from `image_gen` and preserve alpha. For an explicitly selected external provider, verify native alpha support and report any limitation; do not silently switch providers.
12. Inspect outputs and validate: subject, style, composition, text accuracy, and invariants/avoid items.
13. Iterate with a single targeted change, then re-check.
14. For preview-only work, render the image inline; the underlying file may remain at the default `$CODEX_HOME/generated_images/...` path.
15. For project-bound work, move or copy the selected artifact into the workspace and update any consuming code or references. Never leave a project-referenced asset only at the default `$CODEX_HOME/generated_images/...` path.
16. For wallpaper batches, move final deliverables to the wallpaper destination above. For other batches or multi-asset requests, persist every requested deliverable final in the workspace unless the user explicitly asked to keep outputs preview-only. Discarded variants do not need to be kept unless requested.
17. For OpenAI API wallpapers or explicitly selected OpenAI CLI mode, read the fallback-only docs for request and execution controls. For FLUX or Nano Banana, read the selected provider reference instead.
18. Always report the final saved path(s) for any workspace-bound asset(s), plus the final prompt or prompt set and whether the built-in tool or fallback CLI mode was used.

## Transparent image requests

In OpenAI built-in mode, ask `image_gen` for a genuinely transparent background and preserve its alpha. For an explicitly selected external provider, follow its documented native alpha capabilities; if unsupported, report the limitation instead of switching providers.

## Prompt augmentation

Reformat user prompts into a structured, production-oriented spec. Make the user's goal clearer and more actionable, but do not blindly add detail.

Treat this as prompt-shaping guidance, not a closed schema. Use only the lines that help, and add a short extra labeled line when it materially improves clarity.

### Specificity policy

Use the user's prompt specificity to decide how much augmentation is appropriate:

- If the prompt is already specific and detailed, preserve that specificity and only normalize/structure it.
- If the prompt is generic, you may add tasteful augmentation when it will materially improve the result.

Allowed augmentations:
- composition or framing hints
- polish level or intended-use hints
- practical layout guidance
- reasonable scene concreteness that supports the stated request

Not allowed augmentations:
- extra characters or objects that are not implied by the request
- brand names, slogans, palettes, or narrative beats that are not implied
- arbitrary side-specific placement unless the surrounding layout supports it

## Use-case taxonomy (exact slugs)

Classify each request into one of these buckets and keep the slug consistent across prompts and references.

Generate:
- photorealistic-natural — candid/editorial lifestyle scenes with real texture and natural lighting.
- product-mockup — product/packaging shots, catalog imagery, merch concepts.
- ui-mockup — app/web interface mockups and wireframes; specify the desired fidelity.
- infographic-diagram — diagrams/infographics with structured layout and text.
- scientific-educational — classroom explainers, scientific diagrams, and learning visuals with required labels and accuracy constraints.
- ads-marketing — campaign concepts and ad creatives with audience, brand position, scene, and exact tagline/copy.
- productivity-visual — slide, chart, workflow, and data-heavy business visuals.
- logo-brand — logo/mark exploration, vector-friendly.
- illustration-story — comics, children’s book art, narrative scenes.
- stylized-concept — style-driven concept art, 3D/stylized renders.
- historical-scene — period-accurate/world-knowledge scenes.

Edit:
- text-localization — translate/replace in-image text, preserve layout.
- identity-preserve — try-on, person-in-scene; lock face/body/pose.
- precise-object-edit — remove/replace a specific element (including interior swaps).
- lighting-weather — time-of-day/season/atmosphere changes only.
- background-extraction — transparent background / clean cutout. Follow the provider-specific rules in the Transparent image requests section.
- style-transfer — apply reference style while changing subject/scene.
- compositing — multi-image insert/merge with matched lighting/perspective.
- sketch-to-render — drawing/line art to photoreal render.

## Shared prompt schema

Use the following labeled spec as shared prompt scaffolding for both top-level modes:

```text
Use case: <taxonomy slug>
Asset type: <where the asset will be used>
Primary request: <user's main prompt>
Input images: <Image 1: role; Image 2: role> (optional)
Scene/backdrop: <environment>
Subject: <main subject>
Style/medium: <photo/illustration/3D/etc>
Composition/framing: <wide/close/top-down; placement>
Lighting/mood: <lighting + mood>
Color palette: <palette notes>
Materials/textures: <surface details>
Text (verbatim): "<exact text>"
Constraints: <must keep/must avoid>
Avoid: <negative constraints>
```

Notes:
- `Asset type` and `Input images` are prompt scaffolding, not dedicated CLI flags.
- `Scene/backdrop` refers to the visual setting. It is not the same as the fallback CLI `background` parameter, which controls output transparency behavior.
- Fallback-only execution notes such as `Quality:`, `Input fidelity:`, masks, output format, and output paths belong in the CLI path only. Do not treat them as built-in `image_gen` tool arguments.

Augmentation rules:
- Keep it short.
- Add only the details needed to improve the prompt materially.
- For wallpapers, use a photographic camera-and-exposure brief only when the user asks for a photographic wallpaper. Choose plausible camera, lens, exposure, and support details for that scene; do not impose photographic language on illustrated or stylized wallpapers, or on other asset types.
- For edits, explicitly list invariants (`change only X; keep Y unchanged`).
- If any critical detail is missing and blocks success, ask a question; otherwise proceed.

## Examples

### Generation example (hero image)
```text
Use case: product-mockup
Asset type: landing page hero
Primary request: a minimal hero image of a ceramic coffee mug
Style/medium: clean product photography
Composition/framing: wide composition with usable negative space for page copy if needed
Lighting/mood: soft studio lighting
Constraints: no logos, no text, no watermark
```

### Edit example (invariants)
```text
Use case: precise-object-edit
Asset type: product photo background replacement
Primary request: replace only the background with a warm sunset gradient
Constraints: change only the background; keep the product and its edges unchanged; no text; no watermark
```

## Prompting best practices
- Structure prompt as scene/backdrop -> subject -> details -> constraints.
- Include intended use (ad, UI mock, infographic) to set the mode and polish level.
- Use camera/composition language for photorealism.
- Only use SVG/vector stand-ins when the user explicitly asked for vector output or a non-image placeholder.
- Quote exact text and specify typography + placement.
- For tricky words, spell them letter-by-letter and require verbatim rendering.
- For multi-image inputs, reference images by index and describe how they should be used.
- For edits, repeat invariants every iteration to reduce drift.
- Iterate with single-change follow-ups.
- If the prompt is generic, add only the extra detail that will materially help.
- If the prompt is already detailed, normalize it instead of expanding it.
- For CLI fallback only, see `references/cli.md` and `references/image-api.md` for model, `quality`, `input_fidelity`, masks, output format, and output-path guidance.
- For transparent images, follow the provider-specific rules in the Transparent image requests section and preserve genuine alpha.

More principles shared by both modes: `references/prompting.md`.
Copy/paste specs shared by both modes: `references/sample-prompts.md`.

## Guidance by asset type
Asset-type templates (website assets, game assets, wireframes, logo) are consolidated in `references/sample-prompts.md`.

## GPT Image 2.5 guidance for CLI/API mode

The fallback CLI defaults to `gpt-image-2.5-flare` for fast, high-quality generation. Use `gpt-image-2.5-sunburst` for workflows where editing precision matters most. Preserve a model the user explicitly chose. Before a paid request, check the current [official image-generation guide](https://developers.openai.com/api/docs/guides/image-generation).

- Both 2.5 models support native transparency with `--background transparent --output-format png` or `webp`; no older-model fallback is needed.
- Both support `low`, `medium`, `high`, `xhigh`, `max`, and `auto` quality. Use `high` for final assets unless the task calls for another level; do not choose expensive quality upgrades without a reason.
- Use an explicit size for assets that need exact dimensions. `auto` may return a smaller image and a different aspect ratio; inspect the actual output dimensions before reporting or installing it.
- Flexible sizes must satisfy the CLI's pixel, edge, aspect-ratio, and multiple-of-16 checks. Common sizes include `2048x1152`, `3440x1440`, and `3840x2160`. Above `2560x1440` total pixels is experimental.
- Omit `input_fidelity` with GPT Image 2/2.5; use the model's default fidelity. Older models retain their supported controls for compatibility.
- Read [references/image-api.md](references/image-api.md) for model capabilities and [references/cli.md](references/cli.md) for runnable commands. Confirm current behavior with `--help` and `--dry-run` when changing models or options.

## Fallback CLI mode only

### Temp and output conventions
These conventions apply only to the CLI fallback. They do not describe built-in `image_gen` output behavior.
- Use `tmp/imagegen/` for intermediate files (for example JSONL batches); delete them when done.
- Stage final artifacts under `output/imagegen/`. Move only inspected desktop wallpaper images to `~/Pictures/Wallpaper/` unless an explicit destination was requested. Keep prompt files in `output/imagegen/`.
- Use `--out` or `--out-dir` to control output paths; keep filenames stable and descriptive.

### Dependencies

Use the persistent `~/.local/share/imagegen/.venv` environment for API commands, including wallpapers. Its preinstalled packages are `openai` and `pillow`. Follow [references/cli.md](references/cli.md) for one-time setup or repair; do not reinstall on every request. Use `uv` to manage it.

### Environment
- For live OpenAI API calls, use `scripts/generate_with_keyring.py`; it retrieves `service=openai` from the system keyring and passes the key only to the child process environment.
- Never print, log, or save the key, and never ask the user to paste it into chat.
- If the keyring item is missing or inaccessible, stop and tell the user what keyring access failed. Do not silently switch generation paths after the user explicitly chose the API. If sandbox policy blocks keyring access, request the needed escalation only after API use is authorized.

If installation is not possible in this environment, tell the user which dependency is missing and how to install it into their active environment.

### Script-mode notes
- CLI commands + examples: `references/cli.md`
- API parameter quick reference: `references/image-api.md`
- Network approvals / sandbox settings for CLI mode: `references/codex-network.md`

## Reference map
- `references/prompting.md`: shared prompting principles for both modes.
- `references/sample-prompts.md`: shared copy/paste prompt recipes for both modes.
- `references/cli.md`: fallback-only CLI usage via `scripts/image_gen.py`.
- `references/image-api.md`: fallback-only API/CLI parameter reference.
- `references/codex-network.md`: fallback-only network/sandbox troubleshooting for CLI mode.
- `scripts/image_gen.py`: fallback-only CLI implementation.
- `scripts/generate_with_keyring.py`: OpenAI keyring wrapper for local wallpapers under the standing preference, or explicitly chosen CLI mode.
- `references/flux.md`: explicitly selected FLUX REST workflow, keyring entry, polling, dimensions and credit accounting.
- `references/nano-banana.md`: explicitly selected Google Nano Banana REST workflow, keyring entries, model discovery, output parsing and dimensions.
