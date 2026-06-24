# marketplace-bot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an Elixir/Phoenix LiveView app that runs a daily Apify-backed scan of Facebook Marketplace for AV receivers, classifies/extracts model + eARC support (hybrid table+LLM), sends a Telegram digest of new matches, and lets the user browse and curate listings in a web UI.

**Architecture:** A single Phoenix 1.7 app serves the LiveView UI and runs the daily pipeline as an Oban cron job. SQLite (`ecto_sqlite3`) is the store. All external I/O (Apify, DeepSeek, Kagi, Telegram) goes through `Req`. The data source sits behind a `Source` behaviour so the Apify actor is swappable. The eARC resolver is a user-correctable `models` table with an LLM fallback (Kagi FastGPT web research → DeepSeek verdict) cached back into the table.

**Tech Stack:** Elixir, Phoenix 1.7 + LiveView, Ecto + ecto_sqlite3 (SQLite), Oban (Lite engine, Cron plugin), Req (HTTP), DeepSeek API (OpenAI-compatible chat completions, raw HTTP), Kagi FastGPT API (raw HTTP), Telegram Bot API, Apify REST API.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-06-24-marketplace-bot-design.md` is authoritative; this plan implements it.
- **App name / module:** OTP app `:marketplace_bot`, base module `MarketplaceBot`, web module `MarketplaceBotWeb`.
- **Database:** SQLite via `ecto_sqlite3`. SQLite has weak concurrent-connection support — **all ExUnit test modules that touch the Repo use `async: false`**.
- **DeepSeek API (LLM):** OpenAI-compatible chat completions over raw HTTP via `Req` — `POST https://api.deepseek.com/v1/chat/completions`, header `Authorization: Bearer $DEEPSEEK_API_KEY`. Models (use **verbatim**, do not "correct"): classify/extract = `deepseek-v4-flash`; eARC verdict = `deepseek-v4-pro`. Force JSON with `response_format: {"type": "json_object"}` and describe the required JSON shape in the prompt, then parse/validate client-side (do not assume json_schema support). **Verify the exact base URL, model IDs, and JSON-mode behavior against current DeepSeek docs on the first real call** (treated as a probe, like the Apify shape).
- **Kagi research (eARC):** `POST https://kagi.com/api/v0/fastgpt`, header `Authorization: Bot $KAGI_API_KEY`, body `{"query": "..."}`; response carries a researched answer plus references (expected at `data.output` / `data.references`). The app calls the Kagi **HTTP API directly via Req** (not via an MCP client — MCP is for AI-tool integration, not a backend service's outbound calls). **Verify the endpoint and response shape against current Kagi docs on the first real call.** eARC research flow: Kagi FastGPT researches `"{brand} {model} HDMI eARC support"` → `deepseek-v4-pro` converts that into a `yes`/`no`/`unknown` verdict.
- **Secrets:** `.env` is gitignored and never committed. Env vars: `APIFY_TOKEN`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `DEEPSEEK_API_KEY`, `KAGI_API_KEY`. Read them in `config/runtime.exs`.
- **eARC verdicts** are the strings `"yes"`, `"no"`, `"unknown"`; model `source` is `"seed"`, `"llm"`, or `"user"` (user is authoritative, never auto-overwritten).
- **Swappable implementations** are selected via app config and overridden in tests: `:source`, `:receiver_llm`, `:earc_llm`, `:notifier`.
- **HTTP test seam:** every `Req` call merges `Application.get_env(:marketplace_bot, <Module>)[:req_options] || []`; tests set `req_options: [plug: {Req.Test, <Module>}]` and register stubs with `Req.Test.stub/2`.
- **Local web port:** `4010` (documented in CLAUDE.md). Bind to local only; the public route (Cloudflare Tunnel + Zero Trust) is provisioned by your ops process, never by this app.
- **Search config (v1, in app config, not UI):** search URL `https://www.facebook.com/marketplace/113243215352508/search?query=receiver&exact=false&maxPrice=500`; `max_listings` separate `:initial` (probe, up to 1000) and `:daily` values; unknown-eARC listings are included, tagged "eARC unconfirmed".

---

### Task 1: Scaffold the Phoenix app (SQLite, Oban, Req, config, Source behaviour)

**Files:**
- Create (generated): full Phoenix tree at repo root — `mix.exs`, `config/*.exs`, `lib/marketplace_bot/`, `lib/marketplace_bot_web/`, `test/`, `assets/`, `priv/`
- Modify: `.gitignore` (append Elixir/Phoenix ignores), `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/runtime.exs`, `lib/marketplace_bot/application.ex`
- Create: `lib/marketplace_bot/sources/source.ex`, `lib/marketplace_bot/sources/fake.ex`
- Create: `priv/repo/migrations/*_add_oban_jobs.exs`

**Interfaces:**
- Produces: `MarketplaceBot.Repo`; `MarketplaceBot.Sources.Source` behaviour with `@callback fetch(opts :: keyword()) :: {:ok, [map()]} | {:error, term()}`; `MarketplaceBot.Sources.Fake` implementing it; Oban running in the supervision tree.

- [ ] **Step 1: Generate the Phoenix app into a temp dir (non-interactive), then copy into the repo**

The repo already contains files, so `mix phx.new .` would prompt interactively. Generate into a clean temp dir and copy the tree in, keeping our existing files.

```bash
mix local.hex --force && mix local.rebar --force
mix archive.install hex phx_new --force
GEN=/tmp/scratch/mb_gen
rm -rf "$GEN"
mix phx.new "$GEN" --app marketplace_bot --module MarketplaceBot --database sqlite3 --no-mailer --install
# Copy generated tree into the repo, but keep our own .gitignore / docs / .env*
rsync -a --exclude='.git' --exclude='.gitignore' "$GEN"/ /home/<user>/projects/marketplace-bot/
```

- [ ] **Step 2: Append Elixir/Phoenix ignores to our existing `.gitignore`**

Add these lines to `.gitignore` (our file already ignores `.env`, `*.db`, `data/`):

```gitignore

# elixir / phoenix
/_build/
/deps/
/.elixir_ls/
*.beam
erl_crash.dump
marketplace_bot-*.tar
/priv/static/assets/
/priv/static/cache_manifest.json
npm-debug.log
```

- [ ] **Step 3: Add `oban` and `req` deps**

In `mix.exs`, add to `deps/0`:

```elixir
{:oban, "~> 2.18"},
{:req, "~> 0.5"}
```

Run:

```bash
mix deps.get
```

- [ ] **Step 4: Configure Oban (Lite engine + Cron), the search config, and the web port**

In `config/config.exs`, before the `import_config` line, add:

```elixir
config :marketplace_bot, Oban,
  engine: Oban.Engines.Lite,
  repo: MarketplaceBot.Repo,
  queues: [default: 5],
  plugins: [
    {Oban.Plugins.Cron,
     # 13:00 UTC ≈ 8:00am Central (standard). Tune after the volume probe.
     crontab: [{"0 13 * * *", MarketplaceBot.Jobs.DailyScan}]}
  ]

config :marketplace_bot, :search,
  url:
    "https://www.facebook.com/marketplace/113243215352508/search?query=receiver&exact=false&maxPrice=500",
  max_listings: [initial: 1000, daily: 250]

# LLM / research providers. Model strings are user-chosen — keep verbatim.
config :marketplace_bot, :llm,
  deepseek_base_url: "https://api.deepseek.com/v1",
  classify_model: "deepseek-v4-flash",
  earc_model: "deepseek-v4-pro",
  kagi_fastgpt_url: "https://kagi.com/api/v0/fastgpt"

# Swappable implementations (overridden in test)
config :marketplace_bot,
  source: MarketplaceBot.Sources.Apify,
  receiver_llm: MarketplaceBot.Receivers.LLM,
  earc_llm: MarketplaceBot.Earc.LLM,
  notifier: MarketplaceBot.Notifier.Telegram,
  web_base_url: "http://localhost:4010"
```

In `config/dev.exs`, change the endpoint http port from `4000` to `4010`:

```elixir
http: [ip: {127, 0, 0, 1}, port: 4010],
```

- [ ] **Step 5: Add the Oban migration**

```bash
mix ecto.gen.migration add_oban_jobs
```

Edit the generated migration to:

```elixir
defmodule MarketplaceBot.Repo.Migrations.AddObanJobs do
  use Ecto.Migration
  def up, do: Oban.Migration.up()
  def down, do: Oban.Migration.down(version: 1)
end
```

- [ ] **Step 6: Add Oban to the supervision tree**

In `lib/marketplace_bot/application.ex`, add to the `children` list (after `MarketplaceBot.Repo`):

```elixir
{Oban, Application.fetch_env!(:marketplace_bot, Oban)},
```

- [ ] **Step 7: Configure Oban for tests (manual mode, no cron/queues)**

In `config/test.exs`, add:

```elixir
config :marketplace_bot, Oban, testing: :manual

config :marketplace_bot,
  source: MarketplaceBot.Sources.Fake,
  receiver_llm: MarketplaceBot.Receivers.LLMStub,
  earc_llm: MarketplaceBot.Earc.LLMStub,
  notifier: MarketplaceBot.Notifier.Stub
```

(The stub modules referenced here are created in later tasks; tests that need them define or rely on them. `Sources.Fake` is created in this task.)

- [ ] **Step 8: Define the `Source` behaviour**

Create `lib/marketplace_bot/sources/source.ex`:

```elixir
defmodule MarketplaceBot.Sources.Source do
  @moduledoc """
  Behaviour for a Marketplace data source. Implementations fetch raw listings
  and normalize them to the internal listing map shape consumed by
  `MarketplaceBot.Listings.upsert_new/1`.

  The internal listing map has keys:
    :fb_id, :url, :title, :price_cents, :currency, :description,
    :city, :state, :lat, :lng, :images, :seller, :condition,
    :fb_created_at, :is_live, :is_sold, :is_pending
  """
  @callback fetch(opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
end
```

- [ ] **Step 9: Write a failing test for `Sources.Fake`**

Create `test/marketplace_bot/sources/fake_test.exs`:

```elixir
defmodule MarketplaceBot.Sources.FakeTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.Sources.Fake

  test "returns the listings passed via opts" do
    listings = [%{fb_id: "1", title: "Denon AVR-X3700H"}]
    assert {:ok, ^listings} = Fake.fetch(listings: listings)
  end

  test "defaults to an empty list" do
    assert {:ok, []} = Fake.fetch([])
  end
end
```

- [ ] **Step 10: Run the test to verify it fails**

Run: `mix test test/marketplace_bot/sources/fake_test.exs`
Expected: FAIL — `Fake` is undefined.

- [ ] **Step 11: Implement `Sources.Fake`**

Create `lib/marketplace_bot/sources/fake.ex`:

```elixir
defmodule MarketplaceBot.Sources.Fake do
  @moduledoc "Test/dev source that returns listings handed to it via opts."
  @behaviour MarketplaceBot.Sources.Source

  @impl true
  def fetch(opts), do: {:ok, Keyword.get(opts, :listings, [])}
end
```

- [ ] **Step 12: Set up the database and run the full suite**

```bash
mix ecto.create
mix ecto.migrate
MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate
mix compile --warnings-as-errors
mix test
```
Expected: PASS (Phoenix's generated tests + the Fake source test).

- [ ] **Step 13: Commit**

```bash
git add -A
git commit -m "Scaffold Phoenix app: SQLite, Oban, Req, Source behaviour + Fake"
```

---

### Task 2: Listings context, schema, and dedup

**Files:**
- Create: `priv/repo/migrations/*_create_listings.exs`
- Create: `lib/marketplace_bot/listings/listing.ex`
- Create: `lib/marketplace_bot/listings.ex`
- Test: `test/marketplace_bot/listings_test.exs`

**Interfaces:**
- Consumes: `MarketplaceBot.Repo`.
- Produces:
  - `MarketplaceBot.Listings.Listing` schema.
  - `MarketplaceBot.Listings.upsert_new(maps :: [map()]) :: {:ok, [Listing.t()]}` — inserts only listings whose `fb_id` is unseen, returns the newly-inserted structs.
  - `update_listing(Listing.t(), map()) :: {:ok, Listing.t()} | {:error, Changeset.t()}`
  - `set_status(Listing.t(), String.t()) :: {:ok, Listing.t()}`
  - `get_listing!(id) :: Listing.t()`
  - `list_matches(filters :: map()) :: [Listing.t()]`

- [ ] **Step 1: Write the migration**

Create the migration with `mix ecto.gen.migration create_listings`, then set its body:

```elixir
defmodule MarketplaceBot.Repo.Migrations.CreateListings do
  use Ecto.Migration

  def change do
    create table(:listings) do
      add :fb_id, :string, null: false
      add :url, :string
      add :title, :string
      add :price_cents, :integer
      add :currency, :string
      add :description, :text
      add :city, :string
      add :state, :string
      add :lat, :float
      add :lng, :float
      add :images, {:array, :string}, default: []
      add :seller, :string
      add :condition, :string
      add :fb_created_at, :utc_datetime
      add :is_live, :boolean
      add :is_sold, :boolean
      add :is_pending, :boolean
      add :is_receiver, :boolean, default: true, null: false
      add :model_id, references(:models, on_delete: :nilify_all)
      add :earc_verdict, :string
      add :status, :string, default: "new", null: false
      add :first_seen_at, :utc_datetime
      add :notified_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:listings, [:fb_id])
    create index(:listings, [:status])
    create index(:listings, [:earc_verdict])
  end
end
```

Note: the `models` table is created in Task 6. Move this migration's timestamp **after** the models migration, or create `models` first. Simplest: generate the `models` migration (Task 6 Step 1) before running `mix ecto.migrate`. Until then, comment out the `model_id` reference line and the `:model_id` column, then add them back in Task 6 via a follow-up migration. **Chosen approach:** create the `models` table migration now as part of Task 2 Step 1b so the reference resolves.

- [ ] **Step 1b: Create the `models` table migration now (schema/context come in Task 6)**

`mix ecto.gen.migration create_models`, body:

```elixir
defmodule MarketplaceBot.Repo.Migrations.CreateModels do
  use Ecto.Migration

  def change do
    create table(:models) do
      add :brand, :string
      add :model, :string
      add :key, :string, null: false
      add :verdict, :string, default: "unknown", null: false
      add :source, :string, default: "seed", null: false
      add :notes, :text
      timestamps(type: :utc_datetime)
    end

    create unique_index(:models, [:key])
  end
end
```

Ensure this migration's timestamp sorts **before** `create_listings` (rename the file so its leading timestamp is lower, or generate it first). Then:

```bash
mix ecto.migrate
MIX_ENV=test mix ecto.migrate
```

- [ ] **Step 2: Write the failing context test**

Create `test/marketplace_bot/listings_test.exs`:

```elixir
defmodule MarketplaceBot.ListingsTest do
  use MarketplaceBot.DataCase, async: false
  alias MarketplaceBot.Listings
  alias MarketplaceBot.Listings.Listing

  defp map(fb_id, attrs \\ %{}) do
    Map.merge(%{fb_id: fb_id, title: "Listing #{fb_id}", url: "u#{fb_id}"}, attrs)
  end

  test "upsert_new inserts unseen listings and returns them" do
    assert {:ok, [a, b]} = Listings.upsert_new([map("1"), map("2")])
    assert a.fb_id == "1" and b.fb_id == "2"
    assert a.first_seen_at != nil
  end

  test "upsert_new skips already-seen fb_ids" do
    {:ok, _} = Listings.upsert_new([map("1")])
    assert {:ok, [new]} = Listings.upsert_new([map("1"), map("2")])
    assert new.fb_id == "2"
    assert Repo.aggregate(Listing, :count) == 2
  end

  test "update_listing and set_status" do
    {:ok, [l]} = Listings.upsert_new([map("1")])
    {:ok, l} = Listings.update_listing(l, %{earc_verdict: "yes"})
    assert l.earc_verdict == "yes"
    {:ok, l} = Listings.set_status(l, "interested")
    assert l.status == "interested"
  end

  test "list_matches returns receiver listings, filtered by verdict" do
    {:ok, [l]} = Listings.upsert_new([map("1")])
    {:ok, _} = Listings.update_listing(l, %{is_receiver: true, earc_verdict: "yes"})
    assert [%Listing{fb_id: "1"}] = Listings.list_matches(%{verdict: "yes"})
    assert [] = Listings.list_matches(%{verdict: "no"})
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mix test test/marketplace_bot/listings_test.exs`
Expected: FAIL — `Listings` / `Listing` undefined.

- [ ] **Step 4: Implement the schema**

Create `lib/marketplace_bot/listings/listing.ex`:

```elixir
defmodule MarketplaceBot.Listings.Listing do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @cast_fields ~w(fb_id url title price_cents currency description city state lat lng
                  images seller condition fb_created_at is_live is_sold is_pending
                  is_receiver model_id earc_verdict status first_seen_at notified_at)a

  schema "listings" do
    field :fb_id, :string
    field :url, :string
    field :title, :string
    field :price_cents, :integer
    field :currency, :string
    field :description, :string
    field :city, :string
    field :state, :string
    field :lat, :float
    field :lng, :float
    field :images, {:array, :string}, default: []
    field :seller, :string
    field :condition, :string
    field :fb_created_at, :utc_datetime
    field :is_live, :boolean
    field :is_sold, :boolean
    field :is_pending, :boolean
    field :is_receiver, :boolean, default: true
    field :model_id, :id
    field :earc_verdict, :string
    field :status, :string, default: "new"
    field :first_seen_at, :utc_datetime
    field :notified_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(listing, attrs) do
    listing
    |> cast(attrs, @cast_fields)
    |> validate_required([:fb_id])
    |> unique_constraint(:fb_id)
  end
end
```

- [ ] **Step 5: Implement the context**

Create `lib/marketplace_bot/listings.ex`:

```elixir
defmodule MarketplaceBot.Listings do
  @moduledoc "Core listing domain: dedup, queries, status."
  import Ecto.Query
  alias MarketplaceBot.Repo
  alias MarketplaceBot.Listings.Listing

  @spec upsert_new([map()]) :: {:ok, [Listing.t()]}
  def upsert_new(maps) do
    incoming_ids = maps |> Enum.map(&to_string(&1[:fb_id] || &1["fb_id"])) |> Enum.uniq()

    existing =
      Repo.all(from l in Listing, where: l.fb_id in ^incoming_ids, select: l.fb_id)
      |> MapSet.new()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    new_maps =
      maps
      |> Enum.uniq_by(&to_string(&1[:fb_id] || &1["fb_id"]))
      |> Enum.reject(&MapSet.member?(existing, to_string(&1[:fb_id] || &1["fb_id"])))

    inserted =
      for m <- new_maps do
        attrs = Map.put(normalize_keys(m), :first_seen_at, now)
        {:ok, listing} = %Listing{} |> Listing.changeset(attrs) |> Repo.insert()
        listing
      end

    {:ok, inserted}
  end

  defp normalize_keys(m) do
    Map.new(m, fn {k, v} -> {to_string(k) |> String.to_atom(), v} end)
  end

  @spec update_listing(Listing.t(), map()) :: {:ok, Listing.t()} | {:error, Ecto.Changeset.t()}
  def update_listing(%Listing{} = listing, attrs),
    do: listing |> Listing.changeset(attrs) |> Repo.update()

  @spec set_status(Listing.t(), String.t()) :: {:ok, Listing.t()} | {:error, Ecto.Changeset.t()}
  def set_status(%Listing{} = listing, status), do: update_listing(listing, %{status: status})

  @spec get_listing!(term()) :: Listing.t()
  def get_listing!(id), do: Repo.get!(Listing, id)

  @spec list_matches(map()) :: [Listing.t()]
  def list_matches(filters \\ %{}) do
    Listing
    |> where([l], l.is_receiver == true)
    |> filter_verdict(filters[:verdict])
    |> filter_status(filters[:status])
    |> order_by([l], desc: l.first_seen_at)
    |> Repo.all()
  end

  defp filter_verdict(q, nil), do: q
  defp filter_verdict(q, v), do: where(q, [l], l.earc_verdict == ^v)
  defp filter_status(q, nil), do: where(q, [l], l.status != "dismissed")
  defp filter_status(q, s), do: where(q, [l], l.status == ^s)
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/marketplace_bot/listings_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Add Listings context + schema with fb_id dedup"
```

---

### Task 3: Apify source (normalize + fetch)

**Files:**
- Create: `lib/marketplace_bot/sources/apify.ex`
- Test: `test/marketplace_bot/sources/apify_test.exs`
- Test fixture: `test/support/fixtures/apify_item.json`

**Interfaces:**
- Consumes: `:search` config; `Req` (with `req_options` seam).
- Produces:
  - `MarketplaceBot.Sources.Apify.normalize(item :: map()) :: map()` (pure; actor JSON item → internal listing map).
  - `MarketplaceBot.Sources.Apify.fetch(opts) :: {:ok, [map()]} | {:error, term()}` (calls the actor's `run-sync-get-dataset-items` endpoint, maps results through `normalize/1`).

- [ ] **Step 1: Add a representative Apify item fixture**

Create `test/support/fixtures/apify_item.json` (shape per the spec's documented actor output; will be reconciled against real output in Task 13):

```json
{
  "id": "987654321",
  "url": "https://www.facebook.com/marketplace/item/987654321",
  "title": "Denon AVR-X3700H 9.2 Receiver",
  "price": {"amount": "450", "currency": "USD", "formatted": "$450"},
  "description": "Excellent condition, supports 8K and eARC.",
  "location": {"city": "Victoria", "state": "TX", "latitude": 28.8, "longitude": -96.9},
  "images": ["https://scontent.example/a.jpg", "https://scontent.example/b.jpg"],
  "seller": "Jane D.",
  "condition": "Used - Like New",
  "creation_time": 1717000000,
  "is_live": true,
  "is_sold": false,
  "is_pending": false
}
```

- [ ] **Step 2: Write the failing `normalize/1` test**

Create `test/marketplace_bot/sources/apify_test.exs`:

```elixir
defmodule MarketplaceBot.Sources.ApifyTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.Sources.Apify

  setup do
    item =
      File.read!("test/support/fixtures/apify_item.json") |> Jason.decode!()

    %{item: item}
  end

  test "normalize maps actor JSON to the internal listing map", %{item: item} do
    n = Apify.normalize(item)
    assert n.fb_id == "987654321"
    assert n.title =~ "Denon"
    assert n.price_cents == 45_000
    assert n.currency == "USD"
    assert n.city == "Victoria"
    assert n.state == "TX"
    assert n.images == ["https://scontent.example/a.jpg", "https://scontent.example/b.jpg"]
    assert %DateTime{} = n.fb_created_at
    assert n.is_live == true
  end

  test "normalize tolerates missing fields" do
    n = Apify.normalize(%{"id" => "1"})
    assert n.fb_id == "1"
    assert n.price_cents == nil
    assert n.images == []
  end

  test "fetch calls the actor endpoint and returns normalized listings", %{item: item} do
    Req.Test.stub(MarketplaceBot.Sources.Apify, fn conn ->
      Req.Test.json(conn, [item])
    end)

    assert {:ok, [listing]} =
             Apify.fetch(
               token: "t",
               req_options: [plug: {Req.Test, MarketplaceBot.Sources.Apify}]
             )

    assert listing.fb_id == "987654321"
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mix test test/marketplace_bot/sources/apify_test.exs`
Expected: FAIL — `Apify` undefined.

- [ ] **Step 4: Implement `Apify`**

Create `lib/marketplace_bot/sources/apify.ex`:

```elixir
defmodule MarketplaceBot.Sources.Apify do
  @moduledoc """
  Fetches Marketplace listings via the Apify actor
  `calm_builder/facebook-marketplace-scraper` (run-sync-get-dataset-items).
  Swappable behind `MarketplaceBot.Sources.Source`.
  """
  @behaviour MarketplaceBot.Sources.Source

  @actor "calm_builder~facebook-marketplace-scraper"
  @endpoint "https://api.apify.com/v2/acts/#{@actor}/run-sync-get-dataset-items"

  @impl true
  def fetch(opts \\ []) do
    token = opts[:token] || System.get_env("APIFY_TOKEN")
    search = Application.get_env(:marketplace_bot, :search, [])
    max_listings = opts[:max_listings] || get_in(search, [:max_listings, :daily]) || 250
    url = opts[:search_url] || search[:url]

    body = %{
      startUrls: [%{url: url}],
      maxListings: max_listings,
      fetchDetails: true,
      getNewItems: true
    }

    req_opts =
      [
        method: :post,
        url: @endpoint,
        params: [token: token],
        json: body,
        receive_timeout: 120_000
      ]
      |> Keyword.merge(opts[:req_options] || [])

    case Req.request(req_opts) do
      {:ok, %{status: 200, body: items}} when is_list(items) ->
        {:ok, Enum.map(items, &normalize/1)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:apify_http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Normalize one actor JSON item to the internal listing map."
  @spec normalize(map()) :: map()
  def normalize(item) do
    %{
      fb_id: to_string(item["id"]),
      url: item["url"],
      title: item["title"],
      price_cents: price_cents(item["price"]),
      currency: get_in(item, ["price", "currency"]),
      description: item["description"],
      city: get_in(item, ["location", "city"]),
      state: get_in(item, ["location", "state"]),
      lat: get_in(item, ["location", "latitude"]),
      lng: get_in(item, ["location", "longitude"]),
      images: item["images"] || [],
      seller: item["seller"],
      condition: item["condition"],
      fb_created_at: to_datetime(item["creation_time"]),
      is_live: item["is_live"],
      is_sold: item["is_sold"],
      is_pending: item["is_pending"]
    }
  end

  defp price_cents(%{"amount" => amount}) when is_binary(amount) do
    case Float.parse(amount) do
      {f, _} -> round(f * 100)
      :error -> nil
    end
  end

  defp price_cents(%{"amount" => amount}) when is_number(amount), do: round(amount * 100)
  defp price_cents(_), do: nil

  defp to_datetime(ts) when is_integer(ts), do: DateTime.from_unix!(ts)
  defp to_datetime(_), do: nil
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/marketplace_bot/sources/apify_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add Apify source: normalize + fetch via Req (run-sync-get-dataset-items)"
```

---

### Task 4: Receivers extractor (negative-keyword prefilter + regex)

**Files:**
- Create: `lib/marketplace_bot/receivers/extractor.ex`
- Test: `test/marketplace_bot/receivers/extractor_test.exs`

**Interfaces:**
- Produces (pure):
  - `MarketplaceBot.Receivers.Extractor.likely_non_av?(text :: String.t()) :: boolean()`
  - `MarketplaceBot.Receivers.Extractor.extract(text :: String.t()) :: {:ok, brand :: String.t(), model :: String.t()} | :unknown`

- [ ] **Step 1: Write the failing test**

Create `test/marketplace_bot/receivers/extractor_test.exs`:

```elixir
defmodule MarketplaceBot.Receivers.ExtractorTest do
  use ExUnit.Case, async: true
  alias MarketplaceBot.Receivers.Extractor

  test "negative keywords flag obvious non-AV listings" do
    assert Extractor.likely_non_av?("Trailer hitch receiver 2 inch")
    assert Extractor.likely_non_av?("DirecTV satellite receiver")
    refute Extractor.likely_non_av?("Denon AVR-X3700H home theater receiver")
  end

  test "regex extracts known brand/model patterns" do
    assert {:ok, "Denon", "AVR-X3700H"} = Extractor.extract("Denon AVR-X3700H 9.2 receiver")
    assert {:ok, "Yamaha", "RX-V685"} = Extractor.extract("Yamaha RX-V685 like new")
    assert {:ok, "Onkyo", "TX-NR696"} = Extractor.extract("ONKYO tx-nr696 atmos")
    assert {:ok, "Marantz", "SR6015"} = Extractor.extract("Marantz SR6015")
    assert {:ok, "Pioneer", "VSX-1131"} = Extractor.extract("Pioneer VSX-1131")
  end

  test "extract returns :unknown when no pattern matches" do
    assert :unknown = Extractor.extract("vintage stereo receiver, works great")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/marketplace_bot/receivers/extractor_test.exs`
Expected: FAIL — `Extractor` undefined.

- [ ] **Step 3: Implement the extractor**

Create `lib/marketplace_bot/receivers/extractor.ex`:

```elixir
defmodule MarketplaceBot.Receivers.Extractor do
  @moduledoc """
  Cheap, pure first passes for the classify/extract step:
  a negative-keyword prefilter and a regex fast-path for common AV brands.
  Anything not handled here falls through to the LLM (see Receivers).
  """

  @negative ~w(hitch trailer satellite directv dish gps antenna radar fuel
               drone vape baby walkie cb)

  # {brand, regex}. Regex captures the full model token in group 1.
  @patterns [
    {"Denon", ~r/\b(AVR[- ]?X?\d{3,4}H?)\b/i},
    {"Marantz", ~r/\b((?:SR|NR)\d{3,4})\b/i},
    {"Marantz", ~r/\b(Cinema\s?\d{1,2})\b/i},
    {"Yamaha", ~r/\b(RX[- ]?[VA]\d{3,4}[A-Z]?)\b/i},
    {"Onkyo", ~r/\b(TX[- ]?(?:NR|RZ)\d{2,4})\b/i},
    {"Pioneer", ~r/\b(VSX[- ]?\d{3,4})\b/i},
    {"Sony", ~r/\b(STR[- ]?(?:DH|DN|AN)\d{3,4})\b/i},
    {"Anthem", ~r/\b(MRX\s?\d{3,4})\b/i},
    {"NAD", ~r/\b(T\s?7\d{2,3})\b/i},
    {"Integra", ~r/\b(DRX[- ]?\d{1,2}\.\d)\b/i},
    {"Arcam", ~r/\b(AVR\d{2,3})\b/i}
  ]

  @spec likely_non_av?(String.t()) :: boolean()
  def likely_non_av?(text) when is_binary(text) do
    down = String.downcase(text)
    Enum.any?(@negative, &String.contains?(down, &1))
  end

  def likely_non_av?(_), do: false

  @spec extract(String.t()) :: {:ok, String.t(), String.t()} | :unknown
  def extract(text) when is_binary(text) do
    Enum.find_value(@patterns, :unknown, fn {brand, re} ->
      case Regex.run(re, text, capture: :all_but_first) do
        [model | _] -> {:ok, brand, normalize_model(model)}
        _ -> nil
      end
    end)
  end

  def extract(_), do: :unknown

  # Uppercase, collapse internal spaces, ensure a hyphen after the alpha prefix.
  defp normalize_model(model) do
    model
    |> String.upcase()
    |> String.replace(~r/\s+/, "")
    |> insert_hyphen()
  end

  defp insert_hyphen(m) do
    cond do
      String.contains?(m, "-") -> m
      Regex.match?(~r/^[A-Z]+\d/, m) -> Regex.replace(~r/^([A-Z]+)(\d.*)$/, m, "\\1-\\2")
      true -> m
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/marketplace_bot/receivers/extractor_test.exs`
Expected: PASS. If a normalization assertion fails (e.g. `RX-V685` vs `RXV685`), adjust `normalize_model/1` and the test fixture together so they agree — the canonical form is "alpha prefix, hyphen, digits".

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add Receivers.Extractor: negative-keyword prefilter + brand regex"
```

---

### Task 5: DeepSeek client + Receivers LLM fallback (classify + extract)

**Files:**
- Create: `lib/marketplace_bot/deepseek.ex`
- Create: `lib/marketplace_bot/receivers/llm.ex`
- Create: `test/support/stubs.ex`
- Test: `test/marketplace_bot/receivers/llm_test.exs`

**Interfaces:**
- Consumes: `Req` (with `req_options` seam), `DEEPSEEK_API_KEY`, `:llm` config.
- Produces:
  - `MarketplaceBot.DeepSeek.chat(messages :: [map()], model :: String.t(), opts :: keyword()) :: {:ok, content :: String.t()} | {:error, term()}` — OpenAI-compatible chat-completions call; `response_format: {type: "json_object"}`; returns the assistant message string (expected to be a JSON object).
  - `@callback classify_extract(listing :: map(), opts :: keyword()) :: {:ok, %{is_av_receiver: boolean(), brand: String.t() | nil, model: String.t() | nil}} | {:error, term()}` (behaviour `MarketplaceBot.Receivers.LLM.Behaviour`)
  - `MarketplaceBot.Receivers.LLM` implementing it via `DeepSeek.chat/3` on `deepseek-v4-flash`.

> **Provider note:** DeepSeek is OpenAI-compatible. We use `response_format: {"type": "json_object"}` (not json_schema — don't assume schema support) and describe the JSON shape in the prompt. Verify the exact base URL / model IDs / JSON-mode behavior against current DeepSeek docs when wiring the first real call (Task 13).

- [ ] **Step 1: Write the failing test (stub DeepSeek via Req.Test)**

Create `test/marketplace_bot/receivers/llm_test.exs`:

```elixir
defmodule MarketplaceBot.Receivers.LLMTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.Receivers.LLM

  # DeepSeek = OpenAI-compatible: assistant content is choices[0].message.content
  defp stub(content_json) do
    Req.Test.stub(MarketplaceBot.DeepSeek, fn conn ->
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => content_json}}]})
    end)
  end

  test "parses a structured classify/extract response" do
    stub(~s({"is_av_receiver": true, "brand": "Sony", "model": "STR-DN1080"}))

    assert {:ok, %{is_av_receiver: true, brand: "Sony", model: "STR-DN1080"}} =
             LLM.classify_extract(
               %{title: "Sony surround receiver", description: "model STR-DN1080"},
               api_key: "k",
               req_options: [plug: {Req.Test, MarketplaceBot.DeepSeek}]
             )
  end

  test "returns is_av_receiver false for non-AV items" do
    stub(~s({"is_av_receiver": false}))

    assert {:ok, %{is_av_receiver: false}} =
             LLM.classify_extract(%{title: "wifi receiver dongle"},
               api_key: "k",
               req_options: [plug: {Req.Test, MarketplaceBot.DeepSeek}]
             )
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/marketplace_bot/receivers/llm_test.exs`
Expected: FAIL — `LLM` / `DeepSeek` undefined.

- [ ] **Step 3: Implement the DeepSeek client**

Create `lib/marketplace_bot/deepseek.ex`:

```elixir
defmodule MarketplaceBot.DeepSeek do
  @moduledoc """
  Thin DeepSeek (OpenAI-compatible) chat-completions client over Req.
  Forces JSON-object output. Returns the assistant message content string.
  """

  @spec chat([map()], String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(messages, model, opts \\ []) do
    cfg = Application.get_env(:marketplace_bot, :llm, [])
    api_key = opts[:api_key] || System.get_env("DEEPSEEK_API_KEY")
    base = opts[:base_url] || cfg[:deepseek_base_url] || "https://api.deepseek.com/v1"

    body =
      %{
        model: model,
        messages: messages,
        response_format: %{type: "json_object"}
      }
      |> Map.merge(opts[:body_extra] || %{})

    req_opts =
      [
        method: :post,
        url: base <> "/chat/completions",
        headers: [{"authorization", "Bearer #{api_key}"}],
        json: body,
        receive_timeout: opts[:receive_timeout] || 60_000
      ]
      |> Keyword.merge(opts[:req_options] || [])

    case Req.request(req_opts) do
      {:ok, %{status: 200, body: resp}} -> first_content(resp)
      {:ok, %{status: status, body: body}} -> {:error, {:deepseek_http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp first_content(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content),
       do: {:ok, content}

  defp first_content(_), do: {:error, :bad_response}
end
```

- [ ] **Step 4: Implement the behaviour + Receivers.LLM**

Create `lib/marketplace_bot/receivers/llm.ex`:

```elixir
defmodule MarketplaceBot.Receivers.LLM.Behaviour do
  @callback classify_extract(listing :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
end

defmodule MarketplaceBot.Receivers.LLM do
  @moduledoc "DeepSeek-backed classify + model-extract for ambiguous listings (deepseek-v4-flash)."
  @behaviour MarketplaceBot.Receivers.LLM.Behaviour
  alias MarketplaceBot.DeepSeek

  @impl true
  def classify_extract(listing, opts \\ []) do
    cfg = Application.get_env(:marketplace_bot, :llm, [])
    model = opts[:model] || cfg[:classify_model] || "deepseek-v4-flash"

    prompt = """
    Decide whether this Facebook Marketplace listing is a home-theater A/V receiver
    (a multi-channel surround-sound amplifier — NOT a trailer hitch, satellite/cable
    box, radio, wireless dongle, etc.). If it is, extract the brand and model.

    Title: #{listing[:title] || listing["title"]}
    Description: #{listing[:description] || listing["description"]}

    Respond with ONLY a JSON object of the exact form:
    {"is_av_receiver": true or false, "brand": string or null, "model": string or null}
    """

    messages = [%{role: "user", content: prompt}]

    with {:ok, json} <- DeepSeek.chat(messages, model, opts),
         {:ok, parsed} <- Jason.decode(json) do
      {:ok,
       %{
         is_av_receiver: parsed["is_av_receiver"] == true,
         brand: parsed["brand"],
         model: parsed["model"]
       }}
    end
  end
end
```

- [ ] **Step 5: Add the test stub module referenced in `config/test.exs`**

Create `test/support/stubs.ex`:

```elixir
defmodule MarketplaceBot.Receivers.LLMStub do
  @behaviour MarketplaceBot.Receivers.LLM.Behaviour
  @impl true
  def classify_extract(_listing, _opts \\ []), do: {:ok, %{is_av_receiver: false, brand: nil, model: nil}}
end
```

(More stubs are added to this file in later tasks.)

- [ ] **Step 6: Run to verify it passes**

Run: `mix test test/marketplace_bot/receivers/llm_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Add DeepSeek client + Receivers.LLM classify/extract (deepseek-v4-flash)"
```

---

### Task 6: eARC model schema, context, and seeds

**Files:**
- Create: `lib/marketplace_bot/earc/model.ex`
- Create: `lib/marketplace_bot/earc.ex`
- Create: `priv/repo/seeds/earc_seed.exs` (or a data module) + wire into `priv/repo/seeds.exs`
- Test: `test/marketplace_bot/earc_test.exs`

**Interfaces:**
- Consumes: `MarketplaceBot.Repo`.
- Produces:
  - `MarketplaceBot.Earc.Model` schema (table `models` from Task 2 Step 1b).
  - `MarketplaceBot.Earc.normalize_key(brand, model) :: String.t()`
  - `MarketplaceBot.Earc.find_by_key(key) :: Model.t() | nil`
  - `MarketplaceBot.Earc.upsert_model(brand, model, attrs) :: {:ok, Model.t()}` (find_or_create by key, apply attrs)
  - `MarketplaceBot.Earc.set_user_verdict(Model.t(), verdict) :: {:ok, Model.t()}`

- [ ] **Step 1: Write the failing test**

Create `test/marketplace_bot/earc_test.exs`:

```elixir
defmodule MarketplaceBot.EarcTest do
  use MarketplaceBot.DataCase, async: false
  alias MarketplaceBot.Earc
  alias MarketplaceBot.Earc.Model

  test "normalize_key is case/space insensitive" do
    assert Earc.normalize_key("Denon", "AVR-X3700H") == Earc.normalize_key("denon", " avr-x3700h ")
  end

  test "upsert_model creates then updates by key" do
    {:ok, m} = Earc.upsert_model("Denon", "AVR-X3700H", %{verdict: "yes", source: "seed"})
    assert %Model{verdict: "yes", source: "seed"} = m
    {:ok, m2} = Earc.upsert_model("denon", "avr-x3700h", %{verdict: "unknown", source: "llm"})
    assert m2.id == m.id
    assert m2.verdict == "unknown"
  end

  test "find_by_key" do
    {:ok, _} = Earc.upsert_model("Yamaha", "RX-V685", %{verdict: "no"})
    assert %Model{verdict: "no"} = Earc.find_by_key(Earc.normalize_key("Yamaha", "RX-V685"))
    assert is_nil(Earc.find_by_key("nope"))
  end

  test "set_user_verdict marks source user" do
    {:ok, m} = Earc.upsert_model("Sony", "STR-DN1080", %{verdict: "unknown", source: "llm"})
    {:ok, m} = Earc.set_user_verdict(m, "yes")
    assert m.verdict == "yes" and m.source == "user"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/marketplace_bot/earc_test.exs`
Expected: FAIL — `Earc` / `Earc.Model` undefined.

- [ ] **Step 3: Implement the schema**

Create `lib/marketplace_bot/earc/model.ex`:

```elixir
defmodule MarketplaceBot.Earc.Model do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "models" do
    field :brand, :string
    field :model, :string
    field :key, :string
    field :verdict, :string, default: "unknown"
    field :source, :string, default: "seed"
    field :notes, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(model, attrs) do
    model
    |> cast(attrs, [:brand, :model, :key, :verdict, :source, :notes])
    |> validate_required([:key])
    |> validate_inclusion(:verdict, ~w(yes no unknown))
    |> validate_inclusion(:source, ~w(seed llm user))
    |> unique_constraint(:key)
  end
end
```

- [ ] **Step 4: Implement the context**

Create `lib/marketplace_bot/earc.ex`:

```elixir
defmodule MarketplaceBot.Earc do
  @moduledoc "eARC resolver table: normalized model keys → yes/no/unknown verdicts."
  import Ecto.Query
  alias MarketplaceBot.Repo
  alias MarketplaceBot.Earc.Model

  @spec normalize_key(String.t() | nil, String.t() | nil) :: String.t()
  def normalize_key(brand, model) do
    [brand, model]
    |> Enum.map(&((&1 || "") |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()))
    |> Enum.join(" ")
    |> String.trim()
  end

  @spec find_by_key(String.t()) :: Model.t() | nil
  def find_by_key(key), do: Repo.get_by(Model, key: key)

  @spec upsert_model(String.t() | nil, String.t() | nil, map()) :: {:ok, Model.t()}
  def upsert_model(brand, model, attrs \\ %{}) do
    key = normalize_key(brand, model)
    base = find_by_key(key) || %Model{}

    {:ok, _} =
      base
      |> Model.changeset(Map.merge(%{brand: brand, model: model, key: key}, attrs))
      |> Repo.insert_or_update()
  end

  @spec set_user_verdict(Model.t(), String.t()) :: {:ok, Model.t()}
  def set_user_verdict(%Model{} = m, verdict) do
    m |> Model.changeset(%{verdict: verdict, source: "user"}) |> Repo.update()
  end

  @doc "All models, for the curation list view."
  def list_models, do: Repo.all(from m in Model, order_by: [asc: m.brand, asc: m.model])
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/marketplace_bot/earc_test.exs`
Expected: PASS.

- [ ] **Step 6: Add a verified seed list and wire it into `priv/repo/seeds.exs`**

Create `priv/repo/seeds/earc_seed.exs` — **VERIFY each entry before trusting; these are illustrative.** Keep entries you have confirmed; mark uncertain ones `unknown`.

```elixir
# Verified eARC seed entries. eARC arrived ~2019, standard in HDMI-2.1 lineups (2020+).
[
  {"Denon", "AVR-X3700H", "yes"},
  {"Denon", "AVR-X3800H", "yes"},
  {"Yamaha", "RX-V6A", "yes"},
  {"Yamaha", "RX-A2A", "yes"},
  {"Marantz", "SR6015", "yes"},
  {"Yamaha", "RX-V685", "no"},
  {"Onkyo", "TX-NR696", "no"}
]
```

Append to `priv/repo/seeds.exs`:

```elixir
for {brand, model, verdict} <- Code.eval_file("priv/repo/seeds/earc_seed.exs") |> elem(0) do
  {:ok, _} = MarketplaceBot.Earc.upsert_model(brand, model, %{verdict: verdict, source: "seed"})
end
```

- [ ] **Step 7: Run the seeds and verify**

```bash
mix run priv/repo/seeds.exs
mix run -e 'IO.inspect(length(MarketplaceBot.Earc.list_models()))'
```
Expected: prints the count of seeded models.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add Earc model schema + context + verified seed table"
```

---

### Task 7: eARC LLM lookup (Kagi research + DeepSeek verdict) + resolver orchestration

**Files:**
- Create: `lib/marketplace_bot/kagi.ex`
- Create: `lib/marketplace_bot/earc/llm.ex`
- Modify: `lib/marketplace_bot/earc.ex` (add `resolve_with_fallback/3`)
- Modify: `test/support/stubs.ex` (add `Earc.LLMStub`)
- Test: `test/marketplace_bot/earc/llm_test.exs`, extend `test/marketplace_bot/earc_test.exs`

**Interfaces:**
- Produces:
  - `MarketplaceBot.Kagi.fastgpt(query :: String.t(), opts :: keyword()) :: {:ok, %{answer: String.t(), references: list()}} | {:error, term()}`
  - `MarketplaceBot.Earc.LLM.Behaviour` — `@callback lookup(brand, model, opts) :: {:ok, "yes" | "no" | "unknown"} | {:error, term()}`
  - `MarketplaceBot.Earc.LLM` — Kagi FastGPT researches the model, then `deepseek-v4-pro` (via `DeepSeek.chat/3`) produces the verdict.
  - `MarketplaceBot.Earc.resolve_with_fallback(brand, model, opts) :: {:ok, Model.t()}` — table hit (or user source) returns immediately; otherwise calls the configured LLM, caches the verdict back as `source: "llm"`, returns the model row.

> **Provider note:** No server-side web search here — we retrieve-then-reason. Kagi FastGPT (`POST .../v0/fastgpt`, `Authorization: Bot ...`) returns a researched answer; `deepseek-v4-pro` converts it to a strict verdict. **Verify the Kagi response shape (`data.output` / `data.references`) and DeepSeek model/JSON-mode on the first real call (Task 13).** Kagi uses its own key (`opts[:kagi_api_key]` / `KAGI_API_KEY`); DeepSeek uses `opts[:api_key]` / `DEEPSEEK_API_KEY` — distinct so a shared `opts` doesn't cross-wire them.

- [ ] **Step 1: Write the failing LLM test (one Req.Test stub, branched by path)**

Create `test/marketplace_bot/earc/llm_test.exs`:

```elixir
defmodule MarketplaceBot.Earc.LLMTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.Earc.LLM

  test "researches via Kagi then derives a verdict via DeepSeek" do
    # Both clients route through the same plug; branch on the request path.
    Req.Test.stub(MarketplaceBot.Earc.LLM, fn conn ->
      cond do
        String.contains?(conn.request_path, "fastgpt") ->
          Req.Test.json(conn, %{
            "data" => %{
              "output" => "The Denon AVR-X3700H supports HDMI eARC per the spec sheet.",
              "references" => []
            }
          })

        String.contains?(conn.request_path, "chat/completions") ->
          Req.Test.json(conn, %{
            "choices" => [%{"message" => %{"content" => ~s({"verdict": "yes"})}}]
          })
      end
    end)

    assert {:ok, "yes"} =
             LLM.lookup("Denon", "AVR-X3700H",
               req_options: [plug: {Req.Test, MarketplaceBot.Earc.LLM}]
             )
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/marketplace_bot/earc/llm_test.exs`
Expected: FAIL — `Earc.LLM` / `Kagi` undefined.

- [ ] **Step 3a: Implement the Kagi client**

Create `lib/marketplace_bot/kagi.ex`:

```elixir
defmodule MarketplaceBot.Kagi do
  @moduledoc "Thin Kagi FastGPT client over Req. Returns the researched answer + references."

  @spec fastgpt(String.t(), keyword()) ::
          {:ok, %{answer: String.t(), references: list()}} | {:error, term()}
  def fastgpt(query, opts \\ []) do
    cfg = Application.get_env(:marketplace_bot, :llm, [])
    api_key = opts[:kagi_api_key] || System.get_env("KAGI_API_KEY")
    url = opts[:kagi_fastgpt_url] || cfg[:kagi_fastgpt_url] || "https://kagi.com/api/v0/fastgpt"

    req_opts =
      [
        method: :post,
        url: url,
        headers: [{"authorization", "Bot #{api_key}"}],
        json: %{query: query},
        receive_timeout: opts[:receive_timeout] || 60_000
      ]
      |> Keyword.merge(opts[:req_options] || [])

    case Req.request(req_opts) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        {:ok, %{answer: data["output"] || "", references: data["references"] || []}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:kagi_http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

- [ ] **Step 3b: Implement `Earc.LLM` (Kagi research → DeepSeek verdict)**

Create `lib/marketplace_bot/earc/llm.ex`:

```elixir
defmodule MarketplaceBot.Earc.LLM.Behaviour do
  @callback lookup(brand :: String.t() | nil, model :: String.t() | nil, opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end

defmodule MarketplaceBot.Earc.LLM do
  @moduledoc """
  eARC lookup: Kagi FastGPT researches the model, then deepseek-v4-pro converts
  the research into a "yes" / "no" / "unknown" verdict.
  """
  @behaviour MarketplaceBot.Earc.LLM.Behaviour
  alias MarketplaceBot.{Kagi, DeepSeek}

  @impl true
  def lookup(brand, model, opts \\ []) do
    cfg = Application.get_env(:marketplace_bot, :llm, [])
    deepseek_model = opts[:model] || cfg[:earc_model] || "deepseek-v4-pro"

    research =
      case Kagi.fastgpt(
             ~s(Does the AV receiver "#{brand} #{model}" support HDMI eARC (enhanced ARC)? Cite manufacturer specs.),
             opts
           ) do
        {:ok, %{answer: answer}} -> answer
        {:error, _} -> ""
      end

    prompt = """
    Based on the research below, decide whether the AV receiver "#{brand} #{model}"
    supports HDMI eARC (enhanced ARC — NOT plain ARC). eARC arrived ~2019 and became
    standard in HDMI-2.1 lineups (2020+). Answer "yes" only if eARC is confirmed,
    "no" if confirmed absent, "unknown" if the research does not settle it.

    Research:
    #{research}

    Respond with ONLY a JSON object: {"verdict": "yes" or "no" or "unknown"}
    """

    with {:ok, json} <- DeepSeek.chat([%{role: "user", content: prompt}], deepseek_model, opts),
         {:ok, %{"verdict" => v}} when v in ["yes", "no", "unknown"] <- Jason.decode(json) do
      {:ok, v}
    else
      {:error, _} = err -> err
      _ -> {:ok, "unknown"}
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/marketplace_bot/earc/llm_test.exs`
Expected: PASS.

- [ ] **Step 5: Add the resolver orchestration test**

Append to `test/marketplace_bot/earc_test.exs`:

```elixir
  defmodule YesLLM do
    @behaviour MarketplaceBot.Earc.LLM.Behaviour
    @impl true
    def lookup(_b, _m, _o \\ []), do: {:ok, "yes"}
  end

  test "resolve_with_fallback returns a table hit without calling the LLM" do
    {:ok, _} = Earc.upsert_model("Denon", "AVR-X3700H", %{verdict: "yes", source: "seed"})
    {:ok, m} = Earc.resolve_with_fallback("Denon", "AVR-X3700H", llm: __MODULE__.YesLLM)
    assert m.verdict == "yes" and m.source == "seed"
  end

  test "resolve_with_fallback calls the LLM on a miss and caches as llm" do
    {:ok, m} = Earc.resolve_with_fallback("Onkyo", "TX-RZ50", llm: __MODULE__.YesLLM)
    assert m.verdict == "yes" and m.source == "llm"
    # Cached: a second call still reads the row (not re-resolved here)
    assert Earc.find_by_key(Earc.normalize_key("Onkyo", "TX-RZ50")).source == "llm"
  end

  test "resolve_with_fallback never overwrites a user verdict" do
    {:ok, m} = Earc.upsert_model("Sony", "STR-DN1080", %{verdict: "no", source: "user"})
    {:ok, m2} = Earc.resolve_with_fallback("Sony", "STR-DN1080", llm: __MODULE__.YesLLM)
    assert m2.id == m.id and m2.verdict == "no" and m2.source == "user"
  end
```

- [ ] **Step 6: Run to verify the new tests fail**

Run: `mix test test/marketplace_bot/earc_test.exs`
Expected: FAIL — `resolve_with_fallback/3` undefined.

- [ ] **Step 7: Implement `resolve_with_fallback/3`**

Add to `lib/marketplace_bot/earc.ex`:

```elixir
  @doc """
  Resolve eARC for a brand/model. Table is source of truth; user verdicts are
  authoritative. On a miss or a non-user "unknown", call the configured LLM and
  cache the result back as source "llm".
  """
  @spec resolve_with_fallback(String.t() | nil, String.t() | nil, keyword()) :: {:ok, Model.t()}
  def resolve_with_fallback(brand, model, opts \\ []) do
    llm = opts[:llm] || Application.get_env(:marketplace_bot, :earc_llm)
    key = normalize_key(brand, model)

    case find_by_key(key) do
      %Model{source: "user"} = m ->
        {:ok, m}

      %Model{verdict: v} = m when v in ["yes", "no"] ->
        {:ok, m}

      _ ->
        verdict =
          case llm.lookup(brand, model, opts) do
            {:ok, v} -> v
            {:error, _} -> "unknown"
          end

        upsert_model(brand, model, %{verdict: verdict, source: "llm"})
    end
  end
```

- [ ] **Step 8: Add the `Earc.LLMStub` referenced by `config/test.exs`**

Append to `test/support/stubs.ex`:

```elixir
defmodule MarketplaceBot.Earc.LLMStub do
  @behaviour MarketplaceBot.Earc.LLM.Behaviour
  @impl true
  def lookup(_brand, _model, _opts \\ []), do: {:ok, "unknown"}
end
```

- [ ] **Step 9: Run to verify it passes**

Run: `mix test test/marketplace_bot/earc_test.exs test/marketplace_bot/earc/llm_test.exs`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "Add Kagi client + Earc.LLM (Kagi research → deepseek-v4-pro) + resolve_with_fallback"
```

---

### Task 8: Runs schema + context

**Files:**
- Create: `priv/repo/migrations/*_create_runs.exs`
- Create: `lib/marketplace_bot/runs/run.ex`, `lib/marketplace_bot/runs.ex`
- Test: `test/marketplace_bot/runs_test.exs`

**Interfaces:**
- Produces:
  - `MarketplaceBot.Runs.record(attrs :: map()) :: {:ok, Run.t()}` with keys `:started_at, :finished_at, :fetched, :new, :matched, :errors`.
  - `MarketplaceBot.Runs.list_recent(limit) :: [Run.t()]`

- [ ] **Step 1: Migration**

`mix ecto.gen.migration create_runs`, body:

```elixir
defmodule MarketplaceBot.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    create table(:runs) do
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      add :fetched, :integer, default: 0
      add :new, :integer, default: 0
      add :matched, :integer, default: 0
      add :errors, :map, default: %{}
      timestamps(type: :utc_datetime)
    end
  end
end
```

```bash
mix ecto.migrate && MIX_ENV=test mix ecto.migrate
```

- [ ] **Step 2: Failing test**

Create `test/marketplace_bot/runs_test.exs`:

```elixir
defmodule MarketplaceBot.RunsTest do
  use MarketplaceBot.DataCase, async: false
  alias MarketplaceBot.Runs

  test "record and list_recent" do
    {:ok, run} = Runs.record(%{fetched: 10, new: 3, matched: 1, errors: %{}})
    assert run.fetched == 10
    assert [%{matched: 1}] = Runs.list_recent(5)
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mix test test/marketplace_bot/runs_test.exs`
Expected: FAIL — `Runs` undefined.

- [ ] **Step 4: Implement schema + context**

Create `lib/marketplace_bot/runs/run.ex`:

```elixir
defmodule MarketplaceBot.Runs.Run do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "runs" do
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :fetched, :integer, default: 0
    field :new, :integer, default: 0
    field :matched, :integer, default: 0
    field :errors, :map, default: %{}
    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs),
    do: cast(run, attrs, [:started_at, :finished_at, :fetched, :new, :matched, :errors])
end
```

Create `lib/marketplace_bot/runs.ex`:

```elixir
defmodule MarketplaceBot.Runs do
  import Ecto.Query
  alias MarketplaceBot.Repo
  alias MarketplaceBot.Runs.Run

  @spec record(map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs), do: %Run{} |> Run.changeset(attrs) |> Repo.insert()

  @spec list_recent(pos_integer()) :: [Run.t()]
  def list_recent(limit \\ 20),
    do: Repo.all(from r in Run, order_by: [desc: r.inserted_at], limit: ^limit)
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/marketplace_bot/runs_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add Runs context for daily-run history"
```

---

### Task 9: Telegram notifier

**Files:**
- Create: `lib/marketplace_bot/notifier/telegram.ex`
- Modify: `test/support/stubs.ex` (add `Notifier.Stub`)
- Test: `test/marketplace_bot/notifier/telegram_test.exs`

**Interfaces:**
- Produces:
  - `MarketplaceBot.Notifier.Behaviour` — `@callback send_digest(listings :: [Listing.t()], opts) :: {:ok, term()} | {:error, term()} | :noop`
  - `MarketplaceBot.Notifier.Telegram.build_digest(listings) :: String.t()` (pure)
  - `MarketplaceBot.Notifier.Telegram.send_digest(listings, opts)` (posts to Telegram `sendMessage`; `:noop` on empty).

- [ ] **Step 1: Failing test**

Create `test/marketplace_bot/notifier/telegram_test.exs`:

```elixir
defmodule MarketplaceBot.Notifier.TelegramTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.Notifier.Telegram
  alias MarketplaceBot.Listings.Listing

  defp listing(attrs),
    do: struct(Listing, Map.merge(%{id: 1, title: "Denon AVR-X3700H", city: "Victoria",
         price_cents: 45000, currency: "USD", earc_verdict: "yes", url: "https://fb/1"}, attrs))

  test "build_digest includes title, price, city, verdict tag, and web link" do
    text = Telegram.build_digest([listing(%{})], "http://localhost:4010")
    assert text =~ "Denon AVR-X3700H"
    assert text =~ "$450"
    assert text =~ "Victoria"
    assert text =~ "http://localhost:4010/listings/1"
  end

  test "unknown verdict is tagged unconfirmed" do
    text = Telegram.build_digest([listing(%{earc_verdict: "unknown"})], "http://x")
    assert text =~ "unconfirmed"
  end

  test "send_digest is :noop for empty input" do
    assert :noop = Telegram.send_digest([])
  end

  test "send_digest posts to Telegram" do
    Req.Test.stub(MarketplaceBot.Notifier.Telegram, fn conn ->
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert {:ok, _} =
             Telegram.send_digest([listing(%{})],
               token: "t", chat_id: "c",
               req_options: [plug: {Req.Test, MarketplaceBot.Notifier.Telegram}]
             )
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/marketplace_bot/notifier/telegram_test.exs`
Expected: FAIL — `Telegram` undefined.

- [ ] **Step 3: Implement notifier**

Create `lib/marketplace_bot/notifier/telegram.ex`:

```elixir
defmodule MarketplaceBot.Notifier.Behaviour do
  @callback send_digest(listings :: [struct()], opts :: keyword()) ::
              {:ok, term()} | {:error, term()} | :noop
end

defmodule MarketplaceBot.Notifier.Telegram do
  @moduledoc "Daily digest of new eARC matches via the Telegram Bot API."
  @behaviour MarketplaceBot.Notifier.Behaviour

  @impl true
  def send_digest(listings, opts \\ [])
  def send_digest([], _opts), do: :noop

  def send_digest(listings, opts) do
    token = opts[:token] || System.get_env("TELEGRAM_BOT_TOKEN")
    chat_id = opts[:chat_id] || System.get_env("TELEGRAM_CHAT_ID")
    base_url = opts[:web_base_url] || Application.get_env(:marketplace_bot, :web_base_url)

    body = %{
      chat_id: chat_id,
      text: build_digest(listings, base_url),
      parse_mode: "Markdown",
      disable_web_page_preview: true
    }

    req_opts =
      [
        method: :post,
        url: "https://api.telegram.org/bot#{token}/sendMessage",
        json: body,
        receive_timeout: 30_000
      ]
      |> Keyword.merge(opts[:req_options] || [])

    case Req.request(req_opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:telegram_http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec build_digest([struct()], String.t()) :: String.t()
  def build_digest(listings, base_url) do
    header = "*#{length(listings)} new eARC receiver match(es):*\n"

    items =
      Enum.map_join(listings, "\n\n", fn l ->
        tag = if l.earc_verdict == "unknown", do: " _(eARC unconfirmed)_", else: ""
        price = format_price(l.price_cents, l.currency)

        "• *#{l.title}*#{tag}\n#{price} — #{l.city}\n[View](#{base_url}/listings/#{l.id}) · [FB](#{l.url})"
      end)

    header <> "\n" <> items
  end

  defp format_price(nil, _), do: "price n/a"
  defp format_price(cents, currency) do
    sym = if currency in [nil, "USD"], do: "$", else: "#{currency} "
    "#{sym}#{div(cents, 100)}"
  end
end
```

- [ ] **Step 4: Add the `Notifier.Stub` referenced by `config/test.exs`**

Append to `test/support/stubs.ex`:

```elixir
defmodule MarketplaceBot.Notifier.Stub do
  @behaviour MarketplaceBot.Notifier.Behaviour
  @impl true
  def send_digest(_listings, _opts \\ []), do: {:ok, :stubbed}
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/marketplace_bot/notifier/telegram_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add Telegram notifier: build_digest + send_digest"
```

---

### Task 10: DailyScan Oban worker (the pipeline)

**Files:**
- Create: `lib/marketplace_bot/receivers.ex` (orchestrates prefilter → regex → LLM)
- Create: `lib/marketplace_bot/jobs/daily_scan.ex`
- Test: `test/marketplace_bot/receivers_test.exs`, `test/marketplace_bot/jobs/daily_scan_test.exs`

**Interfaces:**
- Consumes: `Listings`, `Receivers.Extractor`, `Receivers.LLM` (via config), `Earc`, `Notifier` (via config), `Runs`, `Sources.Source` (via config).
- Produces:
  - `MarketplaceBot.Receivers.classify_extract(listing :: map() | struct(), opts) :: {:ok, brand, model} | :skip`
  - `MarketplaceBot.Jobs.DailyScan` — an `Oban.Worker`; `perform(%Oban.Job{}) :: {:ok, %{...}}`.

- [ ] **Step 1: Failing test for `Receivers.classify_extract`**

Create `test/marketplace_bot/receivers_test.exs`:

```elixir
defmodule MarketplaceBot.ReceiversTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.Receivers

  defmodule AvLLM do
    @behaviour MarketplaceBot.Receivers.LLM.Behaviour
    @impl true
    def classify_extract(_l, _o \\ []), do: {:ok, %{is_av_receiver: true, brand: "Yamaha", model: "RX-A8A"}}
  end

  defmodule NotAvLLM do
    @behaviour MarketplaceBot.Receivers.LLM.Behaviour
    @impl true
    def classify_extract(_l, _o \\ []), do: {:ok, %{is_av_receiver: false, brand: nil, model: nil}}
  end

  test "negative keyword short-circuits to :skip" do
    assert :skip = Receivers.classify_extract(%{title: "trailer hitch receiver"}, llm: AvLLM)
  end

  test "regex fast-path returns brand/model without the LLM" do
    assert {:ok, "Denon", "AVR-X3700H"} =
             Receivers.classify_extract(%{title: "Denon AVR-X3700H"}, llm: NotAvLLM)
  end

  test "ambiguous listing uses the LLM (av → ok)" do
    assert {:ok, "Yamaha", "RX-A8A"} =
             Receivers.classify_extract(%{title: "Yamaha home theater amp"}, llm: AvLLM)
  end

  test "ambiguous listing uses the LLM (not av → skip)" do
    assert :skip = Receivers.classify_extract(%{title: "generic stereo box"}, llm: NotAvLLM)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/marketplace_bot/receivers_test.exs`
Expected: FAIL — `Receivers` undefined.

- [ ] **Step 3: Implement `Receivers`**

Create `lib/marketplace_bot/receivers.ex`:

```elixir
defmodule MarketplaceBot.Receivers do
  @moduledoc "Classify + extract: prefilter → regex fast-path → LLM fallback."
  alias MarketplaceBot.Receivers.Extractor

  @spec classify_extract(map() | struct(), keyword()) :: {:ok, String.t(), String.t()} | :skip
  def classify_extract(listing, opts \\ []) do
    title = field(listing, :title) || ""
    desc = field(listing, :description) || ""
    text = String.trim(title <> " " <> desc)

    cond do
      Extractor.likely_non_av?(text) ->
        :skip

      true ->
        case Extractor.extract(text) do
          {:ok, brand, model} -> {:ok, brand, model}
          :unknown -> via_llm(listing, opts)
        end
    end
  end

  defp via_llm(listing, opts) do
    llm = opts[:llm] || Application.get_env(:marketplace_bot, :receiver_llm)

    case llm.classify_extract(as_map(listing), opts) do
      {:ok, %{is_av_receiver: true, brand: brand, model: model}} -> {:ok, brand, model}
      _ -> :skip
    end
  end

  defp field(m, k) when is_map(m), do: Map.get(m, k) || Map.get(m, to_string(k))
  defp as_map(%_{} = s), do: Map.from_struct(s)
  defp as_map(m), do: m
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/marketplace_bot/receivers_test.exs`
Expected: PASS.

- [ ] **Step 5: Failing test for the DailyScan worker (end-to-end with fakes)**

Create `test/marketplace_bot/jobs/daily_scan_test.exs`:

```elixir
defmodule MarketplaceBot.Jobs.DailyScanTest do
  use MarketplaceBot.DataCase, async: false
  alias MarketplaceBot.Jobs.DailyScan
  alias MarketplaceBot.{Listings, Runs}

  # Capture digest calls
  defmodule CapNotifier do
    @behaviour MarketplaceBot.Notifier.Behaviour
    @impl true
    def send_digest(listings, _opts \\ []) do
      send(self(), {:digest, Enum.map(listings, & &1.fb_id)})
      {:ok, :ok}
    end
  end

  defmodule YesLLM do
    @behaviour MarketplaceBot.Earc.LLM.Behaviour
    @impl true
    def lookup(_b, _m, _o \\ []), do: {:ok, "yes"}
  end

  setup do
    listings = [
      %{fb_id: "a", title: "Denon AVR-X3700H 9.2", url: "u-a"},
      %{fb_id: "b", title: "Trailer hitch receiver", url: "u-b"},
      %{fb_id: "c", title: "Sony STR-DN1080", url: "u-c"}
    ]

    opts = [
      source: MarketplaceBot.Sources.Fake,
      source_opts: [listings: listings],
      earc_llm: YesLLM,
      notifier: CapNotifier
    ]

    %{opts: opts}
  end

  test "fetch → dedup → classify → resolve → notify → record", %{opts: opts} do
    assert {:ok, summary} = DailyScan.run(opts)

    # a (Denon) and c (Sony) are receivers; b (hitch) is filtered out
    assert summary.new == 3
    assert summary.matched == 2

    a = Repo.get_by!(Listings.Listing, fb_id: "a")
    assert a.is_receiver and a.earc_verdict == "yes" and a.notified_at != nil

    b = Repo.get_by!(Listings.Listing, fb_id: "b")
    refute b.is_receiver

    assert_received {:digest, ids}
    assert Enum.sort(ids) == ["a", "c"]

    assert [%{matched: 2, new: 3}] = Runs.list_recent(1)
  end

  test "second run with same listings notifies nobody new", %{opts: opts} do
    {:ok, _} = DailyScan.run(opts)
    assert {:ok, %{new: 0, matched: 0}} = DailyScan.run(opts)
  end
end
```

- [ ] **Step 6: Run to verify it fails**

Run: `mix test test/marketplace_bot/jobs/daily_scan_test.exs`
Expected: FAIL — `DailyScan` undefined.

- [ ] **Step 7: Implement the worker**

Create `lib/marketplace_bot/jobs/daily_scan.ex`:

```elixir
defmodule MarketplaceBot.Jobs.DailyScan do
  @moduledoc "Daily pipeline: fetch → dedup → classify/extract → eARC → digest → record."
  use Oban.Worker, queue: :default, max_attempts: 3

  alias MarketplaceBot.{Listings, Receivers, Earc, Runs}

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run([])

  @doc "Run the pipeline. `opts` lets tests inject source/llm/notifier; prod uses config."
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) do
    started = DateTime.utc_now() |> DateTime.truncate(:second)
    source = opts[:source] || Application.get_env(:marketplace_bot, :source)
    notifier = opts[:notifier] || Application.get_env(:marketplace_bot, :notifier)

    {:ok, raw} = source.fetch(opts[:source_opts] || [])
    {:ok, new} = Listings.upsert_new(raw)

    enriched = Enum.map(new, &enrich(&1, opts))
    matches = Enum.filter(enriched, &match?(&1))

    notifier.send_digest(matches, opts)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    for l <- matches, do: Listings.update_listing(l, %{notified_at: now})

    {:ok, run} =
      Runs.record(%{
        started_at: started,
        finished_at: now,
        fetched: length(raw),
        new: length(new),
        matched: length(matches),
        errors: %{}
      })

    {:ok, %{run_id: run.id, fetched: length(raw), new: length(new), matched: length(matches)}}
  end

  defp enrich(listing, opts) do
    case Receivers.classify_extract(listing, opts) do
      :skip ->
        {:ok, l} = Listings.update_listing(listing, %{is_receiver: false})
        l

      {:ok, brand, model} ->
        {:ok, m} = Earc.resolve_with_fallback(brand, model, opts)

        {:ok, l} =
          Listings.update_listing(listing, %{
            is_receiver: true,
            model_id: m.id,
            earc_verdict: m.verdict
          })

        l
    end
  end

  defp match?(l), do: l.is_receiver and l.earc_verdict in ["yes", "unknown"]
end
```

- [ ] **Step 8: Run to verify it passes**

Run: `mix test test/marketplace_bot/jobs/daily_scan_test.exs`
Expected: PASS.

- [ ] **Step 9: Run the full suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "Add Receivers orchestration + DailyScan Oban worker (full pipeline)"
```

---

### Task 11: LiveView index (browse matches)

**Files:**
- Create: `lib/marketplace_bot_web/live/listing_live/index.ex`
- Create: `lib/marketplace_bot_web/live/listing_live/index.html.heex`
- Modify: `lib/marketplace_bot_web/router.ex` (root route → index)
- Test: `test/marketplace_bot_web/live/listing_live/index_test.exs`

**Interfaces:**
- Consumes: `Listings.list_matches/1`.
- Produces: route `/` and `/listings` → `MarketplaceBotWeb.ListingLive.Index`; verdict/status filters via `handle_params`.

- [ ] **Step 1: Wire the route**

In `lib/marketplace_bot_web/router.ex`, inside the browser `scope "/"`, replace the generated `get "/", PageController, :home` with:

```elixir
live "/", ListingLive.Index, :index
live "/listings", ListingLive.Index, :index
live "/listings/:id", ListingLive.Show, :show
```

(`Show` is implemented in Task 12; the route can exist now — its test runs in Task 12.)

- [ ] **Step 2: Failing LiveView test**

Create `test/marketplace_bot_web/live/listing_live/index_test.exs`:

```elixir
defmodule MarketplaceBotWeb.ListingLive.IndexTest do
  use MarketplaceBotWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias MarketplaceBot.Listings

  setup do
    {:ok, [a]} = Listings.upsert_new([%{fb_id: "a", title: "Denon AVR-X3700H", url: "u"}])
    {:ok, _} = Listings.update_listing(a, %{is_receiver: true, earc_verdict: "yes", city: "Victoria"})
    {:ok, [b]} = Listings.upsert_new([%{fb_id: "b", title: "Yamaha RX-V685", url: "u2"}])
    {:ok, _} = Listings.update_listing(b, %{is_receiver: true, earc_verdict: "no", city: "Edna"})
    :ok
  end

  test "lists matches and filters by verdict", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Denon AVR-X3700H"
    assert html =~ "Yamaha RX-V685"

    html = view |> element("a", "eARC: yes") |> render_click()
    assert html =~ "Denon AVR-X3700H"
    refute html =~ "Yamaha RX-V685"
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mix test test/marketplace_bot_web/live/listing_live/index_test.exs`
Expected: FAIL — `ListingLive.Index` undefined.

- [ ] **Step 4: Implement the LiveView module**

Create `lib/marketplace_bot_web/live/listing_live/index.ex`:

```elixir
defmodule MarketplaceBotWeb.ListingLive.Index do
  use MarketplaceBotWeb, :live_view
  alias MarketplaceBot.Listings

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{verdict: params["verdict"]}
    {:noreply, assign(socket, listings: Listings.list_matches(filters), verdict: params["verdict"])}
  end
end
```

- [ ] **Step 5: Implement the template**

Create `lib/marketplace_bot_web/live/listing_live/index.html.heex`:

```heex
<div class="mx-auto max-w-5xl p-4">
  <h1 class="text-2xl font-semibold mb-4">AV Receiver Matches</h1>

  <div class="flex gap-3 mb-6 text-sm">
    <.link patch={~p"/listings"} class="underline">all</.link>
    <.link patch={~p"/listings?verdict=yes"} class="underline">eARC: yes</.link>
    <.link patch={~p"/listings?verdict=unknown"} class="underline">eARC: unconfirmed</.link>
  </div>

  <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
    <.link :for={l <- @listings} navigate={~p"/listings/#{l.id}"} class="block border rounded-lg overflow-hidden hover:shadow">
      <img :if={l.images != [] and l.images != nil} src={hd(l.images)} class="w-full h-40 object-cover" />
      <div class="p-3">
        <div class="font-medium"><%= l.title %></div>
        <div class="text-sm text-gray-600"><%= price(l) %> · <%= l.city %></div>
        <span class={"inline-block mt-2 text-xs px-2 py-0.5 rounded #{badge(l.earc_verdict)}"}>
          <%= verdict_label(l.earc_verdict) %>
        </span>
      </div>
    </.link>
  </div>

  <p :if={@listings == []} class="text-gray-500">No matches yet.</p>
</div>
```

Add the small view helpers at the bottom of `index.ex` (inside the module):

```elixir
  defp price(%{price_cents: nil}), do: "price n/a"
  defp price(%{price_cents: c}), do: "$#{div(c, 100)}"
  defp verdict_label("yes"), do: "eARC: yes"
  defp verdict_label("unknown"), do: "eARC: unconfirmed"
  defp verdict_label(v), do: "eARC: #{v}"
  defp badge("yes"), do: "bg-green-100 text-green-800"
  defp badge("unknown"), do: "bg-yellow-100 text-yellow-800"
  defp badge(_), do: "bg-gray-100 text-gray-700"
```

- [ ] **Step 6: Run to verify it passes**

Run: `mix test test/marketplace_bot_web/live/listing_live/index_test.exs`
Expected: PASS. (If the filter link assertion is brittle, switch the test to `render_patch(view, ~p"/listings?verdict=yes")` and assert on the resulting HTML.)

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Add ListingLive.Index: browse matches with verdict filter"
```

---

### Task 12: LiveView show + curate actions

**Files:**
- Create: `lib/marketplace_bot_web/live/listing_live/show.ex`, `show.html.heex`
- Modify: `lib/marketplace_bot/earc.ex` (add `get_model/1` if needed for re-resolve)
- Test: `test/marketplace_bot_web/live/listing_live/show_test.exs`

**Interfaces:**
- Consumes: `Listings.get_listing!/1`, `Listings.set_status/2`, `Listings.update_listing/2`, `Earc.set_user_verdict/2`, `Earc.resolve_with_fallback/3`, `Receivers.classify_extract/2`.
- Produces: detail page with photo gallery, inline eARC correction (`correct_verdict`), model override (`override_model`), and status buttons (`set_status`).

- [ ] **Step 1: Failing test**

Create `test/marketplace_bot_web/live/listing_live/show_test.exs`:

```elixir
defmodule MarketplaceBotWeb.ListingLive.ShowTest do
  use MarketplaceBotWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias MarketplaceBot.{Listings, Earc}

  setup do
    {:ok, m} = Earc.upsert_model("Denon", "AVR-X3700H", %{verdict: "unknown", source: "llm"})
    {:ok, [l]} = Listings.upsert_new([%{fb_id: "a", title: "Denon AVR-X3700H", url: "u",
                  images: ["http://img/1.jpg"], description: "nice"}])
    {:ok, l} = Listings.update_listing(l, %{is_receiver: true, earc_verdict: "unknown", model_id: m.id})
    %{listing: l, model: m}
  end

  test "renders detail with photos and FB link", %{conn: conn, listing: l} do
    {:ok, _view, html} = live(conn, ~p"/listings/#{l.id}")
    assert html =~ "Denon AVR-X3700H"
    assert html =~ "http://img/1.jpg"
    assert html =~ "nice"
  end

  test "correcting the verdict writes a user verdict", %{conn: conn, listing: l, model: m} do
    {:ok, view, _html} = live(conn, ~p"/listings/#{l.id}")
    view |> element("button[phx-value-verdict=yes]") |> render_click()
    assert Earc.find_by_key(m.key).source == "user"
    assert Earc.find_by_key(m.key).verdict == "yes"
    assert Listings.get_listing!(l.id).earc_verdict == "yes"
  end

  test "status buttons update the listing", %{conn: conn, listing: l} do
    {:ok, view, _html} = live(conn, ~p"/listings/#{l.id}")
    view |> element("button[phx-value-status=interested]") |> render_click()
    assert Listings.get_listing!(l.id).status == "interested"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/marketplace_bot_web/live/listing_live/show_test.exs`
Expected: FAIL — `ListingLive.Show` undefined.

- [ ] **Step 3: Implement the LiveView module**

Create `lib/marketplace_bot_web/live/listing_live/show.ex`:

```elixir
defmodule MarketplaceBotWeb.ListingLive.Show do
  use MarketplaceBotWeb, :live_view
  alias MarketplaceBot.{Listings, Earc, Receivers}
  alias MarketplaceBot.Earc.Model
  alias MarketplaceBot.Repo

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, assign_listing(socket, id)}
  end

  @impl true
  def handle_event("set_status", %{"status" => status}, socket) do
    {:ok, l} = Listings.set_status(socket.assigns.listing, status)
    {:noreply, assign(socket, listing: l)}
  end

  def handle_event("correct_verdict", %{"verdict" => verdict}, socket) do
    l = socket.assigns.listing

    if l.model_id do
      model = Repo.get!(Model, l.model_id)
      {:ok, _} = Earc.set_user_verdict(model, verdict)
      {:ok, l} = Listings.update_listing(l, %{earc_verdict: verdict})
      {:noreply, assign(socket, listing: l, model: Repo.get(Model, l.model_id))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("override_model", %{"brand" => brand, "model" => model}, socket) do
    {:ok, m} = Earc.resolve_with_fallback(brand, model)
    {:ok, l} = Listings.update_listing(socket.assigns.listing, %{model_id: m.id, earc_verdict: m.verdict})
    {:noreply, assign(socket, listing: l, model: m)}
  end

  defp assign_listing(socket, id) do
    l = Listings.get_listing!(id)
    model = if l.model_id, do: Repo.get(Model, l.model_id), else: nil
    assign(socket, listing: l, model: model)
  end
end
```

- [ ] **Step 4: Implement the template**

Create `lib/marketplace_bot_web/live/listing_live/show.html.heex`:

```heex
<div class="mx-auto max-w-3xl p-4">
  <.link navigate={~p"/listings"} class="text-sm underline">← back</.link>
  <h1 class="text-2xl font-semibold mt-2 mb-1"><%= @listing.title %></h1>
  <div class="text-gray-600 mb-4">
    <%= if @listing.price_cents, do: "$#{div(@listing.price_cents, 100)}", else: "price n/a" %>
    · <%= @listing.city %>, <%= @listing.state %>
  </div>

  <div class="grid grid-cols-2 gap-2 mb-4">
    <img :for={src <- @listing.images || []} src={src} class="w-full rounded" />
  </div>

  <p class="whitespace-pre-line mb-4"><%= @listing.description %></p>

  <a href={@listing.url} target="_blank" class="inline-block mb-6 underline">View on Facebook ↗</a>

  <div class="border-t pt-4 space-y-4">
    <div>
      <div class="text-sm font-medium mb-1">
        eARC: <%= @listing.earc_verdict %>
        <span :if={@model}>· model <%= @model.brand %> <%= @model.model %> (<%= @model.source %>)</span>
      </div>
      <div class="flex gap-2">
        <button phx-click="correct_verdict" phx-value-verdict="yes"
          class="px-2 py-1 text-sm border rounded">eARC yes</button>
        <button phx-click="correct_verdict" phx-value-verdict="no"
          class="px-2 py-1 text-sm border rounded">eARC no</button>
        <button phx-click="correct_verdict" phx-value-verdict="unknown"
          class="px-2 py-1 text-sm border rounded">unknown</button>
      </div>
    </div>

    <form phx-submit="override_model" class="flex gap-2 items-end">
      <div>
        <label class="block text-xs">brand</label>
        <input name="brand" class="border rounded px-2 py-1 text-sm" />
      </div>
      <div>
        <label class="block text-xs">model</label>
        <input name="model" class="border rounded px-2 py-1 text-sm" />
      </div>
      <button class="px-2 py-1 text-sm border rounded">override + re-resolve</button>
    </form>

    <div class="flex gap-2">
      <button :for={s <- ~w(interested dismissed contacted)} phx-click="set_status" phx-value-status={s}
        class={"px-2 py-1 text-sm border rounded #{if @listing.status == s, do: "bg-gray-200"}"}>
        <%= s %>
      </button>
    </div>
  </div>
</div>
```

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/marketplace_bot_web/live/listing_live/show_test.exs`
Expected: PASS.

- [ ] **Step 6: Run the full suite + compile with warnings as errors**

```bash
mix compile --warnings-as-errors
mix test
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Add ListingLive.Show: photos, inline eARC correction, model override, status"
```

---

### Task 13: Seed, real-run probe, docs, and tuning

**Files:**
- Modify: `CLAUDE.md` (record local port, run instructions)
- Create: `.env` entries (locally only — never commit)
- No new code unless the probe reveals a JSON-shape mismatch.

**Interfaces:** none new — this task validates against reality (spec §"open items").

- [ ] **Step 1: Ensure `.env` is populated locally and loaded**

Confirm `.env` has `APIFY_TOKEN`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `DEEPSEEK_API_KEY`, `KAGI_API_KEY`. Load it into the shell before running (e.g. `set -a; source .env; set +a`). Confirm `config/runtime.exs` reads these via `System.get_env/1` for prod; for local `mix` runs the modules read env directly. **Verify on this first real call:** DeepSeek base URL + model IDs + JSON-mode behavior, and the Kagi FastGPT response shape (`data.output`); reconcile the client modules + their tests if anything differs.

- [ ] **Step 2: Seed the eARC table**

```bash
mix run priv/repo/seeds.exs
```

- [ ] **Step 3: Probe the real Apify actor (volume + JSON shape + radius)**

```bash
set -a; source .env; set +a
mix run -e '
  {:ok, items} = MarketplaceBot.Sources.Apify.fetch(max_listings: 50)
  IO.puts("fetched: #{length(items)}")
  IO.inspect(Enum.take(items, 2), label: "sample normalized")
'
```
Verify: items come back; `title`/`description`/`images`/`city` populate; cities are within ~60 mi of Ganado. **If field names differ from `apify_item.json`, update `Apify.normalize/1` and the fixture together, re-run Task 3's test.** Note the real count to set `:daily` `max_listings` in `config/config.exs`.

- [ ] **Step 4: Run the pipeline end-to-end once (real services)**

```bash
set -a; source .env; set +a
mix run -e 'IO.inspect(MarketplaceBot.Jobs.DailyScan.run([]))'
```
Verify: a Telegram digest arrives; `runs` has a row; matches show `is_receiver: true` and a verdict. Confirm the Kagi FastGPT call returns research and `deepseek-v4-pro` yields a clean `yes`/`no`/`unknown` (adjust the verdict prompt or JSON parsing if DeepSeek wraps the JSON in prose).

- [ ] **Step 5: Start the web app and click through**

```bash
set -a; source .env; set +a
mix phx.server
# visit http://localhost:4010 — browse matches, open a detail page, correct a verdict, set status
```

- [ ] **Step 6: Update `CLAUDE.md`**

Record under a "Run / deploy" section: local port **4010**; `set -a; source .env; set +a` then `mix phx.server`; daily scan via Oban cron (13:00 UTC) or manual `mix run -e 'MarketplaceBot.Jobs.DailyScan.run([])'`; the tuned `max_listings` values; and that the public route (Cloudflare Tunnel + Zero Trust to `marketplace-bot.example.com` → `<host-ip>:4010`) is handed to your ops process when moving to unraid.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Tune search config from real Apify probe; document run/port in CLAUDE.md"
```

---

## Deferred (post-v1, not in this plan)

Per the spec §14: full control panel (edit search config + trigger runs from the UI), local image caching, vision-model back-panel model reading, multi-region search management, and the unraid Docker deploy (`Dockerfile` + `deploy.sh` + Compose Manager, with your ops process wiring the tunnel/Access). Tackle these as separate spec→plan cycles when the user wants them.
