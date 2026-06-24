defmodule MarketplaceBotWeb.ImageControllerTest do
  use MarketplaceBotWeb.ConnCase, async: false
  alias MarketplaceBot.Listings.Listing
  alias MarketplaceBot.Repo

  setup do
    dir = Path.join(System.tmp_dir!(), "imgctrl-#{System.unique_integer([:positive])}")
    prev = Application.get_env(:marketplace_bot, :image_cache_dir)
    Application.put_env(:marketplace_bot, :image_cache_dir, dir)
    on_exit(fn -> File.rm_rf(dir); Application.put_env(:marketplace_bot, :image_cache_dir, prev) end)
    {:ok, l} = %Listing{} |> Listing.changeset(%{fb_id: "ctrl1", images: ["https://scontent.fbcdn.net/a.jpg"]}) |> Repo.insert()
    %{listing: l}
  end

  test "serves cached image bytes with content-type", %{conn: conn, listing: l} do
    png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", 2::32, 2::32, 0::40>>
    Req.Test.stub(MarketplaceBot.ImageCache, fn c -> Req.Test.text(c, png) end)

    conn = get(conn, ~p"/img/#{l.fb_id}/0")
    assert conn.status == 200
    assert response_content_type(conn, :png)
  end

  test "404 for unknown fb_id", %{conn: conn} do
    assert get(conn, ~p"/img/nope/0").status == 404
  end

  test "404 for out-of-range index", %{conn: conn, listing: l} do
    assert get(conn, ~p"/img/#{l.fb_id}/9").status == 404
  end
end
