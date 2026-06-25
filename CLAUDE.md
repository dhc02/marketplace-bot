# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status: implemented (Elixir / Phoenix + LiveView)

The app is built and tested (branch `feature/marketplace-bot`). The authoritative design is `docs/superpowers/specs/2026-06-24-marketplace-bot-design.md` and the implementation plan is `docs/superpowers/plans/2026-06-24-marketplace-bot.md`. See the **Run / deploy** section below for how to run it and the pending first-live-run verification. `PLAN.md` is the original handoff (historical).

## What this is

Personal, single-user tool. Once a day, unattended: scan **Facebook Marketplace** for home-theater AV receivers, decide which listings have **eARC**, and send a **Telegram digest of new matches**.

## Pipeline

```
Apify run(search URLs) → raw listings
  → dedup by `id` against local store (only NEW)
    → extract make/model from title+description
      → eARC resolver (model → yes/no/unknown)
        → keep eARC matches → daily Telegram digest
  (all seen ids written back to the store)
```

## Architecture constraints (the non-obvious ones)

- **Data source = the Apify actor `calm_builder/facebook-marketplace-scraper`, NOT a self-hosted scraper.** Do not write a Playwright/Selenium scraper — it's fragile and risks an FB ban. Apify accesses Marketplace server-side. Input is full Marketplace **search URLs** (location/query/filters baked into the URL) plus `maxListings`, `fetchDetails: true`, `getNewItems: true`.
- **The actor must sit behind a swappable `Source` interface** (`fetch() -> list[Listing]`). It's a small single-author third-party actor that could go dark; the rest of the pipeline must not depend on its specifics. Normalize its output to an internal `Listing` shape.
- **"New" = listing `id` not previously seen**, tracked in a local SQLite store — more robust than trusting `creation_time`. The store also holds the model, eARC verdict, and notified flag to avoid re-alerting.
- **eARC resolver is data-driven, not hardcoded from memory.** It's a user-correctable table (YAML/JSON) of `model → yes/no/unknown`, with an LLM fallback for unknowns whose results get cached back into the table. eARC support is a function of model/model-year (~2019+). **Verify specs — do not trust the LLM's or your own recall.** Treat anything not in the table as `unknown` and (per current lean) still include it in the digest tagged "eARC unconfirmed" so good listings aren't silently dropped.

## Suggested build order

Per `PLAN.md` §4: scaffold + `.env` + `Source` interface → **Fetcher first** (validate the real actor JSON shape before building downstream) → SQLite store + dedup → model extractor → eARC resolver (curated table first, LLM fallback later) → Telegram notifier wired into a single `run-once` entrypoint → daily schedule + deploy.

## Secrets & config

- Secrets live in `.env` (gitignored — **never commit, never rsync to servers**). See `.env.example`: `APIFY_TOKEN`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `DEEPSEEK_API_KEY` (classify/extract = `deepseek-v4-flash`, eARC verdict = `deepseek-v4-pro`), `KAGI_V0_API_KEY` (FastGPT `/api/v0` web research for eARC; the v1 `KAGI_API_KEY` is kept for future v1 endpoints). Endpoint/token overridable via `KAGI_FASTGPT_URL` / `KAGI_TOKEN`.
- 1Password (your vault, `op` CLI) is available for storing/fetching these. On unraid, prod `.env` lives at `/mnt/user/appdata/marketplace-bot/.env` and is edited there only.

## Deploy

No `deploy.sh` exists yet (deploy target is an open decision). When the user picks a target, follow the global CLAUDE.md conventions — if unraid Docker: bind mounts only under `/mnt/user/appdata/marketplace-bot/`, Compose Manager, a `deploy.sh` following one of the reference patterns, and document the port/domain here.

## Exposing a web surface

There is no public web surface today — the bot only fetches and pushes a Telegram digest. If you add a web UI later, bind it to a local port and put it behind your own authenticating proxy / access control; never expose it unauthenticated.

## Run / deploy

- **Runs as a systemd service on the VM** (chosen over unraid). Unit `/etc/systemd/system/marketplace-bot.service` (repo copy: `deploy/marketplace-bot.service`), launched by `scripts/start.sh` (resolves the asdf toolchain from `.tool-versions`, loads `.env`, migrates, runs `mix phx.server` in dev mode). **Auto-starts on boot** (`WantedBy=multi-user.target`) and **restarts on crash** (`Restart=always`). Binds `0.0.0.0:4010` (LAN: http://<host-ip>:4010). Manage: `sudo systemctl {status,restart,stop} marketplace-bot`; logs: `journalctl -u marketplace-bot -f`. (Dev mode is intentional — `check_origin: false` lets LiveView work behind the tunnel; a prod OTP release is a possible future hardening.)
- **Local dev (alternative):** `sudo systemctl stop marketplace-bot` first (it holds port 4010), then `set -a; source .env; set +a; mix phx.server`.
- **Scheduled scan:** runs automatically via the service's Oban cron **twice daily** — `{"0 13 * * *", ...}` and `{"0 23 * * *", MarketplaceBot.Jobs.DailyScan}` (13:00 & 23:00 UTC ≈ 8am & 6pm Central). Manual run: `mix run -e 'MarketplaceBot.Jobs.DailyScan.run([])'` (note: `mix run` does not bind the port, so it coexists with the service).
- **Required env (.env):** `APIFY_TOKEN`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `DEEPSEEK_API_KEY`, `KAGI_V0_API_KEY` (FastGPT `/api/v0`), `KAGI_API_KEY` (v1, unused by FastGPT).
- **LLM/research providers:** classify/extract = `deepseek-v4-flash`; eARC verdict = `deepseek-v4-pro`; eARC research = Kagi FastGPT (`/api/v0`, v0 token). Endpoint/token env-overridable (`KAGI_FASTGPT_URL`, `KAGI_TOKEN`) for a zero-code v0→v1 cutover. Defaults in `config :marketplace_bot, :llm`. Vision (photo model-extraction for unconfirmed receivers) = Gemini gemini-2.5-flash-lite (GEMINI_API_KEY; GEMINI_VISION_MODEL / GEMINI_BASE_URL overridable); runs in the pipeline only when a receiver has no model parsed from text.
- **Search:** brand-targeted, multi-location FB Marketplace queries — `config :marketplace_bot, :search` (`location_ids`, `brands`, `extra_queries`, `max_price`, `reference` = El Campo for distance scoring). Live-verified: Apify `run-sync` returns **HTTP 201**; `Sources.Apify.normalize/1` matches the real JSON. (Add Houston/Victoria FB location IDs to `location_ids` for distinct regional searches.)
- **Public access:** Cloudflare Tunnel + Zero Trust at `marketplace-bot.example.com` → `<host-ip>:4010` (this VM), restricted to the owner. **Wired by your ops process, not by this app.**

## References

- Actor: https://apify.com/calm_builder/facebook-marketplace-scraper
- Apify Python client: https://docs.apify.com/api/client/python/
- Telegram Bot API: https://core.telegram.org/bots/api
