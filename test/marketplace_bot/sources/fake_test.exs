defmodule MarketplaceBot.Sources.FakeTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.Sources.Fake

  test "returns the listings passed via opts" do
    listings = [%{fb_id: "1", title: "Denon AVR-X3700H"}]
    assert {:ok, ^listings} = Fake.fetch(listings: listings)
  end

  test "defaults to an empty list" do
    assert {:ok, []} = Fake.fetch([])
  end
end
