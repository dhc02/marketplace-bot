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
