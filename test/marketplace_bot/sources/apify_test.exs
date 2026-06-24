defmodule MarketplaceBot.Sources.ApifyTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.Sources.Apify

  setup do
    item =
      File.read!("test/support/fixtures/apify_item.json") |> Jason.decode!()

    %{item: item}
  end

  test "normalize maps actor JSON to the internal listing map", %{item: item} do
    n = Apify.normalize(item)
    assert n.fb_id == "987654321"
    assert n.title =~ "Denon"
    assert n.price_cents == 45_000
    assert n.currency == "USD"
    assert n.city == "Victoria"
    assert n.state == "TX"
    assert n.images == ["https://scontent.example/a.jpg", "https://scontent.example/b.jpg"]
    assert %DateTime{} = n.fb_created_at
    assert n.is_live == true
  end

  test "normalize tolerates missing fields" do
    n = Apify.normalize(%{"id" => "1"})
    assert n.fb_id == "1"
    assert n.price_cents == nil
    assert n.images == []
  end

  test "fetch calls the actor endpoint and returns normalized listings", %{item: item} do
    Req.Test.stub(MarketplaceBot.Sources.Apify, fn conn ->
      # Apify run-sync-get-dataset-items returns 201 (not 200) on success
      conn |> Plug.Conn.put_status(201) |> Req.Test.json([item])
    end)

    assert {:ok, [listing]} =
             Apify.fetch(
               token: "t",
               req_options: [plug: {Req.Test, MarketplaceBot.Sources.Apify}]
             )

    assert listing.fb_id == "987654321"
  end

  describe "build_search_urls/1" do
    test "returns one URL per (location_id x query)" do
      search = [
        location_ids: ["113243215352508"],
        brands: ["denon", "marantz"],
        extra_queries: ["av receiver"],
        max_price: 500
      ]

      urls = Apify.build_search_urls(search)
      # 1 location × (2 brands + 1 extra_query) = 3 URLs
      assert length(urls) == 3
    end

    test "URL contains location id, query=denon, and maxPrice=500" do
      search = [
        location_ids: ["113243215352508"],
        brands: ["denon"],
        extra_queries: [],
        max_price: 500
      ]

      [url] = Apify.build_search_urls(search)
      assert url =~ "113243215352508"
      assert url =~ "query=denon"
      assert url =~ "maxPrice=500"
    end

    test "multi-word query is www-form-encoded" do
      search = [
        location_ids: ["113243215352508"],
        brands: [],
        extra_queries: ["av receiver"],
        max_price: 500
      ]

      [url] = Apify.build_search_urls(search)
      # URI.encode_www_form encodes space as +
      assert url =~ "av+receiver" or url =~ "av%20receiver"
    end
  end
end
