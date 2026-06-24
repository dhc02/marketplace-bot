defmodule MarketplaceBot.Sources.Fake do
  @moduledoc "Test/dev source that returns listings handed to it via opts."
  @behaviour MarketplaceBot.Sources.Source

  @impl true
  def fetch(opts), do: {:ok, Keyword.get(opts, :listings, [])}
end
