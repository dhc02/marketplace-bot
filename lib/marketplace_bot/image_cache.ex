defmodule MarketplaceBot.ImageCache do
  @moduledoc """
  Cache-on-first-view for listing images. Downloads a listing's FB-CDN image
  the first time it's requested, stores it under the cache dir, records its
  pixel dimensions, and serves the local copy thereafter.
  """

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
        <<_precision::8, height::16, width::16, _::binary>> = rest
        %{w: width, h: height}

      true ->
        skip = len - 2

        if byte_size(rest) >= skip do
          next = binary_part(rest, skip, byte_size(rest) - skip)
          jpeg_dims(next)
        else
          nil
        end
    end
  end

  defp jpeg_dims(_), do: nil
end
