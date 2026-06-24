# UI improvements — design spec

**Date:** 2026-06-24
**Status:** approved design, pre-implementation
**Branch:** `feature/ui-improvements`

## 1. Purpose

Make the LiveView browse/curate UI more usable and pleasant: put the curate actions first, stop images from breaking/shifting the layout, give clear feedback on actions, add status filtering, and apply a clean daisyUI styling pass. Single-user personal tool; same information architecture.

## 2. Scope (the 7 requirements)

1. Show page: move model/eARC info, override fields, and status buttons **above** the images.
2. Lazy-load images with correct-sized placeholders (no layout shift); **self-serve via cache-on-first-view** (FB CDN URLs expire).
3. Press feedback/confirmation on the curate buttons.
4. "In progress" animation for override + re-resolve.
5. Clean daisyUI styling pass (Tailwind v4 + daisyUI 5 already installed).
6. Index filters for interested / dismissed / contacted.
7. Filters as buttons, not plain links.

## 3. Design

### A. Show page reorder (#1)
Reorder `listing_live/show.html.heex` to: header (title / price / city / distance) → **curate panel** (eARC verdict + correct buttons, override-model form, status buttons) → image gallery → description → Facebook link. No logic change in `show.ex`.

### B. Image caching — cache-on-first-view, self-served (#2)
- **`MarketplaceBot.ImageCache`** — `path_and_meta(listing, index)` returns `{:ok, local_path, content_type}` or `{:error, reason}`. On a miss it downloads `Enum.at(listing.images, index)` (a URL previously stored from Apify — **not** user input, so no SSRF) via `Req`, writes it to the cache dir, parses pixel dimensions from the bytes, persists them (see schema), and returns the path. On a hit it returns the cached file without re-downloading. Download/parse failure returns `{:error, _}` (never raises).
- **Cache dir:** `data/image_cache/` (the `data/` dir is already gitignored). Files keyed `"#{fb_id}-#{index}"` with an extension from the detected type.
- **`ImageController.show/2`** at route `GET /img/:fb_id/:index` (in the browser pipeline or a minimal pipeline): looks up the listing by `fb_id`, calls `ImageCache`, and serves the bytes with the detected `content-type` and a long `cache-control`. Returns 404 for an unknown `fb_id`/out-of-range index, or when the source download fails.
- **Schema:** add `image_dims` to `listings` — a JSON column (`{:array, :map}` via the ecto_sqlite3 JSON type, or `:map` keyed by index) storing `%{"w" => w, "h" => h}` per image index. Migration `add :image_dims, :map` (nullable). Lazily populated by `ImageCache` on first fetch via `Listings.put_image_dim/3` (a focused update that merges one index's dims; concurrency-safe enough for a single user).
- **Dimension reader:** a small pure-Elixir `ImageCache.dimensions/1` parsing JPEG (SOF markers), PNG (IHDR), and WebP (VP8/VP8L/VP8X) headers — no system/library deps. Unknown format → `nil` dims (falls back to default aspect-ratio).
- **Templates:**
  - **Show gallery:** `<img src={~p"/img/#{@listing.fb_id}/#{i}"} loading="lazy" {dim_attrs}>` where `dim_attrs` injects exact `width`/`height` when known (no layout shift); otherwise the `<img>` sits in a default aspect-ratio container. `i` is the 0-based index over `@listing.images`.
  - **Index thumbnail:** first image via the cache route in a fixed aspect-ratio box (`aspect-[4/3] object-cover`), `loading="lazy"`. Uniform thumbnails by design.
  - Missing/failed image → a neutral placeholder (broken-image state styled, not a raw broken `<img>`).

### C. Button-press feedback (#3)
Status and verdict buttons: render a clear **active** state (daisyUI `btn-active` + semantic color) with a CSS `transition`; show an in-flight cue using Phoenix's `phx-click-loading` Tailwind variant (e.g., reduced opacity / `loading` spinner). The post-event re-render's active highlight is the confirmation. No new server events.

### D. Override "in progress" animation (#4)
The override-model form's submit button gets `phx-disable-with="Re-resolving…"` (disables + relabels) and a spinner via the `phx-submit-loading` variant. `override_model` already calls `Earc.resolve_with_fallback` (Kagi/DeepSeek — can be slow), so the disabled+spinner state covers the latency.

### E. Index filters as buttons (#6, #7)
Replace the text-link filters in `index.html.heex` with two daisyUI button groups:
- **eARC:** All / Yes / Unconfirmed → `?verdict=` (`""`/`yes`/`unknown`)
- **Status:** Active / Interested / Contacted / Dismissed → `?status=` (absent/`interested`/`contacted`/`dismissed`)

Each is a `patch` link styled as a button (`join` group), with the active option highlighted (derived from `@verdict`/`@status` assigns). `index.ex` `handle_params` reads both `verdict` and `status` and passes `%{verdict: ..., status: ...}` to `Listings.list_matches/1` (already supports both; nil status hides "dismissed"). "Active" = no status param (default view).

### F. Clean daisyUI polish (#5)
A tidy page header, `card`-based listing tiles (index grid + show), color-coded `badge` verdicts (reuse existing badge color logic), consistent `btn` variants for actions, and coherent spacing/typography across both pages. No information-architecture change. Reuse `core_components` where it already provides a primitive.

## 4. Testing
- **`ImageCache`** (`Req.Test` seam): cache miss downloads + writes + returns path/type and persists dims; cache hit does not re-download; `dimensions/1` parses a tiny PNG and JPEG fixture; a failed download returns `{:error, _}` (no raise). Use a temp cache dir per test.
- **`ImageController`**: returns image bytes + correct `content-type` for a valid `fb_id`/index; 404 for unknown id or out-of-range index.
- **Index LiveView**: `?status=interested` shows only interested listings; default view excludes "dismissed"; `?verdict=yes` filters verdict; filter buttons render with the active one highlighted.
- **Show LiveView**: the curate panel renders **before** the gallery in the markup; the override submit carries `phx-disable-with`; status/verdict buttons reflect the active selection.

## 5. Out of scope
- Editing search config / triggering runs from the UI (separate feature).
- On-demand "re-check photos with vision" button (could be added later).
- Cache eviction/cleanup (cache grows with views; fine for a single user).
- Multi-image dimension capture during the daily scan (we capture lazily on view).

## 6. Files
- Modify: `lib/marketplace_bot_web/live/listing_live/show.html.heex`, `index.html.heex`, `index.ex`
- Modify: `lib/marketplace_bot/listings.ex` (`put_image_dim/3`), `lib/marketplace_bot/listings/listing.ex` (+ migration)
- Create: `lib/marketplace_bot/image_cache.ex`, `lib/marketplace_bot_web/controllers/image_controller.ex`, route in `router.ex`
- Tests: `test/marketplace_bot/image_cache_test.exs`, `test/marketplace_bot_web/controllers/image_controller_test.exs`, extend `index`/`show` live tests
- Assets: minor CSS only if a Tailwind variant can't express an animation (prefer variants).
