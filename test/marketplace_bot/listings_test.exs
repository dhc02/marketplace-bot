defmodule MarketplaceBot.ListingsTest do
  use MarketplaceBot.DataCase, async: false
  alias MarketplaceBot.Listings
  alias MarketplaceBot.Listings.Listing

  defp map(fb_id, attrs \\ %{}) do
    Map.merge(%{fb_id: fb_id, title: "Listing #{fb_id}", url: "u#{fb_id}"}, attrs)
  end

  test "upsert_new inserts unseen listings and returns them" do
    assert {:ok, [a, b]} = Listings.upsert_new([map("1"), map("2")])
    assert a.fb_id == "1" and b.fb_id == "2"
    assert a.first_seen_at != nil
  end

  test "upsert_new skips already-seen fb_ids" do
    {:ok, _} = Listings.upsert_new([map("1")])
    assert {:ok, [new]} = Listings.upsert_new([map("1"), map("2")])
    assert new.fb_id == "2"
    assert Repo.aggregate(Listing, :count) == 2
  end

  test "update_listing and set_status" do
    {:ok, [l]} = Listings.upsert_new([map("1")])
    {:ok, l} = Listings.update_listing(l, %{earc_verdict: "yes"})
    assert l.earc_verdict == "yes"
    {:ok, l} = Listings.set_status(l, "interested")
    assert l.status == "interested"
  end

  test "list_matches returns receiver listings, filtered by verdict" do
    {:ok, [l]} = Listings.upsert_new([map("1")])
    {:ok, _} = Listings.update_listing(l, %{is_receiver: true, earc_verdict: "yes"})
    assert [%Listing{fb_id: "1"}] = Listings.list_matches(%{verdict: "yes"})
    assert [] = Listings.list_matches(%{verdict: "no"})
  end

  test "list_matches sorts by distance to El Campo and populates distance_mi" do
    # near El Campo
    {:ok, [near]} = Listings.upsert_new([map("near", %{lat: 29.2, lng: -96.27})])
    {:ok, _} = Listings.update_listing(near, %{is_receiver: true})
    # far from El Campo (near Houston)
    {:ok, [far]} = Listings.upsert_new([map("far", %{lat: 29.76, lng: -95.37})])
    {:ok, _} = Listings.update_listing(far, %{is_receiver: true})

    [first, second] = Listings.list_matches(%{})

    assert first.fb_id == "near"
    assert second.fb_id == "far"
    assert first.distance_mi != nil
    assert second.distance_mi != nil
    assert first.distance_mi < second.distance_mi
  end

  test "get_listing! populates distance_mi virtual field" do
    {:ok, [l]} = Listings.upsert_new([map("x", %{lat: 29.2, lng: -96.27})])
    fetched = Listings.get_listing!(l.id)
    assert fetched.distance_mi != nil
  end
end
