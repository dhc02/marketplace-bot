defmodule MarketplaceBotWeb.ImageController do
  use MarketplaceBotWeb, :controller
  alias MarketplaceBot.{ImageCache, Repo}
  alias MarketplaceBot.Listings.Listing

  def show(conn, %{"fb_id" => fb_id, "index" => index_str}) do
    with {index, ""} <- Integer.parse(index_str),
         true <- index >= 0,
         %Listing{} = listing <- Repo.get_by(Listing, fb_id: fb_id),
         {:ok, path, content_type} <- ImageCache.fetch(listing, index, req_options: req_options(conn)) do
      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_file(200, path)
    else
      _ -> conn |> put_status(404) |> text("not found")
    end
  end

  # In tests, a Req.Test plug is configured app-wide (Step 3a); in dev/prod this is [].
  defp req_options(_conn), do: Application.get_env(:marketplace_bot, :image_req_options, [])
end
