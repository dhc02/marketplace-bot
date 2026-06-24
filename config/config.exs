# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :marketplace_bot,
  ecto_repos: [MarketplaceBot.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :marketplace_bot, MarketplaceBotWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MarketplaceBotWeb.ErrorHTML, json: MarketplaceBotWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: MarketplaceBot.PubSub,
  live_view: [signing_salt: "0PtOWokT"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  marketplace_bot: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  marketplace_bot: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

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
  location_ids: ["113243215352508"],
  brands: ["denon", "marantz", "yamaha", "onkyo", "pioneer", "sony", "anthem", "nad", "integra", "arcam", "harman kardon"],
  extra_queries: ["av receiver", "home theater receiver"],
  max_price: 500,
  max_listings: [initial: 1000, daily: 250],
  reference: %{name: "El Campo", lat: 29.1966, lng: -96.2697}

# LLM / research providers. Model strings are user-chosen — keep verbatim.
config :marketplace_bot, :llm,
  deepseek_base_url: "https://api.deepseek.com/v1",
  classify_model: "deepseek-v4-flash",
  earc_model: "deepseek-v4-pro",
  kagi_fastgpt_url: "https://kagi.com/api/v0/fastgpt",
  gemini_base_url: "https://generativelanguage.googleapis.com/v1beta",
  gemini_vision_model: "gemini-2.5-flash-lite",
  vision_max_images: 8

# Swappable implementations (overridden in test)
config :marketplace_bot,
  source: MarketplaceBot.Sources.Apify,
  receiver_llm: MarketplaceBot.Receivers.LLM,
  earc_llm: MarketplaceBot.Earc.LLM,
  notifier: MarketplaceBot.Notifier.Telegram,
  vision: MarketplaceBot.Vision.Gemini,
  web_base_url: "http://localhost:4010"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
