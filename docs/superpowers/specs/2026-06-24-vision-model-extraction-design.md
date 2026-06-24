# Vision model-extraction for unconfirmed receivers — design spec

**Date:** 2026-06-24
**Status:** approved design, pre-implementation
**Branch:** `feature/vision-model-extraction`

## 1. Purpose

When a listing is classified as an AV receiver but **no model number could be parsed from the title/description**, read the listing's **photos** with a vision model to recover the brand/model, then re-resolve eARC. This rescues "eARC unconfirmed" listings whose model is only visible on the unit (front fascia or rear-panel label).

## 2. Provider — Gemini `gemini-2.5-flash-lite` (decided by live test)

A live test on a real FB Marketplace photo settled the provider:
- **DeepSeek's API is text-only.** `deepseek-v4-flash` returned `400 invalid_request_error: unknown variant 'image_url', expected 'text'`. DeepSeek V4 is multimodal in the chat UI only — **not** via the API. Ruled out.
- **Gemini `gemini-2.5-flash-lite`** read a back-panel label perfectly: `{"brand":"MARANTZ","model":"SR6004","text_seen":"MARANTZ\nMODEL NO. SR6004\n..."}`. Cheap (flash-lite tier), strong OCR, structured JSON output.

Auth: `GEMINI_API_KEY` (set in `.env`, validated against the live Gemini API). Native `generateContent` endpoint with `inline_data` (base64) parts and `response_mime_type: application/json`.

## 3. Trigger — live in the pipeline, model-recovery only

Runs **only** during the daily pipeline, and **only** when a listing is a confirmed receiver with **no parsed model**:
- regex fast-path hit (model already known) → **no** vision call
- DeepSeek text-classify returns `is_av_receiver: true` with a **blank/nil model** → **vision call**
- non-receiver (`:skip`) → **no** vision call

This is model *recovery*, not re-classification, and it minimizes Gemini calls (only the genuinely-unconfirmed receivers). No backfill of existing rows, no on-demand UI button (out of scope — see §9).

## 4. Architecture & integration

New rung at the end of the existing extract chain in `MarketplaceBot.Receivers`:

> negative-keyword prefilter → regex fast-path → DeepSeek text classify → **(NEW) Gemini vision pass**

- **`MarketplaceBot.Vision`** (behaviour): `@callback extract_model(image_urls :: [String.t()], opts :: keyword()) :: {:ok, %{brand: String.t() | nil, model: String.t() | nil}} | {:error, term()}`
- **`MarketplaceBot.Vision.Gemini`** (impl): downloads each image (Req, browser `user-agent`), base64-inlines them into one `generateContent` call, parses the JSON `{brand, model}`. Caps at `vision_max_images` (default 8). Merges `opts[:req_options]` for the `Req.Test` seam.
- **`MarketplaceBot.Receivers`**: in the LLM path, when the model is blank/nil, call the configured vision impl on `listing.images`. On a model hit, return `{:ok, vision_brand || brand, vision_model}`; otherwise return the original (blank) result unchanged.
- **Swap/seam:** the vision impl is selected via `opts[:vision] || Application.get_env(:marketplace_bot, :vision)` (default `MarketplaceBot.Vision.Gemini`); test config overrides with a stub (matching the existing `:source`/`:receiver_llm`/`:earc_llm`/`:notifier` pattern).

## 5. Images

Send the listing's `images` (FB CDN URLs) to Gemini in a **single** call (Gemini accepts multiple inline images), capped at `vision_max_images` (default 8) since the back-panel label could be in any photo. Each image is downloaded with a browser `user-agent` (confirmed: FB CDN returns 200 to that). flash-lite makes one multi-image call ≈ $0.001 — negligible, and only on unconfirmed receivers.

## 6. Result handling & errors

- **Model recovered** → the recovered `{brand, model}` flows into the existing `Earc.resolve_with_fallback/3` (yielding a real verdict instead of "unknown") and `Listings.update_listing` sets `model_id` + `earc_verdict` (no new pipeline code — it reuses `DailyScan.enrich/2`).
- **Nothing found, or any error** (image download fails, Gemini error/timeout, unparseable response) → degrade gracefully to the current "unconfirmed" behavior. The vision step must **never crash** the pipeline (consistent with the worker's best-effort error handling; `Receivers` treats a vision `{:error, _}` like "no model found").

## 7. Config & env

Add to `config :marketplace_bot, :llm` (or a `:vision` block), env-overridable per the project convention:
- `gemini_base_url` (default `https://generativelanguage.googleapis.com/v1beta`), env `GEMINI_BASE_URL`
- `gemini_vision_model` (default `gemini-2.5-flash-lite`), env `GEMINI_VISION_MODEL`
- `vision_max_images` (default `8`) — config-only (`config :marketplace_bot, :llm, vision_max_images`), NOT env-overridable: the image cap is set once, not a runtime cutover knob like the endpoint/model
- Secret: `GEMINI_API_KEY` (sent as `x-goog-api-key` header).
- Swappable impl: `config :marketplace_bot, vision: MarketplaceBot.Vision.Gemini` (test → a stub).

## 8. Testing

- **`Vision.Gemini.extract_model`** with a single `Req.Test` stub branched by host/path — image download (`fbcdn`/any) vs Gemini `generateContent` (`generativelanguage`) — asserting it base64-inlines and parses `{brand, model}` from a stubbed Gemini JSON response; and that a Gemini error / bad body returns `{:error, _}` (not a crash).
- **`Receivers`**: a receiver-with-no-model triggers the (injected fake) vision step and returns the recovered model; a regex hit (model present) does **not** call vision; a non-receiver does **not** call vision.
- **`DailyScan` integration**: a listing classified as receiver-with-no-model + a fake vision returning a model ends up persisted with that `model_id` and a resolved (non-"unknown") `earc_verdict`; a fake vision returning nothing leaves it unconfirmed.

## 9. Out of scope (deferred)

- Backfill of existing unconfirmed listings already in the DB.
- On-demand "check photos" UI button (may ride along with the UI-improvements feature).
- Vision-based *re-classification* (deciding is_av_receiver from photos) — this feature only recovers a model for already-classified receivers.
