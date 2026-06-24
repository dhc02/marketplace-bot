defmodule MarketplaceBot.Geo do
  @moduledoc "Great-circle distance helpers, anchored to a configured reference point."
  @earth_radius_mi 3958.8

  @doc "Reference point from :search config (defaults to El Campo, TX)."
  def reference do
    Application.get_env(:marketplace_bot, :search, [])[:reference] ||
      %{name: "El Campo", lat: 29.1966, lng: -96.2697}
  end

  @doc "Distance in miles from (lat, lng) to `ref`; nil if coords are missing."
  def distance_mi(lat, lng, ref \\ reference())

  def distance_mi(lat, lng, %{lat: rlat, lng: rlng})
      when is_number(lat) and is_number(lng) and is_number(rlat) and is_number(rlng) do
    rad = fn d -> d * :math.pi() / 180 end
    dlat = rad.(rlat - lat)
    dlng = rad.(rlng - lng)
    a = :math.pow(:math.sin(dlat / 2), 2) +
          :math.cos(rad.(lat)) * :math.cos(rad.(rlat)) * :math.pow(:math.sin(dlng / 2), 2)
    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    Float.round(@earth_radius_mi * c, 1)
  end

  def distance_mi(_lat, _lng, _ref), do: nil
end
