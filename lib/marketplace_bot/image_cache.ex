defmodule MarketplaceBot.ImageCache do
  @moduledoc """
  Cache-on-first-view for listing images. Downloads a listing's FB-CDN image
  the first time it's requested, stores it under the cache dir, records its
  pixel dimensions, and serves the local copy thereafter.
  """

  alias MarketplaceBot.Listings

  @exts %{"image/png" => "png", "image/jpeg" => "jpg", "image/webp" => "webp"}

  @spec fetch(MarketplaceBot.Listings.Listing.t(), non_neg_integer(), keyword()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def fetch(listing, index, opts \\ []) do
    dir = opts[:cache_dir] || Application.get_env(:marketplace_bot, :image_cache_dir, "data/image_cache")

    case Enum.at(listing.images || [], index) do
      nil ->
        {:error, :no_image}

      url ->
        case existing(dir, listing.fb_id, index) do
          {:ok, _, _} = hit -> hit
          :miss -> download_and_cache(listing, index, url, dir, opts)
        end
    end
  end

  defp existing(dir, fb_id, index) do
    case Path.wildcard(Path.join(dir, "#{fb_id}-#{index}.*")) do
      [path | _] -> {:ok, path, ct_from_ext(path)}
      [] -> :miss
    end
  end

  defp download_and_cache(listing, index, url, dir, opts) do
    req = Keyword.merge([method: :get, url: url, headers: [{"user-agent", "Mozilla/5.0"}], receive_timeout: 30_000], opts[:req_options] || [])

    with {:ok, %{status: 200, body: bin}} when is_binary(bin) <- Req.request(req),
         ct when is_binary(ct) <- content_type(bin) do
      File.mkdir_p!(dir)
      ext = Map.get(@exts, ct, "img")
      path = Path.join(dir, "#{listing.fb_id}-#{index}.#{ext}")
      File.write!(path, bin)

      case dimensions(bin) do
        %{w: w, h: h} -> Listings.put_image_dim(listing, index, %{"w" => w, "h" => h})
        nil -> :ok
      end

      {:ok, path, ct}
    else
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_an_image}
      other -> {:error, other}
    end
  end

  defp ct_from_ext(path) do
    case Path.extname(path) do
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end
  end

  @doc "Detect content-type from magic bytes. nil if unrecognized."
  @spec content_type(binary) :: String.t() | nil
  def content_type(<<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>>), do: "image/png"
  def content_type(<<0xFF, 0xD8, _::binary>>), do: "image/jpeg"
  def content_type(<<"RIFF", _::32, "WEBP", _::binary>>), do: "image/webp"
  def content_type(_), do: nil

  @doc "Pixel dimensions of a JPEG/PNG binary, or nil for unknown formats."
  @spec dimensions(binary) :: %{w: pos_integer, h: pos_integer} | nil
  def dimensions(<<0x89, "PNG\r\n", 0x1A, 0x0A, _len::32, "IHDR", w::32, h::32, _::binary>>),
    do: %{w: w, h: h}

  def dimensions(<<0xFF, 0xD8, rest::binary>>), do: jpeg_dims(rest)
  def dimensions(_), do: nil

  # Walk JPEG segments until a Start-Of-Frame marker (carries height/width).
  defp jpeg_dims(<<0xFF, 0xFF, rest::binary>>), do: jpeg_dims(<<0xFF, rest::binary>>)

  defp jpeg_dims(<<0xFF, marker, len::16, rest::binary>>) do
    cond do
      marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC] ->
        case rest do
          <<_precision::8, height::16, width::16, _::binary>> -> %{w: width, h: height}
          _ -> nil
        end

      true ->
        skip = len - 2

        if skip >= 0 and byte_size(rest) >= skip do
          jpeg_dims(binary_part(rest, skip, byte_size(rest) - skip))
        else
          nil
        end
    end
  end

  defp jpeg_dims(_), do: nil
end
