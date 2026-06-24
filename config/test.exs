import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :marketplace_bot, MarketplaceBot.Repo,
  database: Path.expand("../marketplace_bot_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :marketplace_bot, MarketplaceBotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "B3vc4H8pW38jqEPHrHTuzN6GvFJ8+cA3D7nCik0MCSHrxprRYm4JqhZt8dEWoDbf",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :marketplace_bot, Oban, testing: :manual

config :marketplace_bot,
  source: MarketplaceBot.Sources.Fake,
  receiver_llm: MarketplaceBot.Receivers.LLMStub,
  earc_llm: MarketplaceBot.Earc.LLMStub,
  notifier: MarketplaceBot.Notifier.Stub,
  vision: MarketplaceBot.Vision.Stub
