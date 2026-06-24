# marketplace-bot — plan / handoff

Personal-use tool that scans **Facebook Marketplace** for home-theater AV receivers, determines
which listings have **eARC** (the key feature), and sends a **daily digest of new matching
listings**. Single user (me), runs unattended once a day.

This doc is the handoff for a fresh Claude Code instance. Read it, then **confirm the open
decisions (§6) with me before building** — they're not settled yet.

---

## 1. Key decisions already made

- **Data source: the Apify actor, NOT a self-hosted scraper.** No Facebook Developer account
  is needed (there is no public Marketplace API), and we are *not* writing our own Playwright
  scraper (too fragile, risks getting a FB account banned). Apify does the access server-side.
- **Actor:** [`calm_builder/facebook-marketplace-scraper`](https://apify.com/calm_builder/facebook-marketplace-scraper)
  - **Input:** one or more full Marketplace **search URLs** (location + query + filters already
    baked into the URL, e.g. `facebook.com/marketplace/<city>/search?query=av%20receiver&...`),
    plus `maxListings` (1–1000), `fetchDetails: true` (needed for full description),
    `getNewItems: true` (newest first).
  - **Output fields per listing:** `id, url, title, price{amount,currency,formatted},
    description, location{city,state,country,latitude,longitude}, images, videos, seller,
    category, condition, creation_time, is_live, is_sold, is_pending`. Not every field is
    always present.
  - **Pricing:** ~$0.45 / 1,000 results, pay-per-event. A daily ~100-listing run ≈ $1.35/mo;
    Apify free plan's ~$5/mo credit likely covers it entirely.
  - **Caveat:** small third-party actor (no published maintenance schedule, single author). It
    works now but could go dark. **→ Architect the data source as a swappable interface** so we
    can drop in another Marketplace actor without touching the rest of the pipeline.

## 2. Pipeline (how a daily run flows)

```
Apify run(search URLs) ──► raw listings
   └─ dedup by `id` against local store ──► only NEW listings
        └─ extract make/model from title+description
             └─ eARC resolver (model ──► yes/no/unknown)
                  └─ keep eARC=yes ──► daily Telegram digest
   (all seen ids written back to the store)
```

## 3. Components

1. **Fetcher** — calls the Apify actor via the Apify API
   (`run-sync-get-dataset-items`, or start-run + poll), passing the configured search URL(s)
   and options. Normalizes results to our internal listing shape. **Keep behind a `Source`
   interface** (`fetch() -> list[Listing]`) so the actor is swappable.
2. **Store** — SQLite (stdlib). Table of seen listings keyed by `id` (+ first_seen, model,
   earc verdict, notified flag). Drives "new" detection and avoids re-alerting. "New" = id not
   previously seen (more robust than trusting `creation_time`).
3. **Model extractor** — parse brand + model from `title`/`description`. Regex for the common
   patterns (Denon `AVR-X####`, Marantz `SR####`/`Cinema ##`, Yamaha `RX-V###`/`RX-A###`,
   Onkyo `TX-NR###`/`TX-RZ##`, Pioneer `VSX-####`, Sony `STR-DH###`/`STR-AN####`). LLM fallback
   for messy titles. Optional: vision-model pass on `images[0]` (back panel) when the title has
   no model — nice-to-have, not v1.
4. **eARC resolver** — `model -> {yes,no,unknown}`. **Data-driven** (a YAML/JSON table the user
   can correct), with an LLM fallback for unknown models whose result gets cached back into the
   table. See §5 — do NOT hardcode specs blindly.
5. **Notifier** — once-a-day digest of new eARC matches. Telegram bot recommended (already in
   use here). One message listing each match: title, price, location/city, link, optional first
   image.
6. **Scheduler** — daily cron / systemd timer / container cron, depending on §6.

## 4. Suggested build order

1. Scaffold (language per §6), `.env` handling, `Source` interface.
2. **Fetcher first** — get the actor pulling real listings from one search URL; inspect the
   actual JSON shape and confirm `description`/`creation_time` populate with `fetchDetails:true`.
   Everything downstream depends on real output, so validate it before building more.
3. SQLite store + dedup.
4. Model extractor → eARC resolver (start with the curated table only; add LLM fallback after).
5. Telegram notifier; wire end-to-end as a single `run-once` entrypoint.
6. Schedule it (daily) + deploy per §6.
7. Tune: search URL(s), price ceiling, brand filters, and grow the eARC table from real hits.

## 5. eARC lookup notes

- eARC support is essentially a function of **model / model-year**: it arrived in ~2019-era
  receivers and became standard in HDMI-2.1 lineups (2020+). Low-end models lagged.
- **Build it data-driven and verify, don't trust memory.** Seed the table by running an
  LLM-with-web-search pass over the models that actually appear in listings, and let the user
  correct entries. Cache unknowns once resolved.
- Tiny *illustrative* seed (⚠️ VERIFY before trusting — examples only, not authoritative):
  Denon AVR-X3700H / X3800H = yes; Yamaha RX-V6A / RX-A2A = yes; older pre-2019 mid/low models
  = usually no. The resolver should treat anything not in the table as `unknown` and fall back.
- Handle `unknown` deliberately: probably *include* unknowns in the digest but tag them
  "eARC unconfirmed" so nothing good is silently filtered out. Confirm preference with the user.

## 6. OPEN DECISIONS — confirm with me before building

1. **Where it runs.** Options: (a) **unraid Docker** (Compose Manager, bind-mounted data dir,
   daily cron) — best for set-and-forget, matches house conventions; (b) **this VM** (systemd
   timer / crontab) — simplest to start; (c) Cloudflare Workers (Cron Trigger + D1/KV) — possible
   but Apify polling + LLM calls are easier on a normal container, not recommended for v1.
   *Lean: start on the VM to validate, then move to unraid Docker for permanence.*
2. **eARC resolver strategy:** curated table only / LLM only / **hybrid** (table + LLM fallback,
   cached). *Lean: hybrid.*
3. **Delivery:** **Telegram bot** vs email. *Lean: Telegram (already used here).*
4. **Search scope (user input needed):** which city + radius, price ceiling, brands to include,
   how many listings/day to pull.
5. **Language:** **Python** (clean for this glue: `apify-client`, stdlib `sqlite3`, simple
   Telegram Bot API) vs Node. *Lean: Python.*

## 7. House conventions (this environment)

- Project lives at `~/projects/marketplace-bot` (this repo). Deploy targets are unraid Docker or
  Cloudflare Workers; if dockerized, follow the unraid conventions (bind mounts only under
  `/mnt/user/appdata/marketplace-bot/`, Compose Manager, `deploy.sh`). See global CLAUDE.md.
- **Secrets** (`APIFY_TOKEN`, `TELEGRAM_BOT_TOKEN`, Telegram chat id, optional LLM API key) go in
  `.env` — **never committed, never rsynced to servers**. 1Password (your vault) via the `op` CLI
  is available for storing/fetching them. On unraid, prod `.env` lives at
  `/mnt/user/appdata/marketplace-bot/.env`.
- Telegram is already in use on this machine; a bot token + your chat id is all the notifier needs.

## 8. References

- Actor: https://apify.com/calm_builder/facebook-marketplace-scraper
- Apify API client docs (Python): https://docs.apify.com/api/client/python/
- Telegram Bot API: https://core.telegram.org/bots/api
