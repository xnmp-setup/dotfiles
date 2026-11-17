# Nano Banana / Google Gemini

Use only when the user selects Nano Banana/Gemini or continues an established task with it. OpenAI remains the default. This workflow was verified on 2026-10-11; verify current model availability and settings before a paid request.

## Credential and model discovery

- Primary known keyring selector: `service=gemini-api`. Another known Google API entry is `service=gemini-cli-api-key`. Retrieve with `secret-tool lookup service <selector>`, capturing stdout within the calling process. Never display or save the secret, include it in command-line arguments, or ask for it in chat. Redact it from any provider error text.
- If the user needs to store a key, have them run `secret-tool store --label="Gemini API key" service gemini-api` in their terminal and paste it at the password prompt.
- Authenticate to Google using the `x-goog-api-key` header. Use `GET https://generativelanguage.googleapis.com/v1beta/models` to check accessible image models. Do not dump unrelated credentials or silently substitute a different provider.
- Tested default within this explicitly selected provider: **Nano Banana 2.1**, model ID `gemini-nano-banana-2.1`. Nano Banana Pro is a distinct model (`gemini-3-pro-image`); Nano Banana 2 uses `gemini-3.1-flash-image`. Preserve a user's explicit choice and verify availability rather than assuming aliases are interchangeable.

## REST generation

Submit `POST https://generativelanguage.googleapis.com/v1beta/interactions` with `x-goog-api-key` authentication and JSON content type:

```json
{
  "model": "gemini-nano-banana-2.1",
  "input": "The saved scene description",
  "response_format": {
    "type": "image",
    "aspect_ratio": "21:9",
    "image_size": "4K"
  },
  "store": false
}
```

- `image_size` is case-sensitive. The tested model supports `1K`, `2K`, and `4K`; use `4K` for detailed ultrawide wallpapers. These tiers do not accept an arbitrary exact 3440x1440 size.
- `store=false` avoids retaining an Interaction for later conversational retrieval. It does not assert that Google performs no other service processing or retention.
- For references/edits, `input` can contain an ordered array of text and image content blocks, with base64 `data` and `mime_type`. Assign each reference a role. Upload only images authorized for Google and the requested task; OpenAI-only standing authorization does not itself grant Google upload authorization.
- In the REST response, inspect `steps` with `type="model_output"`, then their `content` blocks with `type="image"`. Decode base64 `data` and honor `mime_type` when choosing the native file extension. The SDK convenience property `output_image` is not a top-level REST response field.
- If there is no image block, report the failure/status rather than claiming generation succeeded. Do not automatically repeat a paid request after an uncertain timeout.
- Inspect actual output dimensions and format. A tested `4K`, `21:9` result was 6336x2688 JPEG. Preserve the native image and create a 3440x1440 PNG with a minimal aspect-ratio crop and downsampling, following the main skill's staging and save rules. Do not label the native JPEG as PNG or say the delivered size was generated natively.
- Save model, prompt, requested settings, native/delivered dimensions and returned usage counters in metadata. Usage tokens alone are not an invoice; use current pricing to label any cost calculation as an estimate. Do not claim a remaining account balance without querying a supported billing source.

## Sources

- [Image generation and model selection](https://ai.google.dev/gemini-api/docs/image-generation)
- [Interactions REST request and response schema](https://ai.google.dev/api/interactions-api)
- [Model discovery](https://ai.google.dev/api/models)
- [Current pricing](https://ai.google.dev/gemini-api/docs/pricing)
