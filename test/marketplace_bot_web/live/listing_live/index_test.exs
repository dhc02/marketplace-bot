defmodule MarketplaceBotWeb.ListingLive.IndexTest do
  use MarketplaceBotWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias MarketplaceBot.Listings

  setup do
    {:ok, [a]} = Listings.upsert_new([%{fb_id: "a", title: "Denon AVR-X3700H", url: "u"}])
    {:ok, _} = Listings.update_listing(a, %{is_receiver: true, earc_verdict: "yes", city: "Victoria"})
    {:ok, [b]} = Listings.upsert_new([%{fb_id: "b", title: "Yamaha RX-V685", url: "u2"}])
    {:ok, _} = Listings.update_listing(b, %{is_receiver: true, earc_verdict: "no", city: "Edna"})
    :ok
  end

  test "lists matches and filters by verdict", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Denon AVR-X3700H"
    assert html =~ "Yamaha RX-V685"

    html = render_patch(view, ~p"/listings?verdict=yes")
    assert html =~ "Denon AVR-X3700H"
    refute html =~ "Yamaha RX-V685"
  end
end
