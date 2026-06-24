defmodule MarketplaceBot.Vision do
  @moduledoc "Behaviour: extract a receiver's brand/model from listing photos."
  @callback extract_model(image_urls :: [String.t()], opts :: keyword()) ::
              {:ok, %{brand: String.t() | nil, model: String.t() | nil}} | {:error, term()}
end
