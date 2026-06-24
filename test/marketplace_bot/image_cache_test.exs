defmodule MarketplaceBot.ImageCacheTest do
  use ExUnit.Case, async: false
  alias MarketplaceBot.ImageCache

  # PNG header: 8-byte sig + IHDR length + "IHDR" + width::32 + height::32
  defp png(w, h), do: <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", w::32, h::32, 0::40>>
  # JPEG: SOI + SOF0 (len 17, precision 8, height::16, width::16, ...)
  defp jpeg(w, h), do: <<0xFF, 0xD8, 0xFF, 0xC0, 0, 17, 8, h::16, w::16, 0::80>>

  test "reads PNG dimensions" do
    assert ImageCache.dimensions(png(120, 60)) == %{w: 120, h: 60}
  end

  test "reads JPEG dimensions (skips APP0 segment first)" do
    app0 = <<0xFF, 0xE0, 0, 4, 0, 0>>
    assert ImageCache.dimensions(<<0xFF, 0xD8>> <> app0 <> <<0xFF, 0xC0, 0, 17, 8, 60::16, 120::16, 0::80>>) == %{w: 120, h: 60}
  end

  test "unknown format returns nil" do
    assert ImageCache.dimensions(<<0, 1, 2, 3, 4>>) == nil
  end

  test "content_type detects png/jpeg, nil otherwise" do
    assert ImageCache.content_type(png(1, 1)) == "image/png"
    assert ImageCache.content_type(jpeg(1, 1)) == "image/jpeg"
    assert ImageCache.content_type(<<0, 1, 2>>) == nil
  end
end
