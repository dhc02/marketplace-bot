defmodule MarketplaceBot.Repo do
  use Ecto.Repo,
    otp_app: :marketplace_bot,
    adapter: Ecto.Adapters.SQLite3
end
