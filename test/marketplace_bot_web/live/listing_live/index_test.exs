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

  test "status filter shows only that status; default hides dismissed", %{conn: conn} do
    ins = fn fb, status -> {:ok, _} = %MarketplaceBot.Listings.Listing{} |> MarketplaceBot.Listings.Listing.changeset(%{fb_id: fb, title: fb, is_receiver: true, earc_verdict: "yes", status: status}) |> MarketplaceBot.Repo.insert() end
    ins.("keep", "interested")
    ins.("gone", "dismissed")

    {:ok, _lv, html} = live(conn, ~p"/listings?status=interested")
    assert html =~ "keep"
    refute html =~ "gone"

    {:ok, _lv, html2} = live(conn, ~p"/listings")
    refute html2 =~ "gone"

    # filter rendered as buttons with an active one
    assert html =~ "btn"
  end
end
