defmodule MarketplaceBot.GeoTest do
  use ExUnit.Case, async: true
  alias MarketplaceBot.Geo

  test "distance from El Campo to itself is approximately 0" do
    ref = %{lat: 29.1966, lng: -96.2697}
    assert Geo.distance_mi(29.1966, -96.2697, ref) <= 1.0
  end

  test "distance from El Campo to Houston is roughly 60-90 miles" do
    # Houston coords: 29.7604, -95.3698
    ref = %{lat: 29.1966, lng: -96.2697}
    dist = Geo.distance_mi(29.7604, -95.3698, ref)
    assert dist >= 60 and dist <= 90
  end

  test "distance_mi returns nil when coords are missing" do
    assert Geo.distance_mi(nil, nil) == nil
  end
end
