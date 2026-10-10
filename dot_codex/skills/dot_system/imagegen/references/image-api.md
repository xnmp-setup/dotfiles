# Image API quick reference

Read this for explicit CLI/API/model requests. These controls apply to the Image API and bundled CLI, not the built-in `image_gen` tool.

Before a paid request, verify current capabilities in the [official guide](https://developers.openai.com/api/docs/guides/image-generation) and [generation endpoint reference](https://developers.openai.com/api/reference/resources/images/methods/generate). This reference was checked on 2026-10-10.

## Model selection

| Model | Quality | Sizes | Use |
| --- | --- | --- | --- |
| `gpt-image-2.5-flare` | `low`, `medium`, `high`, `xhigh`, `max`, `auto` | Flexible constrained sizes or `auto` | Default for fast, high-quality generation |
| `gpt-image-2.5-sunburst` | Same as Flare | Same as Flare | Editing precision |
| `gpt-image-2` | `low`, `medium`, `high`, `auto` | Flexible constrained sizes or `auto` | Existing integrations or explicit requests |
| `gpt-image-1.5`, `gpt-image-1`, `gpt-image-1-mini` | `low`, `medium`, `high`, `auto` | `1024x1024`, `1536x1024`, `1024x1536`, `auto` | Legacy compatibility or explicit requests |

Preserve an explicitly chosen model. Both 2.5 models support native transparency. GPT Image 2 transparency is currently in preview. Transparent outputs require PNG or WebP.

## Flexible size constraints

GPT Image 2/2.5, including dated snapshots, accept `WIDTHxHEIGHT` with:

- Width and height divisible by 16.
- Maximum edge 3840 pixels.
- Aspect ratio between 1:3 and 3:1.
- Total pixels between 655,360 and 8,294,400.

Above 2560x1440 total pixels is experimental. Common sizes include `1024x1024`, `2048x1152`, `3440x1440`, and `3840x2160`. Use an explicit size when exact dimensions matter; `auto` can return a smaller image with a different aspect ratio. Inspect actual output dimensions before reporting or installing it.

## Endpoints and parameters

- Generate: `POST /v1/images/generations` (`client.images.generate`).
- Edit: `POST /v1/images/edits` (`client.images.edit`).
- `model`: Explicit model ID; CLI defaults to Flare.
- `prompt`: Desired image and preservation constraints.
- `n`: 1–10 images.
- `size`, `quality`: As above; CLI quality defaults to `medium`.
- `background`: `transparent`, `opaque`, or `auto`; separate from the prompt's scene description.
- `output_format`: `png`, `jpeg`, or `webp`.
- `output_compression`: 0–100 for JPEG/WebP.
- `moderation`: `auto` or `low`.

Edits also accept input images and optional masks. Omit `input_fidelity` for GPT Image 2/2.5 and use model defaults; legacy models retain supported `low`/`high` controls. Masks guide edits but do not guarantee exact geometry. Input images/masks must be under 50MB.

## Output and failure handling

The API returns `data[].b64_json`; the bundled CLI decodes and saves it. Inspect dimensions, composition, requested details, and alpha when relevant. Larger sizes and higher quality can increase latency and cost.

Do not silently drop user-required options or substitute a different model after an error. Adjust optional controls only within the authorized request. `--max-attempts` and `--fail-fast` are batch-only CLI controls; use the subcommand's `--help` before relying on an option.
