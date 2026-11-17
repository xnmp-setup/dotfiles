# FLUX / Black Forest Labs

Use only when the user selects FLUX or continues an established FLUX task. OpenAI remains the default. This workflow was verified on 2026-10-11; verify current model availability, request fields and pricing before a paid request.

## Credential and setup

- Known keyring selector: `service=bfl`. Retrieve with `secret-tool lookup service bfl`, capturing stdout inside the calling process. Never send the lookup output to tool logs, put the key in command-line arguments, or save it in files. Redact the key from any provider error text before displaying it.
- To create/update the entry, have the user run `secret-tool store --label="Black Forest Labs API key" service bfl` in their terminal and paste the key at its password prompt. Do not ask for a key in chat.
- Account, credits and project keys are managed at [dashboard.bfl.ai](https://dashboard.bfl.ai). BFL keys are separate from OpenAI and Google keys.

## Image generation

- Tested model: **FLUX 3 Image**, released 2026-10-01. FLUX.2 [max] is an older model, not the recent FLUX 3 release. Honor an explicitly requested model rather than substituting.
- Submit `POST https://api.bfl.ai/v1/flux-3-image` with `x-key` authentication and JSON content type. For an ultrawide wallpaper, use:

```json
{
  "prompt": "The saved scene description",
  "aspect_ratio": "21:9",
  "resolution": "4k",
  "grounding": false
}
```

- `grounding` defaults to true and uses web/image search. Use false for an invented fantasy scene or a text-only comparison; true can be useful for factual scenes. `resolution` supports `768sq`, `1k`, `1.5k`, `2k`, and `4k`. These are provider tiers, not arbitrary exact dimensions.
- References/edits: provide `images` as image URLs or base64, up to ten images, and describe each image's role. Upload only images authorized for the selected provider and requested task; the skill's OpenAI standing authorization alone does not grant BFL upload authorization.
- Preserve the returned request ID, `polling_url`, and numeric `cost`, `input_mp`, and `output_mp` fields in job metadata immediately after acceptance. The submission response defines `cost` in credits; it can be null. Poll that exact URL; validate it is HTTPS on a documented BFL API host before attaching the credential. A regional URL such as `api.isr.bfl.ai` is normal.
- Continue through documented in-progress statuses, stop on terminal failure, and download `result.sample` once status is `Ready`. The signed download URL expires after one hour. Never send `x-key` to that URL. Do not automatically repeat a submission after an uncertain timeout, or resubmit because polling/downloading failed; resume a recorded job first when its ID is available.
- Inspect actual image format and dimensions rather than trusting the requested tier. A tested `4k`, `21:9` result was 6256x2688. Crop minimally to the target aspect ratio and downsample to 3440x1440; preserve a native copy when useful. Follow the main skill's destination and collision rules.

## Credit accounting

- Read the key's balance with `GET https://api.bfl.ai/v1/credits`, authenticated with `x-key`; the response has numeric `credits`.
- One BFL credit equals US$0.01. Prefer the request-specific numeric `cost` returned on submission when available. When the user asks about usage, also record balance before submission and after completion. Their difference is the net account balance change; the shared organization pool, concurrent activity, transfers and auto top-ups can affect attribution.
- As of verification, a FLUX 3 Image `4k` request's list price is US$0.607 (60.7 credits). A launch discount ended on 2026-10-08. Recheck pricing rather than applying an expired promotion.
- Save request settings, dimensions, measured usage and remaining balance in metadata, without credentials. Distinguish measured charges from list-price estimates when a generation response has no cost field. Report currency as USD.

## Sources

- [FLUX 3 Image request and cost schema](https://docs.bfl.ml/api-reference/utility/generate-an-image-with-flux-3)
- [FLUX 3 Image request settings](https://docs.bfl.ai/flux_3/flux3_image_overview)
- [Submit, poll and download](https://docs.bfl.ai/flux_3/flux3_image_generate)
- [Credit endpoint](https://api.bfl.ai/docs)
- [Current prices](https://bfl.ai/pricing)
- [Release dates](https://docs.bfl.ai/release-notes)
