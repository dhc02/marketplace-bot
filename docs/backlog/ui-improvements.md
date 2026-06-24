# UI Improvements — backlog (feature #1)

Captured from the owner 2026-06-24. To be designed (brainstorm → spec → plan) on its own
branch `feature/ui-improvements` after the vision feature lands.

## Requirements (verbatim)

1. On the listing (Show) page, move model info, override fields, and interested/dismissed/contacted buttons **above** the images.
2. Lazy-load images with correct-sized placeholders to avoid layout shift while loading. (Are these images served by the Phoenix server? If not, pull them and serve them ourselves, or at least cache them when first viewed.)
3. Add an animation/confirmation when buttons are pressed.
4. Add an animation indicating the "override + re-resolve" action is underway.
5. Add Tailwind for styling the app.
6. Add filters on the main (index) page for interested, dismissed, and contacted.
7. Make filters buttons instead of just links.

## Design notes / decisions to settle during the UI brainstorm

- **#5 caveat:** Tailwind is **already present** — Phoenix 1.8 ships Tailwind v4 + daisyUI (the dev server logs show `tailwindcss v4.3.0` / `daisyUI 5.5.20`, and `index.html.heex` already uses utility classes). So #5 is really "lean on it and actually style the app" (the current UI is minimal/utilitarian). Confirm scope: a styling pass / visual direction (frontend-design skill candidate).
- **#2 is the one real architecture decision.** Today `images` are FB CDN URLs rendered directly in `<img src=…>` — **not** served by Phoenix, and FB CDN URLs **expire**. Options to weigh:
  - (a) **Cache-on-first-view:** a Phoenix route downloads + caches the image to disk on first request, serves locally thereafter.
  - (b) **Download during the daily pipeline:** fetch + store images when the listing is ingested (most robust against expiry; more storage).
  - (c) Leave remote, just add lazy-loading + placeholders (cheapest; doesn't fix expiry).
  - For correct-sized placeholders we need image **dimensions**, which the Apify JSON provides (`images[].image.width/height`) but `Sources.Apify.normalize/1` currently **drops** (it keeps only URL strings). Capturing dimensions is a prerequisite for no-layout-shift placeholders — so #2 likely touches the Listing schema + normalizer too.
- **#6/#7** depend on `Listings.list_matches/1`, which already supports a `:status` filter — wiring index buttons for interested/dismissed/contacted is mostly LiveView.
- **#1/#3/#4** are LiveView/template + small JS-hook/transition work (LiveView JS commands or CSS transitions; #4 needs a loading state on the override form submit).
