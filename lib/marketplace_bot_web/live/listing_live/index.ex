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

  defp price(%{price_cents: nil}), do: "price n/a"
  defp price(%{price_cents: c}), do: "$#{div(c, 100)}"
  defp dist_label(%{distance_mi: nil}), do: ""
  defp dist_label(%{distance_mi: d}), do: " · #{d} mi from El Campo"
  defp verdict_label("yes"), do: "eARC: yes"
  defp verdict_label("unknown"), do: "eARC: unconfirmed"
  defp verdict_label(v), do: "eARC: #{v}"
  defp badge("yes"), do: "bg-green-100 text-green-800"
  defp badge("unknown"), do: "bg-yellow-100 text-yellow-800"
  defp badge(_), do: "bg-gray-100 text-gray-700"
end
