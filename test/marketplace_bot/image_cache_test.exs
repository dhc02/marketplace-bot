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

  alias MarketplaceBot.Listings.Listing
  alias MarketplaceBot.Repo

  defp tmp_dir do
    d = Path.join(System.tmp_dir!(), "imgcache-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(d) end)
    d
  end

  defp insert_listing(images) do
    {:ok, l} = %Listing{} |> Listing.changeset(%{fb_id: "img#{System.unique_integer([:positive])}", images: images}) |> Repo.insert()
    l
  end

  describe "fetch/3" do
    setup do
      # ImageCacheTest uses the Repo, so wrap in the sandbox like DataCase does.
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      :ok
    end

    test "cache miss downloads, writes the file, returns path/type, and persists dims" do
      png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", 40::32, 20::32, 0::40>>
      l = insert_listing(["https://scontent.fbcdn.net/a.jpg"])
      dir = tmp_dir()

      Req.Test.stub(MarketplaceBot.ImageCache, fn conn -> Req.Test.text(conn, png) end)

      assert {:ok, path, "image/png"} =
               ImageCache.fetch(l, 0, cache_dir: dir, req_options: [plug: {Req.Test, MarketplaceBot.ImageCache}])

      assert File.exists?(path)
      assert Repo.get!(Listing, l.id).image_dims == %{"0" => %{"w" => 40, "h" => 20}}
    end

    test "cache hit does not re-download" do
      l = insert_listing(["https://scontent.fbcdn.net/a.jpg"])
      dir = tmp_dir()
      png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", 1::32, 1::32, 0::40>>
      Req.Test.stub(MarketplaceBot.ImageCache, fn conn -> Req.Test.text(conn, png) end)
      {:ok, path1, _} = ImageCache.fetch(l, 0, cache_dir: dir, req_options: [plug: {Req.Test, MarketplaceBot.ImageCache}])

      # Second call with a plug that would raise if hit:
      Req.Test.stub(MarketplaceBot.ImageCache, fn _ -> raise "should not download on cache hit" end)
      assert {:ok, ^path1, "image/png"} = ImageCache.fetch(l, 0, cache_dir: dir, req_options: [plug: {Req.Test, MarketplaceBot.ImageCache}])
    end

    test "missing image index returns error" do
      l = insert_listing([])
      assert {:error, :no_image} = ImageCache.fetch(l, 0, cache_dir: tmp_dir())
    end

    test "failed download returns error (no raise)" do
      l = insert_listing(["https://scontent.fbcdn.net/a.jpg"])
      Req.Test.stub(MarketplaceBot.ImageCache, fn conn -> Plug.Conn.send_resp(conn, 403, "nope") end)
      assert {:error, _} = ImageCache.fetch(l, 0, cache_dir: tmp_dir(), req_options: [plug: {Req.Test, MarketplaceBot.ImageCache}])
    end
  end
end
