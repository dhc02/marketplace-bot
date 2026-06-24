defmodule MarketplaceBotWeb.ListingLive.Show do
  use MarketplaceBotWeb, :live_view
  alias MarketplaceBot.{Listings, Earc}
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
      {:ok, model} = Earc.set_user_verdict(model, verdict)
      {:ok, l} = Listings.update_listing(l, %{earc_verdict: verdict})
      {:noreply, assign(socket, listing: l, model: model)}
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
