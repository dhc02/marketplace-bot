defmodule MarketplaceBot.Vision.Gemini do
  @moduledoc """
  Reads a receiver's brand/model from listing photos using Gemini generateContent.
  Downloads each image, base64-inlines them into one multi-image request, and
  parses a JSON {brand, model}. Endpoint/model are env-overridable.
  """
  @behaviour MarketplaceBot.Vision

  @prompt "These are photos from a Facebook Marketplace listing of a home-theater A/V receiver. " <>
            "Read any brand and model number/name printed on the unit (front fascia or rear panel). " <>
            ~s(Respond with ONLY a JSON object: {"brand": string or null, "model": string or null}.)

  @impl true
  def extract_model(image_urls, opts \\ []) do
    cfg = Application.get_env(:marketplace_bot, :llm, [])
    api_key = opts[:api_key] || System.get_env("GEMINI_API_KEY")

    base =
      opts[:base_url] || System.get_env("GEMINI_BASE_URL") || cfg[:gemini_base_url] ||
        "https://generativelanguage.googleapis.com/v1beta"

    model =
      opts[:model] || System.get_env("GEMINI_VISION_MODEL") || cfg[:gemini_vision_model] ||
        "gemini-2.5-flash-lite"

    max_images = opts[:max_images] || cfg[:vision_max_images] || 8

    image_parts =
      image_urls
      |> Enum.take(max_images)
      |> Enum.map(&download_inline(&1, opts))
      |> Enum.reject(&is_nil/1)

    if image_parts == [] do
      {:error, :no_images}
    else
      body = %{
        contents: [%{parts: [%{text: @prompt} | image_parts]}],
        generationConfig: %{response_mime_type: "application/json"}
      }

      req_opts =
        [
          method: :post,
          url: "#{base}/models/#{model}:generateContent",
          headers: [{"x-goog-api-key", api_key}],
          json: body,
          receive_timeout: opts[:receive_timeout] || 120_000
        ]
        |> Keyword.merge(opts[:req_options] || [])

      with {:ok, %{status: 200, body: resp}} <- Req.request(req_opts),
           text when is_binary(text) <- first_text(resp),
           {:ok, parsed} <- Jason.decode(text) do
        {:ok, %{brand: parsed["brand"], model: parsed["model"]}}
      else
        {:ok, %{status: status, body: body}} -> {:error, {:gemini_http, status, body}}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  end

  defp download_inline(url, opts) do
    dl_opts =
      [method: :get, url: url, headers: [{"user-agent", "Mozilla/5.0"}], receive_timeout: 30_000]
      |> Keyword.merge(opts[:req_options] || [])

    case Req.request(dl_opts) do
      {:ok, %{status: 200, body: bin}} when is_binary(bin) ->
        %{inline_data: %{mime_type: "image/jpeg", data: Base.encode64(bin)}}

      _ ->
        nil
    end
  end

  defp first_text(%{"candidates" => [%{"content" => %{"parts" => [%{"text" => t} | _]}} | _]})
       when is_binary(t),
       do: t

  defp first_text(_), do: nil
end
