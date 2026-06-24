# marketplace-bot

A personal, single-user tool that once a day scans **Facebook Marketplace** for home-theater **A/V receivers**, decides which listings likely support **eARC**, and sends a **Telegram digest of new matches** — with a Phoenix LiveView UI to browse and curate them. Elixir/Phoenix + SQLite.

## Pipeline

```
Apify actor (Marketplace search URLs) → raw listings
  → dedup by id (only new)
    → classify + extract make/model  (negative-keyword prefilter → regex → DeepSeek)
      → eARC resolver  (curated table → Kagi FastGPT + DeepSeek research, cached;
                         Gemini vision reads the model number off photos when the text has none)
        → keep eARC matches → daily Telegram digest
```

The LiveView UI lets you browse listings, view photos, correct the eARC verdict / override the model, and set a status (interested / contacted / dismissed).

## Stack & design notes

- **Elixir / Phoenix 1.8 + LiveView**, **SQLite** (`ecto_sqlite3`), **Oban** (daily cron), `Req` for all HTTP.
- **Data source is the Apify actor** [`calm_builder/facebook-marketplace-scraper`](https://apify.com/calm_builder/facebook-marketplace-scraper), not a self-hosted scraper — kept behind a swappable `Source` interface.
- **eARC is data-driven**: a user-correctable table of `model → yes/no/unknown`, with cached LLM/web-research fallback. Unknowns are still surfaced, tagged "eARC unconfirmed."
- Providers: **DeepSeek** (classify/extract + eARC verdict), **Kagi FastGPT** (eARC web research), **Google Gemini** (vision model-extraction from photos).

## Setup

1. `cp .env.example .env` and fill in the tokens (Apify, Telegram, DeepSeek, Kagi, Gemini).
2. `mix setup` — installs deps, creates + migrates the SQLite DB, seeds the eARC table.
3. `mix phx.server` — then visit http://localhost:4010.

## Daily scan

Runs automatically via Oban cron (13:00 UTC). Run it manually with:

```
mix run -e 'MarketplaceBot.Jobs.DailyScan.run([])'
```

## Configuration

- **Search** (locations, brands, price ceiling, distance reference): `config :marketplace_bot, :search` in `config/config.exs`.
- **Providers / models**: `config :marketplace_bot, :llm` — endpoints and models are environment-overridable.
- All secrets live in `.env` (gitignored); see `.env.example`.

## Tests

```
mix test
```
