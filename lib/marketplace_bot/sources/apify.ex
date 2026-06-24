defmodule MarketplaceBot.Sources.Apify do
  @moduledoc """
  Fetches Marketplace listings via the Apify actor
  `calm_builder/facebook-marketplace-scraper` (run-sync-get-dataset-items).
  Swappable behind `MarketplaceBot.Sources.Source`.
  """
  @behaviour MarketplaceBot.Sources.Source

  @actor "calm_builder~facebook-marketplace-scraper"
  @endpoint "https://api.apify.com/v2/acts/#{@actor}/run-sync-get-dataset-items"

  @doc "FB Marketplace search URLs — one per (location_id × query), where query = brands ++ extra_queries."
  def build_search_urls(search) do
    locations = search[:location_ids] || []
    queries = (search[:brands] || []) ++ (search[:extra_queries] || [])
    max_price = search[:max_price] || 500
    for loc <- locations, q <- queries do
      "https://www.facebook.com/marketplace/#{loc}/search?query=#{URI.encode_www_form(q)}&exact=false&maxPrice=#{max_price}"
    end
  end

  @impl true
  def fetch(opts \\ []) do
    token = opts[:token] || System.get_env("APIFY_TOKEN")
    search = Application.get_env(:marketplace_bot, :search, [])
    max_listings = opts[:max_listings] || get_in(search, [:max_listings, :daily]) || 250
    start_urls = opts[:start_urls] || build_search_urls(search)

    body = %{
      startUrls: Enum.map(start_urls, &(%{url: &1})),
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
      {:ok, %{status: status, body: items}} when status in [200, 201] and is_list(items) ->
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
