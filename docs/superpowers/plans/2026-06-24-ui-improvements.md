# UI Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve the LiveView browse/curate UI: curate-actions-first Show layout, self-served cached images with no layout shift, action feedback, status filters, and a clean daisyUI styling pass.

**Architecture:** A new `ImageCache` (downloads + caches FB-CDN images on first view, parsing pixel dims) served by an `ImageController` route; image dims persisted in a new `listings.image_dims` JSON column. The Show and Index LiveView templates are restyled with daisyUI and rewired to the cache route, plus button/loading feedback and index filter buttons. `Listings.list_matches/1` already supports `:verdict`/`:status` filtering — only the Index wiring changes.

**Tech Stack:** Elixir/Phoenix 1.8 + LiveView, Ecto + ecto_sqlite3 (JSON `:map` column), `Req` (+ `Req.Test` seam), Tailwind v4 + daisyUI 5.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-06-24-ui-improvements-design.md` (authoritative).
- Image source URLs come from `listing.images` (stored from Apify) — NOT user input. The cache route takes `fb_id` + `index` and looks the URL up; it must never fetch an arbitrary user-supplied URL (no SSRF).
- `ImageCache` and the controller must NEVER raise on bad input / failed download / unknown format — return `{:error, _}` / serve a 404, and the template shows a placeholder.
- Cache dir lives under `data/` (already gitignored). Never commit cached images.
- HTTP test seam: every `Req` call merges `opts[:req_options]` so tests route through `Req.Test`.
- All Repo-touching test modules use `async: false` (matches the project).
- Dimension parsing is pure Elixir (no system deps); support JPEG + PNG; unknown/WebP → `nil` dims (template falls back to a default aspect-ratio box).
- Styling uses the already-installed Tailwind v4 + daisyUI 5; prefer Phoenix's `phx-click-loading` / `phx-submit-loading` Tailwind variants and `phx-disable-with` over custom JS. No information-architecture changes.
- Run tests with `mix test <path>`; keep `mix compile --warnings-as-errors` clean. Full suite is currently 62 green.

---

### Task 1: `image_dims` column + `Listings.put_image_dim/3`

**Files:**
- Create: `priv/repo/migrations/<timestamp>_add_image_dims_to_listings.exs` (via generator)
- Modify: `lib/marketplace_bot/listings/listing.ex`
- Modify: `lib/marketplace_bot/listings.ex`
- Test: `test/marketplace_bot/listings_test.exs` (extend)

**Interfaces:**
- Produces: `listings.image_dims` (`:map`, JSON), keyed by stringified image index → `%{"w" => integer, "h" => integer}`. `Listings.put_image_dim(listing, index, dims_map) :: {:ok, Listing.t()} | {:error, Changeset.t()}`.

- [ ] **Step 1: Generate the migration**

Run: `mix ecto.gen.migration add_image_dims_to_listings`
Then set its contents to:

```elixir
defmodule MarketplaceBot.Repo.Migrations.AddImageDimsToListings do
  use Ecto.Migration

  def change do
    alter table(:listings) do
      add :image_dims, :map
    end
  end
end
```

- [ ] **Step 2: Add the field + cast**

In `lib/marketplace_bot/listings/listing.ex`: add to the schema (after `field :images, ...`):

```elixir
    field :image_dims, :map
```

and add `image_dims` to the `@cast_fields` list (append inside the `~w(...)a` sigil).

- [ ] **Step 3: Write the failing test**

Append to `test/marketplace_bot/listings_test.exs` (inside the module):

```elixir
  test "put_image_dim/3 merges dimensions keyed by string index" do
    {:ok, l} = %MarketplaceBot.Listings.Listing{} |> MarketplaceBot.Listings.Listing.changeset(%{fb_id: "dim1"}) |> Repo.insert()
    {:ok, l} = MarketplaceBot.Listings.put_image_dim(l, 0, %{"w" => 100, "h" => 50})
    {:ok, l} = MarketplaceBot.Listings.put_image_dim(l, 1, %{"w" => 200, "h" => 80})
    assert l.image_dims == %{"0" => %{"w" => 100, "h" => 50}, "1" => %{"w" => 200, "h" => 80}}
  end
