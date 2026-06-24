# marketplace-bot — design spec

**Date:** 2026-06-24
**Status:** approved design, pre-implementation
**Supersedes the language/runtime leanings in `PLAN.md`.** `PLAN.md` remains the reference for domain logic (the Apify actor, the pipeline shape, eARC notes). This spec is authoritative where the two differ.

## 1. Purpose

Personal, single-user tool. Once a day, unattended: scan **Facebook Marketplace** for home-theater AV receivers within ~60 mi of Ganado, TX, determine which have **eARC**, and surface new matches two ways:

1. a **daily Telegram digest** of new eARC matches, and
2. a **browsable web app** (Phoenix LiveView) to click through listings, view all photos and details, and curate (correct eARC verdicts, override parsed models, set per-listing status).

## 2. Resolved decisions

| Decision | Choice |
| --- | --- |
| Language / framework | **Elixir, Phoenix 1.7 + LiveView** |
| Datastore | **SQLite** via `ecto_sqlite3` (single file on a bind mount) |
| Scheduler | **Oban cron** (in-app; no host cron) |
| eARC resolution | **Hybrid** — curated table is source of truth; on a miss, Kagi FastGPT researches the model and `deepseek-v4-pro` produces the verdict, cached back |
| Delivery | **Both** — Telegram daily digest *and* the web app |
| Web app scope (v1) | **Browse + curate** (not a full control panel) |
| Runtime | **VM now** (`mix phx.server`), **unraid Docker later** |
| HTTP client | **`Req`** for Apify, Telegram, DeepSeek, and Kagi |
| LLM / research | **DeepSeek** (OpenAI-compatible): `deepseek-v4-flash` for classify/extract, `deepseek-v4-pro` for the eARC verdict; **Kagi FastGPT** for eARC web research |

## 3. Search scope

- **Search URL:** `https://www.facebook.com/marketplace/113243215352508/search?query=receiver&exact=false&maxPrice=500`
  - location `113243215352508` = Ganado, TX area; query `receiver`; `exact=false`; price ceiling **$500** via `maxPrice=500`.
- **Brands:** no whitelist — consider all brands. This makes classification (is it even an AV receiver?) a first-class pipeline step (§6).
- **Listings per run (`maxListings`, actor range 1–1000):** config-driven, with a separate **initial-probe** value (pull large, up to 1000, to discover real volume) and a **daily** value (set generously above the real daily-new rate after the probe; dedup makes over-pulling cheap).
- **Unknown-eARC handling:** still surface the listing, **tagged "eARC unconfirmed"** — never silently dropped.
- **No price floor** in v1.

### Open items verified by running, not guessing

- **Radius:** the 60 mi radius is *not* encoded in the URL (FB stores it per-session). Confirm the actual geographic coverage the actor returns on the first run; append params or adjust if off.
- **Volume:** first run probes real listing counts → informs the steady-state daily `maxListings`.

## 4. Architecture overview

A single Phoenix app / OS process serves the web UI **and** runs the daily pipeline as an Oban cron job. SQLite file lives in a data dir (bind-mounted on unraid). All external I/O via `Req`.

## 5. Data flow (one daily run)

```
Oban cron → DailyScan job
  Source.fetch()  →  raw listings (Apify actor; search URL + maxPrice + maxListings, fetchDetails:true, getNewItems:true)
   → upsert/dedup by FB id (Listings)         ── only NEW listings continue downstream
      → negative-keyword prefilter            (drop obvious non-AV: hitch, trailer, satellite, directv, dish, gps…)
        → Classifier + Extractor              (regex fast-path → LLM fallback: is_av_receiver?, brand, model)
          → eARC Resolver                     (model → :yes/:no/:unknown; table → LLM fallback, cached back)
            → keep :yes + :unknown(tagged)    → Telegram digest (each links to its web detail page)
  → write a Run row (counts, errors)
```

All expensive work (classify/extract/eARC LLM calls) runs **only on new, deduped listings**, and results are cached, so steady-state cost stays low even at high pull volume.

## 6. Contexts & modules

- **`MarketplaceBot.Listings`** — core domain: upsert/dedup by `fb_id`, UI queries, status updates.
- **`MarketplaceBot.Sources`** — `Source` behaviour: `fetch(opts) :: {:ok, [listing_map]} | {:error, term}`.
  - **`Sources.Apify`** — calls Apify `run-sync-get-dataset-items`, passes the search URL + options, normalizes the actor's JSON → internal listing map. This is the swappable-actor seam (`PLAN.md` requirement: drop in another Marketplace actor without touching the rest of the pipeline).
  - **`Sources.Fake`** — returns captured-JSON fixtures for tests; no network.
- **`MarketplaceBot.Receivers`** — classification + model extraction (below).
- **`MarketplaceBot.Earc`** — resolver + LLM fallback (§8).
- **`MarketplaceBot.Notifier.Telegram`** — builds & sends the digest.
- **`MarketplaceBot.Jobs.DailyScan`** — the Oban worker wiring the pipeline together.

## 7. Classification + model extraction

Cheapest-first, to keep LLM volume down on a noisy broad query:

