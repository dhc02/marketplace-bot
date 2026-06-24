defmodule MarketplaceBot.Listings do
  @moduledoc "Core listing domain: dedup, queries, status."
  import Ecto.Query
  alias MarketplaceBot.Repo
  alias MarketplaceBot.Listings.Listing
  alias MarketplaceBot.Geo

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

    {:ok, inserted} =
      Repo.transaction(fn ->
        for m <- new_maps do
          attrs = Map.put(normalize_keys(m), "first_seen_at", now)
          {:ok, listing} = %Listing{} |> Listing.changeset(attrs) |> Repo.insert()
          listing
        end
      end)

    {:ok, inserted}
  end

  defp normalize_keys(m) do
    Map.new(m, fn {k, v} -> {to_string(k), v} end)
  end

  @spec update_listing(Listing.t(), map()) :: {:ok, Listing.t()} | {:error, Ecto.Changeset.t()}
  def update_listing(%Listing{} = listing, attrs),
    do: listing |> Listing.changeset(attrs) |> Repo.update()

  @spec set_status(Listing.t(), String.t()) :: {:ok, Listing.t()} | {:error, Ecto.Changeset.t()}
  def set_status(%Listing{} = listing, status), do: update_listing(listing, %{status: status})

  @spec get_listing!(term()) :: Listing.t()
  def get_listing!(id), do: Repo.get!(Listing, id) |> with_distance()

  @spec list_matches(map()) :: [Listing.t()]
  def list_matches(filters \\ %{}) do
    Listing
    |> where([l], l.is_receiver == true)
    |> filter_verdict(filters[:verdict])
    |> filter_status(filters[:status])
    |> order_by([l], desc: l.first_seen_at)
    |> Repo.all()
    |> Enum.map(&with_distance/1)
    |> Enum.sort_by(&(&1.distance_mi || 1.0e9))
  end

  defp filter_verdict(q, nil), do: q
  defp filter_verdict(q, v), do: where(q, [l], l.earc_verdict == ^v)
  defp filter_status(q, nil), do: where(q, [l], l.status != "dismissed")
  defp filter_status(q, s), do: where(q, [l], l.status == ^s)

  defp with_distance(%Listing{} = listing) do
    %{listing | distance_mi: Geo.distance_mi(listing.lat, listing.lng)}
  end
end