```

- [ ] **Step 4: Run to verify it fails**

Run: `mix test test/marketplace_bot/listings_test.exs`
Expected: FAIL — `put_image_dim/3` undefined.

- [ ] **Step 5: Implement `put_image_dim/3`**

In `lib/marketplace_bot/listings.ex`, add (near `set_status/2`):

```elixir
  @spec put_image_dim(Listing.t(), non_neg_integer(), map()) ::
          {:ok, Listing.t()} | {:error, Ecto.Changeset.t()}
  def put_image_dim(%Listing{} = listing, index, %{} = dims) do
    current = listing.image_dims || %{}
    update_listing(listing, %{image_dims: Map.put(current, to_string(index), dims)})
  end
```

- [ ] **Step 6: Run to verify it passes**

Run: `mix test test/marketplace_bot/listings_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Add listings.image_dims column + Listings.put_image_dim/3"
```

---

### Task 2: `ImageCache.dimensions/1` (pure-Elixir JPEG/PNG dimension reader)

**Files:**
- Create: `lib/marketplace_bot/image_cache.ex` (start the module with just `dimensions/1`)
- Test: `test/marketplace_bot/image_cache_test.exs`

**Interfaces:**
- Produces: `MarketplaceBot.ImageCache.dimensions(binary) :: %{w: pos_integer, h: pos_integer} | nil` and `MarketplaceBot.ImageCache.content_type(binary) :: String.t() | nil`.

- [ ] **Step 1: Write the failing test**

Create `test/marketplace_bot/image_cache_test.exs`:

```elixir
defmodule MarketplaceBot.ImageCacheTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.ImageCache

  # PNG header: 8-byte sig + IHDR length + "IHDR" + width::32 + height::32
  defp png(w, h), do: <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", w::32, h::32, 0::40>>
  # JPEG: SOI + SOF0 (len 17, precision 8, height::16, width::16, ...)
  defp jpeg(w, h), do: <<0xFF, 0xD8, 0xFF, 0xC0, 0, 17, 8, h::16, w::16, 0::80>>

  test "reads PNG dimensions" do
    assert ImageCache.dimensions(png(120, 60)) == %{w: 120, h: 60}
  end

  test "reads JPEG dimensions (skips APP0 segment first)" do
    app0 = <<0xFF, 0xE0, 0, 4, 0, 0>>
    assert ImageCache.dimensions(<<0xFF, 0xD8>> <> app0 <> <<0xFF, 0xC0, 0, 17, 8, 60::16, 120::16, 0::80>>) == %{w: 120, h: 60}
  end

  test "unknown format returns nil" do
    assert ImageCache.dimensions(<<0, 1, 2, 3, 4>>) == nil
  end

  test "content_type detects png/jpeg, nil otherwise" do
    assert ImageCache.content_type(png(1, 1)) == "image/png"
    assert ImageCache.content_type(jpeg(1, 1)) == "image/jpeg"
    assert ImageCache.content_type(<<0, 1, 2>>) == nil
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/marketplace_bot/image_cache_test.exs`
Expected: FAIL — `ImageCache` undefined.

- [ ] **Step 3: Implement the module**

Create `lib/marketplace_bot/image_cache.ex`:

```elixir
defmodule MarketplaceBot.ImageCache do
  @moduledoc """
  Cache-on-first-view for listing images. Downloads a listing's FB-CDN image
  the first time it's requested, stores it under the cache dir, records its
  pixel dimensions, and serves the local copy thereafter.
  """

  @doc "Detect content-type from magic bytes. nil if unrecognized."
  @spec content_type(binary) :: String.t() | nil
  def content_type(<<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>>), do: "image/png"
  def content_type(<<0xFF, 0xD8, _::binary>>), do: "image/jpeg"
  def content_type(<<"RIFF", _::32, "WEBP", _::binary>>), do: "image/webp"
  def content_type(_), do: nil

  @doc "Pixel dimensions of a JPEG/PNG binary, or nil for unknown formats."
  @spec dimensions(binary) :: %{w: pos_integer, h: pos_integer} | nil
  def dimensions(<<0x89, "PNG\r\n", 0x1A, 0x0A, _len::32, "IHDR", w::32, h::32, _::binary>>),
    do: %{w: w, h: h}

  def dimensions(<<0xFF, 0xD8, rest::binary>>), do: jpeg_dims(rest)
  def dimensions(_), do: nil

  # Walk JPEG segments until a Start-Of-Frame marker (carries height/width).
  defp jpeg_dims(<<0xFF, 0xFF, rest::binary>>), do: jpeg_dims(<<0xFF, rest::binary>>)

  defp jpeg_dims(<<0xFF, marker, len::16, rest::binary>>) do
    cond do
      marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC] ->
        <<_precision::8, height::16, width::16, _::binary>> = rest
        %{w: width, h: height}

      true ->
        skip = len - 2

        case rest do
          <<_::binary-size(skip), next::binary>> -> jpeg_dims(next)
          _ -> nil
        end
    end
  end

  defp jpeg_dims(_), do: nil
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/marketplace_bot/image_cache_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "ImageCache: pure-Elixir JPEG/PNG dimension + content-type readers"
```

---

### Task 3: `ImageCache.fetch/3` (download → cache → persist dims)

**Files:**
- Modify: `lib/marketplace_bot/image_cache.ex`
- Modify: `config/config.exs` (cache dir default)
- Test: `test/marketplace_bot/image_cache_test.exs` (extend)

**Interfaces:**
- Consumes: `dimensions/1`, `content_type/1` (Task 2); `Listings.put_image_dim/3` (Task 1).
- Produces: `MarketplaceBot.ImageCache.fetch(listing, index, opts) :: {:ok, path :: String.t(), content_type :: String.t()} | {:error, term()}`. Cache hit returns the existing file; miss downloads (via `Req`, `opts[:req_options]` seam), writes to `opts[:cache_dir] || config || "data/image_cache"`, persists dims via `Listings.put_image_dim/3`, and returns.

- [ ] **Step 1: Add cache dir config**

In `config/config.exs`, near the other `config :marketplace_bot, ...` blocks, add:

```elixir
config :marketplace_bot, :image_cache_dir, "data/image_cache"
```

- [ ] **Step 2: Write the failing test**

Append to `test/marketplace_bot/image_cache_test.exs`:

```elixir
  alias MarketplaceBot.Listings
  alias MarketplaceBot.Listings.Listing
  alias MarketplaceBot.Repo

  defp tmp_dir do
    d = Path.join(System.tmp_dir!(), "imgcache-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(d) end)
    d
  end

  defp insert_listing(images) do
    {:ok, l} = %Listing{} |> Listing.changeset(%{fb_id: "img#{System.unique_integer([:positive])}", images: images}) |> Repo.insert()
    l
  end

  describe "fetch/3" do
    setup do
      # ImageCacheTest uses the Repo, so wrap in the sandbox like DataCase does.
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      :ok
    end

    test "cache miss downloads, writes the file, returns path/type, and persists dims" do
      png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", 40::32, 20::32, 0::40>>
      l = insert_listing(["https://scontent.fbcdn.net/a.jpg"])
      dir = tmp_dir()

      Req.Test.stub(MarketplaceBot.ImageCache, fn conn -> Req.Test.text(conn, png) end)

      assert {:ok, path, "image/png"} =
               ImageCache.fetch(l, 0, cache_dir: dir, req_options: [plug: {Req.Test, MarketplaceBot.ImageCache}])

      assert File.exists?(path)
      assert Repo.get!(Listing, l.id).image_dims == %{"0" => %{"w" => 40, "h" => 20}}
    end

    test "cache hit does not re-download" do
      l = insert_listing(["https://scontent.fbcdn.net/a.jpg"])
      dir = tmp_dir()
      png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", 1::32, 1::32, 0::40>>
      Req.Test.stub(MarketplaceBot.ImageCache, fn conn -> Req.Test.text(conn, png) end)
      {:ok, path1, _} = ImageCache.fetch(l, 0, cache_dir: dir, req_options: [plug: {Req.Test, MarketplaceBot.ImageCache}])

      # Second call with a plug that would raise if hit:
      Req.Test.stub(MarketplaceBot.ImageCache, fn _ -> raise "should not download on cache hit" end)
      assert {:ok, ^path1, "image/png"} = ImageCache.fetch(l, 0, cache_dir: dir, req_options: [plug: {Req.Test, MarketplaceBot.ImageCache}])
    end

    test "missing image index returns error" do
      l = insert_listing([])
      assert {:error, :no_image} = ImageCache.fetch(l, 0, cache_dir: tmp_dir())
    end

    test "failed download returns error (no raise)" do
      l = insert_listing(["https://scontent.fbcdn.net/a.jpg"])
      Req.Test.stub(MarketplaceBot.ImageCache, fn conn -> Plug.Conn.send_resp(conn, 403, "nope") end)
      assert {:error, _} = ImageCache.fetch(l, 0, cache_dir: tmp_dir(), req_options: [plug: {Req.Test, MarketplaceBot.ImageCache}])
    end
  end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mix test test/marketplace_bot/image_cache_test.exs`
Expected: FAIL — `fetch/3` undefined.

- [ ] **Step 4: Implement `fetch/3` + helpers**

Add to `lib/marketplace_bot/image_cache.ex` (inside the module):

```elixir
  alias MarketplaceBot.Listings

  @exts %{"image/png" => "png", "image/jpeg" => "jpg", "image/webp" => "webp"}

  @spec fetch(MarketplaceBot.Listings.Listing.t(), non_neg_integer(), keyword()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def fetch(listing, index, opts \\ []) do
    dir = opts[:cache_dir] || Application.get_env(:marketplace_bot, :image_cache_dir, "data/image_cache")

    case Enum.at(listing.images || [], index) do
      nil ->
        {:error, :no_image}

      url ->
        case existing(dir, listing.fb_id, index) do
          {:ok, _, _} = hit -> hit
          :miss -> download_and_cache(listing, index, url, dir, opts)
        end
    end
  end

  defp existing(dir, fb_id, index) do
    case Path.wildcard(Path.join(dir, "#{fb_id}-#{index}.*")) do
      [path | _] -> {:ok, path, ct_from_ext(path)}
      [] -> :miss
    end
  end

  defp download_and_cache(listing, index, url, dir, opts) do
    req = Keyword.merge([method: :get, url: url, headers: [{"user-agent", "Mozilla/5.0"}], receive_timeout: 30_000], opts[:req_options] || [])

    with {:ok, %{status: 200, body: bin}} when is_binary(bin) <- Req.request(req),
         ct when is_binary(ct) <- content_type(bin) || "image/jpeg" do
      File.mkdir_p!(dir)
      ext = Map.get(@exts, ct, "img")
      path = Path.join(dir, "#{listing.fb_id}-#{index}.#{ext}")
      File.write!(path, bin)

      case dimensions(bin) do
        %{w: w, h: h} -> Listings.put_image_dim(listing, index, %{"w" => w, "h" => h})
        nil -> :ok
      end

      {:ok, path, ct}
    else
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp ct_from_ext(path) do
    case Path.extname(path) do
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end
  end
```

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/marketplace_bot/image_cache_test.exs`
Expected: PASS.

- [ ] **Step 6: Run full suite + clean compile**

Run: `mix compile --warnings-as-errors && mix test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "ImageCache.fetch/3: cache-on-first-view download + dims persistence"
```

---

### Task 4: `ImageController` + `/img/:fb_id/:index` route

**Files:**
- Create: `lib/marketplace_bot_web/controllers/image_controller.ex`
- Modify: `lib/marketplace_bot_web/router.ex`
- Test: `test/marketplace_bot_web/controllers/image_controller_test.exs`

**Interfaces:**
- Consumes: `ImageCache.fetch/3` (Task 3).
- Produces: route `GET /img/:fb_id/:index` → cached image bytes with correct `content-type`; 404 on unknown `fb_id`, non-integer/out-of-range index, or fetch error.

- [ ] **Step 1: Write the failing test**

Create `test/marketplace_bot_web/controllers/image_controller_test.exs`:

```elixir
defmodule MarketplaceBotWeb.ImageControllerTest do
  use MarketplaceBotWeb.ConnCase, async: false
  alias MarketplaceBot.Listings.Listing
  alias MarketplaceBot.Repo

  setup do
    dir = Path.join(System.tmp_dir!(), "imgctrl-#{System.unique_integer([:positive])}")
    prev = Application.get_env(:marketplace_bot, :image_cache_dir)
    Application.put_env(:marketplace_bot, :image_cache_dir, dir)
    on_exit(fn -> File.rm_rf(dir); Application.put_env(:marketplace_bot, :image_cache_dir, prev) end)
    {:ok, l} = %Listing{} |> Listing.changeset(%{fb_id: "ctrl1", images: ["https://scontent.fbcdn.net/a.jpg"]}) |> Repo.insert()
    %{listing: l}
  end

  test "serves cached image bytes with content-type", %{conn: conn, listing: l} do
    png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", 2::32, 2::32, 0::40>>
    Req.Test.stub(MarketplaceBot.ImageCache, fn c -> Req.Test.text(c, png) end)

    conn = get(conn, ~p"/img/#{l.fb_id}/0")
    assert conn.status == 200
    assert response_content_type(conn, :png)
  end

  test "404 for unknown fb_id", %{conn: conn} do
    assert get(conn, ~p"/img/nope/0").status == 404
  end

  test "404 for out-of-range index", %{conn: conn, listing: l} do
    assert get(conn, ~p"/img/#{l.fb_id}/9").status == 404
  end
end
```

> `Phoenix.ConnTest` dispatches the controller synchronously in the test process, so the `Req.Test` stub set in the test is visible to the controller — no `Req.Test.allow` needed — provided the controller routes through the test-only plug added in Step 3a.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/marketplace_bot_web/controllers/image_controller_test.exs`
Expected: FAIL — route/controller undefined.

- [ ] **Step 3: Implement the controller**

Create `lib/marketplace_bot_web/controllers/image_controller.ex`:

```elixir
defmodule MarketplaceBotWeb.ImageController do
  use MarketplaceBotWeb, :controller
  alias MarketplaceBot.{ImageCache, Repo}
  alias MarketplaceBot.Listings.Listing

  def show(conn, %{"fb_id" => fb_id, "index" => index_str}) do
    with {index, ""} <- Integer.parse(index_str),
         %Listing{} = listing <- Repo.get_by(Listing, fb_id: fb_id),
         {:ok, path, content_type} <- ImageCache.fetch(listing, index, req_options(conn)) do
      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_file(200, path)
    else
      _ -> conn |> put_status(404) |> text("not found")
    end
  end

  # In tests, a Req.Test plug is configured app-wide (Step 3a); in dev/prod this is [].
  defp req_options(_conn), do: Application.get_env(:marketplace_bot, :image_req_options, [])
end
```

- [ ] **Step 3a: Configure the test-only Req plug**

In `config/test.exs`, add:

```elixir
config :marketplace_bot, :image_req_options, plug: {Req.Test, MarketplaceBot.ImageCache}
```

In dev/prod this key is unset, so `req_options/1` returns `[]` (real HTTP).

- [ ] **Step 4: Add the route**

In `lib/marketplace_bot_web/router.ex`, inside the `scope "/", MarketplaceBotWeb do ... pipe_through :browser` block (alongside the listing routes), add:

```elixir
    get "/img/:fb_id/:index", ImageController, :show
```

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/marketplace_bot_web/controllers/image_controller_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add ImageController + GET /img/:fb_id/:index serving cached images"
```

---

### Task 5: Show page — reorder, cached gallery, feedback, override loading, polish

**Files:**
- Modify: `lib/marketplace_bot_web/live/listing_live/show.html.heex`
- Test: `test/marketplace_bot_web/live/listing_live/show_test.exs` (extend)

**Interfaces:**
- Consumes: route `~p"/img/#{fb_id}/#{i}"` (Task 4); `@listing.image_dims` (Task 1); existing `show.ex` events `correct_verdict`, `override_model`, `set_status` (unchanged).

- [ ] **Step 1: Write the failing test**

Append to `test/marketplace_bot_web/live/listing_live/show_test.exs` (inside the module; it already inserts a listing — reuse its setup or insert one):

```elixir
  test "curate panel renders before the image gallery and override has a loading state", %{conn: conn} do
    {:ok, l} = %MarketplaceBot.Listings.Listing{} |> MarketplaceBot.Listings.Listing.changeset(%{fb_id: "show1", title: "T", images: ["https://scontent.fbcdn.net/a.jpg"]}) |> MarketplaceBot.Repo.insert()
    {:ok, _lv, html} = live(conn, ~p"/listings/#{l.id}")

    # override + status controls appear before the gallery's cache-route <img>
    {panel_pos, _} = :binary.match(html, "override + re-resolve")
    {img_pos, _} = :binary.match(html, "/img/show1/0")
    assert panel_pos < img_pos

    assert html =~ "phx-disable-with"
    assert html =~ ~s(src="/img/show1/0")
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/marketplace_bot_web/live/listing_live/show_test.exs`
Expected: FAIL — gallery still uses raw image URLs / curate panel is below images.

- [ ] **Step 3: Rewrite the template**

Replace the entire contents of `lib/marketplace_bot_web/live/listing_live/show.html.heex` with:

```heex
<div class="mx-auto max-w-3xl p-4 space-y-6">
  <.link navigate={~p"/listings"} class="link link-hover text-sm">← back to matches</.link>

  <header>
    <h1 class="text-2xl font-semibold"><%= @listing.title %></h1>
    <div class="text-base-content/70 mt-1">
      <%= if @listing.price_cents, do: "$#{div(@listing.price_cents, 100)}", else: "price n/a" %>
      · <%= @listing.city %>, <%= @listing.state %>
      <%= if @listing.distance_mi, do: " · #{@listing.distance_mi} mi from El Campo" %>
    </div>
  </header>

  <%!-- Curate panel: ABOVE the images --%>
  <section class="card bg-base-200">
    <div class="card-body gap-4">
      <div>
        <div class="text-sm font-medium mb-1">
          eARC: <span class={"badge #{badge(@listing.earc_verdict)}"}><%= @listing.earc_verdict %></span>
          <span :if={@model} class="text-base-content/70">
            · <%= @model.brand %> <%= @model.model %> (<%= @model.source %>)
          </span>
        </div>
        <div class="join">
          <button :for={v <- ~w(yes no unknown)} phx-click="correct_verdict" phx-value-verdict={v}
            class={"btn btn-sm join-item transition phx-click-loading:opacity-50 #{if @listing.earc_verdict == v, do: "btn-active btn-primary"}"}>
            eARC <%= v %>
          </button>
        </div>
      </div>

      <form id="override-model" phx-submit="override_model" class="flex flex-wrap gap-2 items-end">
        <label class="form-control">
          <span class="label-text text-xs">brand</span>
          <input name="brand" class="input input-bordered input-sm" />
        </label>
        <label class="form-control">
          <span class="label-text text-xs">model</span>
          <input name="model" class="input input-bordered input-sm" />
        </label>
        <button class="btn btn-sm btn-secondary" phx-disable-with="Re-resolving…">
          <span class="loading loading-spinner loading-xs hidden phx-submit-loading:inline-block"></span>
          override + re-resolve
        </button>
      </form>

      <div class="join">
        <button :for={s <- ~w(interested contacted dismissed)} phx-click="set_status" phx-value-status={s}
          class={"btn btn-sm join-item transition phx-click-loading:opacity-50 #{if @listing.status == s, do: "btn-active btn-primary"}"}>
          <%= s %>
        </button>
      </div>
    </div>
  </section>

  <%!-- Gallery: cached, lazy, no layout shift --%>
  <div :if={(@listing.images || []) != []} class="grid grid-cols-2 gap-2">
    <div :for={{_src, i} <- Enum.with_index(@listing.images)} class="overflow-hidden rounded bg-base-300 aspect-[4/3]">
      <img src={~p"/img/#{@listing.fb_id}/#{i}"} loading="lazy" {img_dims(@listing, i)}
        class="w-full h-full object-cover" alt={"#{@listing.title} photo #{i + 1}"} />
    </div>
  </div>

  <p :if={@listing.description} class="whitespace-pre-line"><%= @listing.description %></p>

  <a href={@listing.url} target="_blank" class="link">View on Facebook ↗</a>
</div>
```

- [ ] **Step 4: Add the template helpers**

In `lib/marketplace_bot_web/live/listing_live/show.ex`, add private helpers (used by the HEEx) and ensure they're in scope (LiveView templates call functions defined in the LiveView module):

```elixir
  defp badge("yes"), do: "badge-success"
  defp badge("no"), do: "badge-error"
  defp badge("unknown"), do: "badge-warning"
  defp badge(_), do: "badge-ghost"

  # Returns a keyword list of width/height attrs when dims are known, else [].
  defp img_dims(listing, index) do
    case listing.image_dims && Map.get(listing.image_dims, to_string(index)) do
      %{"w" => w, "h" => h} -> [width: w, height: h]
      _ -> []
    end
  end
```

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/marketplace_bot_web/live/listing_live/show_test.exs`
Expected: PASS.

- [ ] **Step 6: Run full suite + clean compile**

Run: `mix compile --warnings-as-errors && mix test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Show page: curate-first reorder, cached lazy gallery, action feedback, daisyUI polish"
```

---

### Task 6: Index page — status/verdict filter buttons + card polish

**Files:**
- Modify: `lib/marketplace_bot_web/live/listing_live/index.ex`
- Modify: `lib/marketplace_bot_web/live/listing_live/index.html.heex`
- Test: `test/marketplace_bot_web/live/listing_live/index_test.exs` (extend)

**Interfaces:**
- Consumes: `Listings.list_matches/1` with `%{verdict: ..., status: ...}` (existing); cache route (Task 4).

- [ ] **Step 1: Write the failing test**

Append to `test/marketplace_bot_web/live/listing_live/index_test.exs` (inside the module):

```elixir
  test "status filter shows only that status; default hides dismissed", %{conn: conn} do
    ins = fn fb, status -> {:ok, _} = %MarketplaceBot.Listings.Listing{} |> MarketplaceBot.Listings.Listing.changeset(%{fb_id: fb, title: fb, is_receiver: true, earc_verdict: "yes", status: status}) |> MarketplaceBot.Repo.insert() end
    ins.("keep", "interested")
    ins.("gone", "dismissed")

    {:ok, _lv, html} = live(conn, ~p"/listings?status=interested")
    assert html =~ "keep"
    refute html =~ "gone"

    {:ok, _lv, html2} = live(conn, ~p"/listings")
    refute html2 =~ "gone"

    # filter rendered as buttons with an active one
    assert html =~ "btn"
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/marketplace_bot_web/live/listing_live/index_test.exs`
Expected: FAIL — index doesn't read `status` / filters aren't buttons.

- [ ] **Step 3: Update `handle_params`**

In `lib/marketplace_bot_web/live/listing_live/index.ex`, replace `handle_params/3` with:

```elixir
  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{verdict: params["verdict"], status: params["status"]}

    {:noreply,
     assign(socket,
       listings: Listings.list_matches(filters),
       verdict: params["verdict"],
       status: params["status"]
     )}
  end
```

- [ ] **Step 4: Rewrite the template**

Replace the entire contents of `lib/marketplace_bot_web/live/listing_live/index.html.heex` with:

```heex
<div class="mx-auto max-w-5xl p-4 space-y-6">
  <h1 class="text-2xl font-semibold">AV Receiver Matches</h1>

  <div class="space-y-2">
    <div class="join">
      <.link patch={~p"/listings"} class={"btn btn-sm join-item #{if is_nil(@verdict) and is_nil(@status), do: "btn-active btn-primary"}"}>All</.link>
      <.link patch={~p"/listings?verdict=yes"} class={"btn btn-sm join-item #{if @verdict == "yes", do: "btn-active btn-primary"}"}>eARC: yes</.link>
      <.link patch={~p"/listings?verdict=unknown"} class={"btn btn-sm join-item #{if @verdict == "unknown", do: "btn-active btn-primary"}"}>eARC: unconfirmed</.link>
    </div>
    <div class="join">
      <.link patch={~p"/listings?status=interested"} class={"btn btn-sm join-item #{if @status == "interested", do: "btn-active btn-primary"}"}>Interested</.link>
      <.link patch={~p"/listings?status=contacted"} class={"btn btn-sm join-item #{if @status == "contacted", do: "btn-active btn-primary"}"}>Contacted</.link>
      <.link patch={~p"/listings?status=dismissed"} class={"btn btn-sm join-item #{if @status == "dismissed", do: "btn-active btn-primary"}"}>Dismissed</.link>
    </div>
  </div>

  <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
    <.link :for={l <- @listings} navigate={~p"/listings/#{l.id}"} class="card bg-base-100 shadow hover:shadow-lg transition overflow-hidden">
      <figure class="aspect-[4/3] bg-base-300">
        <img :if={(l.images || []) != []} src={~p"/img/#{l.fb_id}/0"} loading="lazy" class="w-full h-full object-cover" alt={l.title} />
      </figure>
      <div class="card-body p-3 gap-1">
        <div class="font-medium line-clamp-2"><%= l.title %></div>
        <div class="text-sm text-base-content/70"><%= price(l) %> · <%= l.city %><%= dist_label(l) %></div>
        <span class={"badge badge-sm #{badge(l.earc_verdict)}"}><%= verdict_label(l.earc_verdict) %></span>
      </div>
    </.link>
  </div>

  <p :if={@listings == []} class="text-base-content/60">No matches.</p>
</div>
```

- [ ] **Step 5: Update the badge helper colors**

In `lib/marketplace_bot_web/live/listing_live/index.ex`, replace the `badge/1` clauses with daisyUI badge classes:

```elixir
  defp badge("yes"), do: "badge-success"
  defp badge("unknown"), do: "badge-warning"
  defp badge(_), do: "badge-ghost"
```

(Keep the existing `price/1`, `dist_label/1`, `verdict_label/1` helpers as they are.)

- [ ] **Step 6: Run to verify it passes**

Run: `mix test test/marketplace_bot_web/live/listing_live/index_test.exs`
Expected: PASS.

- [ ] **Step 7: Run full suite + clean compile**

Run: `mix compile --warnings-as-errors && mix test`
Expected: PASS (full suite green).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Index page: status/verdict filter buttons + daisyUI card polish"
```

---

## Live verification (after merge — operational, not a task)

With the service running, open `http://<host>:4010/listings`, confirm: filters work as buttons, thumbnails load (and re-load instantly on revisit = cache hit), the Show page shows curate controls above images with no layout jump as photos load, the override button shows the spinner/disabled state, and status/verdict buttons highlight on click. Cached files appear under `data/image_cache/`.
