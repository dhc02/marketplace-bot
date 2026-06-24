# Vision Model-Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a listing is classified as an AV receiver but no model was parsed from text, read its photos with Gemini to recover the brand/model, then let the existing eARC resolver produce a real verdict.

**Architecture:** A new `MarketplaceBot.Vision` behaviour + `MarketplaceBot.Vision.Gemini` impl (downloads photos, base64-inlines them into one Gemini `generateContent` call, parses `{brand, model}`). It plugs into `MarketplaceBot.Receivers` as the final rung of the extract chain — invoked **only** when the DeepSeek text-classify path returns a receiver with a blank/nil model. `DailyScan.enrich/2` is unchanged: it already resolves eARC + sets `model_id` from whatever `Receivers.classify_extract/2` returns.

**Tech Stack:** Elixir, Req (HTTP, with `Req.Test` seam), Google Gemini `generateContent` (native API, `inline_data` base64, `response_mime_type: application/json`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-06-24-vision-model-extraction-design.md` (authoritative).
- Provider: Gemini `gemini-2.5-flash-lite` via `POST {base}/models/{model}:generateContent`, auth header `x-goog-api-key: $GEMINI_API_KEY`. (DeepSeek API is text-only — confirmed by live test; do NOT route vision through DeepSeek.)
- `MarketplaceBot.Vision` behaviour: `@callback extract_model(image_urls :: [String.t()], opts :: keyword()) :: {:ok, %{brand: String.t() | nil, model: String.t() | nil}} | {:error, term()}`.
- Vision runs ONLY on a confirmed receiver with no parsed model (regex hit → no vision; non-receiver → no vision). It is model-recovery, not re-classification.
- Must NEVER crash the pipeline: a vision `{:error, _}`, no images, or unparseable response degrades to "no model found" (listing stays unconfirmed).
- HTTP test seam: every `Req` call merges `opts[:req_options]` so tests route through `Req.Test`. Swappable impl via config key `:vision` (test overrides with a stub) — same pattern as `:source`/`:receiver_llm`/`:earc_llm`/`:notifier`.
- Config/env (env overrides win): `gemini_base_url` (`GEMINI_BASE_URL`, default `https://generativelanguage.googleapis.com/v1beta`), `gemini_vision_model` (`GEMINI_VISION_MODEL`, default `gemini-2.5-flash-lite`), `vision_max_images` (default `8`). Secret: `GEMINI_API_KEY` (already in `.env`).
- All Repo-touching test modules use `async: false`.

---

### Task 1: Vision behaviour + Gemini client + config + stub

**Files:**
- Create: `lib/marketplace_bot/vision.ex` (behaviour)
- Create: `lib/marketplace_bot/vision/gemini.ex` (impl)
- Modify: `config/config.exs` (add `:llm` gemini keys + `vision:` swappable impl)
- Modify: `config/test.exs` (add `vision: MarketplaceBot.Vision.Stub`)
- Modify: `test/support/stubs.ex` (add `MarketplaceBot.Vision.Stub`)
- Test: `test/marketplace_bot/vision/gemini_test.exs`

**Interfaces:**
- Produces: `MarketplaceBot.Vision` behaviour (`extract_model/2`); `MarketplaceBot.Vision.Gemini.extract_model(image_urls, opts) :: {:ok, %{brand: ..., model: ...}} | {:error, term()}`.

- [ ] **Step 1: Add config**

In `config/config.exs`, extend the existing `config :marketplace_bot, :llm` block with three keys (keep the existing keys):

```elixir
  gemini_base_url: "https://generativelanguage.googleapis.com/v1beta",
  gemini_vision_model: "gemini-2.5-flash-lite",
  vision_max_images: 8
```

In the existing swappable-impls block (`config :marketplace_bot, source: ..., notifier: ..., web_base_url: ...`), add:

```elixir
  vision: MarketplaceBot.Vision.Gemini,
```

In `config/test.exs`, in the existing override block (`config :marketplace_bot, source: ..., notifier: ...`), add:

```elixir
  vision: MarketplaceBot.Vision.Stub,
```

- [ ] **Step 2: Write the failing test**

Create `test/marketplace_bot/vision/gemini_test.exs`:

```elixir
defmodule MarketplaceBot.Vision.GeminiTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.Vision.Gemini

  # One Req.Test stub serves BOTH the image download (fbcdn host) and the
  # Gemini call (generativelanguage host), branched on conn.host.
  defp stub(gemini_text) do
    Req.Test.stub(MarketplaceBot.Vision.Gemini, fn conn ->
      if conn.host =~ "generativelanguage" do
        Req.Test.json(conn, %{
          "candidates" => [%{"content" => %{"parts" => [%{"text" => gemini_text}]}}]
        })
      else
        Req.Test.text(conn, "FAKE-IMAGE-BYTES")
      end
    end)
  end

  test "downloads photos and parses brand/model from Gemini" do
    stub(~s({"brand": "Marantz", "model": "SR6004"}))

    assert {:ok, %{brand: "Marantz", model: "SR6004"}} =
             Gemini.extract_model(["https://scontent.fbcdn.net/x.jpg"],
               api_key: "k",
               req_options: [plug: {Req.Test, MarketplaceBot.Vision.Gemini}]
             )
  end

  test "returns {:error, :no_images} for an empty image list" do
    assert {:error, :no_images} =
             Gemini.extract_model([], req_options: [plug: {Req.Test, MarketplaceBot.Vision.Gemini}])
  end

  test "returns {:error, _} on a Gemini error (no crash)" do
    Req.Test.stub(MarketplaceBot.Vision.Gemini, fn conn ->
      if conn.host =~ "generativelanguage" do
        conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "rate"})
      else
        Req.Test.text(conn, "FAKE-IMAGE-BYTES")
      end
    end)

    assert {:error, _} =
             Gemini.extract_model(["https://scontent.fbcdn.net/x.jpg"],
               api_key: "k",
               req_options: [plug: {Req.Test, MarketplaceBot.Vision.Gemini}]
             )
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mix test test/marketplace_bot/vision/gemini_test.exs`
Expected: FAIL — `Vision.Gemini` undefined.

- [ ] **Step 4: Implement the behaviour**

Create `lib/marketplace_bot/vision.ex`:

```elixir
defmodule MarketplaceBot.Vision do
  @moduledoc "Behaviour: extract a receiver's brand/model from listing photos."
  @callback extract_model(image_urls :: [String.t()], opts :: keyword()) ::
              {:ok, %{brand: String.t() | nil, model: String.t() | nil}} | {:error, term()}
end
```

- [ ] **Step 5: Implement the Gemini client**

Create `lib/marketplace_bot/vision/gemini.ex`:

```elixir
defmodule MarketplaceBot.Vision.Gemini do
  @moduledoc """
  Reads a receiver's brand/model from listing photos using Gemini generateContent.
  Downloads each image, base64-inlines them into one multi-image request, and
  parses a JSON {brand, model}. Endpoint/model are env-overridable.
  """
  @behaviour MarketplaceBot.Vision

  @prompt "These are photos from a Facebook Marketplace listing of a home-theater A/V receiver. " <>
            "Read any brand and model number/name printed on the unit (front fascia or rear panel). " <>
            ~s(Respond with ONLY a JSON object: {"brand": string or null, "model": string or null}.)

  @impl true
  def extract_model(image_urls, opts \\ []) do
    cfg = Application.get_env(:marketplace_bot, :llm, [])
    api_key = opts[:api_key] || System.get_env("GEMINI_API_KEY")

    base =
      opts[:base_url] || System.get_env("GEMINI_BASE_URL") || cfg[:gemini_base_url] ||
        "https://generativelanguage.googleapis.com/v1beta"

    model =
      opts[:model] || System.get_env("GEMINI_VISION_MODEL") || cfg[:gemini_vision_model] ||
        "gemini-2.5-flash-lite"

    max_images = opts[:max_images] || cfg[:vision_max_images] || 8

    image_parts =
      image_urls
      |> Enum.take(max_images)
      |> Enum.map(&download_inline(&1, opts))
      |> Enum.reject(&is_nil/1)

    if image_parts == [] do
      {:error, :no_images}
    else
      body = %{
        contents: [%{parts: [%{text: @prompt} | image_parts]}],
        generationConfig: %{response_mime_type: "application/json"}
      }

      req_opts =
        [
          method: :post,
          url: "#{base}/models/#{model}:generateContent",
          headers: [{"x-goog-api-key", api_key}],
          json: body,
          receive_timeout: opts[:receive_timeout] || 120_000
        ]
        |> Keyword.merge(opts[:req_options] || [])

      with {:ok, %{status: 200, body: resp}} <- Req.request(req_opts),
           text when is_binary(text) <- first_text(resp),
           {:ok, parsed} <- Jason.decode(text) do
        {:ok, %{brand: parsed["brand"], model: parsed["model"]}}
      else
        {:ok, %{status: status, body: body}} -> {:error, {:gemini_http, status, body}}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  end

  defp download_inline(url, opts) do
    dl_opts =
      [method: :get, url: url, headers: [{"user-agent", "Mozilla/5.0"}], receive_timeout: 30_000]
      |> Keyword.merge(opts[:req_options] || [])

    case Req.request(dl_opts) do
      {:ok, %{status: 200, body: bin}} when is_binary(bin) ->
        %{inline_data: %{mime_type: "image/jpeg", data: Base.encode64(bin)}}

      _ ->
        nil
    end
  end

  defp first_text(%{"candidates" => [%{"content" => %{"parts" => [%{"text" => t} | _]}} | _]})
       when is_binary(t),
       do: t

  defp first_text(_), do: nil
end
```

- [ ] **Step 6: Add the test stub referenced by `config/test.exs`**

Append to `test/support/stubs.ex`:

```elixir
defmodule MarketplaceBot.Vision.Stub do
  @behaviour MarketplaceBot.Vision
  @impl true
  def extract_model(_image_urls, _opts \\ []), do: {:ok, %{brand: nil, model: nil}}
end
```

- [ ] **Step 7: Run to verify it passes**

Run: `mix test test/marketplace_bot/vision/gemini_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add Vision behaviour + Gemini client (photo model-extraction)"
```

---

### Task 2: Wire the vision recovery step into Receivers

**Files:**
- Modify: `lib/marketplace_bot/receivers.ex`
- Test: `test/marketplace_bot/receivers_test.exs` (extend)

**Interfaces:**
- Consumes: `MarketplaceBot.Vision` behaviour (`extract_model/2`); existing `Receivers.LLM.Behaviour`.
- Produces: `Receivers.classify_extract/2` now recovers a model via the configured `:vision` impl when the LLM path returns a receiver with a blank/nil model.

- [ ] **Step 1: Write the failing tests**

Append to `test/marketplace_bot/receivers_test.exs` (inside the module):

```elixir
  defmodule AvNoModelLLM do
    @behaviour MarketplaceBot.Receivers.LLM.Behaviour
    @impl true
    def classify_extract(_l, _o \\ []), do: {:ok, %{is_av_receiver: true, brand: "Marantz", model: nil}}
  end

  defmodule FoundVision do
    @behaviour MarketplaceBot.Vision
    @impl true
    def extract_model(_imgs, _o \\ []), do: {:ok, %{brand: "Marantz", model: "SR6004"}}
  end

  defmodule EmptyVision do
    @behaviour MarketplaceBot.Vision
    @impl true
    def extract_model(_imgs, _o \\ []), do: {:ok, %{brand: nil, model: nil}}
  end

  defmodule RaiseVision do
    @behaviour MarketplaceBot.Vision
    @impl true
    def extract_model(_imgs, _o \\ []), do: raise("vision should not be called")
  end

  test "receiver with no parsed model recovers the model via vision" do
    assert {:ok, "Marantz", "SR6004"} =
             Receivers.classify_extract(
               %{title: "marantz home theater receiver", images: ["u"]},
               llm: AvNoModelLLM, vision: FoundVision
             )
  end

  test "stays unconfirmed (model nil) when vision finds nothing" do
    assert {:ok, "Marantz", nil} =
             Receivers.classify_extract(
               %{title: "marantz home theater receiver", images: ["u"]},
               llm: AvNoModelLLM, vision: EmptyVision
             )
  end

  test "vision is NOT called when regex already found a model" do
    assert {:ok, "Denon", "AVR-X3700H"} =
             Receivers.classify_extract(
               %{title: "Denon AVR-X3700H", images: ["u"]},
               llm: AvNoModelLLM, vision: RaiseVision
             )
  end

  test "vision is NOT called for a non-receiver" do
    assert :skip =
             Receivers.classify_extract(
               %{title: "trailer hitch receiver", images: ["u"]},
               llm: AvNoModelLLM, vision: RaiseVision
             )
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/marketplace_bot/receivers_test.exs`
Expected: FAIL — the "recovers the model via vision" test returns `{:ok, "Marantz", nil}` (no vision wired yet), and `RaiseVision`-based tests may pass already but the recovery test fails.

- [ ] **Step 3: Wire vision into the LLM path**

In `lib/marketplace_bot/receivers.ex`, replace the `via_llm/2` function with the version below and add the `recover_via_vision/3` + `blank?/1` helpers. (The `via_llm` head shape — reading `opts[:receiver_llm] || opts[:llm] || config` — is preserved; only the receiver-with-blank-model branch changes.)

```elixir
  defp via_llm(listing, opts) do
    llm = opts[:receiver_llm] || opts[:llm] || Application.get_env(:marketplace_bot, :receiver_llm)

    case llm.classify_extract(as_map(listing), opts) do
      {:ok, %{is_av_receiver: true, brand: brand, model: model}} ->
        if blank?(model), do: recover_via_vision(listing, brand, opts), else: {:ok, brand, model}

      _ ->
        :skip
    end
  end

  # Receiver confirmed but no model parsed from text — try reading the photos.
  defp recover_via_vision(listing, brand, opts) do
    vision = opts[:vision] || Application.get_env(:marketplace_bot, :vision)
    images = field(listing, :images) || []

    if vision && images != [] do
      case vision.extract_model(images, opts) do
        {:ok, %{model: m} = r} when is_binary(m) and m != "" -> {:ok, r[:brand] || brand, m}
        _ -> {:ok, brand, nil}
      end
    else
      {:ok, brand, nil}
    end
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: true
```

(If the current `via_llm/2` differs in detail, keep its existing `llm` resolution and `as_map`/`field` helpers — only the `{:ok, %{is_av_receiver: true, ...}}` arm needs the `blank?`/`recover_via_vision` behavior. `field/2` and `as_map/1` already exist in this module.)

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/marketplace_bot/receivers_test.exs`
Expected: PASS (all, including the 4 new tests).

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: PASS (no regressions; the test-config `Vision.Stub` returns nil model, so existing pipeline tests are unaffected).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Receivers: recover model from photos via vision when text yields none"
```

---

### Task 3: End-to-end pipeline test + docs

**Files:**
- Test: `test/marketplace_bot/jobs/daily_scan_test.exs` (extend)
- Modify: `.env.example`, `CLAUDE.md`

**Interfaces:**
- Consumes: `DailyScan.run/1` (existing), `Receivers` vision recovery (Task 2). No production code change to `DailyScan` — `enrich/2` already resolves eARC + sets `model_id` from `classify_extract/2`'s result.

- [ ] **Step 1: Write the failing integration test**

Append to `test/marketplace_bot/jobs/daily_scan_test.exs` (inside the module; it already defines `YesLLM` and `CapNotifier`):

```elixir
  defmodule AvNoModelLLM do
    @behaviour MarketplaceBot.Receivers.LLM.Behaviour
    @impl true
    def classify_extract(_l, _o \\ []), do: {:ok, %{is_av_receiver: true, brand: "Marantz", model: nil}}
  end

  defmodule FoundVision do
    @behaviour MarketplaceBot.Vision
    @impl true
    def extract_model(_imgs, _o \\ []), do: {:ok, %{brand: "Marantz", model: "SR6004"}}
  end

  test "recovers model via vision for a receiver with no parsed model, then resolves eARC" do
    listings = [
      %{fb_id: "vis1", title: "marantz home theater receiver", url: "u", images: ["http://img/1.jpg"]}
    ]

    opts = [
      source: MarketplaceBot.Sources.Fake,
      source_opts: [listings: listings],
      receiver_llm: AvNoModelLLM,
      vision: FoundVision,
      earc_llm: YesLLM,
      notifier: CapNotifier
    ]

    assert {:ok, %{matched: 1}} = DailyScan.run(opts)

    l = Repo.get_by!(MarketplaceBot.Listings.Listing, fb_id: "vis1")
    assert l.is_receiver
    assert l.model_id != nil
    assert l.earc_verdict == "yes"
  end
```

- [ ] **Step 2: Run to verify it fails (then passes)**

Run: `mix test test/marketplace_bot/jobs/daily_scan_test.exs`
Expected: PASS if Task 2 is complete (vision recovery flows through `enrich/2` unchanged). If it FAILS with `model_id == nil`, confirm Task 2's `recover_via_vision` is wired and `opts[:vision]` is threaded by `DailyScan.run` into `classify_extract` (it passes `opts` through). Do NOT modify `DailyScan` production code unless a real gap is found — report it if so.

- [ ] **Step 3: Update `.env.example`**

Under the existing Kagi block, add the Gemini vision entries:

```
# Gemini — vision model-extraction for unconfirmed receivers (reads photos for a model number)
GEMINI_API_KEY=
# Optional overrides:
# GEMINI_VISION_MODEL=gemini-2.5-flash-lite
# GEMINI_BASE_URL=https://generativelanguage.googleapis.com/v1beta
```

- [ ] **Step 4: Update `CLAUDE.md`**

In the "LLM/research providers" bullet of the Run/deploy section, append:

```
Vision (photo model-extraction for unconfirmed receivers) = Gemini gemini-2.5-flash-lite (GEMINI_API_KEY; GEMINI_VISION_MODEL / GEMINI_BASE_URL overridable); runs in the pipeline only when a receiver has no model parsed from text.
```

- [ ] **Step 5: Run the full suite + compile clean**

```bash
mix compile --warnings-as-errors
mix test
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Vision: end-to-end pipeline test + document GEMINI_API_KEY"
```

---

## Live verification (after merge, needs real key + a real unconfirmed listing)

Not a task — operational. With `GEMINI_API_KEY` in `.env`, run the pipeline (or `MarketplaceBot.Vision.Gemini.extract_model(image_urls)` on a real unconfirmed receiver's `images`) and confirm Gemini reads a model and the listing's verdict resolves. The provider was already smoke-tested live (read "Marantz SR6004" from a real photo).