1. **Negative-keyword prefilter** (free): drop titles clearly not AV — `hitch`, `trailer`, `satellite`, `directv`, `dish`, `gps`, etc. (list grows from real data).
2. **Regex fast-path** (free): known AV model patterns — Denon `AVR-X####`, Marantz `SR/NR####` & `Cinema ##`, Yamaha `RX-V###`/`RX-A###`, Onkyo `TX-NR###`/`TX-RZ##`, Pioneer `VSX-####`, Sony `STR-DH###`/`STR-AN####`, plus Anthem/NAD/Integra/Arcam. A match ⇒ it's an AV receiver *and* yields brand + model — no LLM needed.
3. **LLM fallback** (DeepSeek `deepseek-v4-flash`, JSON mode, cached per listing): for the ambiguous remainder, one call returns `{is_av_receiver: bool, brand, model}`. Non-receivers are dropped.

## 8. eARC resolver (hybrid)

`model → :yes | :no | :unknown`.

- A **`models`** table is the source of truth: `brand`, normalized `model` key, `verdict`, `source` (`:seed | :llm | :user`), `notes`.
- Seeded from a **verified** list in `priv/repo/seeds` (verify entries before trusting; eARC arrived ~2019 and became standard in HDMI-2.1 lineups 2020+).
- Unknown models → **Kagi FastGPT** researches the model, then **`deepseek-v4-pro`** turns the research into a verdict; result caches back as `source: :llm`.
- A user correction in the web UI overwrites as `source: :user` — authoritative, never auto-overwritten by a later LLM pass.
- `:unknown` verdicts still surface in the digest and UI, tagged "eARC unconfirmed."

## 9. Data model (SQLite / Ecto)

- **`listings`** — `fb_id` (unique), `url`, `title`, `price_cents`, `currency`, `description`, `city`, `state`, `lat`, `lng`, `images` (JSON array of URLs), `seller`, `condition`, `fb_created_at`, `is_live`/`is_sold`/`is_pending`, `first_seen_at`, `model_id` (fk, nullable), `earc_verdict` (cached snapshot), `status` (`new | interested | dismissed | contacted`), `notified_at`.
- **`models`** — the eARC table (§8).
- **`runs`** — `started_at`, `finished_at`, `fetched`, `new`, `matched`, `errors` (JSON). Feeds a small run-history view + observability.

## 10. Web UI (LiveView)

- **Index** — responsive grid of matches: thumbnail, price, city, model, eARC badge (yes / unconfirmed). Filters by verdict + status; hides `dismissed` by default.
- **Show** — photo gallery (all `images`), full description, price, location, seller, **outbound link to the FB listing**, model + eARC verdict with **inline correction** (writes `models` as `:user`, re-resolves), **model override** (re-runs extraction), and status buttons (interested / dismissed / contacted).
- **Photos:** render FB CDN image URLs directly. They may expire over time — acceptable for active listings; local image caching is deferred.
- **Auth:** none in-app for v1. The app binds to a local port; Cloudflare Access (provisioned by your ops process) enforces "the owner only" when exposed. **Claude Code does not wire the tunnel / DNS / Access** — per project `CLAUDE.md`, build to a local port and hand your ops process the host:port + desired hostname.

## 11. Config & secrets

- `.env` → `runtime.exs`: `APIFY_TOKEN`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `DEEPSEEK_API_KEY`, `KAGI_API_KEY`.
- Non-secret app config: search URL(s), `maxListings` (separate **initial-probe** vs **daily** values), `maxPrice`, LLM model ids (`deepseek-v4-flash`, `deepseek-v4-pro`), DeepSeek base URL, Kagi FastGPT URL.
- Search config lives in config for v1; moving it into an editable UI is the deferred "full control panel."

## 12. Testing

ExUnit. `Sources.Fake` + captured Apify JSON fixtures drive end-to-end pipeline tests with no network. Unit tests for: the regex extractor (real-world titles including non-AV decoys like hitch/satellite receivers), the eARC resolver (with a fake LLM), and LiveView tests for index/show + the curate actions (verdict correction, model override, status changes).

## 13. Deploy

- **VM now:** `mix phx.server`; Oban cron fires the daily scan.
- **unraid later:** release Dockerfile; SQLite file + `.env` on bind mounts under `/mnt/user/appdata/marketplace-bot/`; Compose Manager (`net.unraid.docker.managed: composeman`); a `deploy.sh` following a reference pattern; a chosen local port documented in `CLAUDE.md`. Then hand your ops process the host:port + desired hostname (`marketplace-bot.example.com`) for the tunnel + Zero Trust Access.

## 14. Deferred (not v1)

- Full control panel (edit search URLs / filters / price / `maxListings` and trigger on-demand runs from the UI).
- Local image caching.
- Vision-model back-panel model reading when the title has no model.
- Multi-region / multi-URL search management.

## 15. Suggested build order

1. Phoenix app scaffold (`ecto_sqlite3`, Oban, Req), `.env` → `runtime.exs`, the `Source` behaviour + `Sources.Fake`.
2. **`Sources.Apify` first** — get real listings from the search URL; capture the actual JSON, confirm `description`/`creation_time`/`images` populate with `fetchDetails:true`; use this run as the volume + radius probe.
3. `Listings` context: schema, migration, upsert/dedup by `fb_id`.
4. `Receivers` (prefilter → regex → LLM) and `Earc` resolver (seed table first, LLM fallback after).
5. `Notifier.Telegram`; wire the full `DailyScan` Oban worker end-to-end.
6. LiveView index + show + curate actions.
7. Schedule daily (Oban cron) and tune `maxListings` / radius from the probe results.
8. Dockerfile + `deploy.sh` for unraid when ready; hand off to your ops process for the public route.
