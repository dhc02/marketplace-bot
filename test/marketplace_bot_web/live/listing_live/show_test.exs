defmodule MarketplaceBotWeb.ListingLive.ShowTest do
  use MarketplaceBotWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias MarketplaceBot.{Listings, Earc}

  setup do
    {:ok, m} = Earc.upsert_model("Denon", "AVR-X3700H", %{verdict: "unknown", source: "llm"})
    {:ok, [l]} = Listings.upsert_new([%{fb_id: "a", title: "Denon AVR-X3700H", url: "u",
                  images: ["http://img/1.jpg"], description: "nice"}])
    {:ok, l} = Listings.update_listing(l, %{is_receiver: true, earc_verdict: "unknown", model_id: m.id})
    %{listing: l, model: m}
  end

  test "renders detail with photos and FB link", %{conn: conn, listing: l} do
    {:ok, _view, html} = live(conn, ~p"/listings/#{l.id}")
    assert html =~ "Denon AVR-X3700H"
    assert html =~ ~s(src="/img/#{l.fb_id}/0")
    assert html =~ "nice"
  end

  test "correcting the verdict writes a user verdict", %{conn: conn, listing: l, model: m} do
    {:ok, view, _html} = live(conn, ~p"/listings/#{l.id}")
    view |> element("button[phx-value-verdict=yes]") |> render_click()
    assert Earc.find_by_key(m.key).source == "user"
    assert Earc.find_by_key(m.key).verdict == "yes"
    assert Listings.get_listing!(l.id).earc_verdict == "yes"
  end

  test "status buttons update the listing", %{conn: conn, listing: l} do
    {:ok, view, _html} = live(conn, ~p"/listings/#{l.id}")
    view |> element("button[phx-value-status=interested]") |> render_click()
    assert Listings.get_listing!(l.id).status == "interested"
  end

  test "curate panel renders before the image gallery and override has a loading state", %{conn: conn} do
    {:ok, l} = %MarketplaceBot.Listings.Listing{} |> MarketplaceBot.Listings.Listing.changeset(%{fb_id: "show1", title: "T", images: ["https://scontent.fbcdn.net/a.jpg"]}) |> MarketplaceBot.Repo.insert()
    {:ok, _lv, html} = live(conn, ~p"/listings/#{l.id}")

    # override + status controls appear before the gallery's cache-route <img>
    {panel_pos, _} = :binary.match(html, "override + re-resolve")
    {img_pos, _} = :binary.match(html, "/img/show1/0")
    assert panel_pos < img_pos

    assert html =~ "phx-disable-with"
    assert html =~ ~s(src="/img/show1/0")
  end
end
